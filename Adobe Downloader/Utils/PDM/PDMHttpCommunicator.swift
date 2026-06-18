//
//  PDMHttpCommunicator.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit

final class PDMHttpCommunicator {

    private var readStream: CFReadStream?
    private var runLoop: CFRunLoop?
    private var currentURL: URL?
    private var downloadInitialized = false
    private var isInDownloadMode = false
    private(set) var cancelDownload = false

    private let cookieManager = PDMCookieManager.shared
    private var proxyConfig: PDMProxyConfig = PDMProxyConfig()
    private var userAgent: String = ""
    private var bluestreakDisabledDueToProxy = false
    private var cookieSaved = false
    private var statusCodeChecked = false
    private(set) var lastResponseStatusCode: Int = 0
    private(set) var lastETag: String = ""
    private(set) var lastContentRange: String = ""
    private(set) var lastContentLength: Int64 = 0

    init() {
        userAgent = Self.buildFFCUserAgent()
    }

    func setProxy(_ config: PDMProxyConfig) {
        proxyConfig = config
    }

    func setUserAgent(_ ua: String) {
        userAgent = ua
    }

    func cancel() {
        cancelDownload = true
        closeStream()
    }

    func reset() {
        cancelDownload = false
        downloadInitialized = false
        isInDownloadMode = false
        cookieSaved = false
        closeStream()
    }

    func sendRequest(_ config: PDMHTTPRequestConfig) -> PDMHTTPResponse {
        guard let url = URL(string: config.url) else {
            return PDMHTTPResponse(statusCode: -1)
        }

        currentURL = url

        let cfURL = url as CFURL
        let cfMethod = config.method as CFString
        let request = CFHTTPMessageCreateRequest(
            kCFAllocatorDefault,
            cfMethod,
            cfURL,
            kCFHTTPVersion1_1
        ).takeRetainedValue()

        if config.useCookie {
            cookieManager.applyCookies(to: request, url: url)
        }

        if !userAgent.isEmpty {
            CFHTTPMessageSetHeaderFieldValue(request, "User-Agent" as CFString, userAgent as CFString)
        }

        if let start = config.rangeStart, let end = config.rangeEnd {
            let rangeValue = "bytes=\(start)-\(end)"
            CFHTTPMessageSetHeaderFieldValue(request, "Range" as CFString, rangeValue as CFString)
        } else if let start = config.rangeStart {
            let rangeValue = "bytes=\(start)-"
            CFHTTPMessageSetHeaderFieldValue(request, "Range" as CFString, rangeValue as CFString)
        }

        for (key, value) in config.headers {
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }

        let stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request).takeRetainedValue()

