//
//  PDMAssetDownloadManager.swift
//  Adobe Downloader
//

import Foundation

final class PDMAssetDownloadManager {

    let state = PDMAtomicState(.idle)

    private let communicator: PDMHttpCommunicator
    private let bluestreakManager: PDMBluestreakManager
    private let errorHandler: PDMErrorHandler
    private let validationManager: PDMValidationManager
    private let progressTracker: PDMProgressTracker

    private var downloadURL: URL?
    private var destinationURL: URL?
    private var downloadHeaders: [(String, String)] = []
    private var fileSize: Int64 = 0
    private var etag: String = ""
    private var validationInfo: ValidationInfo?
    private var downloadMode: PDMDownloadMode = .singleStream
    private var aamd: AAMDFileManager?
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

    private var progressHandler: ((Int64, Int64, Double) -> Void)?
    private var rangeAvailabilityHandler: ((Int64, Bool) -> Void)?


    init(
        communicator: PDMHttpCommunicator? = nil,
        bluestreakConfig: PDMBluestreakConfig = PDMBluestreakConfig()
    ) {
        let comm = communicator ?? PDMHttpCommunicator()
        self.communicator = comm
        self.bluestreakManager = PDMBluestreakManager(config: bluestreakConfig)
        self.errorHandler = PDMErrorHandler()
        self.validationManager = PDMValidationManager(communicator: comm)
        self.progressTracker = PDMProgressTracker()
    }

    func pause() {
        state.set(.paused)
        communicator.cancel()
    }

    func cancelDownload() {
        state.set(.cancelled)
        communicator.cancel()
    }

    func downloadFile(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        totalSize: Int64,
        validationInfo: ValidationInfo?,
        etag: String = "",
        progressHandler: ((Int64, Int64, Double) -> Void)?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil
    ) async -> PDMDownloadResult {

        self.downloadURL = url
        self.destinationURL = destinationURL
        self.downloadHeaders = headers
        self.validationInfo = validationInfo
        self.etag = etag
        self.progressHandler = progressHandler
        self.rangeAvailabilityHandler = rangeAvailabilityHandler

        state.set(.running)
        errorHandler.resetRetryCount()
        resetRetryTracking()

        let aamd = AAMDFileManager(downloadFileURL: destinationURL)
        self.aamd = aamd

        fileSize = totalSize
        if aamd.exists() && aamd.validateAAMDFile() {
            if let headers = aamd.readHeaders(), let storedSize = headers["FILE_SIZE"], let size = Int64(storedSize), size > 0 {
                fileSize = size
            }
        }
        if fileSize <= 0 {
            fileSize = validationManager.getRemoteFileSize(
                url: url.absoluteString,
                headers: headers
            )
        }

        downloadMode = bluestreakManager.resolveDownloadMode(
            communicator: communicator,
            url: url,
            headers: headers,
            fileSize: fileSize
        )

        segmentSize = validationInfo?.segmentSize ?? Int64(2 * 1024 * 1024)
        segmentCount = downloadMode.isSingleStream ? 1 : max(1, Int((fileSize + segmentSize - 1) / segmentSize))

        var resumeBytes: Int64 = 0

        var shouldInitializeDownloadFiles = !aamd.exists()

        if aamd.exists() {
            if aamd.validateAAMDFile(),
               aamd.validateHeaders(
                   remoteETag: etag,
                   remoteFileSize: fileSize,
                   remoteURL: url.absoluteString,
                   segmentSize: segmentSize
               ) {
                if let headers = aamd.readHeaders() {
                    if let modeStr = headers["DOWNLOAD_MODE"], let mode = parseDownloadMode(from: modeStr) {
                        downloadMode = mode
                    }
                    if let countStr = headers["SEGMENT_COUNT"], let count = Int(countStr), count > 0 {
                        segmentCount = count
                    }
                }
                resumeBytes = aamd.getTotalBytesDownloaded(segmentCount: segmentCount)
            } else {
                shouldInitializeDownloadFiles = true
            }
        }

        if shouldInitializeDownloadFiles {
            guard initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                return .error(PDMDownloadError.downloadFailed("Cannot initialize download files"))
            }
            resumeBytes = 0
        }

        await progressTracker.configure(
            totalBytes: fileSize,
            callback: progressHandler,
            initialBytes: resumeBytes
        )

        await progressTracker.forceReport()

