//
//  PDMDownloadEngine.swift
//  Adobe Downloader
//

import Foundation

final class PDMDownloadEngine {

    static let shared = PDMDownloadEngine()

    private init() {}

    func downloadFileWithChunks(
        packageIdentifier: String,
        url: URL,
        destinationURL: URL,
        headers: [String: String],
        validationURL: String? = nil,
        progressHandler: ((Double, Int64, Int64, Double) -> Void)?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil,
        cancellationHandler: (() async -> Bool)? = nil
    ) async throws {

        let headerTuples = headers.map { ($0.key, $0.value) }
        var totalSize: Int64 = 0
        var validationInfo: ValidationInfo? = nil

        let communicator = PDMHttpCommunicator()

        let enrichedHeaders = enrichHeaders(headerTuples)

        let sizeResponse = communicator.sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString,
            method: "HEAD",
            headers: enrichedHeaders,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 30
        ))

        if sizeResponse.isSuccess {
            totalSize = sizeResponse.contentLength
        }

        if let validationURLString = validationURL, !validationURLString.isEmpty {
            let validationMgr = PDMValidationManager(communicator: communicator)
            validationInfo = validationMgr.fetchValidationInfo(
                from: validationURLString,
                headers: enrichedHeaders
            )
            if validationInfo != nil && totalSize <= 0 {
                if let info = validationInfo {
                    let lastSeg = info.lastSegmentSize > 0
                        ? info.lastSegmentSize
                        : info.segmentSize
                    totalSize = Int64(max(0, info.segmentCount - 1)) * info.segmentSize + lastSeg
                }
            }
        }

        let bluestreakConfig = PDMBluestreakConfig(
            downloadEnabled: true,
            extractionV2Enabled: false,
            maxSegments: StorageData.shared.maxConcurrentDownloads,
            segmentSize: validationInfo?.segmentSize ?? (2 * 1024 * 1024),
            isAutoUpdate: false,
            isLowBandwidthMode: false
        )

        let assetManager = PDMAssetDownloadManager(
            communicator: communicator,
            bluestreakConfig: bluestreakConfig
        )

        try await assetManager.downloadFile(
            url: url,
            destinationURL: destinationURL,
            headers: enrichedHeaders,
            totalSize: totalSize,
            validationInfo: validationInfo,
            progressHandler: progressHandler,
            rangeAvailabilityHandler: rangeAvailabilityHandler,
            cancellationCheck: cancellationHandler
        )
    }

    private func enrichHeaders(_ headers: [(String, String)]) -> [(String, String)] {
        var result = headers

        if !result.contains(where: { $0.0.lowercased() == "x-adobe-app-id" }) {
            result.append(("x-adobe-app-id", PDMConstants.adobeAppId))
        }

        return result
    }
}
