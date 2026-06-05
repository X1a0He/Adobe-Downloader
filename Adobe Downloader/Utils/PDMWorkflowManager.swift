//
//  PDMWorkflowManager.swift
//  Adobe Downloader
//

import Foundation

enum PDMState: Int, CaseIterable, CustomStringConvertible {
    case downloadPackageManifest = 0    // State 0: 下载 manifest.xml
    case parseAssetManifest = 1         // State 1: 解析 manifest
    case downloadAssetValidation = 2    // State 2: 下载 validation.xml
    case parseAssetValidation = 3       // State 3: 解析 validation
    case checkDownloadedBits = 4        // State 4: 检查已下载部分
    case startOverlappedExtraction = 5  // State 5: 开始边下载边解压
    case downloadAssetBits = 6          // State 6: 下载资产文件
    case closeOverlappedExtraction = 7  // State 7: 关闭交叉解压
    case assetSignatureValidation = 8   // State 8: 签名验证（官方IDA核验）
    case executeAsset = 9               // State 9: 执行资产（官方IDA核验）
    case workflowCompletion = 10        // State 10: 完成

    var description: String {
        switch self {
        case .downloadPackageManifest: return "DOWNLOAD_PACKAGE_MANIFEST"
        case .parseAssetManifest: return "PARSE_ASSET_MANIFEST"
        case .downloadAssetValidation: return "DOWNLOAD_ASSET_VALIDATION"
        case .parseAssetValidation: return "PARSE_ASSET_VALIDATION"
        case .checkDownloadedBits: return "CHECK_DOWNLOADED_ASSET_BITS"
        case .startOverlappedExtraction: return "START_OVERLAPPED_EXTRACTION"
        case .downloadAssetBits: return "DOWNLOAD_ASSET_BITS"
        case .closeOverlappedExtraction: return "CLOSE_OVERLAPPED_EXTRACTION"
        case .assetSignatureValidation: return "ASSET_SIGNATURE_VALIDATION"
        case .executeAsset: return "EXECUTE_ASSET"
        case .workflowCompletion: return "PDM_WORKFLOW_COMPLETION"
        }
    }
}

enum FileDownloaderState: Int {
    case preDownload = 0
    case preparing = 1
    case ready = 2
    case downloading = 3
    case progress = 4
    case error = 7
    case fatalError = 8
    case completed = 9
}

struct AssetGlobalData {
    var manifestURL: String = ""
    var tempDirectory: URL
    var manifestPath: String = ""
    var downloadURL: String = ""
    var validationURL: String = ""
    var validationURLs: [String] = []
    var inlineValidationData: String = ""
    var downloadFileName: String = ""
    var downloadFileHash: String = ""
    var totalSize: Int64 = 0
}

struct PDMError: Error, LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? { "PDM Error \(code): \(message)" }

    static let manifestDownloadFailed = PDMError(code: 113, message: "Manifest file could not be downloaded")
    static let manifestParseFailed = PDMError(code: 107, message: "Failed to parse asset manifest")
    static let validationDownloadFailed = PDMError(code: 113, message: "Validation file could not be downloaded")
    static let assetDownloadFailed = PDMError(code: 119, message: "Asset download failed")
    static let signatureValidationFailed = PDMError(code: 134, message: "Signature validation failed")
    static let assetExecutionFailed = PDMError(code: 119, message: "Asset execution failed")
}

private enum PDMManifestAssetType: String {
    case zip = "ZIP"
    case dmg = "DMG"
    case binary = "BINARY"

