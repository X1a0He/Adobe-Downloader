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
}

class PDMWorkflowManager {

    private var currentState: PDMState = .downloadPackageManifest
    private var globalData: AssetGlobalData
    private var validationInfo: ValidationInfo?
    private var isRunning = false
    private var overlappedExtractor: HDPIMOverlappedZipExtractor?
    private var overlappedExtractionTask: Task<HDPIMExtractionResult, Error>?
    private var overlappedExtractionResult: HDPIMExtractionResult?

    var progressHandler: ((PDMState, Double) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?
    var cancellationCheck: (() async -> Bool)?

    private var destinationURL: URL?

    init(tempDirectory: URL) {
        self.globalData = AssetGlobalData(tempDirectory: tempDirectory)
    }

    func execute(
        manifestURL: String,
        cdnBaseURL: String,
        headers: [String: String],
        destinationDirectory: URL,
        progressHandler: ((PDMState, Double) -> Void)? = nil,
        cancellationCheck: (() async -> Bool)? = nil
    ) async throws -> URL {
        self.progressHandler = progressHandler
        self.cancellationCheck = cancellationCheck
        self.globalData.manifestURL = manifestURL
        self.isRunning = true

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

        if let assetPath = try xmlDoc.nodes(forXPath: "//asset_list/asset/asset_path").first?.stringValue {
            if assetPath.hasPrefix("http") {
                globalData.downloadURL = assetPath
            } else {
                let cleanCdn = cdnBaseURL.hasSuffix("/") ? String(cdnBaseURL.dropLast()) : cdnBaseURL
                let cleanPath = assetPath.hasPrefix("/") ? assetPath : "/\(assetPath)"
                globalData.downloadURL = cleanCdn + cleanPath
            }
        }

        if let validationPath = try xmlDoc.nodes(forXPath: "//asset_list/asset/validation_url").first?.stringValue {
            globalData.validationURL = validationPath
        }

        if let assetSize = try xmlDoc.nodes(forXPath: "//asset_list/asset/asset_size").first?.stringValue {
            globalData.totalSize = Int64(assetSize) ?? 0
        }

        if let downloadURL = URL(string: globalData.downloadURL) {
            globalData.downloadFileName = downloadURL.lastPathComponent
        }

        progressHandler?(.parseAssetManifest, 1.0)
        await moveToNextState()
    }

    private func handleAssetValidationDownload(headers: [String: String]) async throws {
        guard !globalData.validationURL.isEmpty else {
            await moveToNextState()
            return
        }

        progressHandler?(.downloadAssetValidation, 0)

        guard let url = URL(string: globalData.validationURL) else {
            await moveToNextState()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.downloadTimeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            await moveToNextState()
            return
        }

        let validationFile = globalData.tempDirectory.appendingPathComponent("validation.xml")
        try data.write(to: validationFile)

        progressHandler?(.downloadAssetValidation, 1.0)
        await moveToNextState()
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
        }

        progressHandler?(.parseAssetValidation, 1.0)
        await moveToNextState()
    }

    private func handleCheckDownloadedBits(destinationDirectory: URL) async throws {
        progressHandler?(.checkDownloadedBits, 0)

        if !globalData.downloadFileName.isEmpty {
            let filePath = destinationDirectory.appendingPathComponent(globalData.downloadFileName)
            destinationURL = filePath

            if FileManager.default.fileExists(atPath: filePath.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path)
                let existingSize = attrs?[.size] as? Int64 ?? 0

                if existingSize == globalData.totalSize && globalData.totalSize > 0 {
                    progressHandler?(.checkDownloadedBits, 1.0)
                    currentState = .workflowCompletion
                    return
                }
            }
        }

        progressHandler?(.checkDownloadedBits, 1.0)
        await moveToNextState()
    }

    private func handleStartOverlappedExtraction(destinationDirectory: URL) async throws {
        progressHandler?(.startOverlappedExtraction, 0)

        guard !globalData.downloadURL.isEmpty,
              let url = URL(string: globalData.downloadURL) else {
            await moveToNextState()
            return
        }

        let fileName = globalData.downloadFileName.isEmpty ? url.lastPathComponent : globalData.downloadFileName
        guard fileName.lowercased().hasSuffix(".zip") else {
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

        progressHandler?(.downloadAssetBits, 0)

        let packageIdentifier = "PDM_\(fileName)"

        let result = await PDMDownloadEngine.shared.downloadFile(
            packageId: packageIdentifier,
            url: url,
            destinationURL: filePath,
            headers: headers,
            validationURL: globalData.validationURL.isEmpty ? nil : globalData.validationURL,
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

        let fileName = globalData.downloadFileName.isEmpty ?
            URL(string: globalData.downloadURL)?.lastPathComponent ?? "asset" :
            globalData.downloadFileName
        let assetURL = destinationDirectory.appendingPathComponent(fileName)

        if fileName.lowercased().hasSuffix(".dmg") {
            let extractor = HDPIMDMGExtractor()
            let result = try await extractor.extract(
                request: HDPIMExtractionRequest(
                    sourceURL: assetURL,
                    destinationURL: destinationDirectory,
                    compressionType: "dmg",
                    packageName: fileName,
                    validationURL: nil,
                    isDMG: true,
                    allowOverlap: false
                ),
                cancellationCheck: { [weak self] in !(self?.isRunning ?? false) }
            )
            destinationURL = result.extractRoot
        } else if let extractionResult = overlappedExtractionResult {
            destinationURL = extractionResult.extractRoot
        } else {
            destinationURL = assetURL
        }

        progressHandler?(.executeAsset, 1.0)
        await moveToNextState()
    }

    private func handleAssetSignatureValidation() async throws {
        progressHandler?(.assetSignatureValidation, 0)

        guard let destination = destinationURL else {
            await moveToNextState()
            return
        }

        if destination.pathExtension.lowercased() == "dmg" ||
           destination.pathExtension.lowercased() == "pkg" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", destination.path]

            let pipe = Pipe()
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                throw PDMError(code: 134, message: "Signature validation failed: \(output)")
            }
        }

        progressHandler?(.assetSignatureValidation, 1.0)
        await moveToNextState()
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
