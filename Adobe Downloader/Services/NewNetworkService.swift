//
//  NewNetworkService.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation

class NewNetworkService {
    typealias ProductsData = ([Product], [UniqueProduct])

    private func makeProductsURL() throws -> URL {
        var components = URLComponents(string: NetworkConstants.productsURL)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "channel", value: "ccm"),
            URLQueryItem(name: "channel", value: "sti"),
        ]

        #if arch(arm64)
        queryItems.append(URLQueryItem(name: "platform", value: "macarm64"))
        #endif
        queryItems.append(URLQueryItem(name: "platform", value: "macuniversal"))
        queryItems.append(URLQueryItem(name: "platform", value: "osx10-64"))
        queryItems.append(URLQueryItem(name: "platform", value: "osx10"))

        queryItems.append(URLQueryItem(name: "payload", value: "true"))
        queryItems.append(URLQueryItem(name: "productType", value: "Desktop"))
        queryItems.append(URLQueryItem(name: "_type", value: "json"))

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw NetworkError.invalidURL(NetworkConstants.productsURL)
        }
        return url
    }

    func fetchProductsData() async throws -> ProductsData {
        let url = try makeProductsURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.ffcRequestTimeout

        NetworkConstants.ffcRequestHeaders.forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, nil)
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData("无法解码JSON数据")
        }

        let result: ProductsData = try await Task.detached(priority: .userInitiated) {
            try NewJSONParser.parse(jsonString: jsonString)

            let products = globalCcmResult.products

            if products.isEmpty { return ([], []) }

            let validProducts = products.filter { $0.hasValidVersions(allowedPlatform: StorageData.shared.allowedPlatform) }

            var uniqueProductsDict = [String: UniqueProduct]()
            for product in validProducts {
                uniqueProductsDict[product.id] = UniqueProduct(id: product.id, displayName: product.displayName)
            }
            let uniqueProducts = Array(uniqueProductsDict.values)

            return (products, uniqueProducts)
        }.value

        return result
    }

    func getApplicationInfo(
        buildGuid: String,
        sapCode: String? = nil,
        version: String? = nil,
        platform: String? = nil
    ) async throws -> String {
        let url: URL

        if let sapCode = sapCode, let version = version {
            var components = URLComponents(string: NetworkConstants.applicationJsonURLV3)
            var queryItems = [
                URLQueryItem(name: "name", value: sapCode),
                URLQueryItem(name: "version", value: version),
            ]
            if let platform = platform {
                queryItems.append(URLQueryItem(name: "platform", value: platform))
            }
            components?.queryItems = queryItems
            guard let builtURL = components?.url else {
                throw NetworkError.invalidURL(NetworkConstants.applicationJsonURLV3)
            }
            url = builtURL
        } else {
            guard let directURL = URL(string: NetworkConstants.applicationJsonURLV3) else {
                throw NetworkError.invalidURL(NetworkConstants.applicationJsonURLV3)
            }
            url = directURL
        }

        var lastError: Error?

        for attempt in 0..<NetworkConstants.maxServiceCallRetries {
            do {
                let result = try await performApplicationJsonRequest(url: url, buildGuid: buildGuid)

                if result == "Build is not operational" {
                    throw NetworkError.invalidData(
                        "该版本已被Adobe撤销 (SapCode: \(sapCode ?? "unknown"), version: \(version ?? "unknown"))"
                    )
                }

                return result

            } catch {
                lastError = error

                if case NetworkError.invalidData = error { throw error }

                if attempt < NetworkConstants.maxServiceCallRetries - 1 {
                    let delay = UInt64(5 * (attempt + 1)) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError ?? NetworkError.invalidResponse
    }

    private func performApplicationJsonRequest(url: URL, buildGuid: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.serviceCallTimeout

        var headers = NetworkConstants.applicationJsonHeaders
        if !buildGuid.isEmpty {
            headers["x-adobe-build-guid"] = buildGuid
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 412 else {
            throw NetworkError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData("无法将响应数据转换为json字符串")
        }

        if jsonString.isEmpty {
            throw NetworkError.invalidData("收到空响应，将进行重试")
        }

        return jsonString
    }
}
