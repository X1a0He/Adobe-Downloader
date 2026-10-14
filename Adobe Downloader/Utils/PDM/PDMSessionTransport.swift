//
//  PDMSessionTransport.swift
//  Adobe Downloader
//

import Foundation
import CFNetwork
import Security

/// 仅由 PDMDownloadIO.queue 调用实际收尾，保证提前取消与正常回调共用同一个完成屏障。
final class PDMTransferCompletion: @unchecked Sendable {
    private let handler: (Bool) throws -> Void
    private var result: Result<Void, Error>?

    init(handler: @escaping (Bool) throws -> Void) {
        self.handler = handler
    }

    func run(succeeded: Bool) -> Error? {
        if result == nil {
            result = Result { try handler(succeeded) }
        }
        if case .failure(let error)? = result { return error }
        return nil
    }

    func wait() async -> Error? {
        await withCheckedContinuation { continuation in
            PDMDownloadIO.queue.async {
                continuation.resume(returning: self.run(succeeded: false))
            }
        }
    }
}

enum PDMSessionTransportError: LocalizedError {
    case bodyTooLarge(limit: Int)
    case bufferLimitExceeded(limit: Int)
    case encodedBody(String)
    case multipleResponses

    var errorDescription: String? {
        switch self {
        case .bodyTooLarge(let limit):
            return "HTTP metadata response exceeds the \(limit)-byte limit"
        case .bufferLimitExceeded(let limit):
            return "Download write buffer exceeds the \(limit)-byte limit"
        case .encodedBody(let encoding):
            return "Download response uses unsupported Content-Encoding: \(encoding)"
        case .multipleResponses:
            return "Download returned more than one response body"
        }
    }
}

