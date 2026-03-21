//
//  PDMAssetDownloadManager.swift
//  Adobe Downloader
//

import Foundation

final class PDMAssetDownloadManager {

    private let communicator: PDMHttpCommunicator
    private let bluestreakManager: PDMBluestreakManager
    private let errorHandler: PDMErrorHandler
    private let validationManager: PDMValidationManager
    private let progressTracker: PDMProgressTracker

    private var downloadMode: PDMDownloadMode = .singleStream
    private var segments: [PDMSegment] = []
    private var isPaused = false
    private var isCancelled = false
    private var currentError: PDMErrorCode = .none

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

    func downloadFile(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        totalSize: Int64,
        validationInfo: ValidationInfo?,
        progressHandler: ((Double, Int64, Int64, Double) -> Void)?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil,
        cancellationCheck: (() async -> Bool)?
    ) async throws {
        isCancelled = false
        isPaused = false
        currentError = .none
        errorHandler.resetRetryCount()

        var fileSize = totalSize
        if fileSize <= 0 {
            fileSize = validationManager.getRemoteFileSize(
                url: url.absoluteString,
                headers: headers
            )
        }

        await progressTracker.configure(
            totalBytes: fileSize,
            segmentsTotal: 0,
            callback: progressHandler
        )

        downloadMode = bluestreakManager.resolveDownloadMode(
            communicator: communicator,
            url: url,
            headers: headers,
            fileSize: fileSize
        )

        var shouldRetry = true
        while shouldRetry {
            shouldRetry = false

            do {
                if let check = cancellationCheck, await check() {
                    throw PDMDownloadError.criticalError("Download cancelled")
                }

                switch downloadMode {
                case .singleStream:
                    try await downloadSingleStream(
                        url: url,
                        destinationURL: destinationURL,
                        headers: headers,
                        fileSize: fileSize,
                        rangeAvailabilityHandler: rangeAvailabilityHandler,
                        cancellationCheck: cancellationCheck
                    )
                case .multiStream(let maxSegments):
                    try await downloadMultiStream(
                        url: url,
                        destinationURL: destinationURL,
                        headers: headers,
                        fileSize: fileSize,
                        maxSegments: maxSegments,
                        validationInfo: validationInfo,
                        rangeAvailabilityHandler: rangeAvailabilityHandler,
                        cancellationCheck: cancellationCheck
                    )
                }

            } catch {
                let errorCode = PDMErrorHandler.classify(error)
                currentError = errorCode

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
                    throw error

                case .ignore:
                    break
                }
            }
        }

        if let info = validationInfo {
            let valid = try validationManager.validateFile(
                at: destinationURL,
                validationInfo: info,
                totalSize: fileSize
            )
            if !valid {
                throw PDMDownloadError.segmentValidationFailed(-1)
            }
        }

