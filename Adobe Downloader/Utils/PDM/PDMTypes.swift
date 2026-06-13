//
//  PDMTypes.swift
//  Adobe Downloader
//

import Foundation

enum PDMErrorCode: Int, CustomStringConvertible {
    case none = 0
    case manifestDownloadFailed = 107
    case bluestreakNotAvailable = 113
    case downloadFailed = 116
    case segmentValidationFailed = 117
    case cancelled = 118
    case criticalError = 119
    case needRetry = 126
    case signatureValidationFailed = 134

    var description: String {
        switch self {
        case .none: return "PDM_NO_ERROR"
        case .manifestDownloadFailed: return "PDM_MANIFEST_DOWNLOAD_FAILED"
        case .bluestreakNotAvailable: return "PDM_BLUESTREAK_NOT_AVAILABLE"
        case .downloadFailed: return "PDM_DOWNLOAD_FAILED"
        case .segmentValidationFailed: return "PDM_SEGMENT_VALIDATION_FAILED"
        case .cancelled: return "PDM_CANCELLED"
        case .criticalError: return "PDM_CRITICAL_ERROR"
        case .needRetry: return "PDM_NEED_RETRY"
        case .signatureValidationFailed: return "PDM_SIGNATURE_VALIDATION_FAILED"
        }
    }

    var isFatal: Bool {
        switch self {
        case .none, .downloadFailed, .needRetry, .cancelled:
            return false
        default:
            return true
        }
    }

    var shouldSwitchToSingleStream: Bool {
        self == .bluestreakNotAvailable || self == .segmentValidationFailed
    }
}

enum PDMStatusCode: Int {
    case downloading = 2
    case downloadingActive = 16
    case downloadComplete = 32
    case extractFailed = 64
    case extractPass = 128
    case cancelled = 4
}

enum PDMDownloadMode: Equatable {
    case singleStream
    case multiStream(maxSegments: Int)

    var isSingleStream: Bool {
        if case .singleStream = self { return true }
        return false
    }

    var maxSegments: Int {
        switch self {
        case .singleStream: return 1
        case .multiStream(let max): return max
        }
    }
}

enum PDMReadResult {
    case complete           // 0: 数据读取完毕
    case moreData           // 1: 还有更多数据
    case streamEnd          // 2: 流结束
    case error(PDMErrorCode) // 3: 读取错误
}

enum PDMErrorAction {
    case retry
    case switchToSingleStreamAndRetry
    case fatal
    case ignore
}

struct PDMProxyConfig {
    var host: String = ""
    var port: Int = 0
    var username: String = ""
    var password: String = ""
    var type: PDMProxyType = .none

    var isConfigured: Bool {
        !host.isEmpty && port > 0
    }

    var isHTTPS: Bool {
        type == .https
    }
}

enum PDMProxyType {
    case none
    case http
    case https
    case socks
}

struct PDMBluestreakConfig {
    var downloadEnabled: Bool = true
    var extractionV2Enabled: Bool = false
    var maxSegments: Int = 40
    var segmentSize: Int64 = 2 * 1024 * 1024
    var isAutoUpdate: Bool = false
    var isLowBandwidthMode: Bool = false
    var lowBandwidthMaxDelayMs: Int = 0
}

struct PDMProgress {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speed: Double = 0
    var segmentsCompleted: Int = 0
    var segmentsTotal: Int = 0

    var fraction: Double {
        totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
    }
}

struct PDMHTTPRequestConfig {
    var url: String
    var method: String = "GET"
    var headers: [(String, String)] = []
    var useCookie: Bool = true
    var autoRedirect: Bool = true
    var validateSSL: Bool = true
    var timeoutSeconds: Double = 300
    var rangeStart: Int64? = nil
    var rangeEnd: Int64? = nil
}

struct PDMHTTPResponse {
    var statusCode: Int = 0
    var headers: [String: String] = [:]
    var data: Data = Data()
    var contentLength: Int64 = 0

    var isSuccess: Bool {
        (200...299).contains(statusCode)
    }

    var isPartialContent: Bool {
        statusCode == 206
    }

    var supportsRangeRequests: Bool {
        headers["Accept-Ranges"]?.lowercased() == "bytes"
            || headers["accept-ranges"]?.lowercased() == "bytes"
    }

    var etag: String? {
        headers["ETag"] ?? headers["etag"]
    }

    var contentRange: String? {
        headers["Content-Range"] ?? headers["content-range"]
    }
}

enum PDMDownloadState: Int {
    case idle = 0
    case running = 1
    case paused = 2
    case cancelled = 3
    case completed = 4
    case error = 5
}

enum PDMDownloadResult {
    case completed
    case paused(bytesDownloaded: Int64)
    case cancelled
    case error(PDMDownloadError)
}

enum PDMConstants {
    static let pollingIntervalMs: UInt32 = 300_000
    static let rangeCheckRetryCount = 3
    static let rangeCheckRetryDelayMs: UInt32 = 100_000
    static let rangeCheckTimeoutSeconds: Double = 6.0
    static let maxDownloadRetries = 3
    static let downloadBufferSize = 64 * 1024
    static let deadConnectionTimeoutSeconds: Double = 101
    static let maxDeadConnections = 100

    static let adobeAppId = "accc-hdcore-desktop"

    static let cfRunLoopTimeout: Double = 1.0
}
