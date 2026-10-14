//
//  PDMAssetDownloadManager.swift
//  Adobe Downloader
//

import Foundation
import Darwin

final class PDMAssetDownloadManager {

    let state: PDMAtomicState
    private let cancellation: PDMTransferCancellation

    private let communicator: PDMHttpCommunicator
    private let bluestreakManager: PDMBluestreakManager
    private let errorHandler: PDMErrorHandler
    private let validationManager: PDMValidationManager
    private let progressTracker: PDMProgressTracker

    private var fileSize: Int64 = 0
    private var etag: String = ""
    private var validationInfo: ValidationInfo?
    private var artifactIdentity: DownloadArtifactStore.Identity?
    private var reusedExistingBytes = false
    private var didRestartUnverifiedResume = false
    private var downloadMode: PDMDownloadMode = .singleStream
    private var segmentSize: Int64 = 2 * 1024 * 1024
    private var segmentCount: Int = 1
    private let criticalErrorForceRetryLimit = 3
    private var criticalErrorForceRetryCount = 0
    private var lastCriticalErrorProgressBytes: Int64 = -1
    private let needRetryLimit = 3
    private var needRetryCount = 0
    private var didFallbackBluestreakToSingleStream = false
    private var didFallbackSegmentValidationToSingleStream = false
    private var didFallbackCriticalErrorToSingleStream = false
    private var didRetryDownloadFailed = false
    private var didRetryNeedRetry = false

    private var progressHandler: PDMProgressTracker.ProgressCallback?
    private var rangeAvailabilityHandler: ((Int64, Bool) -> Void)?


    init(
        communicator: PDMHttpCommunicator? = nil,
        bluestreakConfig: PDMBluestreakConfig = PDMBluestreakConfig(),
        state: PDMAtomicState = PDMAtomicState(.idle),
        cancellation: PDMTransferCancellation = PDMTransferCancellation()
    ) {
        self.state = state
        self.cancellation = cancellation
        let comm = communicator ?? PDMHttpCommunicator(cancellation: cancellation)
        self.communicator = comm
        self.bluestreakManager = PDMBluestreakManager(config: bluestreakConfig)
        self.errorHandler = PDMErrorHandler()
        self.validationManager = PDMValidationManager(communicator: comm)
        self.progressTracker = PDMProgressTracker()
    }

    func pause() {
        if state.requestStop(.paused) {
            cancellation.cancel()
            communicator.cancel()
        }
    }

    func cancelDownload() {
        if state.requestStop(.cancelled) {
            cancellation.cancel()
            communicator.cancel()
        }
    }

    func downloadFile(
        url: URL,
        destinationURL: URL,
        metadataDirectory: URL? = nil,
        headers: [(String, String)],
        totalSize: Int64,
        validationInfo: ValidationInfo?,
        artifactIdentity: DownloadArtifactStore.Identity? = nil,
        etag: String = "",
        progressHandler: PDMProgressTracker.ProgressCallback?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil
    ) async -> PDMDownloadResult {

        defer { progressTracker.stop() }
        self.validationInfo = validationInfo
        self.artifactIdentity = artifactIdentity
        self.etag = etag
        self.progressHandler = progressHandler
        self.rangeAvailabilityHandler = rangeAvailabilityHandler

        if state.current == .idle { _ = state.compareAndSet(expected: .idle, new: .running) }
        if let interrupted = interruptionResult(bytesDownloaded: 0) { return interrupted }
        errorHandler.resetRetryCount()
        resetRetryTracking()

        let aamd = AAMDFileManager(downloadFileURL: destinationURL, metadataDirectory: metadataDirectory)
        fileSize = max(totalSize, 0)
        if fileSize <= 0 {
            do {
                fileSize = try await validationManager.getRemoteFileSize(url: url.absoluteString, headers: headers)
            } catch {
                if let interrupted = interruptionResult(bytesDownloaded: 0) { return interrupted }
            }
        }
        if let interrupted = interruptionResult(bytesDownloaded: (await resumeSnapshot(aamd))?.downloadedBytes ?? 0) {
            return interrupted
        }

        downloadMode = await bluestreakManager.resolveDownloadMode(
            communicator: communicator, url: url, headers: headers, fileSize: fileSize
        )
        if let interrupted = interruptionResult(bytesDownloaded: (await resumeSnapshot(aamd))?.downloadedBytes ?? 0) {
            return interrupted
        }
        segmentSize = validationInfo?.segmentSize ?? Int64(2 * 1024 * 1024)
        guard segmentSize > 0 else {
            return .error(PDMDownloadError.downloadFailed("Invalid segment size"))
        }
        segmentCount = downloadMode.isSingleStream ? 1 : Int((fileSize - 1) / segmentSize + 1)
        var resumeBytes: Int64 = 0
        var shouldInitialize = true
        if let snapshot = await resumeSnapshot(aamd),
           (try? await PDMDownloadIO.run { [self] in
               aamd.validateHeaders(remoteETag: etag, remoteFileSize: fileSize, remoteURL: url.absoluteString, segmentSize: segmentSize)
           }) == true,
           snapshot.downloadMode.isSingleStream || !downloadMode.isSingleStream {
            if snapshot.downloadMode.isSingleStream { downloadMode = .singleStream }
            segmentCount = snapshot.segmentCount
            resumeBytes = snapshot.downloadedBytes
            shouldInitialize = false
        }
        if shouldInitialize || (resumeBytes == 0 && FileManager.default.fileExists(atPath: DownloadArtifactStore.receiptURL(for: destinationURL).path)) {
            guard await initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                return .error(PDMDownloadError.downloadFailed("Cannot initialize download files; existing material was preserved"))
            }
        }

