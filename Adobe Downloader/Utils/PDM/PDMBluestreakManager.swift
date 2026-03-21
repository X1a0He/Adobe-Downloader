//
//  PDMBluestreakManager.swift
//  Adobe Downloader
//

import Foundation

final class PDMBluestreakManager {

    private(set) var config: PDMBluestreakConfig

    init(config: PDMBluestreakConfig = PDMBluestreakConfig()) {
        self.config = config
    }

    func resolveDownloadMode(
        communicator: PDMHttpCommunicator,
        url: URL,
        headers: [(String, String)],
        fileSize: Int64
    ) -> PDMDownloadMode {
        guard config.downloadEnabled else {
            return .singleStream
        }

        if config.isAutoUpdate {
            return .singleStream
        }

        if config.isLowBandwidthMode {
            return .singleStream
        }

        if communicator.isBluestreakDisabledByProxy {
            return .singleStream
        }

        if fileSize <= config.segmentSize {
            return .singleStream
        }

        let supportsRange = communicator.checkByteRangeAcceptance(
            url: url,
            headers: headers,
            fileSize: fileSize
        )

        if !supportsRange {
            return .singleStream
        }

        return .multiStream(maxSegments: config.maxSegments)
    }

    func disableBluestreak(reason: String) {
        config.downloadEnabled = false
        print("[PDMBluestreak] Disabled: \(reason)")
    }

    func calculateSegments(
        totalSize: Int64,
        validationInfo: ValidationInfo?
    ) -> [PDMSegment] {
        if let info = validationInfo, info.segmentCount > 0 {
            var segments: [PDMSegment] = []
            for i in 0..<info.segmentCount {
                let start = Int64(i) * info.segmentSize
                let size: Int64
                if i == info.segmentCount - 1 {
                    size = info.lastSegmentSize > 0 ? info.lastSegmentSize : (totalSize - start)
                } else {
                    size = info.segmentSize
                }
                let hash = i < info.segments.count ? info.segments[i].hash : ""
                segments.append(PDMSegment(
                    index: i,
                    startByte: start,
                    endByte: start + size - 1,
                    size: size,
                    expectedHash: hash
                ))
            }
            return segments
        }

        let segmentSize = config.segmentSize
        let count = Int(ceil(Double(totalSize) / Double(segmentSize)))
        var segments: [PDMSegment] = []

        for i in 0..<count {
            let start = Int64(i) * segmentSize
            let end = min(start + segmentSize - 1, totalSize - 1)
            let size = end - start + 1
            segments.append(PDMSegment(
                index: i,
                startByte: start,
                endByte: end,
                size: size,
                expectedHash: ""
            ))
        }

        return segments
    }

    var isOverlappedExtractionEnabled: Bool {
        config.extractionV2Enabled && config.downloadEnabled
    }
}

struct PDMSegment {
    let index: Int
    let startByte: Int64
    let endByte: Int64
    let size: Int64
    let expectedHash: String

    var downloadedBytes: Int64 = 0
    var isComplete: Bool = false
    var isDownloading: Bool = false
}
