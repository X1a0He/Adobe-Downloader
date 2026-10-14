//
//  PDMDownloadEngine.swift
//  Adobe Downloader
//

import Foundation

final class PDMDownloadEngine {

    static let shared = PDMDownloadEngine()

    private var activeExecutions: [String: PDMDownloadExecution] = [:]
    private var destinationOwners: [String: UUID] = [:]
    private let executionsLock = NSLock()

    private init() {}

    func downloadFile(
        packageId: String,
        url: URL,
        destinationURL: URL,
        metadataDirectory: URL? = nil,
        headers: [String: String],
        expectedTotalSize: Int64 = 0,
        validationURL: String? = nil,
        validationURLs: [String] = [],
        validationInfo: ValidationInfo? = nil,
        artifactIdentity: DownloadArtifactStore.Identity? = nil,
        progressHandler: PDMProgressTracker.ProgressCallback?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil
    ) async -> PDMDownloadResult {
        let execution = PDMDownloadExecution(packageId: packageId, destinationURL: destinationURL)
        guard register(execution) else {
            return .error(PDMDownloadError.downloadFailed("Another download still owns this package or destination"))
        }
        defer { finish(execution) }

        return await withTaskCancellationHandler {
            if Task.isCancelled { execution.requestStop(.cancelled) }
            let result = await performDownload(
                execution: execution,
                url: url,
                destinationURL: destinationURL,
                metadataDirectory: metadataDirectory,
                headers: headers,
                expectedTotalSize: expectedTotalSize,
                validationURL: validationURL,
                validationURLs: validationURLs,
                inlineValidation: validationInfo,
                artifactIdentity: artifactIdentity,
                progressHandler: progressHandler,
                rangeAvailabilityHandler: rangeAvailabilityHandler
            )
            let aamd = AAMDFileManager(downloadFileURL: destinationURL, metadataDirectory: metadataDirectory)
            if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }
            if case .error = result { _ = execution.state.compareAndSet(expected: .running, new: .error) }
            return result
        } onCancel: {
            execution.requestStop(.cancelled)
        }
    }

    private func performDownload(
        execution: PDMDownloadExecution,
        url: URL,
        destinationURL: URL,
        metadataDirectory: URL?,
        headers: [String: String],
        expectedTotalSize: Int64,
        validationURL: String?,
        validationURLs: [String],
        inlineValidation: ValidationInfo?,
        artifactIdentity: DownloadArtifactStore.Identity?,
        progressHandler: PDMProgressTracker.ProgressCallback?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)?
    ) async -> PDMDownloadResult {
        let requestLimit = await MainActor.run { max(1, StorageData.shared.maxConcurrentDownloads) }
        let enrichedHeaders = enrichHeaders(headers.map { ($0.key, $0.value) })
        let communicator = PDMHttpCommunicator(cancellation: execution.cancellation)
        let aamd = AAMDFileManager(downloadFileURL: destinationURL, metadataDirectory: metadataDirectory)
        if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }

        let sizeResponse: PDMHTTPResponse
        do {
            sizeResponse = try await communicator.sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString,
            method: "HEAD",
            headers: enrichedHeaders,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 30
            ))
        } catch {
            if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }
            if Task.isCancelled { return .cancelled }
            sizeResponse = PDMHTTPResponse(statusCode: -1)
        }
        if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }

        var totalSize = sizeResponse.isSuccess ? sizeResponse.contentLength : 0
        let etag = sizeResponse.isSuccess ? (sizeResponse.etag ?? "") : ""
        if totalSize > 0, expectedTotalSize > 0, totalSize != expectedTotalSize {
            return .error(PDMDownloadError.downloadFailed("Remote size differs from declared asset size"))
        }
        if totalSize <= 0 { totalSize = expectedTotalSize }
        if !sizeResponse.isSuccess, let snapshot = aamd.resumeSnapshot(), snapshot.downloadedBytes > 0 {
            return .error(PDMDownloadError.downloadFailed("Cannot verify remote identity before resuming download"))
        }

        var validationInfo = inlineValidation
        if let info = inlineValidation {
            guard let size = validationTotalSize(info),
                  (expectedTotalSize <= 0 || size == expectedTotalSize),
                  (totalSize <= 0 || size == totalSize) else {
                return .error(PDMDownloadError(code: .signatureValidationFailed, message: "Inline validation does not match asset geometry"))
            }
            if totalSize <= 0 { totalSize = size }
        }
        let candidates = normalizedValidationCandidates(primary: validationURL, candidates: validationURLs)
        if validationInfo == nil, !candidates.isEmpty {
            let validationManager = PDMValidationManager(communicator: communicator)
            for candidate in candidates {
                if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }
                let fetched: ValidationInfo?
                do {
                    fetched = try await validationManager.fetchValidationInfo(from: candidate, headers: enrichedHeaders)
                } catch {
                    if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }
                    if Task.isCancelled { return .cancelled }
                    continue
                }
                guard let info = fetched,
                      let size = validationTotalSize(info),
                      (expectedTotalSize <= 0 || size == expectedTotalSize),
                      (totalSize <= 0 || size == totalSize) else { continue }
                validationInfo = info
                if totalSize <= 0 { totalSize = size }
                break
            }
            if let stopped = stoppedResult(execution, aamd: aamd) { return stopped }
            guard validationInfo != nil else {
                return .error(PDMDownloadError(
                    code: .signatureValidationFailed,
                    message: "Validation data could not be downloaded, parsed, or matched to asset size"
                ))
            }
        }

        let config = PDMBluestreakConfig(
            downloadEnabled: true,
            extractionV2Enabled: false,
            maxSegments: min(3, requestLimit),
            segmentSize: validationInfo?.segmentSize ?? (2 * 1024 * 1024),
            isAutoUpdate: false,
            isLowBandwidthMode: false
        )
        let manager = PDMAssetDownloadManager(
            communicator: communicator,
            bluestreakConfig: config,
            state: execution.state,
            cancellation: execution.cancellation
        )
        return await manager.downloadFile(
            url: url,
            destinationURL: destinationURL,
            metadataDirectory: metadataDirectory,
            headers: enrichedHeaders,
            totalSize: totalSize,
            validationInfo: validationInfo,
            artifactIdentity: artifactIdentity,
            etag: etag,
            progressHandler: { [weak self] downloaded, total, speed, phase in
                guard let self, self.isCurrent(execution), execution.state.current == .running else { return }
                progressHandler?(downloaded, total, speed, phase)
            },
            rangeAvailabilityHandler: { [weak self] bytes, complete in
                guard let self, self.isCurrent(execution),
                      execution.state.current == .running || (complete && execution.state.current == .completed) else { return }
                rangeAvailabilityHandler?(bytes, complete)
            }
        )
    }

    private func stoppedResult(_ execution: PDMDownloadExecution, aamd: AAMDFileManager) -> PDMDownloadResult? {
        switch execution.state.current {
        case .paused: return .paused(bytesDownloaded: aamd.resumeSnapshot()?.downloadedBytes ?? 0)
        case .cancelled: return .cancelled
        default: return nil
        }
    }

    private func normalizedValidationCandidates(primary: String?, candidates: [String]) -> [String] {
        var result: [String] = []
        for value in [primary].compactMap({ $0 }) + candidates {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    private func validationTotalSize(_ info: ValidationInfo) -> Int64? {
        guard info.segmentSize > 0, info.segmentCount > 0,
              info.lastSegmentSize > 0, info.lastSegmentSize <= info.segmentSize,
              !info.algorithm.isEmpty,
              info.segments.count == info.segmentCount,
              Set(info.segments.map(\.segmentNumber)).count == info.segmentCount,
              info.segments.allSatisfy({ (1...info.segmentCount).contains($0.segmentNumber) && !$0.hash.isEmpty }) else { return nil }
        let (prefix, overflow) = Int64(info.segmentCount - 1).multipliedReportingOverflow(by: info.segmentSize)
        let (size, totalOverflow) = prefix.addingReportingOverflow(info.lastSegmentSize)
        return overflow || totalOverflow ? nil : size
    }

    func pause(packageId: String) {
        getExecution(packageId)?.requestStop(.paused)
    }

    func cancelDownload(packageId: String) {
        getExecution(packageId)?.requestStop(.cancelled)
    }

    func pauseAndWait(packageId: String) async {
        guard let execution = getExecution(packageId) else { return }
        execution.requestStop(.paused)
        await execution.waitUntilFinished()
    }

    func cancelAndWait(packageId: String) async {
        guard let execution = getExecution(packageId) else { return }
        execution.requestStop(.cancelled)
        await execution.waitUntilFinished()
    }

    func pauseAll() {
        for execution in allExecutions() { execution.requestStop(.paused) }
    }

    func cancelAll() {
        for execution in allExecutions() { execution.requestStop(.cancelled) }
    }

    private func register(_ execution: PDMDownloadExecution) -> Bool {
        executionsLock.lock()
        defer { executionsLock.unlock() }
        guard activeExecutions[execution.packageId] == nil,
              destinationOwners[execution.destinationPath] == nil else { return false }
        activeExecutions[execution.packageId] = execution
        destinationOwners[execution.destinationPath] = execution.id
        return true
    }

    private func finish(_ execution: PDMDownloadExecution) {
        executionsLock.lock()
        if activeExecutions[execution.packageId]?.id == execution.id {
            activeExecutions.removeValue(forKey: execution.packageId)
        }
        if destinationOwners[execution.destinationPath] == execution.id {
            destinationOwners.removeValue(forKey: execution.destinationPath)
        }
        executionsLock.unlock()
        execution.finish()
    }

    private func getExecution(_ packageId: String) -> PDMDownloadExecution? {
        executionsLock.lock()
        defer { executionsLock.unlock() }
        return activeExecutions[packageId]
    }

    private func allExecutions() -> [PDMDownloadExecution] {
        executionsLock.lock()
        defer { executionsLock.unlock() }
        return Array(activeExecutions.values)
    }

    private func isCurrent(_ execution: PDMDownloadExecution) -> Bool {
        executionsLock.lock()
        defer { executionsLock.unlock() }
        return activeExecutions[execution.packageId]?.id == execution.id
    }

    private func enrichHeaders(_ headers: [(String, String)]) -> [(String, String)] {
        var result = headers
        if !result.contains(where: { $0.0.lowercased() == "x-adobe-app-id" }) {
            result.append(("x-adobe-app-id", PDMConstants.adobeAppId))
        }
        return result
    }
}