        if config.url.hasPrefix("https") {
            let sslSettings: [String: Any]
            if !config.validateSSL {
                sslSettings = [
                    kCFStreamSSLValidatesCertificateChain as String: false,
                    kCFStreamPropertySocketSecurityLevel as String: kCFStreamSocketSecurityLevelSSLv3
                ]
            } else {
                sslSettings = [
                    kCFStreamPropertySocketSecurityLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL
                ]
            }
            CFReadStreamSetProperty(
                stream,
                CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings),
                sslSettings as CFDictionary
            )
        }

        if proxyConfig.isConfigured {
            applyProxy(to: stream)
        }

        if config.autoRedirect {
            CFReadStreamSetProperty(
                stream,
                CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect),
                kCFBooleanTrue
            )
        }

        readStream = stream

        guard CFReadStreamOpen(stream) else {
            closeStream()
            return PDMHTTPResponse(statusCode: -1)
        }

        var responseData = Data()
        let bufferSize = PDMConstants.downloadBufferSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let deadline = Date().addingTimeInterval(config.timeoutSeconds)

        while !cancelDownload {
            if Date() > deadline {
                closeStream()
                return PDMHTTPResponse(statusCode: -1)
            }

            if CFReadStreamHasBytesAvailable(stream) {
                let bytesRead = CFReadStreamRead(stream, buffer, bufferSize)
                if bytesRead > 0 {
                    responseData.append(buffer, count: bytesRead)
                } else if bytesRead == 0 {
                    break  // 流结束
                } else {
                    closeStream()
                    return PDMHTTPResponse(statusCode: -1)
                }
            } else {
                let status = CFReadStreamGetStatus(stream)
                if status == .atEnd || status == .closed {
                    break
                }
                if status == .error {
                    closeStream()
                    return PDMHTTPResponse(statusCode: -1)
                }
                // 等待数据
                CFRunLoopRunInMode(.defaultMode, 0.01, true)
            }
        }

        let response = buildResponse(from: stream, data: responseData)

        cookieManager.saveCookies(from: response.headers, for: url)

        closeStream()
        return response
    }

    func initHttpDownload(
        url: URL,
        startByte: Int64,
        endByte: Int64,
        headers: [(String, String)] = [],
        validateSSL: Bool = true
    ) -> Bool {
        currentURL = url
        downloadInitialized = false
        statusCodeChecked = false
        lastResponseStatusCode = 0
        lastETag = ""
        lastContentRange = ""
        lastContentLength = 0

        let cfURL = url as CFURL
        let request = CFHTTPMessageCreateRequest(
            kCFAllocatorDefault,
            "GET" as CFString,
            cfURL,
            kCFHTTPVersion1_1
        ).takeRetainedValue()

        let rangeValue = "bytes=\(startByte)-\(endByte)"
        CFHTTPMessageSetHeaderFieldValue(request, "Range" as CFString, rangeValue as CFString)

        cookieManager.applyCookies(to: request, url: url)

        if !userAgent.isEmpty {
            CFHTTPMessageSetHeaderFieldValue(request, "User-Agent" as CFString, userAgent as CFString)
        }

        for (key, value) in headers {
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }

        let stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request).takeRetainedValue()

        if url.scheme == "https" {
            let sslSettings: [String: Any] = [
                kCFStreamPropertySocketSecurityLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL
            ]
            CFReadStreamSetProperty(
                stream,
                CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings),
                sslSettings as CFDictionary
            )
        }

        if proxyConfig.isConfigured {
            applyProxy(to: stream)
        }

        CFReadStreamSetProperty(
            stream,
            CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect),
            kCFBooleanTrue
        )

        readStream = stream

        guard CFReadStreamOpen(stream) else {
            closeStream()
            return false
        }

        downloadInitialized = true
        return true
    }

    func initIndefiniteHttpDownload(
        url: URL,
        headers: [(String, String)] = [],
        validateSSL: Bool = true
    ) -> Bool {
        currentURL = url
        downloadInitialized = false
        statusCodeChecked = false
        lastResponseStatusCode = 0
        lastETag = ""
        lastContentRange = ""
        lastContentLength = 0

        let cfURL = url as CFURL
        let request = CFHTTPMessageCreateRequest(
            kCFAllocatorDefault,
            "GET" as CFString,
            cfURL,
            kCFHTTPVersion1_1
        ).takeRetainedValue()

        cookieManager.applyCookies(to: request, url: url)

        if !userAgent.isEmpty {
            CFHTTPMessageSetHeaderFieldValue(request, "User-Agent" as CFString, userAgent as CFString)
        }

        for (key, value) in headers {
            CFHTTPMessageSetHeaderFieldValue(request, key as CFString, value as CFString)
        }

        let stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request).takeRetainedValue()

        if url.scheme == "https" {
            let sslSettings: [String: Any] = [
                kCFStreamPropertySocketSecurityLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL
            ]
            CFReadStreamSetProperty(
                stream,
                CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings),
                sslSettings as CFDictionary
            )
        }

        if proxyConfig.isConfigured {
            applyProxy(to: stream)
        }

        CFReadStreamSetProperty(
            stream,
            CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPShouldAutoredirect),
            kCFBooleanTrue
        )

        readStream = stream

        guard CFReadStreamOpen(stream) else {
            closeStream()
            return false
        }

        downloadInitialized = true
        return true
    }

    func checkByteRangeAcceptance(
        url: URL,
        headers: [(String, String)] = [],
        fileSize: Int64
    ) -> Bool {
        guard fileSize > 1 else {
            return false
        }

        for attempt in 0...PDMConstants.rangeCheckRetryCount {
            if attempt > 0 {
                usleep(PDMConstants.rangeCheckRetryDelayMs)
            }

            let startByte = fileSize - 2
            let endByte = fileSize - 1

            guard initHttpDownload(
                url: url,
                startByte: startByte,
                endByte: endByte,
                headers: headers
            ) else {
                closeStream()
                continue
            }

            let deadline = Date().addingTimeInterval(PDMConstants.rangeCheckTimeoutSeconds)
            var gotResponse = false
            var statusCode = 0
            var contentLength: Int64 = -1

            while !cancelDownload && Date() < deadline {
                guard let stream = readStream else { break }

                if CFReadStreamHasBytesAvailable(stream) {
                    if let responseMsg = CFReadStreamCopyProperty(
                        stream,
                        CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
                    ) {
                        let cfResponse = responseMsg as! CFHTTPMessage
                        statusCode = CFHTTPMessageGetResponseStatusCode(cfResponse)

                        if let url = currentURL {
                            cookieManager.saveCookies(from: cfResponse, for: url)
                        }

                        if let headers = CFHTTPMessageCopyAllHeaderFields(cfResponse)?.takeRetainedValue() as? [String: String],
                           let length = headers["Content-Length"] ?? headers["content-length"] {
                            contentLength = Int64(length) ?? -1
                        }

                        gotResponse = true
                    }

                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
                    defer { buffer.deallocate() }
                    let _ = CFReadStreamRead(stream, buffer, 16)
                    break
                }

                let status = CFReadStreamGetStatus(stream)
                if status == .error || status == .atEnd {
                    break
                }

                CFRunLoopRunInMode(.defaultMode, 0.01, true)
            }

            closeStream()

            if gotResponse && statusCode == 206 && contentLength == 2 {
                return true
            }
        }

        return false
    }

    func downloadRemainingData(
        buffer: UnsafeMutablePointer<UInt8>,
        bufferSize: Int,
        progressCallback: ((Int64) -> Void)? = nil
    ) -> (result: PDMReadResult, bytesRead: Int) {
        guard !cancelDownload, let stream = readStream else {
            return (.error(.cancelled), 0)
        }

        isInDownloadMode = true
        defer { isInDownloadMode = false }

        if cancelDownload {
            return (.error(.cancelled), 0)
        }

        captureResponseMetadata()
        let bytesRead = CFReadStreamRead(stream, buffer, bufferSize)

        if bytesRead > 0 {
            progressCallback?(Int64(bytesRead))
            captureResponseMetadata()
            return (.moreData, bytesRead)
        } else if bytesRead == 0 {
            captureResponseMetadata()
            return (.complete, 0)
        } else {
            captureResponseMetadata()
            handleStreamError(stream)

            if proxyConfig.isHTTPS && currentURL?.scheme == "https" {
                bluestreakDisabledDueToProxy = true
            }

            return (.error(.downloadFailed), 0)
        }
    }

    func getResponseStatusCode() -> Int? {
        guard let stream = readStream,
              let responseMsg = CFReadStreamCopyProperty(
                  stream,
                  CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
              ) else {
            return nil
        }
        let cfResponse = responseMsg as! CFHTTPMessage
        return CFHTTPMessageGetResponseStatusCode(cfResponse)
    }

    func getResponseHeaders() -> [String: String] {
        guard let stream = readStream,
              let responseMsg = CFReadStreamCopyProperty(
                  stream,
                  CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
              ) else {
            return [:]
        }
        let cfResponse = responseMsg as! CFHTTPMessage
        guard let headers = CFHTTPMessageCopyAllHeaderFields(cfResponse)?.takeRetainedValue() as? [String: String] else {
            return [:]
        }
        return headers
    }

    var isBluestreakDisabledByProxy: Bool {
        bluestreakDisabledDueToProxy
    }

    func closeStream() {
        if let stream = readStream {
            CFReadStreamSetClient(stream, 0, nil, nil)
            if let rl = runLoop {
                CFReadStreamUnscheduleFromRunLoop(stream, rl, CFRunLoopMode.commonModes)
                runLoop = nil
            }
            CFReadStreamClose(stream)
            readStream = nil
        }
        downloadInitialized = false
        isInDownloadMode = false
    }

    private func applyProxy(to stream: CFReadStream) {
        guard proxyConfig.isConfigured else { return }

        var proxyDict: [String: Any] = [:]

        switch proxyConfig.type {
        case .http, .https:
            proxyDict[kCFStreamPropertyHTTPProxyHost as String] = proxyConfig.host
            proxyDict[kCFStreamPropertyHTTPProxyPort as String] = proxyConfig.port
            if proxyConfig.isHTTPS {
                proxyDict[kCFStreamPropertyHTTPSProxyHost as String] = proxyConfig.host
                proxyDict[kCFStreamPropertyHTTPSProxyPort as String] = proxyConfig.port
            }
        case .socks:
            proxyDict[kCFStreamPropertySOCKSProxyHost as String] = proxyConfig.host
            proxyDict[kCFStreamPropertySOCKSProxyPort as String] = proxyConfig.port
            if !proxyConfig.username.isEmpty {
                proxyDict[kCFStreamPropertySOCKSUser as String] = proxyConfig.username
                proxyDict[kCFStreamPropertySOCKSPassword as String] = proxyConfig.password
            }
        case .none:
            return
        }

        CFReadStreamSetProperty(
            stream,
            CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPProxy),
            proxyDict as CFDictionary
        )
    }

    private func buildResponse(from stream: CFReadStream, data: Data) -> PDMHTTPResponse {
        var response = PDMHTTPResponse()
        response.data = data

        guard let responseMsg = CFReadStreamCopyProperty(
            stream,
            CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
        ) else {
            return response
        }

        let cfResponse = responseMsg as! CFHTTPMessage
        response.statusCode = CFHTTPMessageGetResponseStatusCode(cfResponse)

        if let headers = CFHTTPMessageCopyAllHeaderFields(cfResponse)?.takeRetainedValue() as? [String: String] {
            response.headers = headers
            if let cl = headers["Content-Length"] ?? headers["content-length"] {
                response.contentLength = Int64(cl) ?? 0
            }
        }

        return response
    }

    private func captureResponseMetadata() {
        if statusCodeChecked { return }
        guard let stream = readStream,
              let responseMsg = CFReadStreamCopyProperty(
                  stream,
                  CFStreamPropertyKey(rawValue: kCFStreamPropertyHTTPResponseHeader)
              ) else {
            return
        }

        let cfResponse = responseMsg as! CFHTTPMessage

        if let url = currentURL, !cookieSaved {
            cookieManager.saveCookies(from: cfResponse, for: url)
            cookieSaved = true
        }

        if !statusCodeChecked {
            let statusCode = CFHTTPMessageGetResponseStatusCode(cfResponse)
            if statusCode > 0 {
                lastResponseStatusCode = statusCode
                statusCodeChecked = true
            }
        }

        if lastETag.isEmpty,
           let etagRef = CFHTTPMessageCopyHeaderFieldValue(cfResponse, "ETag" as CFString) {
            lastETag = etagRef.takeRetainedValue() as String
        }

        if lastContentRange.isEmpty,
           let contentRangeRef = CFHTTPMessageCopyHeaderFieldValue(cfResponse, "Content-Range" as CFString) {
            lastContentRange = contentRangeRef.takeRetainedValue() as String
        }

        if lastContentLength == 0,
           let contentLengthRef = CFHTTPMessageCopyHeaderFieldValue(cfResponse, "Content-Length" as CFString) {
            lastContentLength = Int64(contentLengthRef.takeRetainedValue() as String) ?? 0
        }
    }

    private func handleStreamError(_ stream: CFReadStream) {
        if let error = CFReadStreamCopyError(stream) {
            let domain = CFErrorGetDomain(error) as String? ?? "unknown"
            let code = CFErrorGetCode(error)
            print("[PDMHttpCommunicator] Stream error: domain=\(domain) code=\(code)")
        }
    }

    static func buildFFCUserAgent() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let appVersion = UserDefaults.standard.string(forKey: "adobeAppVersion") ?? "6.9.0.618"
        return "CreativeCloud/\(appVersion)/Mac-\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }
}