/// URLSession 回调、任务表和限流计数都限定在同一串行队列；正文只在专用队列写盘。
final class PDMSessionTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Body {
        case headersOnly
        case collected(maximumBytes: Int)
        case streaming(
            response: (PDMHTTPResponse) throws -> Void,
            data: (Data) throws -> Void,
            completion: PDMTransferCompletion
        )
    }

    private struct SessionKey: Hashable {
        let host: String
        let port: Int
        let type: Int
        let username: String
        let password: String

        init(proxy: PDMProxyConfig) {
            host = proxy.isConfigured ? proxy.host : ""
            port = proxy.isConfigured ? proxy.port : 0
            username = proxy.isConfigured ? proxy.username : ""
            password = proxy.isConfigured ? proxy.password : ""
            switch proxy.isConfigured ? proxy.type : .none {
            case .none: type = 0
            case .http: type = 1
            case .https: type = 2
            case .socks: type = 3
            }
        }
    }

    private final class RequestState: @unchecked Sendable {
        let task: URLSessionDataTask
        let originalRequest: URLRequest
        let useCookies: Bool
        let explicitCookie: String?
        let autoRedirect: Bool
        let validateSSL: Bool
        let body: Body
        let cancellation: PDMTransferCancellation
        let stopWrites = PDMTransferCancellation()
        let continuation: CheckedContinuation<PDMHTTPResponse, Error>
        var observation: UUID?
        var deadline: DispatchWorkItem?
        var response: PDMHTTPResponse?
        var failure: Error?
        var pendingBytes = 0
        var suspendedForWrites = false
        var stoppedAfterHeaders = false
        var networkFinished = false
        var completionFinished = false

        init(
            task: URLSessionDataTask,
            request: URLRequest,
            useCookies: Bool,
            explicitCookie: String?,
            autoRedirect: Bool,
            validateSSL: Bool,
            body: Body,
            cancellation: PDMTransferCancellation,
            continuation: CheckedContinuation<PDMHTTPResponse, Error>
        ) {
            self.task = task
            originalRequest = request
            self.useCookies = useCookies
            self.explicitCookie = explicitCookie
            self.autoRedirect = autoRedirect
            self.validateSSL = validateSSL
            self.body = body
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }

    private static let poolLock = NSLock()
    private static var pool: [SessionKey: PDMSessionTransport] = [:]
    private static let highWatermark = 512 * 1024
    private static let lowWatermark = 256 * 1024
    private static let hardBufferLimit = 8 * 1024 * 1024

    private let controlQueue = DispatchQueue(
        label: "com.x1a0he.macOS.Adobe-Downloader.httpCallbacks",
        qos: .utility
    )
    private let delegateQueue: OperationQueue
    private let proxy: PDMProxyConfig
    private let singleRequestSession: Bool
    private let configuration: URLSessionConfiguration
    private var requests: [Int: RequestState] = [:]
    private lazy var session: URLSession = {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = PDMConstants.deadConnectionTimeoutSeconds
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        if proxy.isConfigured {
            configuration.connectionProxyDictionary = Self.proxyDictionary(proxy)
        }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    static func transport(proxy: PDMProxyConfig, validateSSL: Bool) -> PDMSessionTransport {
        // 服务端信任可能随连接复用；放宽证书校验的请求不得进入共享会话。
        if !validateSSL {
            return PDMSessionTransport(configuration: .ephemeral, proxy: proxy, singleRequestSession: true)
        }
        poolLock.lock()
        defer { poolLock.unlock() }
        let key = SessionKey(proxy: proxy)
        if let existing = pool[key] { return existing }
        let transport = PDMSessionTransport(configuration: .ephemeral, proxy: proxy, singleRequestSession: false)
        pool[key] = transport
        return transport
    }

    init(
        configuration: URLSessionConfiguration,
        proxy: PDMProxyConfig = PDMProxyConfig(),
        singleRequestSession: Bool = false
    ) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.proxy = proxy
        self.singleRequestSession = singleRequestSession
        delegateQueue = OperationQueue()
        super.init()
        delegateQueue.name = "PDM URLSession callbacks"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = controlQueue
    }

    func execute(
        request: URLRequest,
        useCookies: Bool,
        explicitCookie: String?,
        autoRedirect: Bool,
        validateSSL: Bool,
        body: Body,
        deadline: TimeInterval?,
        cancellation: PDMTransferCancellation
    ) async throws -> PDMHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { [self] in
                let task = self.session.dataTask(with: request)
                let state = RequestState(
                    task: task,
                    request: request,
                    useCookies: useCookies,
                    explicitCookie: explicitCookie,
                    autoRedirect: autoRedirect,
                    validateSSL: validateSSL,
                    body: body,
                    cancellation: cancellation,
                    continuation: continuation
                )
                self.requests[task.taskIdentifier] = state
                state.observation = cancellation.register { [weak self] in
                    guard let self else { return }
                    self.controlQueue.async { [weak self] in
                        guard let self, let current = self.requests[task.taskIdentifier] else { return }
                        self.fail(current, error: CancellationError())
                    }
                }
                if let deadline, deadline > 0 {
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self,
                              let current = self.requests[task.taskIdentifier],
                              !current.networkFinished else { return }
                        self.fail(current, error: URLError(.timedOut))
                    }
                    state.deadline = timeout
                    self.controlQueue.asyncAfter(deadline: .now() + deadline, execute: timeout)
                }

                // 即使取消先于登记到达，也创建并取消任务，以 didComplete 作为网络结束凭据。
                if cancellation.isCancelled {
                    self.fail(state, error: CancellationError())
                } else {
                    task.resume()
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let state = requests[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard state.failure == nil, !state.cancellation.isCancelled else {
            fail(state, error: CancellationError())
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fail(state, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        saveCookies(from: http)
        let parsed = Self.makeResponse(http)
        if state.response != nil {
            fail(state, error: PDMSessionTransportError.multipleResponses)
            completionHandler(.cancel)
            return
        }
        state.response = parsed

        switch state.body {
        case .headersOnly:
            state.stoppedAfterHeaders = true
            completionHandler(.cancel)
        case .collected(let maximumBytes):
            if parsed.contentLength > Int64(maximumBytes),
               state.originalRequest.httpMethod?.uppercased() != "HEAD" {
                fail(state, error: PDMSessionTransportError.bodyTooLarge(limit: maximumBytes))
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        case .streaming(let handler, _, _):
            let encoding = parsed.headers["content-encoding"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard encoding.isEmpty || encoding.caseInsensitiveCompare("identity") == .orderedSame else {
                fail(state, error: PDMSessionTransportError.encodedBody(encoding))
                completionHandler(.cancel)
                return
            }
            do {
                try handler(parsed)
                completionHandler(.allow)
            } catch {
                fail(state, error: error)
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = requests[dataTask.taskIdentifier],
              state.failure == nil,
              !state.cancellation.isCancelled,
              !data.isEmpty else { return }

        switch state.body {
        case .headersOnly:
            return
        case .collected(let maximumBytes):
            guard let collectedBytes = state.response?.data.count,
                  data.count <= maximumBytes - collectedBytes else {
                fail(state, error: PDMSessionTransportError.bodyTooLarge(limit: maximumBytes))
                return
            }
            state.response?.data.append(data)
        case .streaming(_, let handler, _):
            guard data.count <= Self.hardBufferLimit - state.pendingBytes else {
                fail(state, error: PDMSessionTransportError.bufferLimitExceeded(limit: Self.hardBufferLimit))
                return
            }
            state.pendingBytes += data.count
            if state.pendingBytes >= Self.highWatermark, !state.suspendedForWrites {
                state.suspendedForWrites = true
                dataTask.suspend()
            }
            let byteCount = data.count
            PDMDownloadIO.queue.async {
                var writeError: Error?
                if !state.cancellation.isCancelled && !state.stopWrites.isCancelled {
                    do {
                        try autoreleasepool { try handler(data) }
                    } catch {
                        writeError = error
                        state.stopWrites.cancel()
                    }
                }
                let failure = writeError
                self.controlQueue.async {
                    state.pendingBytes -= byteCount
                    if let failure {
                        self.fail(state, error: failure)
                    } else if state.failure == nil,
                              !state.cancellation.isCancelled,
                              !state.networkFinished,
                              state.suspendedForWrites,
                              state.pendingBytes <= Self.lowWatermark {
                        state.suspendedForWrites = false
                        state.task.resume()
                    }
                    self.finishIfReady(state)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = requests[task.taskIdentifier], !state.networkFinished else { return }
        state.networkFinished = true
        if state.suspendedForWrites {
            state.suspendedForWrites = false
            state.task.resume()
        }
        state.deadline?.cancel()
        state.deadline = nil

        if state.failure == nil {
            if state.cancellation.isCancelled {
                state.failure = CancellationError()
                state.stopWrites.cancel()
            } else if let error {
                let urlError = error as NSError
                let expectedHeaderStop = state.stoppedAfterHeaders
                    && urlError.domain == NSURLErrorDomain
                    && urlError.code == NSURLErrorCancelled
                if !expectedHeaderStop { state.failure = error }
            }
        }

        if case .streaming(_, _, let completion) = state.body {
            // 串行 delegate 队列保证此前所有正文均已入队，网络结束后才提交最终收尾。
            let networkSucceeded = state.failure == nil
            PDMDownloadIO.queue.async {
                let succeeded = networkSucceeded && !state.cancellation.isCancelled && !state.stopWrites.isCancelled
                let completionError = completion.run(succeeded: succeeded)
                self.controlQueue.async {
                    if state.failure == nil, let completionError {
                        state.failure = completionError
                    }
                    state.completionFinished = true
                    self.finishIfReady(state)
                }
            }
        } else {
            state.completionFinished = true
            finishIfReady(state)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let state = requests[task.taskIdentifier],
              state.failure == nil,
              !state.cancellation.isCancelled else {
            completionHandler(nil)
            return
        }
        saveCookies(from: response)
        guard state.autoRedirect else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let sameOrigin = Self.sameOrigin(state.originalRequest.url, redirected.url)
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        if state.useCookies, let url = redirected.url,
           let cookie = PDMCookieManager.shared.cookieHeader(for: url) {
            redirected.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if sameOrigin, let explicitCookie = state.explicitCookie {
            redirected.setValue(explicitCookie, forHTTPHeaderField: "Cookie")
        }
        if !sameOrigin {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let state = requests[task.taskIdentifier],
              state.failure == nil,
              !state.cancellation.isCancelled else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if !state.validateSSL,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else if challenge.protectionSpace.isProxy(),
                  proxy.isConfigured,
                  challenge.protectionSpace.host.caseInsensitiveCompare(proxy.host) == .orderedSame,
                  challenge.protectionSpace.port == proxy.port,
                  !proxy.username.isEmpty,
                  challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, URLCredential(
                user: proxy.username,
                password: proxy.password,
                persistence: .forSession
            ))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func fail(_ state: RequestState, error: Error) {
        if state.failure == nil { state.failure = error }
        state.stopWrites.cancel()
        // cancel 先于 resume，既释放本方 suspend 计数，也不会让暂停期间等待的正文继续成功。
        state.task.cancel()
        if state.suspendedForWrites {
            state.suspendedForWrites = false
            state.task.resume()
        }
    }

    private func finishIfReady(_ state: RequestState) {
        guard state.networkFinished, state.completionFinished, state.pendingBytes == 0,
              requests.removeValue(forKey: state.task.taskIdentifier) != nil else { return }
        if let observation = state.observation {
            state.cancellation.unregister(observation)
        }
        state.deadline?.cancel()
        if singleRequestSession { session.finishTasksAndInvalidate() }

        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
        } else if state.cancellation.isCancelled {
            state.continuation.resume(throwing: CancellationError())
        } else if let response = state.response {
            state.continuation.resume(returning: response)
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    private func saveCookies(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        PDMCookieManager.shared.saveCookies(from: headers, for: url)
    }

    private static func makeResponse(_ response: HTTPURLResponse) -> PDMHTTPResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return PDMHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            contentLength: Int64(headers["content-length"] ?? "") ?? max(0, response.expectedContentLength)
        )
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        let lhsScheme = lhs.scheme?.lowercased()
        let rhsScheme = rhs.scheme?.lowercased()
        let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
        return lhsScheme == rhsScheme && lhs.host?.lowercased() == rhs.host?.lowercased() && lhsPort == rhsPort
    }

    private static func proxyDictionary(_ proxy: PDMProxyConfig) -> [AnyHashable: Any] {
        switch proxy.type {
        case .http, .https:
            var dictionary: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port
            ]
            if proxy.isHTTPS {
                dictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
                dictionary[kCFNetworkProxiesHTTPSProxy as String] = proxy.host
                dictionary[kCFNetworkProxiesHTTPSPort as String] = proxy.port
            }
            return dictionary
        case .socks:
            var dictionary: [AnyHashable: Any] = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                kCFNetworkProxiesSOCKSPort as String: proxy.port
            ]
            if !proxy.username.isEmpty {
                dictionary[kCFStreamPropertySOCKSUser as String] = proxy.username
                dictionary[kCFStreamPropertySOCKSPassword as String] = proxy.password
            }
            return dictionary
        case .none:
            return [:]
        }
    }
}