        rangeAvailabilityHandler?(fileSize, true)
    }

    private func downloadSingleStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        fileSize: Int64,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)?,
        cancellationCheck: (() async -> Bool)?
    ) async throws {
        var startByte: Int64 = 0
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let existingSize = attrs[.size] as? Int64 ?? 0
            if existingSize > 0 && existingSize < fileSize {
                startByte = existingSize
            } else if existingSize == fileSize {
                return  // 已完成
            }
        }

        if startByte == 0 && fileSize > 0 {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let fh = try FileHandle(forWritingTo: destinationURL)
            fh.truncateFile(atOffset: UInt64(fileSize))
            try fh.close()
        }

        let endByte = fileSize - 1
        guard communicator.initHttpDownload(
            url: url,
            startByte: startByte,
            endByte: endByte,
            headers: headers
        ) else {
            throw PDMDownloadError.downloadFailed("Failed to initialize HTTP download")
        }

        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: UInt64(startByte))

        await progressTracker.setDownloadedBytes(startByte)

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var totalDownloaded = startByte
        var remaining = fileSize - startByte

        while !isCancelled && remaining > 0 {
            if let check = cancellationCheck, await check() {
                throw PDMDownloadError.criticalError("Download cancelled")
            }

            let readSize = min(Int(remaining), bufferSize)
            let (result, bytesRead) = communicator.downloadRemainingData(
                buffer: buffer,
                bufferSize: readSize
            )

            switch result {
            case .moreData:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    remaining -= Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                    rangeAvailabilityHandler?(totalDownloaded, false)
                }

            case .complete, .streamEnd:
                if bytesRead > 0 {
                    fileHandle.write(Data(bytes: buffer, count: bytesRead))
                    totalDownloaded += Int64(bytesRead)
                    remaining -= Int64(bytesRead)
                    await progressTracker.addDownloadedBytes(Int64(bytesRead))
                }
                rangeAvailabilityHandler?(totalDownloaded, totalDownloaded >= fileSize)
                return

            case .error(let errorCode):
                throw PDMDownloadError(
                    code: errorCode,
                    message: "Download stream error at byte \(totalDownloaded)"
                )
            }
        }
    }

    private func downloadMultiStream(
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        fileSize: Int64,
        maxSegments: Int,
        validationInfo: ValidationInfo?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)?,
        cancellationCheck: (() async -> Bool)?
    ) async throws {
        segments = bluestreakManager.calculateSegments(
            totalSize: fileSize,
            validationInfo: validationInfo
        )

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let preallocHandle = try FileHandle(forWritingTo: destinationURL)
        preallocHandle.truncateFile(atOffset: UInt64(fileSize))
        try preallocHandle.close()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeCount = 0
            var segmentIndex = 0

            while segmentIndex < segments.count || activeCount > 0 {
                while segmentIndex < segments.count && activeCount < maxSegments {
                    let segment = segments[segmentIndex]
                    segmentIndex += 1
                    activeCount += 1

                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.downloadSegment(
                            segment: segment,
                            url: url,
                            destinationURL: destinationURL,
                            headers: headers,
                            validationInfo: validationInfo,
                            rangeAvailabilityHandler: rangeAvailabilityHandler,
                            cancellationCheck: cancellationCheck
                        )
                    }
                }

                try await group.next()
                activeCount -= 1
            }
        }
    }

    private func downloadSegment(
        segment: PDMSegment,
        url: URL,
        destinationURL: URL,
        headers: [(String, String)],
        validationInfo: ValidationInfo?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)?,
        cancellationCheck: (() async -> Bool)?
    ) async throws {
        let segmentComm = PDMHttpCommunicator()
        segmentComm.setUserAgent(PDMHttpCommunicator.buildFFCUserAgent())

        guard segmentComm.initHttpDownload(
            url: url,
            startByte: segment.startByte,
            endByte: segment.endByte,
            headers: headers
        ) else {
            throw PDMDownloadError.downloadFailed("Failed to init segment \(segment.index)")
        }

        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var segmentData = Data()
        var bytesDownloaded: Int64 = 0

        while !isCancelled {
            if let check = cancellationCheck, await check() {
                throw PDMDownloadError.criticalError("Download cancelled")
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
                        throw PDMDownloadError.segmentValidationFailed(segment.index)
                    }
                }

                let fileHandle = try FileHandle(forWritingTo: destinationURL)
                try fileHandle.seek(toOffset: UInt64(segment.startByte))
                fileHandle.write(segmentData)
                try fileHandle.close()

                await progressTracker.markSegmentComplete()
                rangeAvailabilityHandler?(segment.endByte + 1, false)
                return

            case .error(let errorCode):
                throw PDMDownloadError(
                    code: errorCode,
                    message: "Segment \(segment.index) download error"
                )
            }
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func cancel() {
        isCancelled = true
        communicator.cancel()
    }

    func getCurrentProgress() async -> PDMProgress {
        await progressTracker.getProgress()
    }

    func getCurrentError() -> PDMErrorCode {
        currentError
    }
}