        return await executeWithRetry(url: url, destinationURL: destinationURL, headers: headers, aamd: aamd)
    }

    func resumeDownload() async -> PDMDownloadResult {
        guard state.current == .paused,
              let url = downloadURL,
              let destURL = destinationURL,
              let aamd = self.aamd else {
            return .error(PDMDownloadError(code: .criticalError, message: "Cannot resume: invalid state"))
        }

        communicator.reset()
        state.set(.running)

        let resumeBytes = aamd.getTotalBytesDownloaded(segmentCount: segmentCount)

        await progressTracker.configure(
            totalBytes: fileSize,
            callback: progressHandler,
            initialBytes: resumeBytes
        )
        await progressTracker.forceReport()

        return await executeWithRetry(url: url, destinationURL: destURL, headers: downloadHeaders, aamd: aamd)
    }

    private func executeWithRetry(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {

        var shouldRetry = true
        while shouldRetry {
            shouldRetry = false

            let currentState = state.current
            if currentState == .paused {
                return .paused(bytesDownloaded: await progressTracker.currentDownloadedBytes)
            }
            if currentState == .cancelled {
                return .cancelled
            }

            let result: PDMDownloadResult
            switch downloadMode {
            case .singleStream:
                result = await downloadSingleStream(
                    url: url,
                    destinationURL: destinationURL,
                    headers: headers,
                    aamd: aamd
                )
            case .multiStream(let maxSegments):
                result = await downloadMultiStream(
                    url: url,
                    destinationURL: destinationURL,
                    headers: headers,
                    maxSegments: maxSegments,
                    aamd: aamd
                )
            }

            switch result {
            case .completed:
                if let info = validationInfo {
                    do {
                        let valid = try validationManager.validateFile(
                            at: destinationURL,
                            validationInfo: info,
                            totalSize: fileSize
                        )
                        if !valid {
                            return .error(PDMDownloadError.segmentValidationFailed(-1))
                        }
                    } catch {
                            return .error(PDMDownloadError(code: .segmentValidationFailed, message: error.localizedDescription))
                    }
                }
                rangeAvailabilityHandler?(fileSize, true)
                state.set(.completed)
                return .completed

            case .paused(let bytes):
                return .paused(bytesDownloaded: bytes)

            case .cancelled:
                return .cancelled

            case .error(let err):
                let errorCode = err.errorCode
                let action = await actionForDownloadError(errorCode)

                switch action {
                case .retry:
                    shouldRetry = true
                    communicator.reset()
                case .switchToSingleStreamAndRetry:
                    downloadMode = .singleStream
                    segmentCount = 1
                    bluestreakManager.disableBluestreak(reason: "Error \(errorCode.rawValue)")
                    guard initializeDownloadFiles(aamd: aamd, url: url, destinationURL: destinationURL) else {
                        state.set(.error)
                        return .error(PDMDownloadError.downloadFailed("Cannot initialize single stream retry"))
                    }
                    await progressTracker.configure(
                        totalBytes: fileSize,
                        callback: progressHandler,
                        initialBytes: 0
                    )
                    await progressTracker.forceReport()
                    shouldRetry = true
                    communicator.reset()
                case .fatal:
                    state.set(.error)
                    return .error(err)
                case .ignore:
                    break
                }
            }
        }

        return .completed
    }

    private func resetRetryTracking() {
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
            let progressBytes = await progressTracker.currentDownloadedBytes
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

    private func initializeDownloadFiles(
        aamd: AAMDFileManager,
        url: URL,
        destinationURL: URL
    ) -> Bool {
        aamd.writeMetaInfo()
        aamd.writeHeaders([
            "ETAG": etag,
            "SERVER_PATH": url.absoluteString,
            "FILE_SIZE": String(fileSize),
            "SEGMENT_SIZE": String(segmentSize),
            "NO_Of_BYTES_TO_DOWNLOAD": String(fileSize),
            "DOWNLOAD_START_ADDRESS": "0",
            "DOWNLOAD_MODE": String(describing: downloadMode),
            "SEGMENT_COUNT": String(segmentCount)
        ], segmentTableSpan: aamdSegmentTableSpan())

        return prepareDestinationFile(destinationURL)
    }

    private func aamdSegmentTableSpan() -> Int {
        guard fileSize > 0, segmentSize > 0 else {
            return 0
        }
        return Int(fileSize / segmentSize)
    }

    private func parseDownloadMode(from string: String) -> PDMDownloadMode? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "singleStream" {
            return .singleStream
        }
        if trimmed.hasPrefix("multiStream(maxSegments:") {
            let digits = trimmed.filter { $0.isNumber }
            if let max = Int(digits), max > 0 {
                return .multiStream(maxSegments: max)
            }
        }
        return nil
    }

    private func prepareDestinationFile(_ destinationURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            }

            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer { try? fileHandle.close() }
            fileHandle.truncateFile(atOffset: UInt64(max(fileSize, 0)))
            return true
        } catch {
            return false
        }
    }

    private func downloadSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {

        if fileSize <= 0 {
            return await downloadIndefiniteSingleStream(
                url: url,
                destinationURL: destinationURL,
                headers: headers,
                aamd: aamd
            )
        }

        let startByte = aamd.getBytesDownloadedForSegment(0)
        if startByte >= fileSize {
            return .completed
        }

        let endByte = fileSize - 1
        guard communicator.initHttpDownload(
            url: url,
            startByte: startByte,
            endByte: endByte,
            headers: headers
        ) else {
            return .error(PDMDownloadError.downloadFailed("Failed to initialize HTTP download"))
        }

        guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else {
            return .error(PDMDownloadError.downloadFailed("Cannot open file for writing"))
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(startByte))
        } catch {
            return .error(PDMDownloadError.downloadFailed("Cannot seek to offset \(startByte)"))
        }

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var totalDownloaded = startByte
        var remaining = fileSize - startByte
        var lastAAMDUpdate = Date()
        let aamdUpdateInterval: TimeInterval = 3.0

        while remaining > 0 {
            if state.current == .paused {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                await progressTracker.forceReport()
                communicator.closeStream()
                return .paused(bytesDownloaded: totalDownloaded)
            }

            if state.current == .cancelled {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                communicator.closeStream()
                return .cancelled
            }

            let readSize = min(Int(remaining), bufferSize)
            let (result, bytesRead) = communicator.downloadRemainingData(
                buffer: buffer,
                bufferSize: readSize
            )

            if let responseError = validateDownloadResponse(
                communicator: communicator,
                expectedStart: startByte,
                expectedEnd: endByte,
                expectedTotalSize: fileSize,
                allowFullResponse: startByte == 0
            ) {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                communicator.closeStream()
                return .error(responseError)
            }

            switch result {
            case .moreData:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    remaining -= Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                    rangeAvailabilityHandler?(totalDownloaded, false)

                    let now = Date()
                    if now.timeIntervalSince(lastAAMDUpdate) >= aamdUpdateInterval {
                        aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                        lastAAMDUpdate = now
                    }
                }

            case .complete, .streamEnd:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    remaining -= Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                rangeAvailabilityHandler?(totalDownloaded, totalDownloaded >= fileSize)
                guard totalDownloaded == fileSize else {
                    communicator.closeStream()
                    return .error(PDMDownloadError.downloadFailed("Downloaded size mismatch: \(totalDownloaded)/\(fileSize)"))
                }
                return .completed

            case .error(let errorCode):
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                communicator.closeStream()

                if state.current == .paused {
                    await progressTracker.forceReport()
                    return .paused(bytesDownloaded: totalDownloaded)
                }
                if state.current == .cancelled {
                    return .cancelled
                }

                return .error(PDMDownloadError(
                    code: errorCode,
                    message: "Download stream error at byte \(totalDownloaded)"
                ))
            }
        }

        aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
        guard totalDownloaded == fileSize else {
            communicator.closeStream()
            return .error(PDMDownloadError.downloadFailed("Downloaded size mismatch: \(totalDownloaded)/\(fileSize)"))
        }
        return .completed
    }

    private func downloadIndefiniteSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        aamd.updateSegmentData(segment: 0, bytesDownloaded: 0)

        guard communicator.initIndefiniteHttpDownload(
            url: url,
            headers: headers
        ) else {
            return .error(PDMDownloadError.downloadFailed("Failed to initialize indefinite HTTP download"))
        }

        guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else {
            return .error(PDMDownloadError.downloadFailed("Cannot open file for writing"))
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.truncate(atOffset: 0)
            try fileHandle.seek(toOffset: 0)
        } catch {
            return .error(PDMDownloadError.downloadFailed("Cannot reset destination file"))
        }

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var totalDownloaded: Int64 = 0
        var lastAAMDUpdate = Date()
        let aamdUpdateInterval: TimeInterval = 3.0

        while true {
            if state.current == .paused {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                await progressTracker.forceReport()
                communicator.closeStream()
                return .paused(bytesDownloaded: totalDownloaded)
            }

            if state.current == .cancelled {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                communicator.closeStream()
                return .cancelled
            }

            let (result, bytesRead) = communicator.downloadRemainingData(
                buffer: buffer,
                bufferSize: bufferSize
            )

            switch result {
            case .moreData:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                    rangeAvailabilityHandler?(totalDownloaded, false)

                    let now = Date()
                    if now.timeIntervalSince(lastAAMDUpdate) >= aamdUpdateInterval {
                        aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                        lastAAMDUpdate = now
                    }
                }

            case .complete, .streamEnd:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }

                fileSize = totalDownloaded
                segmentCount = 1
                if etag.isEmpty {
                    etag = communicator.lastETag
                }

                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                aamd.writeHeaders([
                    "ETAG": etag,
                    "SERVER_PATH": url.absoluteString,
                    "FILE_SIZE": String(totalDownloaded),
                    "SEGMENT_SIZE": String(segmentSize),
                    "NO_Of_BYTES_TO_DOWNLOAD": String(totalDownloaded),
                    "DOWNLOAD_START_ADDRESS": "0"
                ], segmentTableSpan: 0)

                await progressTracker.updateTotalBytes(totalDownloaded)
                await progressTracker.forceReport()
                rangeAvailabilityHandler?(totalDownloaded, true)
                communicator.closeStream()
                return .completed

            case .error(let errorCode):
                aamd.updateSegmentData(segment: 0, bytesDownloaded: totalDownloaded)
                communicator.closeStream()

                if state.current == .paused {
                    await progressTracker.forceReport()
                    return .paused(bytesDownloaded: totalDownloaded)
                }
                if state.current == .cancelled {
                    return .cancelled
                }

                return .error(PDMDownloadError(
                    code: errorCode,
                    message: "Indefinite download stream error at byte \(totalDownloaded)"
                ))
            }
        }
    }

    private func downloadMultiStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        maxSegments: Int,
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {

        let segments = bluestreakManager.calculateSegments(
            totalSize: fileSize,
            validationInfo: validationInfo
        )

        var finalResult: PDMDownloadResult = .completed

        do {
            try await withThrowingTaskGroup(of: PDMDownloadResult.self) { group in
                var activeCount = 0
                var segmentIndex = 0

                while segmentIndex < segments.count || activeCount > 0 {
                    if state.current == .paused {
                        group.cancelAll()
                        finalResult = .paused(bytesDownloaded: await progressTracker.currentDownloadedBytes)
                        return
                    }
                    if state.current == .cancelled {
                        group.cancelAll()
                        finalResult = .cancelled
                        return
                    }

                    while segmentIndex < segments.count && activeCount < maxSegments {
                        let segment = segments[segmentIndex]
                        let segIdx = segmentIndex

                        let alreadyDownloaded = aamd.getBytesDownloadedForSegment(segIdx)
                        let segSize = segment.endByte - segment.startByte + 1

                        if alreadyDownloaded >= segSize {
                            segmentIndex += 1
                            continue
                        }

                        segmentIndex += 1
                        activeCount += 1

                        group.addTask { [weak self] in
                            guard let self else { return .cancelled }
                            return await self.downloadSegment(
                                segment: segment,
                                segmentIndex: segIdx,
                                url: url,
                                destinationURL: destinationURL,
                                headers: headers,
                                aamd: aamd
                            )
                        }
                    }

                    if let segResult = try await group.next() {
                        activeCount -= 1
                        switch segResult {
                        case .completed:
                            continue
                        case .paused(let bytes):
                            group.cancelAll()
                            finalResult = .paused(bytesDownloaded: bytes)
                            return
                        case .cancelled:
                            group.cancelAll()
                            finalResult = .cancelled
                            return
                        case .error(let err):
                            group.cancelAll()
                            finalResult = .error(err)
                            return
                        }
                    }
                }
            }
        } catch {
            if state.current == .paused {
                return .paused(bytesDownloaded: await progressTracker.currentDownloadedBytes)
            }
            if state.current == .cancelled {
                return .cancelled
            }
            return .error(PDMDownloadError(code: .downloadFailed, message: error.localizedDescription))
        }

        return finalResult
    }

    private func downloadSegment(
        segment: PDMSegment,
        segmentIndex: Int,
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {
        let alreadyDownloaded = aamd.getBytesDownloadedForSegment(segmentIndex)
        let segmentSize = segment.endByte - segment.startByte + 1
        if alreadyDownloaded >= segmentSize {
            return .completed
        }

        let startByte = segment.startByte + alreadyDownloaded

        let segmentComm = PDMHttpCommunicator()
        segmentComm.setUserAgent(PDMHttpCommunicator.buildFFCUserAgent())

        guard segmentComm.initHttpDownload(
            url: url,
            startByte: startByte,
            endByte: segment.endByte,
            headers: headers
        ) else {
            return .error(PDMDownloadError.downloadFailed("Failed to init segment \(segment.index)"))
        }

        guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else {
            return .error(PDMDownloadError.downloadFailed("Cannot open file for writing"))
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(segment.startByte + alreadyDownloaded))
        } catch {
            return .error(PDMDownloadError.downloadFailed("Cannot seek to segment offset"))
        }

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var bytesDownloaded = alreadyDownloaded
        var bytesSinceLastAAMDUpdate: Int64 = 0
        let aamdUpdateThreshold: Int64 = 0x40000

        while true {
            if state.current == .paused {
                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                segmentComm.closeStream()
                return .paused(bytesDownloaded: bytesDownloaded)
            }

            if state.current == .cancelled {
                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                segmentComm.closeStream()
                return .cancelled
            }

            let (result, bytesRead) = segmentComm.downloadRemainingData(
                buffer: buffer,
                bufferSize: bufferSize
            )

            if let responseError = validateDownloadResponse(
                communicator: segmentComm,
                expectedStart: startByte,
                expectedEnd: segment.endByte,
                expectedTotalSize: fileSize,
                allowFullResponse: false
            ) {
                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                segmentComm.closeStream()
                return .error(responseError)
            }

            switch result {
            case .moreData:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    bytesDownloaded += Int64(bytesRead)
                    bytesSinceLastAAMDUpdate += Int64(bytesRead)
                    if bytesDownloaded > segmentSize {
                        aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                        segmentComm.closeStream()
                        return .error(PDMDownloadError.downloadFailed("Segment \(segment.index) size overflow: \(bytesDownloaded)/\(segmentSize)"))
                    }
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                    if bytesSinceLastAAMDUpdate >= aamdUpdateThreshold {
                        aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                        bytesSinceLastAAMDUpdate = 0
                    }
                }

            case .complete, .streamEnd:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    bytesDownloaded += Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }

                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)

                guard bytesDownloaded == segmentSize else {
                    segmentComm.closeStream()
                    return .error(PDMDownloadError(code: .needRetry, message: "Segment \(segment.index) incomplete: \(bytesDownloaded)/\(segmentSize)"))
                }

                if !segment.expectedHash.isEmpty, let info = validationInfo {
                    guard let readHandle = try? FileHandle(forReadingFrom: destinationURL) else {
                        return .error(PDMDownloadError.downloadFailed("Cannot open file for hash validation"))
                    }
                    defer { try? readHandle.close() }

                    do {
                        try readHandle.seek(toOffset: UInt64(segment.startByte))
                        let segmentData = readHandle.readData(ofLength: Int(segmentSize))
                        guard segmentData.count == Int(segmentSize) else {
                            return .error(PDMDownloadError.downloadFailed("Cannot read full segment for validation"))
                        }
                        let valid = validationManager.validateSegment(
                            data: segmentData,
                            expectedHash: segment.expectedHash,
                            algorithm: info.algorithm
                        )
                        if !valid {
                            return .error(PDMDownloadError.segmentValidationFailed(segment.index))
                        }
                    } catch {
                        return .error(PDMDownloadError.downloadFailed("Hash validation read error"))
                    }
                }

                rangeAvailabilityHandler?(segment.endByte + 1, false)
                return .completed

            case .error(let errorCode):
                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
                segmentComm.closeStream()

                if state.current == .paused {
                    return .paused(bytesDownloaded: bytesDownloaded)
                }
                if state.current == .cancelled {
                    return .cancelled
                }

                return .error(PDMDownloadError(
                    code: errorCode,
                    message: "Segment \(segment.index) download error"
                ))
            }
        }
    }

    private func validateDownloadResponse(
        communicator: PDMHttpCommunicator,
        expectedStart: Int64,
        expectedEnd: Int64,
        expectedTotalSize: Int64,
        allowFullResponse: Bool
    ) -> PDMDownloadError? {
        let statusCode = communicator.lastResponseStatusCode
        guard statusCode != 0 else {
            return nil
        }

        if statusCode == 206 {
            guard contentRangeMatches(
                communicator.lastContentRange,
                expectedStart: expectedStart,
                expectedEnd: expectedEnd,
                expectedTotalSize: expectedTotalSize
            ) else {
                return PDMDownloadError.downloadFailed("Invalid Content-Range: \(communicator.lastContentRange)")
            }
            return nil
        }

        if allowFullResponse && expectedStart == 0 && statusCode == 200 {
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

        if rangeAndTotal[1] != "*",
           let actualTotal = Int64(rangeAndTotal[1]),
           expectedTotalSize > 0,
           actualTotal != expectedTotalSize {
            return false
        }

        return actualStart == expectedStart && actualEnd == expectedEnd
    }
}
