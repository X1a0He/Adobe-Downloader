//
//  PDMCookieManager.swift
//  Adobe Downloader
//

import Foundation

final class PDMCookieManager {

    static let shared = PDMCookieManager()

    private let storage = HTTPCookieStorage.shared
    private let lock = NSLock()

    private init() {}

    func saveCookies(from headers: [String: String], for url: URL) {
        lock.lock()
        defer { lock.unlock() }

        let httpHeaders = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = pair.value
        }

        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: httpHeaders,
            for: url
        )

        for cookie in cookies {
            storage.setCookie(cookie)
        }
    }

    func saveCookies(from cfHeaders: CFHTTPMessage, for url: URL) {
        guard let headerDict = CFHTTPMessageCopyAllHeaderFields(cfHeaders)?.takeRetainedValue() as? [String: String] else {
            return
        }
        saveCookies(from: headerDict, for: url)
    }

    func cookieHeader(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let cookies = storage.cookies(for: url), !cookies.isEmpty else {
            return nil
        }

        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        return headerFields["Cookie"]
    }

    func applyCookies(to request: CFHTTPMessage, url: URL) {
        if let cookieValue = cookieHeader(for: url) {
            CFHTTPMessageSetHeaderFieldValue(
                request,
                "Cookie" as CFString,
                cookieValue as CFString
            )
        }
    }

    func extractCookiesFromURL(_ urlString: String) {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return
        }

        for item in queryItems where item.name.lowercased() == "cookie" {
            if let value = item.value, !value.isEmpty {
                let syntheticHeaders = ["Set-Cookie": value]
                saveCookies(from: syntheticHeaders, for: url)
            }
        }
    }

    func clearCookies(for domain: String) {
        lock.lock()
        defer { lock.unlock() }

        if let cookies = storage.cookies {
            for cookie in cookies where cookie.domain.contains(domain) {
                storage.deleteCookie(cookie)
            }
        }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        if let cookies = storage.cookies {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
    }
}
