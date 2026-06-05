//
//  PDMDownloadEngine.swift
//  Adobe Downloader
//

import Foundation

final class PDMDownloadEngine {

    static let shared = PDMDownloadEngine()

    private var activeManagers: [String: PDMAssetDownloadManager] = [:]
    private let managersLock = NSLock()

    private init() {}

    func downloadFile(
        packageId: String,
        url: URL,
        destinationURL: URL,
        headers: [String: String],
        expectedTotalSize: Int64 = 0,
        validationURL: String? = nil,
        validationURLs: [String] = [],
        progressHandler: ((Int64, Int64, Double) -> Void)?,
        rangeAvailabilityHandler: ((Int64, Bool) -> Void)? = nil
    ) async -> PDMDownloadResult {

        let headerTuples = headers.map { ($0.key, $0.value) }
        let enrichedHeaders = enrichHeaders(headerTuples)

        if let existingManager = getManager(packageId), existingManager.state.current == .paused {
            return await existingManager.resumeDownload()
        }

        let communicator = PDMHttpCommunicator()
        var totalSize: Int64 = 0
        var etag = ""
        var validationInfo: ValidationInfo? = nil

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
            etag = sizeResponse.headers["ETag"] ?? sizeResponse.headers["etag"] ?? ""
        }

        if totalSize <= 0, expectedTotalSize > 0 {
            totalSize = expectedTotalSize
        }

        let validationCandidates = normalizedValidationCandidates(
            primary: validationURL,
            candidates: validationURLs
        )

        if !validationCandidates.isEmpty {
            let validationMgr = PDMValidationManager(communicator: communicator)
            for validationURLString in validationCandidates {
                validationInfo = validationMgr.fetchValidationInfo(
                    from: validationURLString,
                    headers: enrichedHeaders
                )
                if validationInfo != nil {
                    break
                }
            }
            guard validationInfo != nil else {
                return .error(PDMDownloadError(
                    code: .downloadFailed,
                    message: "Validation data could not be downloaded or parsed"
                ))
            }

            if let info = validationInfo {
                let validationSize = validationTotalSize(info)
                if expectedTotalSize > 0, validationSize > 0, validationSize != expectedTotalSize {
                    return .error(PDMDownloadError(
                        code: .signatureValidationFailed,
                        message: "Validation size does not match expected package size"
                    ))
                }
                if totalSize <= 0 {
                    totalSize = validationSize
                } else if validationSize > 0, totalSize != validationSize {
                    return .error(PDMDownloadError(
                        code: .signatureValidationFailed,
                        message: "Validation size does not match remote package size"
                    ))
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

        let manager = PDMAssetDownloadManager(
            communicator: communicator,
            bluestreakConfig: bluestreakConfig
        )

        setManager(packageId, manager: manager)

        let result = await manager.downloadFile(
            url: url,
            destinationURL: destinationURL,
            headers: enrichedHeaders,
            totalSize: totalSize,
            validationInfo: validationInfo,
            etag: etag,
            progressHandler: progressHandler,
            rangeAvailabilityHandler: rangeAvailabilityHandler
        )

        switch result {
        case .completed, .cancelled:
            removeManager(packageId)
        case .paused:
            break
        case .error:
            removeManager(packageId)
        }

        return result
    }

    private func normalizedValidationCandidates(primary: String?, candidates: [String]) -> [String] {
        var result: [String] = []
        for value in [primary].compactMap({ $0 }) + candidates {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    private func validationTotalSize(_ info: ValidationInfo) -> Int64 {
        guard info.segmentCount > 0, info.segmentSize > 0 else {
            return 0
        }
        let lastSegmentSize = info.lastSegmentSize > 0 ? info.lastSegmentSize : info.segmentSize
        return Int64(max(0, info.segmentCount - 1)) * info.segmentSize + lastSegmentSize
    }

    func pause(packageId: String) {
        getManager(packageId)?.pause()
    }

    func cancelDownload(packageId: String) {
        getManager(packageId)?.cancelDownload()
        removeManager(packageId)
    }

    func pauseAll() {
        managersLock.lock()
        let managers = Array(activeManagers.values)
        managersLock.unlock()
        for manager in managers {
            manager.pause()
        }
    }

    func cancelAll() {
        managersLock.lock()
        let managers = activeManagers
        activeManagers.removeAll()
        managersLock.unlock()
        for (_, manager) in managers {
            manager.cancelDownload()
        }
    }

    private func getManager(_ packageId: String) -> PDMAssetDownloadManager? {
        managersLock.lock()
        defer { managersLock.unlock() }
        return activeManagers[packageId]
    }

    private func setManager(_ packageId: String, manager: PDMAssetDownloadManager) {
        managersLock.lock()
        defer { managersLock.unlock() }
        activeManagers[packageId] = manager
    }

    private func removeManager(_ packageId: String) {
        managersLock.lock()
        defer { managersLock.unlock() }
        activeManagers.removeValue(forKey: packageId)
    }

    private func enrichHeaders(_ headers: [(String, String)]) -> [(String, String)] {
        var result = headers
        if !result.contains(where: { $0.0.lowercased() == "x-adobe-app-id" }) {
            result.append(("x-adobe-app-id", PDMConstants.adobeAppId))
        }
        return result
    }
}
