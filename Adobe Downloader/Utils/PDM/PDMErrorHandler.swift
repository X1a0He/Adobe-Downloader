//
//  PDMErrorHandler.swift
//  Adobe Downloader
//

import Foundation

final class PDMErrorHandler {

    private var retryCount = 0
    private let maxRetries = PDMConstants.maxDownloadRetries

    func handleError(_ errorCode: PDMErrorCode) async -> PDMErrorAction {
        switch errorCode {

        case .none:
            return .ignore

        case .cancelled:
            return .ignore

        case .bluestreakNotAvailable:
            retryCount = 0
            return .switchToSingleStreamAndRetry

        case .segmentValidationFailed:
            retryCount = 0
            return .switchToSingleStreamAndRetry

        case .criticalError:
            if retryCount < maxRetries {
                retryCount += 1
                let delaySeconds = UInt64(retryCount)
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                return .retry
            }
            return .fatal

        case .downloadFailed:
            if retryCount < maxRetries {
                retryCount += 1
                return .retry
            }
            return .fatal

        case .needRetry:
            if retryCount < maxRetries {
                retryCount += 1
                return .retry
            }
            return .fatal

        case .manifestDownloadFailed:
            return .fatal

        case .signatureValidationFailed:
            return .fatal
        }
    }

    func resetRetryCount() {
        retryCount = 0
    }

    var currentRetryCount: Int {
        retryCount
    }

    static func classify(_ error: Error) -> PDMErrorCode {
        let nsError = error as NSError

        switch nsError.domain {
        case NSURLErrorDomain:
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .criticalError           // 119
            case NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet:
                return .criticalError           // 119
            case NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return .downloadFailed          // 116
            case NSURLErrorCancelled:
                return .none
            default:
                return .needRetry               // 126
            }

        case NSPOSIXErrorDomain:
            switch nsError.code {
            case 28:  // ENOSPC - 磁盘空间不足
                return .criticalError
            default:
                return .downloadFailed
            }

        default:
            if let pdmError = error as? PDMDownloadError {
                return pdmError.errorCode
            }
            return .downloadFailed
        }
    }
}

struct PDMDownloadError: Error, LocalizedError {
    let errorCode: PDMErrorCode
    let message: String
    let underlyingError: Error?

    var errorDescription: String? {
        "PDM Error \(errorCode.rawValue): \(message)"
    }

    init(code: PDMErrorCode, message: String, underlying: Error? = nil) {
        self.errorCode = code
        self.message = message
        self.underlyingError = underlying
    }

    static func bluestreakNotAvailable(_ reason: String = "") -> PDMDownloadError {
        PDMDownloadError(code: .bluestreakNotAvailable, message: "Bluestreak not available: \(reason)")
    }

    static func segmentValidationFailed(_ segment: Int) -> PDMDownloadError {
        PDMDownloadError(code: .segmentValidationFailed, message: "Segment \(segment) validation failed")
    }

    static func downloadFailed(_ reason: String) -> PDMDownloadError {
        PDMDownloadError(code: .downloadFailed, message: reason)
    }

    static func criticalError(_ reason: String) -> PDMDownloadError {
        PDMDownloadError(code: .criticalError, message: reason)
    }
}
