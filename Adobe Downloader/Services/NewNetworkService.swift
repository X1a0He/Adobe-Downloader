//
//  NewNetworkService.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation

class NewNetworkService {
    typealias ProductsData = ([Product], [UniqueProduct])
    private let defaultChannels = ["ccm", "sti", "nocc"]

    private func makeProductsURL(channels: [String] = ["ccm", "sti", "nocc"]) throws -> URL {
        var components = URLComponents(string: NetworkConstants.productsURL)

        var queryItems: [URLQueryItem] = channels.map {
            URLQueryItem(name: "channel", value: $0)
        }

        appendRequestedProductPlatforms(to: &queryItems)

        queryItems.append(URLQueryItem(name: "payload", value: "true"))
        queryItems.append(URLQueryItem(name: "productType", value: "Desktop"))
        queryItems.append(URLQueryItem(name: "_type", value: "xml"))

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw NetworkError.invalidURL(NetworkConstants.productsURL)
        }
        return url
    }

    func fetchProductsData() async throws -> ProductsData {
        let primaryURL = try makeProductsURL(channels: defaultChannels)
        let primaryJSONString = try await fetchProductsJSONString(url: primaryURL)
        let primaryResults = try await Task.detached(priority: .userInitiated) {
            try NewJSONParser.parseResults(jsonString: primaryJSONString)
        }.value

        let extraChannels = extractDependencyChannels(from: primaryJSONString)
            .subtracting(defaultChannels)
        let mergedResults: (sti: NewParseResult, ccm: NewParseResult)
        if extraChannels.isEmpty {
            mergedResults = primaryResults
        } else {
            let secondaryURL = try makeProductsURL(channels: defaultChannels + extraChannels.sorted())
            let secondaryJSONString = try await fetchProductsJSONString(url: secondaryURL)
            let secondaryResults = try await Task.detached(priority: .userInitiated) {
                try NewJSONParser.parseResults(jsonString: secondaryJSONString)
            }.value
            mergedResults = (
                sti: primaryResults.sti.merged(with: secondaryResults.sti),
                ccm: primaryResults.ccm.merged(with: secondaryResults.ccm)
            )
        }

        let result: ProductsData = await Task.detached(priority: .userInitiated) {
            globalStiResult = mergedResults.sti
            globalCcmResult = mergedResults.ccm
            globalDependencyCache = [:]
            await HDPIMParityDecisionEngine.shared.clearDownloadDecisionCache()
            if !mergedResults.ccm.cdn.isEmpty {
                globalCdn = mergedResults.ccm.cdn
            } else if !mergedResults.sti.cdn.isEmpty {
                globalCdn = mergedResults.sti.cdn
            }

            let products = globalCcmResult.products
            if products.isEmpty { return ([], []) }
            globalRawProducts = products

            let validProducts = products.filter {
                HDPIMParityDecisionEngine.shared.hasVisibleVersion(product: $0)
            }

            var uniqueProductsDict = [String: UniqueProduct]()
            for product in validProducts {
                uniqueProductsDict[product.id] = UniqueProduct(id: product.id, displayName: product.displayName)
            }
            let uniqueProducts = Array(uniqueProductsDict.values)

            return (validProducts, uniqueProducts)
        }.value

        return result
    }

    private func fetchProductsJSONString(url: URL) async throws -> String {
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

        return jsonString
    }

    private func extractDependencyChannels(from jsonString: String) -> Set<String> {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return extractDependencyChannelsFromXML(xmlString: jsonString)
        }

        guard let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        return extractDependencyChannels(from: jsonObject)
    }

    private func extractDependencyChannelsFromXML(xmlString: String) -> Set<String> {
        guard let data = xmlString.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: []) else {
            return []
        }

        let nodes = (try? document.nodes(
            forXPath: "/response/channels/channel/products/product/platforms/platform/custom-data/custom-entry[@key='dependencyFFCChannel']/value"
        )) ?? []

        return Set(
            nodes.compactMap { node in
                node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )
    }

    private func extractDependencyChannels(from jsonObject: [String: Any]) -> Set<String> {
        let channels = channelArray(from: jsonObject)
        guard !channels.isEmpty else {
            return []
        }

        var results = Set<String>()
        for channel in channels {
            guard let productsContainer = channel["products"] as? [String: Any] else {
                continue
            }

            for product in dictionaryArray(from: productsContainer["product"]) {
                guard let platformsContainer = product["platforms"] as? [String: Any] else {
                    continue
                }

                for platform in dictionaryArray(from: platformsContainer["platform"]) {
                    guard let customData = firstDictionary(
                        from: platform,
                        candidateKeys: ["custom-data", "customData", "custom_data"]
                    ) else {
                        continue
                    }

                    for entry in dictionaryArray(
                        from: firstValue(
                            in: customData,
                            candidateKeys: ["custom-entry", "customEntry", "custom_entry"]
                        )
                    ) {
                        let entryKey = (stringValue(in: entry, keys: ["key", "name"]) ?? "").lowercased()
                        guard entryKey == "dependencyffcchannel",
                              let channelValue = stringValue(in: entry, keys: ["value", "content", "text"]),
                              !channelValue.isEmpty else {
                            continue
                        }
                        results.insert(channelValue)
                    }
                }
            }
        }

        return results
    }

    private func channelArray(from jsonObject: [String: Any]) -> [[String: Any]] {
        if let channels = jsonObject["channels"] as? [String: Any] {
            let channelArray = dictionaryArray(from: channels["channel"])
            if !channelArray.isEmpty {
                return channelArray
            }
        }

        return dictionaryArray(from: jsonObject["channel"])
    }

    private func dictionaryArray(from value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let dictionary = value as? [String: Any] {
            return [dictionary]
        }
        return []
    }

    private func firstDictionary(
        from dictionary: [String: Any],
        candidateKeys: [String]
    ) -> [String: Any]? {
        for key in candidateKeys {
            if let value = dictionary[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private func firstValue(
        in dictionary: [String: Any],
        candidateKeys: [String]
    ) -> Any? {
        for key in candidateKeys {
            if let value = dictionary[key] {
                return value
            }
        }
        return nil
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            if let nested = dictionary[key] as? [String: Any] {
                if let value = stringValue(in: nested, keys: ["value", "content", "text"]) {
                    return value
                }
            }
        }
        return nil
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
            } else {
                appendDefaultApplicationPlatforms(to: &queryItems)
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

    private func appendDefaultApplicationPlatforms(to queryItems: inout [URLQueryItem]) {
        for platform in HDPIMParityTargetArchitecture.currentSelection.requestedPlatformIds {
            queryItems.append(URLQueryItem(name: "platform", value: platform))
        }
    }

    private func appendRequestedProductPlatforms(to queryItems: inout [URLQueryItem]) {
        for platform in HDPIMParityTargetArchitecture.currentSelection.catalogPlatformIds {
            queryItems.append(URLQueryItem(name: "platform", value: platform))
        }
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
