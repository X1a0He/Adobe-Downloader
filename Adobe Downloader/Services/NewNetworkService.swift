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
        var components = URLComponents(string: NetworkConstants.productsJSONURL)
        components?.queryItems = [
            URLQueryItem(name: "channel", value: "ccm"),
            URLQueryItem(name: "channel", value: "sti"),
            URLQueryItem(name: "platform", value: "macarm64,macuniversal,osx10-64,osx10"),
            URLQueryItem(name: "_type", value: "json"),
            URLQueryItem(name: "productType", value: "Desktop")
        ]

        guard let url = components?.url else {
            throw NetworkError.invalidURL(NetworkConstants.productsJSONURL)
        }
        print(url)
        return url
    }

    private func configureRequest(_ request: inout URLRequest, headers: [String: String]) {
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    func fetchProductsData() async throws -> ProductsData {
        let url = try makeProductsURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configureRequest(&request, headers: NetworkConstants.adobeRequestHeaders)

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

    func getApplicationInfo(buildGuid: String) async throws -> String {
        guard let url = URL(string: NetworkConstants.applicationJsonURL) else {
            throw NetworkError.invalidURL(NetworkConstants.applicationJsonURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        var headers = NetworkConstants.adobeRequestHeaders
        headers["x-adobe-build-guid"] = buildGuid

        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData("无法将响应数据转换为json符串")
        }

        return jsonString
    }
}
