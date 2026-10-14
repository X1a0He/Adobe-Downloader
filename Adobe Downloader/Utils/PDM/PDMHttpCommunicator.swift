//
//  PDMHttpCommunicator.swift
//  Adobe Downloader
//

import Foundation

final class PDMHttpCommunicator: @unchecked Sendable {

    private let cancellation: PDMTransferCancellation
    private let injectedTransport: PDMSessionTransport?
    private let configurationLock = NSLock()
    private var proxyConfig = PDMProxyConfig()
    private var userAgent = PDMHttpCommunicator.buildFFCUserAgent()
    private var bluestreakDisabledDueToProxy = false

    var cancelDownload: Bool { cancellation.isCancelled || Task.isCancelled }

    init(
        cancellation: PDMTransferCancellation = PDMTransferCancellation(),
        transport: PDMSessionTransport? = nil
    ) {
        self.cancellation = cancellation
        injectedTransport = transport
    }

    func setProxy(_ config: PDMProxyConfig) {
        configurationLock.lock()
        proxyConfig = config
        configurationLock.unlock()
    }

    func setUserAgent(_ ua: String) {
        configurationLock.lock()
        userAgent = ua
        configurationLock.unlock()
    }

    func cancel() {
        cancellation.cancel()
    }

    func sendRequest(_ config: PDMHTTPRequestConfig) async throws -> PDMHTTPResponse {
        guard let url = URL(string: config.url) else { throw URLError(.badURL) }
        let settings = configurationSnapshot()
        let request = makeRequest(url: url, config: config, userAgent: settings.userAgent)
        return try await execute(
            request: request,
            config: config,
            proxy: settings.proxy,
            body: .collected(maximumBytes: 64 * 1024 * 1024),
            deadline: config.timeoutSeconds
        )
    }

    /// 只消费探测响应头。服务器忽略 Range 返回 200 时，也不会继续下载整个包。
    func checkByteRangeAcceptance(
        url: URL,
        headers: [(String, String)] = [],
        fileSize: Int64
    ) async -> Bool {
        guard fileSize > 1 else { return false }

        for attempt in 0..<max(1, PDMConstants.rangeCheckRetryCount) {
            guard !cancelDownload else { return false }
            if attempt > 0 {
                do {
                    // 旧常量保存的是 usleep 使用的微秒值。
                    try await Task.sleep(nanoseconds: UInt64(PDMConstants.rangeCheckRetryDelayMs) * 1_000)
                } catch {
                    return false
                }
            }
            guard !cancelDownload else { return false }

            let config = PDMHTTPRequestConfig(
                url: url.absoluteString,
                headers: headers,
                timeoutSeconds: PDMConstants.rangeCheckTimeoutSeconds,
                rangeStart: 0,
                rangeEnd: 0
            )
            let settings = configurationSnapshot()
            let request = makeRequest(url: url, config: config, userAgent: settings.userAgent)
            do {
                let response = try await execute(
                    request: request,
                    config: config,
                    proxy: settings.proxy,
                    body: .headersOnly,
                    deadline: config.timeoutSeconds
                )
                let contentRange = response.contentRange?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if response.statusCode == 206,
                   response.contentLength == 1,
                   contentRange == "bytes 0-0/\(fileSize)" {
                    return true
                }
            } catch {
                if cancelDownload || error is CancellationError { return false }
            }
        }
        return false
    }

    /// 数据及收尾回调均在专用 I/O 队列执行；返回前网络回调和所有写盘回调都已结束。
    func transfer(
        url: URL,
        range: ClosedRange<Int64>?,
        headers: [(String, String)] = [],
        responseHandler: @escaping (PDMHTTPResponse) throws -> Void,
        dataHandler: @escaping (Data) throws -> Void,
        completionHandler: @escaping (Bool) throws -> Void
    ) async throws -> PDMHTTPResponse {
        let config = PDMHTTPRequestConfig(
            url: url.absoluteString,
            headers: headers,
            timeoutSeconds: PDMConstants.deadConnectionTimeoutSeconds,
            rangeStart: range?.lowerBound,
            rangeEnd: range?.upperBound
        )
        let settings = configurationSnapshot()
        let request = makeRequest(url: url, config: config, userAgent: settings.userAgent)
        let completion = PDMTransferCompletion(handler: completionHandler)
        do {
            return try await execute(
                request: request,
                config: config,
                proxy: settings.proxy,
                body: .streaming(response: responseHandler, data: dataHandler, completion: completion),
                deadline: nil
            )
        } catch {
            // 预算等待或创建请求之前取消时，也要关闭调用方已经打开的文件。
            _ = await completion.wait()
            if settings.proxy.isHTTPS && url.scheme?.lowercased() == "https",
               !(error is CancellationError) {
                markBluestreakDisabledByProxy()
            }
            throw error
        }
    }

    var isBluestreakDisabledByProxy: Bool {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return bluestreakDisabledDueToProxy
    }

    private func configurationSnapshot() -> (proxy: PDMProxyConfig, userAgent: String) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return (proxyConfig, userAgent)
    }

    private func markBluestreakDisabledByProxy() {
        configurationLock.lock()
        bluestreakDisabledDueToProxy = true
        configurationLock.unlock()
    }

    private func makeRequest(
        url: URL,
        config: PDMHTTPRequestConfig,
        userAgent: String
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: config.timeoutSeconds
        )
        request.httpMethod = config.method
        request.httpShouldHandleCookies = false
        if config.useCookie, let cookie = PDMCookieManager.shared.cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let start = config.rangeStart, let end = config.rangeEnd {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        } else if let start = config.rangeStart {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // 分片偏移以原始实体字节为准，不能把透明解压后的正文写入 Range 对应位置。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func execute(
        request: URLRequest,
        config: PDMHTTPRequestConfig,
        proxy: PDMProxyConfig,
        body: PDMSessionTransport.Body,
        deadline: TimeInterval?
    ) async throws -> PDMHTTPResponse {
        let requestCancellation = PDMTransferCancellation()
        let observation = cancellation.register { requestCancellation.cancel() }
        defer { cancellation.unregister(observation) }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !requestCancellation.isCancelled else { throw CancellationError() }
            return try await PDMRequestScheduler.shared.withPermit(cancellation: requestCancellation) {
                let transport = config.validateSSL
                    ? (injectedTransport ?? PDMSessionTransport.transport(proxy: proxy, validateSSL: true))
                    : PDMSessionTransport.transport(proxy: proxy, validateSSL: false)
                return try await transport.execute(
                    request: request,
                    useCookies: config.useCookie,
                    explicitCookie: config.headers.last { $0.0.caseInsensitiveCompare("Cookie") == .orderedSame }?.1,
                    autoRedirect: config.autoRedirect,
                    validateSSL: config.validateSSL,
                    body: body,
                    deadline: deadline,
                    cancellation: requestCancellation
                )
            }
        } onCancel: {
            // 一个分片 Task 的取消不得污染其他分片共用的父令牌。
            requestCancellation.cancel()
        }
    }

    static func buildFFCUserAgent() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let appVersion = UserDefaults.standard.string(forKey: "adobeAppVersion") ?? "6.9.0.618"
        return "CreativeCloud/\(appVersion)/Mac-\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }
}