        reusedExistingBytes = resumeBytes > 0
        progressTracker.configure(totalBytes: fileSize, callback: progressHandler, initialBytes: resumeBytes)
        progressTracker.forceReport()
        return await executeWithRetry(url: url, destinationURL: destinationURL, metadataDirectory: metadataDirectory, headers: headers, aamd: aamd)
    }

    private func interruptionResult(bytesDownloaded: Int64) -> PDMDownloadResult? {
        if state.current == .paused { return .paused(bytesDownloaded: bytesDownloaded) }
        if state.current == .cancelled || Task.isCancelled { return .cancelled }
        return nil
    }

    private func executeWithRetry(
        url: URL,
        destinationURL: URL,
        metadataDirectory: URL?,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        while true {
            if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                return interrupted
            }
            progressTracker.setPhase(.transferring)
            let result: PDMDownloadResult
            switch downloadMode {
            case .singleStream:
                result = await downloadSingleStream(url: url, destinationURL: destinationURL, headers: headers, aamd: aamd)
            case .multiStream(let maxSegments):
                result = await downloadMultiStream(
                    url: url, destinationURL: destinationURL, headers: headers, maxSegments: maxSegments, aamd: aamd
                )
            }
            if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                return interrupted
            }
            switch result {
            case .completed:
                progressTracker.setPhase(.validating)
                guard let snapshot = await resumeSnapshot(aamd), snapshot.isComplete, snapshot.fileSize == fileSize else {
                    return .error(PDMDownloadError.downloadFailed("Download has no complete, valid segment record"))
                }
                if let info = validationInfo {
                    let validationResult = await validateCompletedDownload(info, destinationURL: destinationURL, aamd: aamd)
                    switch validationResult {
                    case .completed: break
                    default: return validationResult
                    }
                }
                if reusedExistingBytes {
                    do {
                        _ = try await PDMDownloadIO.validate { [self] in
                            try DownloadArtifactStore.verify(
                                fileURL: destinationURL, identity: artifactIdentity, expectedSize: fileSize,
                                metadataDirectory: metadataDirectory, validationInfo: validationInfo,
                                allowLegacy: true,
                                cancellationCheck: { self.state.current != .running || self.cancellation.isCancelled }
                            )
                        }
                    } catch is CancellationError {
                        return interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) ?? .cancelled
                    } catch {
                        if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                            return interrupted
                        }
                        guard !didRestartUnverifiedResume else {
                            return .error(PDMDownloadError(code: .signatureValidationFailed, message: error.localizedDescription))
                        }
                        didRestartUnverifiedResume = true
                        guard await initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                            return .error(PDMDownloadError.downloadFailed("Cannot preserve unverified resumed download for retry"))
                        }
                        progressTracker.setDownloadedBytes(0)
                        continue
                    }
                }
                if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                    return interrupted
                }
                progressTracker.forceReport()
                guard state.compareAndSet(expected: .running, new: .completed) else {
                    return interruptionResult(bytesDownloaded: fileSize) ?? .error(PDMDownloadError.criticalError("Invalid completion state"))
                }
                rangeAvailabilityHandler?(fileSize, true)
                return .completed

            case .paused, .cancelled:
                return result

            case .error(let error):
                progressTracker.setPhase(.waiting)
                let action = await actionForDownloadError(error.errorCode)
                if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                    return interrupted
                }
                switch action {
                case .retry:
                    progressTracker.setDownloadedBytes((await resumeSnapshot(aamd))?.downloadedBytes ?? 0)
                case .switchToSingleStreamAndRetry:
                    downloadMode = .singleStream
                    segmentCount = 1
                    bluestreakManager.disableBluestreak(reason: "Error \(error.errorCode.rawValue)")
                    guard await initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                        _ = state.compareAndSet(expected: .running, new: .error)
                        return .error(PDMDownloadError.downloadFailed("Cannot initialize single stream retry"))
                    }
                    progressTracker.setDownloadedBytes(0)
                case .fatal, .ignore:
                    _ = state.compareAndSet(expected: .running, new: .error)
                    return .error(error)
                }
            }
        }
    }

    private func validateCompletedDownload(
        _ info: ValidationInfo,
        destinationURL: URL,
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        for segment in info.segments {
            if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) { return interrupted }
            let index = segment.segmentNumber - 1
            let start = Int64(index) * info.segmentSize
            let length = segment.segmentNumber == info.segmentCount ? info.lastSegmentSize : info.segmentSize
            do {
                guard try await PDMDownloadIO.validate({ [self] in
                    try validationManager.validateSegment(
                        fileURL: destinationURL, startByte: start, segmentSize: length,
                        expectedHash: segment.hash, algorithm: info.algorithm
                    )
                }) else { throw PDMDownloadError.segmentValidationFailed(index) }
            } catch {
                let recordIndex = downloadMode.isSingleStream ? 0 : index
                let invalidBytes: Int64 = (try? await PDMDownloadIO.run {
                    let count = aamd.getBytesDownloadedForSegment(recordIndex)
                    guard aamd.updateSegmentData(segment: recordIndex, bytesDownloaded: 0), aamd.synchronize() else {
                        throw PDMDownloadError.downloadFailed("Cannot invalidate segment checkpoint")
                    }
                    return count
                }) ?? 0
                progressTracker.addDownloadedBytes(-invalidBytes)
                return .error(PDMDownloadError(code: .segmentValidationFailed, message: error.localizedDescription))
            }
        }
        return .completed
    }

    private func resetRetryTracking() {
        reusedExistingBytes = false
        didRestartUnverifiedResume = false
        criticalErrorForceRetryCount = 0
        lastCriticalErrorProgressBytes = -1
        needRetryCount = 0
        didFallbackBluestreakToSingleStream = false
        didFallbackSegmentValidationToSingleStream = false
        didFallbackCriticalErrorToSingleStream = false
        didRetryDownloadFailed = false
        didRetryNeedRetry = false
    }

    private func actionForDownloadError(_ errorCode: PDMErrorCode) async -> PDMErrorAction {
        switch errorCode {
        case .none, .cancelled:
            return .ignore
        case .bluestreakNotAvailable:
            guard !didFallbackBluestreakToSingleStream else {
                return .fatal
            }
            didFallbackBluestreakToSingleStream = true
            return .switchToSingleStreamAndRetry
        case .segmentValidationFailed:
            guard !didFallbackSegmentValidationToSingleStream else {
                return .fatal
            }
            didFallbackSegmentValidationToSingleStream = true
            return .switchToSingleStreamAndRetry
        case .criticalError:
            let progressBytes = progressTracker.currentDownloadedBytes
            if progressBytes != lastCriticalErrorProgressBytes {
                criticalErrorForceRetryCount = 0
                lastCriticalErrorProgressBytes = progressBytes
            }
            if criticalErrorForceRetryCount < criticalErrorForceRetryLimit {
                criticalErrorForceRetryCount += 1
                try? await Task.sleep(nanoseconds: UInt64(criticalErrorForceRetryCount) * 1_000_000_000)
                return .retry
            }
            guard !didFallbackCriticalErrorToSingleStream else {
                return .fatal
            }
            didFallbackCriticalErrorToSingleStream = true
            return .switchToSingleStreamAndRetry
        case .downloadFailed:
            guard !didRetryDownloadFailed else {
                return .fatal
            }
            didRetryDownloadFailed = true
            return .retry
        case .needRetry:
            if needRetryCount < needRetryLimit {
                needRetryCount += 1
                try? await Task.sleep(nanoseconds: UInt64(needRetryCount) * 500_000_000)
                return .retry
            }
            guard !didRetryNeedRetry else {
                return .fatal
            }
            didRetryNeedRetry = true
            return .switchToSingleStreamAndRetry
        default:
            return await errorHandler.handleError(errorCode)
        }
    }

    private func resumeSnapshot(_ aamd: AAMDFileManager) async -> AAMDResumeSnapshot? {
        try? await PDMDownloadIO.run { aamd.resumeSnapshot() }
    }

    private func initializeDownloadFiles(
        aamd: AAMDFileManager,
        url: URL,
        destinationURL: URL
    ) async -> Bool {
        do {
            let initialized = try await PDMDownloadIO.run { [self] in
                try aamd.preserveExistingDownload()
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else { return false }
                let fileHandle = try FileHandle(forWritingTo: destinationURL)
                defer { try? fileHandle.close() }
                try fileHandle.truncate(atOffset: UInt64(max(fileSize, 0)))
                try fileHandle.synchronize()
                guard aamd.writeMetaInfo() else { return false }
                return aamd.writeHeaders(downloadMetadata(url: url), segmentTableSpan: max(0, segmentCount - 1))
                    && aamd.synchronize()
            }
            if initialized { reusedExistingBytes = false }
            return initialized
        } catch {
            print("[PDM] 无法准备下载文件: \(error.localizedDescription)")
            return false
        }
    }

    private func downloadMetadata(url: URL) -> [String: String] {
        [
            "ETAG": etag,
            "SERVER_PATH": url.absoluteString,
            "FILE_SIZE": String(fileSize),
            "SEGMENT_SIZE": String(segmentSize),
            "NO_Of_BYTES_TO_DOWNLOAD": String(fileSize),
            "DOWNLOAD_START_ADDRESS": "0",
            "DOWNLOAD_MODE": String(describing: downloadMode),
            "SEGMENT_COUNT": String(segmentCount)
        ]
    }

    private func downloadSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        if fileSize <= 0 {
            return await downloadIndefiniteSingleStream(url: url, destinationURL: destinationURL, headers: headers, aamd: aamd)
        }
        return await downloadSegment(
            segment: PDMSegment(index: 0, startByte: 0, endByte: fileSize - 1, size: fileSize, expectedHash: ""),
            segmentIndex: 0,
            url: url,
            destinationURL: destinationURL,
            headers: headers,
            aamd: aamd,
            isSingleStream: true
        )
    }

    private func downloadIndefiniteSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        let existingSize = (try? await PDMDownloadIO.run {
            (try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        }) ?? 0
        if existingSize > 0 {
            guard await initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                return .error(PDMDownloadError.downloadFailed("Cannot preserve interrupted indefinite download"))
            }
            progressTracker.setDownloadedBytes(0)
        }
        if let interrupted = interruptionResult(bytesDownloaded: 0) { return interrupted }
        do {
            let writer = try await PDMDownloadIO.run { [self] in
                try PDMSegmentWriter(fileURL: destinationURL, aamd: aamd, segmentIndex: 0,
                                     start: 0, length: nil, initialBytes: 0) { count in
                    self.progressTracker.addDownloadedBytes(count)
                    self.rangeAvailabilityHandler?(self.progressTracker.currentDownloadedBytes, false)
                }
            }
            let response = try await communicator.transfer(
                url: url, range: nil, headers: headers,
                responseHandler: { [self] response in
                    guard response.statusCode == 200 else {
                        throw PDMDownloadError.downloadFailed("Unexpected HTTP status for indefinite download: \(response.statusCode)")
                    }
                    if let error = validateResponseIdentity(response) { throw error }
                },
                dataHandler: { try writer.append($0) },
                completionHandler: { try writer.finish(succeeded: $0) }
            )
            let totalDownloaded = try await PDMDownloadIO.run { writer.writtenBytes }
            if let interrupted = interruptionResult(bytesDownloaded: totalDownloaded) { return interrupted }
            guard totalDownloaded > 0, response.contentLength <= 0 || response.contentLength == totalDownloaded else {
                return .error(PDMDownloadError.downloadFailed("Indefinite download size does not match response"))
            }
            fileSize = totalDownloaded
            segmentCount = 1
            if etag.isEmpty { etag = response.etag ?? "" }
            let persisted = try await PDMDownloadIO.run { [self] in
                aamd.writeHeaders(downloadMetadata(url: url), segmentTableSpan: 0) && aamd.synchronize()
            }
            guard persisted else { return .error(PDMDownloadError.downloadFailed("Cannot finalize download metadata")) }
            progressTracker.updateTotalBytes(totalDownloaded)
            return .completed
        } catch {
            return transferFailure(error)
        }
    }

    private func downloadMultiStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        maxSegments: Int,
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        let segments = bluestreakManager.calculateSegments(totalSize: fileSize, validationInfo: validationInfo)
        var finalResult: PDMDownloadResult = .completed
        await withTaskGroup(of: PDMDownloadResult.self) { group in
            var activeCount = 0
            var segmentIndex = 0
            while segmentIndex < segments.count || activeCount > 0 {
                if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) {
                    group.cancelAll()
                    finalResult = interrupted
                    return
                }
                while segmentIndex < segments.count && activeCount < max(1, maxSegments) {
                    let segment = segments[segmentIndex]
                    let index = segmentIndex
                    segmentIndex += 1
                    activeCount += 1
                    group.addTask { [self] in
                        await downloadSegment(
                            segment: segment, segmentIndex: index, url: url, destinationURL: destinationURL,
                            headers: headers, aamd: aamd
                        )
                    }
                }
                if let result = await group.next() {
                    activeCount -= 1
                    switch result {
                    case .completed:
                        continue
                    default:
                        group.cancelAll()
                        finalResult = result
                        return
                    }
                }
            }
        }
        // TaskGroup 退出时所有分片已关闭流和文件句柄，才允许重试或释放目标路径。
        if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) { return interrupted }
        return finalResult
    }

    private func downloadSegment(
        segment: PDMSegment,
        segmentIndex: Int,
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager,
        isSingleStream: Bool = false
    ) async -> PDMDownloadResult {
        do {
            let length = segment.endByte - segment.startByte + 1
            let initialBytes = try await PDMDownloadIO.run { aamd.getBytesDownloadedForSegment(segmentIndex) }
            guard length > 0, initialBytes >= 0, initialBytes <= length else {
                return .error(PDMDownloadError.downloadFailed("Invalid saved segment byte count"))
            }
            if let interrupted = interruptionResult(bytesDownloaded: initialBytes) { return interrupted }
            if initialBytes == length {
                return await validateCompletedSegment(segment, segmentIndex: segmentIndex, destinationURL: destinationURL, aamd: aamd)
            }
            let startByte = segment.startByte + initialBytes
            var requestHeaders = headers
            if !etag.isEmpty && !etag.hasPrefix("W/"), !headers.contains(where: { $0.0.lowercased() == "if-range" }) {
                requestHeaders.append(("If-Range", etag))
            }
            let writer = try await PDMDownloadIO.run { [self] in
                try PDMSegmentWriter(fileURL: destinationURL, aamd: aamd, segmentIndex: segmentIndex,
                                     start: segment.startByte, length: length, initialBytes: initialBytes) { count in
                    self.progressTracker.addDownloadedBytes(count)
                    if isSingleStream {
                        self.rangeAvailabilityHandler?(self.progressTracker.currentDownloadedBytes, false)
                    }
                }
            }
            _ = try await communicator.transfer(
                url: url, range: startByte...segment.endByte, headers: requestHeaders,
                responseHandler: { [self] response in
                    if let error = validateDownloadResponse(
                        response: response, expectedStart: startByte, expectedEnd: segment.endByte,
                        expectedTotalSize: fileSize, allowFullResponse: isSingleStream && startByte == 0
                    ) { throw error }
                },
                dataHandler: { try writer.append($0) },
                completionHandler: { try writer.finish(succeeded: $0) }
            )
            let writtenBytes = try await PDMDownloadIO.run { writer.writtenBytes }
            if let interrupted = interruptionResult(bytesDownloaded: writtenBytes) { return interrupted }
            guard writtenBytes == length else {
                return .error(PDMDownloadError(code: .needRetry, message: "Segment \(segmentIndex) incomplete: \(writtenBytes)/\(length)"))
            }
            return await validateCompletedSegment(segment, segmentIndex: segmentIndex, destinationURL: destinationURL, aamd: aamd)
        } catch {
            return transferFailure(error)
        }
    }

    private func transferFailure(_ error: Error) -> PDMDownloadResult {
        if let interrupted = interruptionResult(bytesDownloaded: progressTracker.currentDownloadedBytes) { return interrupted }
        if DownloadTaskExecution.isCancellation(error) { return .cancelled }
        if let error = error as? PDMDownloadError { return .error(error) }
        return .error(PDMDownloadError(code: PDMErrorHandler.classify(error), message: error.localizedDescription, underlying: error))
    }

    private func validateCompletedSegment(
        _ segment: PDMSegment,
        segmentIndex: Int,
        destinationURL: URL,
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        if let interrupted = interruptionResult(bytesDownloaded: segment.size) { return interrupted }
        if !segment.expectedHash.isEmpty, let info = validationInfo {
            do {
                guard try await PDMDownloadIO.validate({ [self] in
                    try validationManager.validateSegment(
                        fileURL: destinationURL, startByte: segment.startByte,
                        segmentSize: segment.size, expectedHash: segment.expectedHash, algorithm: info.algorithm
                    )
                }) else { throw PDMDownloadError.segmentValidationFailed(segment.index) }
            } catch {
                _ = try? await PDMDownloadIO.run {
                    aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: 0) && aamd.synchronize()
                }
                progressTracker.addDownloadedBytes(-segment.size)
                return .error(PDMDownloadError(code: .segmentValidationFailed, message: error.localizedDescription))
            }
        }
        if let interrupted = interruptionResult(bytesDownloaded: segment.size) { return interrupted }
        rangeAvailabilityHandler?(segment.endByte + 1, false)
        return .completed
    }

    private func validateResponseIdentity(_ response: PDMHTTPResponse) -> PDMDownloadError? {
        if !etag.isEmpty && (response.etag ?? "") != etag {
            return PDMDownloadError.downloadFailed("Remote ETag changed or disappeared during download")
        }
        return nil
    }

    private func validateDownloadResponse(
        response: PDMHTTPResponse,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64,
        allowFullResponse: Bool
    ) -> PDMDownloadError? {
        let statusCode = response.statusCode
        if let identityError = validateResponseIdentity(response) { return identityError }
        if statusCode == 206 {
            if response.contentLength > 0 && response.contentLength != expectedEnd - expectedStart + 1 {
                return PDMDownloadError.downloadFailed("Response length does not match requested range")
            }
            guard contentRangeMatches(
                (response.contentRange ?? ""),
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                expectedTotalSize: expectedTotalSize
            ) else {
                return PDMDownloadError.downloadFailed("Invalid Content-Range: \((response.contentRange ?? ""))")
            }
            return nil
        }

        if allowFullResponse && expectedStart == 0 && statusCode == 200 {
            if response.contentLength > 0 && response.contentLength != expectedTotalSize {
                return PDMDownloadError.downloadFailed("Response length does not match asset size")
            }
            return nil
        }

        if !allowFullResponse && statusCode == 200 {
            return PDMDownloadError(code: .bluestreakNotAvailable, message: "Server returned 200 instead of 206, range not supported")
        }

        return PDMDownloadError.downloadFailed("Unexpected HTTP status \(statusCode) for range \(expectedStart)-\(expectedEnd)")
    }

    private func contentRangeMatches(
        _ contentRange: String,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64
    ) -> Bool {
        let value = contentRange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes ") else {
            return false
        }

        let rangeAndTotal = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else {
            return false
        }

        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let actualStart = Int64(bounds[0]),
              let actualEnd = Int64(bounds[1]) else {
            return false
        }

        if rangeAndTotal[1] != "*" {
            guard let actualTotal = Int64(rangeAndTotal[1]), actualTotal > actualEnd,
                  expectedTotalSize <= 0 || actualTotal == expectedTotalSize else { return false }
        }

        return actualStart == expectedStart && actualEnd == expectedEnd
    }
}