    init?(_ rawValue: String) {
        self.init(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

private enum PDMManifestValidationSource {
    case relativeURL
    case type2URL
    case type1URL
    case validationDataURL
}

private struct PDMManifestValidationPath {
    let value: String
    let source: PDMManifestValidationSource
}

private struct PDMManifestXMLDocument {
    private let document: XMLDocument

    init(element: XMLElement) throws {
        self.document = try XMLDocument(data: Data(element.xmlString.utf8))
    }

    func firstString(_ xpath: String) throws -> String? {
        let value = try document.nodes(forXPath: xpath)
            .first?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func elements(_ xpath: String) throws -> [XMLElement] {
        try document.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }
}

private struct PDMManifestAction {
    let name: String
    let type: String
    let sequenceNumber: Int
    let actionData: [String: String]
    let rawXML: String

    var isExtract: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "extract"
    }

    var isSupported: Bool {
        isExtract && sequenceNumber > 0
    }

    init?(element: XMLElement) throws {
        let xml = try PDMManifestXMLDocument(element: element)

        self.name = try xml.firstString("//action/name") ?? ""
        self.type = try xml.firstString("//action/type") ?? ""
        self.sequenceNumber = Int(try xml.firstString("//action/sequence_no") ?? "") ?? 0
        self.actionData = try Self.actionData(from: xml)
        self.rawXML = element.xmlString

        guard !name.isEmpty else {
            return nil
        }
    }

    private static func firstString(_ element: XMLElement, xpaths: [String]) throws -> String? {
        for xpath in xpaths {
            let value = try element.nodes(forXPath: xpath)
                .first?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func actionData(from xml: PDMManifestXMLDocument) throws -> [String: String] {
        let dataNodes = try xml.elements("//action/action_data/data")
        var result: [String: String] = [:]

        for dataElement in dataNodes {
            let key = try firstString(dataElement, xpaths: ["key", ".//key"])
                ?? dataElement.attribute(forName: "key")?.stringValue
                ?? ""
            let value = try firstString(dataElement, xpaths: ["value", ".//value"])
                ?? dataElement.attribute(forName: "value")?.stringValue
                ?? ""
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedKey.isEmpty {
                result[normalizedKey] = normalizedValue
            }
        }

        return result
    }

    private static func uniqueElements(_ element: XMLElement, xpaths: [String]) throws -> [XMLElement] {
        var result: [XMLElement] = []
        var seen = Set<String>()

        for xpath in xpaths {
            for node in try element.nodes(forXPath: xpath) {
                guard let actionElement = node as? XMLElement else {
                    continue
                }

                let key = actionElement.xmlString
                guard seen.insert(key).inserted else {
                    continue
                }
                result.append(actionElement)
            }
        }

        return result
    }
}

private struct PDMManifestAsset {
    let type: PDMManifestAssetType
    let rawXML: String
    let assetRelativePath: String
    let assetPath: String
    let inlineValidationData: String
    let validationDataRelativeURL: String
    let validationType2URL: String
    let validationType1URL: String
    let validationDataURL: String
    let sequenceNumber: Int
    let assetSize: Int64
    let actions: [PDMManifestAction]

    var downloadPath: String {
        if !assetRelativePath.isEmpty {
            return assetRelativePath
        }
        return assetPath
    }

    var validationPaths: [PDMManifestValidationPath] {
        if !validationDataRelativeURL.isEmpty {
            return [PDMManifestValidationPath(value: validationDataRelativeURL, source: .relativeURL)]
        }
        if !validationType2URL.isEmpty {
            return [PDMManifestValidationPath(value: validationType2URL, source: .type2URL)]
        }
        if !validationType1URL.isEmpty {
            return [PDMManifestValidationPath(value: validationType1URL, source: .type1URL)]
        }
        if !validationDataURL.isEmpty {
            return [PDMManifestValidationPath(value: validationDataURL, source: .validationDataURL)]
        }
        return []
    }

    var shouldStartOverlappedExtraction: Bool {
        type == .zip && actions.contains { $0.isExtract }
    }

    var downloadFileName: String {
        let path = downloadPath
        if let url = URL(string: path), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "asset_\(sequenceNumber)" : name
    }

    init?(element: XMLElement) throws {
        let xml = try PDMManifestXMLDocument(element: element)
        let rawType = try xml.firstString("//asset/asset_type") ?? ""

        guard let type = PDMManifestAssetType(rawType) else {
            return nil
        }

        self.type = type
        self.rawXML = element.xmlString
        self.assetRelativePath = try xml.firstString("//asset/asset_rel_path") ?? ""
        self.assetPath = Self.sanitizedAssetPath(try xml.firstString("//asset/asset_path") ?? "")
        self.inlineValidationData = try xml.firstString("//asset/validation_data_string") ?? ""
        self.validationDataRelativeURL = try xml.firstString("//asset/validation_data_rel_url") ?? ""
        self.validationType2URL = try xml.firstString("/asset/validation_urls/type2") ?? ""
        self.validationType1URL = try xml.firstString("/asset/validation_urls/type1") ?? ""
        self.validationDataURL = try xml.firstString("//asset/validation_data") ?? ""
        self.sequenceNumber = Int(try xml.firstString("//asset/sequence_no") ?? "") ?? 0
        self.assetSize = Int64(try xml.firstString("//asset/asset_size") ?? "") ?? 0

        let actionNodes = try xml.elements("//asset/actions/action")
        var parsedActions: [PDMManifestAction] = []
        for actionElement in actionNodes {
            guard let action = try PDMManifestAction(element: actionElement), action.isSupported else {
                return nil
            }
            parsedActions.append(action)
        }
        self.actions = parsedActions.sorted { $0.sequenceNumber < $1.sequenceNumber }

        guard sequenceNumber > 0,
              assetSize > 0,
              !downloadPath.isEmpty,
              !inlineValidationData.isEmpty || !validationPaths.isEmpty else {
            return nil
        }
    }

    private static func firstString(_ element: XMLElement, xpaths: [String]) throws -> String? {
        for xpath in xpaths {
            let value = try element.nodes(forXPath: xpath)
                .first?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func uniqueElements(_ element: XMLElement, xpaths: [String]) throws -> [XMLElement] {
        var result: [XMLElement] = []
        var seen = Set<String>()

        for xpath in xpaths {
            for node in try element.nodes(forXPath: xpath) {
                guard let actionElement = node as? XMLElement else {
                    continue
                }

                let key = actionElement.xmlString
                guard seen.insert(key).inserted else {
                    continue
                }
                result.append(actionElement)
            }
        }

        return result
    }

    private static func sanitizedAssetPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.contains("ccmdl.adobe.com"), !result.contains("https") {
            result = result.replacingOccurrences(of: "http", with: "https")
            result = result.replacingOccurrences(of: "ccmdl", with: "ccmdls")
        } else if result.contains("stage-ffc-files.corp.adobe.com"), !result.contains("https") {
            result = result.replacingOccurrences(of: "http", with: "https")
        }
        return result
    }
}

class PDMWorkflowManager {

    private var currentState: PDMState = .downloadPackageManifest
    private var globalData: AssetGlobalData
    private var validationInfo: ValidationInfo?
    private var isRunning = false
    private var overlappedExtractor: HDPIMOverlappedZipExtractor?
    private var overlappedExtractionTask: Task<HDPIMExtractionResult, Error>?
    private var overlappedExtractionResult: HDPIMExtractionResult?
    private var packageIdentifier: String?
    private var assets: [PDMManifestAsset] = []
    private var currentAsset: PDMManifestAsset?
    private var downloadedAssetURL: URL?
    private var executedAssetURL: URL?
    private static let defaultValidationServiceBaseURL = "https://cdn-ffc.oobesaas.adobe.com/core/v1/validation"
    private let validationServiceBaseURL: String

    var progressHandler: ((PDMState, Double) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?
    var cancellationCheck: (() async -> Bool)?

    private var destinationURL: URL?

    init(
        tempDirectory: URL,
        validationServiceBaseURL: String = PDMWorkflowManager.defaultValidationServiceBaseURL
    ) {
        let trimmedValidationServiceBaseURL = validationServiceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.validationServiceBaseURL = trimmedValidationServiceBaseURL.isEmpty
            ? PDMWorkflowManager.defaultValidationServiceBaseURL
            : trimmedValidationServiceBaseURL
        self.globalData = AssetGlobalData(tempDirectory: tempDirectory)
    }

    func execute(
        manifestURL: String,
        cdnBaseURL: String,
        headers: [String: String],
        destinationDirectory: URL,
        packageIdentifier: String? = nil,
        progressHandler: ((PDMState, Double) -> Void)? = nil,
        cancellationCheck: (() async -> Bool)? = nil
    ) async throws -> URL {
        self.progressHandler = progressHandler
        self.cancellationCheck = cancellationCheck
        self.globalData.manifestURL = manifestURL
        self.packageIdentifier = packageIdentifier
        self.isRunning = true
        self.currentState = .downloadPackageManifest
        self.validationInfo = nil
        self.assets = []
        self.currentAsset = nil
        self.downloadedAssetURL = nil
        self.executedAssetURL = nil
        self.destinationURL = nil

        while currentState != .workflowCompletion && isRunning {
            if let check = cancellationCheck, await check() {
                throw NetworkError.cancelled
            }

            try await executeState(cdnBaseURL: cdnBaseURL, headers: headers, destinationDirectory: destinationDirectory)
        }

        guard let destination = destinationURL else {
            throw PDMError(code: 107, message: "Download completed but no destination file")
        }

        return destination
    }

    private func executeState(cdnBaseURL: String, headers: [String: String], destinationDirectory: URL) async throws {
        switch currentState {

        case .downloadPackageManifest:
            try await handlePackageManifestDownload(headers: headers)

        case .parseAssetManifest:
            try await handleAssetManifestParsing(cdnBaseURL: cdnBaseURL)

        case .downloadAssetValidation:
            try await handleAssetValidationDownload(headers: headers)

        case .parseAssetValidation:
            try await handleAssetValidationParsing()

        case .checkDownloadedBits:
            try await handleCheckDownloadedBits(destinationDirectory: destinationDirectory)

        case .startOverlappedExtraction:
            try await handleStartOverlappedExtraction(destinationDirectory: destinationDirectory)

        case .downloadAssetBits:
            try await handleAssetBitsDownload(headers: headers, destinationDirectory: destinationDirectory)

        case .closeOverlappedExtraction:
            try await handleCloseOverlappedExtraction()

        case .assetSignatureValidation:
            try await handleAssetSignatureValidation()

        case .executeAsset:
            try await handleExecutionOfAsset(destinationDirectory: destinationDirectory)

        case .workflowCompletion:
            break
        }
    }

    private func handlePackageManifestDownload(headers: [String: String]) async throws {
        guard !globalData.manifestURL.isEmpty else {
            await moveToNextState()
            return
        }

        guard let url = URL(string: globalData.manifestURL) else {
            throw PDMError.manifestDownloadFailed
        }

        progressHandler?(.downloadPackageManifest, 0)

        let manifestFile = globalData.tempDirectory.appendingPathComponent("manifest.xml")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.downloadTimeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PDMError.manifestDownloadFailed
        }

        try data.write(to: manifestFile)
        globalData.manifestPath = manifestFile.path

        progressHandler?(.downloadPackageManifest, 1.0)

        await moveToNextState()
    }

    private func handleAssetManifestParsing(cdnBaseURL: String) async throws {
        progressHandler?(.parseAssetManifest, 0)

        let manifestFile = URL(fileURLWithPath: globalData.manifestPath)

        guard FileManager.default.fileExists(atPath: manifestFile.path) else {
            await moveToNextState()
            return
        }

        let manifestData = try Data(contentsOf: manifestFile)
        let xmlDoc = try XMLDocument(data: manifestData)

        let version = try firstXMLString(xmlDoc, xpaths: ["//manifest/version"])
        guard version != nil else {
            throw PDMError.manifestParseFailed
        }

        assets = []
        for assetElement in try manifestAssetElements(from: xmlDoc) {
            guard let asset = try PDMManifestAsset(element: assetElement) else {
                throw PDMError.manifestParseFailed
            }
            assets.append(asset)
        }

        guard let asset = assets.last else {
            throw PDMError.manifestParseFailed
        }

        currentAsset = asset
        globalData.downloadURL = resolvedManifestURL(asset.downloadPath, cdnBaseURL: cdnBaseURL)
        globalData.inlineValidationData = asset.inlineValidationData
        globalData.validationURLs = []
        for validationPath in asset.validationPaths {
            appendValidationURL(validationPath, cdnBaseURL: cdnBaseURL)
        }
        globalData.validationURL = globalData.validationURLs.first ?? ""
        globalData.totalSize = asset.assetSize
        globalData.downloadFileName = asset.downloadFileName

        progressHandler?(.parseAssetManifest, 1.0)
        await moveToNextState()
    }

    private func resolvedManifestURL(_ path: String, cdnBaseURL: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return ""
        }

        guard URL(string: trimmedPath)?.scheme == nil else {
            return trimmedPath
        }

        let cleanCdn = cdnBaseURL.hasSuffix("/") ? String(cdnBaseURL.dropLast()) : cdnBaseURL
        let cleanPath = trimmedPath.hasPrefix("/") ? trimmedPath : "/\(trimmedPath)"
        return cleanCdn + cleanPath
    }

    private func firstXMLString(_ xmlDoc: XMLDocument, xpaths: [String]) throws -> String? {
        for xpath in xpaths {
            let value = try xmlDoc.nodes(forXPath: xpath)
                .first?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func manifestAssetElements(from xmlDoc: XMLDocument) throws -> [XMLElement] {
        try xmlDoc.nodes(forXPath: "//manifest/asset_list/asset").compactMap { $0 as? XMLElement }
    }

    private func appendValidationURL(_ path: PDMManifestValidationPath, cdnBaseURL: String) {
        let resolvedURL = resolvedManifestValidationURL(path, cdnBaseURL: cdnBaseURL)
        let candidates = [resolvedURL]
            + validationServiceFallbackURLs(for: resolvedURL)
            + validationServiceFallbackURLs(for: path.value)

        for candidate in candidates where !candidate.isEmpty {
            if !globalData.validationURLs.contains(candidate) {
                globalData.validationURLs.append(candidate)
            }
        }
    }

    private func resolvedManifestValidationURL(_ path: PDMManifestValidationPath, cdnBaseURL: String) -> String {
        switch path.source {
        case .relativeURL:
            return resolvedManifestURL(path.value, cdnBaseURL: cdnBaseURL)
        case .type2URL, .type1URL, .validationDataURL:
            return path.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func validationServiceFallbackURLs(for value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let fileName: String
        if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
            fileName = url.lastPathComponent
        } else {
            fileName = URL(fileURLWithPath: trimmed).lastPathComponent
        }

        guard !fileName.isEmpty else {
            return []
        }

        let cleanBaseURL = validationServiceBaseURL.hasSuffix("/") ? String(validationServiceBaseURL.dropLast()) : validationServiceBaseURL
        return ["\(cleanBaseURL)/\(fileName)"]
    }

    private func handleAssetValidationDownload(headers: [String: String]) async throws {
        let validationFile = globalData.tempDirectory.appendingPathComponent("validation.xml")

        if !globalData.inlineValidationData.isEmpty {
            try globalData.inlineValidationData.write(to: validationFile, atomically: true, encoding: .utf8)
            progressHandler?(.downloadAssetValidation, 1.0)
            await moveToNextState()
            return
        }

        guard !globalData.validationURLs.isEmpty else {
            await moveToNextState()
            return
        }

        progressHandler?(.downloadAssetValidation, 0)

        for validationURL in globalData.validationURLs {
            guard let url = URL(string: validationURL) else {
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = NetworkConstants.downloadTimeout
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty else {
                continue
            }

            try data.write(to: validationFile)

            progressHandler?(.downloadAssetValidation, 1.0)
            await moveToNextState()
            return
        }

        throw PDMError.validationDownloadFailed
    }

    private func handleAssetValidationParsing() async throws {
        progressHandler?(.parseAssetValidation, 0)

        let validationFile = globalData.tempDirectory.appendingPathComponent("validation.xml")

        if FileManager.default.fileExists(atPath: validationFile.path),
           let xmlString = try? String(contentsOf: validationFile, encoding: .utf8) {
            validationInfo = ValidationInfo.parse(from: xmlString)

            if globalData.downloadFileName.isEmpty, let info = validationInfo {
                globalData.downloadFileName = "asset_\(info.packageHashKey.prefix(8)).zip"
            }

            if let info = validationInfo {
                let totalSize = validationTotalSize(info)
                if globalData.totalSize <= 0 {
                    globalData.totalSize = totalSize
                } else if totalSize > 0, totalSize != globalData.totalSize {
                    throw PDMError(code: 107, message: "Validation size does not match asset size")
                }
            }
        }

        progressHandler?(.parseAssetValidation, 1.0)
        await moveToNextState()
    }

    private func validationTotalSize(_ info: ValidationInfo) -> Int64 {
        let lastSegmentSize = info.lastSegmentSize > 0 ? info.lastSegmentSize : info.segmentSize
        return Int64(max(0, info.segmentCount - 1)) * info.segmentSize + lastSegmentSize
    }

    private func handleCheckDownloadedBits(destinationDirectory: URL) async throws {
        progressHandler?(.checkDownloadedBits, 0)

        if !globalData.downloadFileName.isEmpty {
            let filePath = destinationDirectory.appendingPathComponent(globalData.downloadFileName)
            destinationURL = filePath

            if FileManager.default.fileExists(atPath: filePath.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path)
                let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

                if existingSize == globalData.totalSize && globalData.totalSize > 0 {
                    progressHandler?(.checkDownloadedBits, 1.0)
                    downloadedAssetURL = filePath
                    currentState = .assetSignatureValidation
                    return
                }
            }
        }

        progressHandler?(.checkDownloadedBits, 1.0)
        await moveToNextState()
    }

    private func handleStartOverlappedExtraction(destinationDirectory: URL) async throws {
        progressHandler?(.startOverlappedExtraction, 0)

        guard currentAsset?.shouldStartOverlappedExtraction == true,
              !globalData.downloadURL.isEmpty,
              let url = URL(string: globalData.downloadURL) else {
            await moveToNextState()
            return
        }

        let fileName = globalData.downloadFileName.isEmpty ? url.lastPathComponent : globalData.downloadFileName
        guard currentAsset?.type == .zip, fileName.lowercased().hasSuffix(".zip") else {
            await moveToNextState()
            return
        }
        let assetURL = destinationDirectory.appendingPathComponent(fileName)
        let extractRoot = globalData.tempDirectory
            .appendingPathComponent("PDMExtract-\(UUID().uuidString)", isDirectory: true)

        let extractor = HDPIMOverlappedZipExtractor()
        overlappedExtractor = extractor
        overlappedExtractionTask = Task {
            try await extractor.startExtraction(
                request: HDPIMExtractionRequest(
                    sourceURL: assetURL,
                    destinationURL: extractRoot,
                    compressionType: "",
                    packageName: fileName,
                    validationURL: globalData.validationURL.isEmpty ? nil : globalData.validationURL,
                    isDMG: false,
                    allowOverlap: true
                ),
                progressHandler: { [weak self] progress in
                    self?.progressHandler?(.startOverlappedExtraction, progress)
                },
                cancellationCheck: { [weak self] in
                    !(self?.isRunning ?? false)
                }
            )
        }

        progressHandler?(.startOverlappedExtraction, 1.0)
        await moveToNextState()
    }

    private func handleAssetBitsDownload(headers: [String: String], destinationDirectory: URL) async throws {
        guard !globalData.downloadURL.isEmpty else {
            throw PDMError.assetDownloadFailed
        }

        guard let url = URL(string: globalData.downloadURL) else {
            throw PDMError.assetDownloadFailed
        }

        let fileName = globalData.downloadFileName.isEmpty ? url.lastPathComponent : globalData.downloadFileName
        let filePath = destinationDirectory.appendingPathComponent(fileName)
        destinationURL = filePath
        downloadedAssetURL = filePath

        progressHandler?(.downloadAssetBits, 0)

        let effectivePackageIdentifier = packageIdentifier ?? "PDM_\(fileName)"

        let result = await PDMDownloadEngine.shared.downloadFile(
            packageId: effectivePackageIdentifier,
            url: url,
            destinationURL: filePath,
            headers: headers,
            expectedTotalSize: globalData.totalSize,
            validationURL: globalData.validationURL.isEmpty ? nil : globalData.validationURL,
            validationURLs: globalData.validationURLs,
            progressHandler: { [weak self] downloaded, total, speed in
                let progress = total > 0 ? Double(downloaded) / Double(total) : 0
                self?.progressHandler?(.downloadAssetBits, progress)
            },
            rangeAvailabilityHandler: { [weak self] upperBound, isComplete in
                self?.overlappedExtractor?.updateAvailableBytes(upperBound)
                if isComplete {
                    self?.overlappedExtractor?.completeDownload(totalSize: self?.globalData.totalSize ?? 0)
                }
            }
        )

        switch result {
        case .completed:
            break
        case .error(let err):
            throw err
        case .paused:
            throw PDMDownloadError.criticalError("Download paused")
        case .cancelled:
            throw PDMDownloadError.criticalError("Download cancelled")
        }

        progressHandler?(.downloadAssetBits, 1.0)
        await moveToNextState()
    }

    private func handleCloseOverlappedExtraction() async throws {
        progressHandler?(.closeOverlappedExtraction, 0)

        if let task = overlappedExtractionTask {
            overlappedExtractionResult = try await task.value
        }

        progressHandler?(.closeOverlappedExtraction, 1.0)
        await moveToNextState()
    }

    private func handleExecutionOfAsset(destinationDirectory: URL) async throws {
        progressHandler?(.executeAsset, 0)

        guard let asset = currentAsset else {
            await moveToNextState()
            return
        }

        let assetURL = downloadedAssetURL ?? assetFileURL(destinationDirectory: destinationDirectory)
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw PDMError.assetExecutionFailed
        }

        guard !asset.actions.isEmpty else {
            executedAssetURL = assetURL
            progressHandler?(.executeAsset, 1.0)
            await moveToNextState()
            return
        }

        for action in asset.actions {
            guard action.isExtract else {
                throw PDMError.assetExecutionFailed
            }
            executedAssetURL = try await executeExtractAction(asset: asset, assetURL: assetURL)
        }

        progressHandler?(.executeAsset, 1.0)
        await moveToNextState()
    }

    private func handleAssetSignatureValidation() async throws {
        progressHandler?(.assetSignatureValidation, 0)

        guard let assetURL = downloadedAssetURL ?? destinationURL else {
            throw PDMError.signatureValidationFailed
        }

        if let validationInfo, globalData.totalSize > 0 {
            let isValid = try SignatureValidator.validateWithSegments(fileURL: assetURL, validationInfo: validationInfo)
            guard isValid else {
                throw PDMError.signatureValidationFailed
            }
        }

        if shouldValidateCodeSignature(assetURL) {
            guard SignatureValidator.verifyCodeSignature(at: assetURL) else {
                throw PDMError.signatureValidationFailed
            }
        }

        progressHandler?(.assetSignatureValidation, 1.0)
        await moveToNextState()
    }

    private func assetFileURL(destinationDirectory: URL) -> URL {
        if let downloadedAssetURL {
            return downloadedAssetURL
        }

        let fileName = globalData.downloadFileName.isEmpty ?
            URL(string: globalData.downloadURL)?.lastPathComponent ?? "asset" :
            globalData.downloadFileName
        return destinationDirectory.appendingPathComponent(fileName)
    }

    private func executeExtractAction(asset: PDMManifestAsset, assetURL: URL) async throws -> URL {
        switch asset.type {
        case .zip:
            if let extractionResult = overlappedExtractionResult {
                return extractionResult.extractRoot
            }

            let extractRoot = globalData.tempDirectory
                .appendingPathComponent("PDMExtract-\(UUID().uuidString)", isDirectory: true)
            let extractor = HDPIMZipExtractor()
            let result = try extractor.extract(
                request: HDPIMExtractionRequest(
                    sourceURL: assetURL,
                    destinationURL: extractRoot,
                    compressionType: "",
                    packageName: assetURL.lastPathComponent,
                    validationURL: globalData.validationURL.isEmpty ? nil : globalData.validationURL,
                    isDMG: false,
                    allowOverlap: false
                ),
                progressHandler: { [weak self] progress in
                    self?.progressHandler?(.executeAsset, progress)
                },
                cancellationCheck: { [weak self] in !(self?.isRunning ?? false) }
            )
            return result.extractRoot

        case .dmg:
            let extractRoot = globalData.tempDirectory
                .appendingPathComponent("PDMExtract-\(UUID().uuidString)", isDirectory: true)
            let extractor = HDPIMDMGExtractor()
            let result = try await extractor.extract(
                request: HDPIMExtractionRequest(
                    sourceURL: assetURL,
                    destinationURL: extractRoot,
                    compressionType: "dmg",
                    packageName: assetURL.lastPathComponent,
                    validationURL: nil,
                    isDMG: true,
                    allowOverlap: false
                ),
                cancellationCheck: { [weak self] in !(self?.isRunning ?? false) }
            )
            return result.extractRoot

        case .binary:
            return assetURL
        }
    }

    private func shouldValidateCodeSignature(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "app", "pkg", "dmg":
            return true
        default:
            return false
        }
    }

    private func moveToNextState() async {
        guard let nextState = PDMState(rawValue: currentState.rawValue + 1) else {
            currentState = .workflowCompletion
            return
        }
        currentState = nextState
    }

    func cancel() {
        isRunning = false
        overlappedExtractor?.cancel()
        overlappedExtractionTask?.cancel()
    }
}

enum AdaptiveAction: Int {
    case slowDown = 0   // 停用一个线程 (最少保留 1 个)
    case maintain = 1   // 维持当前速度
    case speedUp = 2    // 激活新线程
}

class DeadConnectionDetector {
    private var connectionLastActivity: [String: Date] = [:]
    private var deadConnectionCount = 0
    private let queue = DispatchQueue(label: "com.adobe-downloader.deadConnectionDetector")

    func recordActivity(connectionId: String) {
        queue.async {
            self.connectionLastActivity[connectionId] = Date()
        }
    }

    func detectDeadConnections() -> [String] {
        var deadConnections: [String] = []
        queue.sync {
            let now = Date()
            for (id, lastActivity) in connectionLastActivity {
                if now.timeIntervalSince(lastActivity) > NetworkConstants.deadConnectionTimeout {
                    deadConnections.append(id)
                    deadConnectionCount += 1
                }
            }
            for id in deadConnections {
                connectionLastActivity.removeValue(forKey: id)
            }
        }
        return deadConnections
    }

    var isFatalError: Bool {
        queue.sync { deadConnectionCount > NetworkConstants.maxDeadConnections }
    }

    func removeConnection(_ connectionId: String) {
        queue.async {
            self.connectionLastActivity.removeValue(forKey: connectionId)
        }
    }
}
