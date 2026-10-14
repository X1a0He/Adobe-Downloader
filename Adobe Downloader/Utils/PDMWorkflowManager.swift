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
    var hasInlineValidation = false
    var hasDeclaredValidation = false
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

    static func signatureValidationFailed(reason: String) -> PDMError {
        PDMError(code: 134, message: "Signature validation failed: \(reason)")
    }
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
        if value?.isEmpty == false {
            return value
        }

        let fieldName = xpath.components(separatedBy: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fieldName.isEmpty else {
            return nil
        }
        return firstLocalString(named: fieldName)
    }

    func elements(_ xpath: String) throws -> [XMLElement] {
        let elements = try document.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
        if !elements.isEmpty {
            return elements
        }

        let fieldName = xpath.components(separatedBy: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let root = document.rootElement(), !fieldName.isEmpty else {
            return []
        }
        return localElements(named: fieldName, under: root)
    }

    private func firstLocalString(named fieldName: String) -> String? {
        guard let root = document.rootElement() else {
            return nil
        }

        for element in localElements(named: fieldName, under: root) {
            let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func localElements(named fieldName: String, under root: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        let normalizedFieldName = fieldName.lowercased()

        func visit(_ element: XMLElement) {
            if (element.localName ?? element.name ?? "").lowercased() == normalizedFieldName {
                result.append(element)
            }

            for child in element.children ?? [] {
                guard let childElement = child as? XMLElement else {
                    continue
                }
                visit(childElement)
            }
        }

        visit(root)
        return result
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
    let hasInlineValidation: Bool
    let hasDeclaredValidation: Bool
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
        [
            PDMManifestValidationPath(value: validationDataRelativeURL, source: .relativeURL),
            PDMManifestValidationPath(value: validationDataURL, source: .validationDataURL),
            PDMManifestValidationPath(value: validationType2URL, source: .type2URL),
            PDMManifestValidationPath(value: validationType1URL, source: .type1URL)
        ].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        let assetRelativePath = Self.firstNonEmpty([
            try xml.firstString("//asset/asset_rel_path"),
            try xml.firstString("//asset/asset_relative_path"),
            try xml.firstString("//asset/relative_path")
        ]) ?? ""
        let assetPath = Self.sanitizedAssetPath(Self.firstNonEmpty([
            try xml.firstString("//asset/asset_path"),
            try xml.firstString("//asset/download_url"),
            try xml.firstString("//asset/downloadURL"),
            try xml.firstString("//asset/url"),
            try xml.firstString("//asset/href")
        ]) ?? "")
        let downloadPath = assetRelativePath.isEmpty ? assetPath : assetRelativePath
        let sequenceNumber = Int(try xml.firstString("//asset/sequence_no") ?? "") ?? 1

        guard let type = PDMManifestAssetType(rawType) ?? Self.inferredAssetType(from: downloadPath) else {
            return nil
        }

        self.type = type
        self.rawXML = element.xmlString
        self.assetRelativePath = assetRelativePath
        self.assetPath = assetPath
        self.inlineValidationData = try xml.firstString("//asset/validation_data_string") ?? ""
        self.hasInlineValidation = try !xml.elements("//asset/validation_data_string").isEmpty
        let declaredValidationFields = [
            "//asset/validation_data_string", "//asset/validation_data_rel_url",
            "/asset/validation_urls/type2", "/asset/validation_urls/type1", "//asset/validation_data"
        ]
        self.hasDeclaredValidation = try declaredValidationFields.contains { try !xml.elements($0).isEmpty }
        self.validationDataRelativeURL = try xml.firstString("//asset/validation_data_rel_url") ?? ""
        self.validationType2URL = try xml.firstString("/asset/validation_urls/type2") ?? ""
        self.validationType1URL = try xml.firstString("/asset/validation_urls/type1") ?? ""
        self.validationDataURL = try xml.firstString("//asset/validation_data") ?? ""
        self.sequenceNumber = sequenceNumber
        self.assetSize = Int64(Self.firstNonEmpty([
            try xml.firstString("//asset/asset_size"),
            try xml.firstString("//asset/size"),
            try xml.firstString("//asset/file_size"),
            try xml.firstString("//asset/content_length")
        ]) ?? "") ?? 0

        let actionNodes = try xml.elements("//asset/actions/action")
        var parsedActions: [PDMManifestAction] = []
        for actionElement in actionNodes {
            guard let action = try PDMManifestAction(element: actionElement) else {
                return nil
            }
            if action.isSupported {
                parsedActions.append(action)
            }
        }
        self.actions = parsedActions.sorted { $0.sequenceNumber < $1.sequenceNumber }

        guard sequenceNumber > 0,
              !downloadPath.isEmpty else {
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

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }
        return nil
    }

    private static func inferredAssetType(from path: String) -> PDMManifestAssetType? {
        let lowercasedPath = path.lowercased()
        if lowercasedPath.hasSuffix(".zip") {
            return .zip
        }
        if lowercasedPath.hasSuffix(".dmg") {
            return .dmg
        }
        if !lowercasedPath.isEmpty {
            return .binary
        }
        return nil
    }
}

class PDMWorkflowManager {

    private var currentState: PDMState = .downloadPackageManifest
    private var globalData: AssetGlobalData
    private var validationInfo: ValidationInfo?
    private let lifecycleLock = NSLock()
    private var requestCancellation = PDMTransferCancellation()
    private var executionInProgress = false
    private var cancellationRequested = false
    private var completionCommitted = false
    private var activeDownloadIdentifier: String?
    private var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return executionInProgress && !cancellationRequested && !completionCommitted
    }
    private var activeExtractor: HDPIMOverlappedZipExtractor?
    private var activeExtractionTask: Task<HDPIMExtractionResult, Error>?
    private var overlappedExtractor: HDPIMOverlappedZipExtractor? {
        get {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return activeExtractor
        }
        set {
            lifecycleLock.lock()
            activeExtractor = newValue
            lifecycleLock.unlock()
        }
    }
    private var overlappedExtractionTask: Task<HDPIMExtractionResult, Error>? {
        get {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return activeExtractionTask
        }
        set {
            lifecycleLock.lock()
            activeExtractionTask = newValue
            lifecycleLock.unlock()
        }
    }
    private var overlappedExtractionResult: HDPIMExtractionResult?
    private var packageIdentifier: String?
    private var expectedArtifactIdentity: DownloadArtifactStore.Identity?
    private var assets: [PDMManifestAsset] = []
    private var currentAsset: PDMManifestAsset?
    private var downloadedAssetURL: URL?
    private var executedAssetURL: URL?
    private var activeValidationURL: String = ""
    private static let defaultValidationServiceBaseURL = "https://cdn-ffc.oobesaas.adobe.com/core/v1/validation"
    private let validationServiceBaseURL: String
    private var shouldReturnExecutedAsset = false
    private var shouldSkipAssetActions = false
    private var outputAssetURL: URL?
    private var assetMetadataDirectory: URL?

    var progressHandler: ((PDMState, Double) -> Void)?
    var assetInfoHandler: ((String, Int64) -> Void)?
    var downloadProgressHandler: PDMProgressTracker.ProgressCallback?
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
        artifactIdentity: DownloadArtifactStore.Identity? = nil,
        returnExecutedAsset: Bool = false,
        skipAssetActions: Bool = false,
        outputAssetURL: URL? = nil,
        assetMetadataDirectory: URL? = nil,
        progressHandler: ((PDMState, Double) -> Void)? = nil,
        assetInfoHandler: ((String, Int64) -> Void)? = nil,
        downloadProgressHandler: PDMProgressTracker.ProgressCallback? = nil,
        cancellationCheck: (() async -> Bool)? = nil
    ) async throws -> URL {
        try beginExecution()
        defer { finishExecution() }
        self.progressHandler = progressHandler
        self.assetInfoHandler = assetInfoHandler
        self.downloadProgressHandler = downloadProgressHandler
        self.cancellationCheck = cancellationCheck
        self.globalData = AssetGlobalData(tempDirectory: globalData.tempDirectory)
        self.globalData.manifestURL = manifestURL
        self.packageIdentifier = packageIdentifier
        self.expectedArtifactIdentity = artifactIdentity
        self.currentState = .downloadPackageManifest
        self.validationInfo = nil
        self.assets = []
        self.currentAsset = nil
        self.downloadedAssetURL = nil
        self.executedAssetURL = nil
        self.activeValidationURL = ""
        self.destinationURL = nil
        self.overlappedExtractor = nil
        self.overlappedExtractionTask = nil
        self.overlappedExtractionResult = nil
        self.shouldReturnExecutedAsset = returnExecutedAsset
        self.shouldSkipAssetActions = skipAssetActions
        self.outputAssetURL = outputAssetURL
        self.assetMetadataDirectory = assetMetadataDirectory

        return try await withTaskCancellationHandler {
            do {
                try await checkCancellation()
                try FileManager.default.createDirectory(at: globalData.tempDirectory, withIntermediateDirectories: true)
                while currentState != .workflowCompletion {
                    try await checkCancellation()
                    try await executeState(cdnBaseURL: cdnBaseURL, headers: headers, destinationDirectory: destinationDirectory)
                }
                try await checkCancellation()

                guard let destination = destinationURL else {
                    throw PDMError(code: 107, message: "Download completed but no destination file")
                }

                try commitCompletion()
                return destination
            } catch {
                cancel()
                if let extractionTask = overlappedExtractionTask {
                    _ = try? await extractionTask.value
                }
                throw error
            }
        } onCancel: {
            self.cancel()
        }
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
            try await handleAssetSignatureValidation(headers: headers)

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

        let response = try await PDMHttpCommunicator(cancellation: requestCancellation).sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString, headers: headers.map { ($0.key, $0.value) },
            timeoutSeconds: NetworkConstants.downloadTimeout
        ))
        let data = response.data

        guard response.isSuccess else {
            throw PDMError.manifestDownloadFailed
        }
        try await checkCancellation()

        try await PDMDownloadIO.run { try data.write(to: manifestFile) }
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

        let version = try firstXMLString(xmlDoc, xpaths: ["//manifest/version", "//version"])
        let assetElements = try manifestAssetElements(from: xmlDoc)
        guard version != nil || !assetElements.isEmpty else {
            throw PDMError.manifestParseFailed
        }

        assets = []
        for assetElement in assetElements {
            guard let asset = try PDMManifestAsset(element: assetElement) else {
                throw PDMError.manifestParseFailed
            }
            assets.append(asset)
        }

        guard let asset = assets.first(where: { !$0.actions.isEmpty }) ?? assets.last else {
            throw PDMError.manifestParseFailed
        }

        currentAsset = asset
        globalData.downloadURL = resolvedManifestURL(asset.downloadPath, cdnBaseURL: cdnBaseURL)
        globalData.inlineValidationData = asset.inlineValidationData
        globalData.hasInlineValidation = asset.hasInlineValidation
        globalData.hasDeclaredValidation = asset.hasDeclaredValidation
        globalData.validationURLs = []
        for validationPath in asset.validationPaths {
            appendValidationURL(validationPath, cdnBaseURL: cdnBaseURL)
        }
        globalData.validationURL = globalData.validationURLs.first ?? ""
        globalData.totalSize = asset.assetSize
        globalData.downloadFileName = asset.downloadFileName
        assetInfoHandler?(asset.downloadFileName, asset.assetSize)

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

        for xpath in xpaths {
            let fieldName = xpath.components(separatedBy: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !fieldName.isEmpty else {
                continue
            }
            if let value = firstLocalXMLString(xmlDoc, named: fieldName) {
                return value
            }
        }
        return nil
    }

    private func manifestAssetElements(from xmlDoc: XMLDocument) throws -> [XMLElement] {
        let xpaths = [
            "//manifest/asset_list/asset",
            "//asset_list/asset",
            "/asset"
        ]
        var result: [XMLElement] = []
        var seen = Set<String>()

        for xpath in xpaths {
            for node in try xmlDoc.nodes(forXPath: xpath) {
                guard let element = node as? XMLElement else {
                    continue
                }
                guard seen.insert(element.xmlString).inserted else {
                    continue
                }
                result.append(element)
            }
        }

        if result.isEmpty, let root = xmlDoc.rootElement() {
            for element in localElements(named: "asset", under: root) {
                guard seen.insert(element.xmlString).inserted else {
                    continue
                }
                result.append(element)
            }
        }

        return result
    }

    private func firstLocalXMLString(_ xmlDoc: XMLDocument, named fieldName: String) -> String? {
        guard let root = xmlDoc.rootElement() else {
            return nil
        }

        for element in localElements(named: fieldName, under: root) {
            let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func localElements(named fieldName: String, under root: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        let normalizedFieldName = fieldName.lowercased()

        func visit(_ element: XMLElement) {
            if (element.localName ?? element.name ?? "").lowercased() == normalizedFieldName {
                result.append(element)
            }

            for child in element.children ?? [] {
                guard let childElement = child as? XMLElement else {
                    continue
                }
                visit(childElement)
            }
        }

        visit(root)
        return result
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
        validationInfo = nil
        activeValidationURL = ""

        if globalData.hasInlineValidation {
            guard let info = validationInfo(from: Data(globalData.inlineValidationData.utf8)),
                  validationInfoMatchesAsset(info) else {
                throw PDMError(code: 107, message: "Declared inline validation is invalid or does not match asset size")
            }
            validationInfo = info
            activeValidationURL = "inline"
            progressHandler?(.downloadAssetValidation, 1.0)
            await moveToNextState()
            return
        }

        guard !globalData.validationURLs.isEmpty else {
            guard !globalData.hasDeclaredValidation else {
                throw PDMError(code: 107, message: "Declared validation source is empty")
            }
            await moveToNextState()
            return
        }

        progressHandler?(.downloadAssetValidation, 0)

        for validationURL in globalData.validationURLs {
            try await checkCancellation()
            let validationData: Data
            do {
                validationData = try await downloadValidationData(from: validationURL, headers: headers)
            } catch {
                try await checkCancellation()
                continue
            }

            guard let info = validationInfo(from: validationData),
                  validationInfoMatchesAsset(info) else {
                continue
            }

            validationInfo = info
            activeValidationURL = validationURL
            globalData.validationURL = validationURL

            progressHandler?(.downloadAssetValidation, 1.0)
            await moveToNextState()
            return
        }

        throw PDMError.validationDownloadFailed
    }

    private func downloadValidationData(from validationURL: String, headers: [String: String]) async throws -> Data {
        guard let url = URL(string: validationURL) else {
            throw PDMError.validationDownloadFailed
        }

        let response = try await PDMHttpCommunicator(cancellation: requestCancellation).sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString, headers: headers.map { ($0.key, $0.value) },
            timeoutSeconds: NetworkConstants.downloadTimeout
        ))
        let data = response.data
        guard response.isSuccess, !data.isEmpty else {
            throw PDMError.validationDownloadFailed
        }

        return data
    }

    private func validationInfo(from data: Data) -> ValidationInfo? {
        guard let xmlString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return ValidationInfo.parse(from: xmlString)
    }

    private func validationInfoMatchesAsset(_ info: ValidationInfo) -> Bool {
        let totalSize = validationTotalSize(info)
        return totalSize > 0 && (globalData.totalSize <= 0 || totalSize == globalData.totalSize)
    }

    private func handleAssetValidationParsing() async throws {
        progressHandler?(.parseAssetValidation, 0)

        if globalData.hasDeclaredValidation, validationInfo == nil {
            throw PDMError(code: 107, message: "Declared validation could not be parsed")
        }

        if let info = validationInfo {
            let totalSize = validationTotalSize(info)
            guard totalSize > 0, validationInfoMatchesAsset(info) else {
                throw PDMError(code: 107, message: "Validation size does not match asset size")
            }
            if globalData.downloadFileName.isEmpty {
                globalData.downloadFileName = "asset_\(info.packageHashKey.prefix(8)).zip"
            }
            if globalData.totalSize <= 0 {
                globalData.totalSize = totalSize
            }
        }

        progressHandler?(.parseAssetValidation, 1.0)
        await moveToNextState()
    }

    private func validationTotalSize(_ info: ValidationInfo) -> Int64 {
        guard info.segmentCount > 0, info.segmentSize > 0,
              info.lastSegmentSize > 0, info.lastSegmentSize <= info.segmentSize else {
            return 0
        }
        let precedingSize = Int64(info.segmentCount - 1).multipliedReportingOverflow(by: info.segmentSize)
        guard !precedingSize.overflow else { return 0 }
        let totalSize = precedingSize.partialValue.addingReportingOverflow(info.lastSegmentSize)
        return totalSize.overflow ? 0 : totalSize.partialValue
    }

    private func handleCheckDownloadedBits(destinationDirectory: URL) async throws {
        progressHandler?(.checkDownloadedBits, 0)

        if !globalData.downloadFileName.isEmpty {
            let filePath = outputAssetURL ?? destinationDirectory.appendingPathComponent(globalData.downloadFileName)
            destinationURL = filePath

            do {
                let existingSize = try await PDMDownloadIO.validate { [self] in
                    try DownloadArtifactStore.verify(
                        fileURL: filePath,
                        identity: artifactIdentity(for: filePath),
                        expectedSize: globalData.totalSize,
                        metadataDirectory: assetMetadataDirectory,
                        validationInfo: validationInfo,
                        allowLegacy: false,
                        cancellationCheck: { !self.isRunning }
                    )
                }
                try await checkCancellation()
                globalData.totalSize = existingSize
                progressHandler?(.checkDownloadedBits, 1.0)
                downloadedAssetURL = filePath
                currentState = .assetSignatureValidation
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await checkCancellation()
            }
        }

        progressHandler?(.checkDownloadedBits, 1.0)
        await moveToNextState()
    }

    private func artifactIdentity(for fileURL: URL) -> DownloadArtifactStore.Identity {
        if let expectedArtifactIdentity { return expectedArtifactIdentity }
        return DownloadArtifactStore.Identity(
            name: fileURL.lastPathComponent,
            source: globalData.manifestURL.isEmpty ? globalData.downloadURL : globalData.manifestURL,
            hashKey: validationInfo?.packageHashKey ?? ""
        )
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
        let assetURL = outputAssetURL ?? destinationDirectory.appendingPathComponent(fileName)
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
                    guard let self, self.isRunning else { return }
                    self.progressHandler?(.startOverlappedExtraction, progress)
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
        let filePath = outputAssetURL ?? destinationDirectory.appendingPathComponent(fileName)
        destinationURL = filePath
        downloadedAssetURL = filePath

        progressHandler?(.downloadAssetBits, 0)

        let effectivePackageIdentifier = packageIdentifier ?? "PDM_\(fileName)"
        try registerActiveDownload(effectivePackageIdentifier)
        defer { clearActiveDownload() }

        let result = await PDMDownloadEngine.shared.downloadFile(
            packageId: effectivePackageIdentifier,
            url: url,
            destinationURL: filePath,
            metadataDirectory: assetMetadataDirectory,
            headers: headers,
            expectedTotalSize: globalData.totalSize,
            validationURL: globalData.validationURL.isEmpty ? nil : globalData.validationURL,
            validationURLs: globalData.validationURLs,
            validationInfo: validationInfo,
            artifactIdentity: artifactIdentity(for: filePath),
            progressHandler: { [weak self] downloaded, total, speed, phase in
                guard let self, self.isRunning else { return }
                let progress = total > 0 ? Double(downloaded) / Double(total) : 0
                if total > 0 {
                    self.globalData.totalSize = total
                }
                self.downloadProgressHandler?(downloaded, total, speed, phase)
                self.progressHandler?(.downloadAssetBits, progress)
            },
            rangeAvailabilityHandler: { [weak self] upperBound, isComplete in
                guard let self, self.isRunning else { return }
                self.overlappedExtractor?.updateAvailableBytes(upperBound)
                if isComplete {
                    self.overlappedExtractor?.completeDownload(totalSize: self.globalData.totalSize)
                }
            }
        )

        try await checkCancellation()
        switch result {
        case .completed:
            break
        case .error(let err):
            throw err
        case .paused:
            throw NetworkError.cancelled
        case .cancelled:
            throw NetworkError.cancelled
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

        guard !shouldSkipAssetActions else {
            executedAssetURL = assetURL
            progressHandler?(.executeAsset, 1.0)
            await moveToNextState()
            return
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

    private func firstMismatchedSegment(_ assetURL: URL, info: ValidationInfo) async throws -> Int? {
        try await checkCancellation()
        let mismatch = try await PDMDownloadIO.validate {
            try SignatureValidator.firstMismatchedSegment(fileURL: assetURL, validationInfo: info)
        }
        try await checkCancellation()
        return mismatch
    }

    private func validateAssetSegments(_ assetURL: URL, headers: [String: String]) async throws {
        if let validationInfo,
           try await firstMismatchedSegment(assetURL, info: validationInfo) == nil {
            return
        }

        var firstMismatchSegment: Int?
        var firstValidationURL = activeValidationURL
        let candidateURLs = globalData.validationURLs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for validationURL in candidateURLs where validationURL != activeValidationURL {
            try await checkCancellation()
            let data: Data
            do {
                data = try await downloadValidationData(from: validationURL, headers: headers)
            } catch {
                try await checkCancellation()
                continue
            }
            guard let info = validationInfo(from: data),
                  validationInfoMatchesAsset(info) else {
                continue
            }

            let mismatchSegment = try await firstMismatchedSegment(assetURL, info: info)
            if mismatchSegment == nil {
                validationInfo = info
                activeValidationURL = validationURL
                globalData.validationURL = validationURL
                return
            }

            if firstMismatchSegment == nil {
                firstMismatchSegment = mismatchSegment
                firstValidationURL = validationURL
            }
        }

        if firstMismatchSegment == nil, let validationInfo {
            firstMismatchSegment = try await firstMismatchedSegment(assetURL, info: validationInfo)
        }

        let validationLabel = firstValidationURL.isEmpty ? "unknown validation" : firstValidationURL
        let segmentLabel = firstMismatchSegment.map { " at segment \($0)" } ?? ""
        throw PDMError.signatureValidationFailed(reason: "validation segment hash mismatch\(segmentLabel) for \(assetURL.lastPathComponent) using \(validationLabel)")
    }

    private func handleAssetSignatureValidation(headers: [String: String]) async throws {
        progressHandler?(.assetSignatureValidation, 0)

        guard let assetURL = downloadedAssetURL ?? destinationURL else {
            throw PDMError.signatureValidationFailed(reason: "downloaded asset is missing")
        }

        if globalData.hasDeclaredValidation, validationInfo == nil {
            throw PDMError.signatureValidationFailed(reason: "declared validation is missing")
        }
        if validationInfo != nil {
            try await validateAssetSegments(assetURL, headers: headers)
        }

        if shouldValidateCodeSignature(assetURL) {
            guard try await PDMDownloadIO.validate({ SignatureValidator.verifyCodeSignature(at: assetURL) }) else {
                throw PDMError.signatureValidationFailed(reason: "code signature verification failed for \(assetURL.lastPathComponent)")
            }
        }

        try await checkCancellation()
        try await PDMDownloadIO.validate { [self] in
            try DownloadArtifactStore.recordCompletion(
                fileURL: assetURL,
                identity: artifactIdentity(for: assetURL),
                expectedSize: globalData.totalSize,
                metadataDirectory: assetMetadataDirectory,
                validationInfo: validationInfo,
                cancellationCheck: { [weak self] in !(self?.isRunning ?? false) }
            )
        }
        try await checkCancellation()
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
                    guard let self, self.isRunning else { return }
                    self.progressHandler?(.executeAsset, progress)
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
        case "app", "pkg":
            return true
        default:
            return false
        }
    }

    private func moveToNextState() async {
        guard let nextState = PDMState(rawValue: currentState.rawValue + 1) else {
            if shouldReturnExecutedAsset, let executedAssetURL {
                destinationURL = executedAssetURL
            }
            currentState = .workflowCompletion
            return
        }
        if shouldReturnExecutedAsset, nextState == .workflowCompletion, let executedAssetURL {
            destinationURL = executedAssetURL
        }
        currentState = nextState
    }

    private func beginExecution() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !executionInProgress else {
            throw PDMError(code: 119, message: "A download workflow is already running")
        }
        executionInProgress = true
        requestCancellation = PDMTransferCancellation()
        cancellationRequested = false
        completionCommitted = false
        activeDownloadIdentifier = nil
    }

    private func commitCompletion() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard executionInProgress, !cancellationRequested, !Task.isCancelled else {
            throw NetworkError.cancelled
        }
        completionCommitted = true
    }

    private func finishExecution() {
        lifecycleLock.lock()
        executionInProgress = false
        activeDownloadIdentifier = nil
        lifecycleLock.unlock()
    }

    private func checkCancellation() async throws {
        guard isRunning, !Task.isCancelled else {
            throw NetworkError.cancelled
        }
        if let cancellationCheck, await cancellationCheck() {
            cancel()
            throw NetworkError.cancelled
        }
        guard isRunning, !Task.isCancelled else {
            throw NetworkError.cancelled
        }
    }

    private func registerActiveDownload(_ identifier: String) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard executionInProgress, !cancellationRequested else {
            throw NetworkError.cancelled
        }
        activeDownloadIdentifier = identifier
    }

    private func clearActiveDownload() {
        lifecycleLock.lock()
        activeDownloadIdentifier = nil
        lifecycleLock.unlock()
    }

    func cancel() {
        lifecycleLock.lock()
        guard executionInProgress, !completionCommitted else {
            lifecycleLock.unlock()
            return
        }
        cancellationRequested = true
        let downloadIdentifier = activeDownloadIdentifier
        let requests = requestCancellation
        let extractor = activeExtractor
        let extractionTask = activeExtractionTask
        lifecycleLock.unlock()
        requests.cancel()
        if let downloadIdentifier {
            PDMDownloadEngine.shared.cancelDownload(packageId: downloadIdentifier)
        }
        extractor?.cancel()
        extractionTask?.cancel()
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
