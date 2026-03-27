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
        validationURL: String? = nil,
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
