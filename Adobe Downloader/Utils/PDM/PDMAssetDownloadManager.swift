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

        fileSize = totalSize
        if fileSize <= 0 {
            fileSize = validationManager.getRemoteFileSize(
                url: url.absoluteString,
                headers: headers
            )
        }

        let aamd = AAMDFileManager(downloadFileURL: destinationURL)
        self.aamd = aamd

        downloadMode = bluestreakManager.resolveDownloadMode(
            communicator: communicator,
            url: url,
            headers: headers,
            fileSize: fileSize
        )

        segmentSize = validationInfo?.segmentSize ?? Int64(2 * 1024 * 1024)
        segmentCount = downloadMode.isSingleStream ? 1 : max(1, Int((fileSize + segmentSize - 1) / segmentSize))

        var resumeBytes: Int64 = 0

        if aamd.exists() {
            if aamd.validateAAMDFile(),
               aamd.validateHeaders(
                   remoteETag: etag,
                   remoteFileSize: fileSize,
                   remoteURL: url.absoluteString,
                   segmentSize: segmentSize
               ) {
                resumeBytes = aamd.getTotalBytesDownloaded(segmentCount: segmentCount)
            } else {
                aamd.remove()
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        if !aamd.exists() {
            aamd.writeMetaInfo()
            aamd.writeHeaders([
                "ETAG": etag,
                "SERVER_PATH": url.absoluteString,
                "FILE_SIZE": String(fileSize),
                "SEGMENT_SIZE": String(segmentSize),
                "NO_Of_BYTES_TO_DOWNLOAD": String(fileSize),
                "DOWNLOAD_START_ADDRESS": "0"
            ], segmentCount: segmentCount)

            try? FileManager.default.removeItem(at: destinationURL)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: destinationURL) {
                fh.truncateFile(atOffset: UInt64(fileSize))
                try? fh.close()
            }
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
                let action = await errorHandler.handleError(errorCode)

                switch action {
                case .retry:
                    shouldRetry = true
                    communicator.reset()
                case .switchToSingleStreamAndRetry:
                    downloadMode = .singleStream
                    bluestreakManager.disableBluestreak(reason: "Error \(errorCode.rawValue)")
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

    private func downloadSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        aamd: AAMDFileManager
    ) async -> PDMDownloadResult {

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

            if startByte > 0 && communicator.lastResponseStatusCode == 200 {
                aamd.updateSegmentData(segment: 0, bytesDownloaded: 0)
                communicator.closeStream()
                return .error(PDMDownloadError.downloadFailed("Server does not support Range requests, restarting"))
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
        return .completed
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

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var segmentData = Data()
        var bytesDownloaded = alreadyDownloaded

        if alreadyDownloaded > 0 {
            guard let fileHandle = try? FileHandle(forReadingFrom: destinationURL) else {
                return .error(PDMDownloadError.downloadFailed("Cannot open file for segment resume"))
            }
            defer { try? fileHandle.close() }

            do {
                try fileHandle.seek(toOffset: UInt64(segment.startByte))
                segmentData = fileHandle.readData(ofLength: Int(alreadyDownloaded))
            } catch {
                return .error(PDMDownloadError.downloadFailed("Cannot read resumed segment data"))
            }
        }

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

            switch result {
            case .moreData:
                if bytesRead > 0 {
                    segmentData.append(buffer, count: bytesRead)
                    bytesDownloaded += Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }

            case .complete, .streamEnd:
                if bytesRead > 0 {
                    segmentData.append(buffer, count: bytesRead)
                    bytesDownloaded += Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }

                if !segment.expectedHash.isEmpty, let info = validationInfo {
                    let valid = validationManager.validateSegment(
                        data: segmentData,
                        expectedHash: segment.expectedHash,
                        algorithm: info.algorithm
                    )
                    if !valid {
                        return .error(PDMDownloadError.segmentValidationFailed(segment.index))
                    }
                }

                guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else {
                    return .error(PDMDownloadError.downloadFailed("Cannot open file for segment write"))
                }
                do {
                    try fileHandle.seek(toOffset: UInt64(segment.startByte))
                    fileHandle.write(segmentData)
                    try fileHandle.close()
                } catch {
                    return .error(PDMDownloadError.downloadFailed("File write error: \(error.localizedDescription)"))
                }

                aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: bytesDownloaded)
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
}
