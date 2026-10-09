//
//  NewNetworkService.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation

class NewNetworkService {
    func fetchProductsData(context: CatalogRequestContext, generation: UUID) async throws -> CatalogSnapshot {
        var requests: [CatalogShard]
        if context.apiVersion == "4" {
            requests = context.platforms.map { CatalogShard(channels: ["ccm"], platforms: [$0]) }
                + [CatalogShard(channels: ["sti"], platforms: context.platforms),
                   CatalogShard(channels: ["nocc"], platforms: context.platforms)]
        } else {
            requests = [CatalogShard(channels: context.channels, platforms: context.platforms)]
        }
        var parsed = ParsedCatalog()
        var metrics = CatalogMeasurements()
        var requestedChannels = Set(context.channels)
        while !requests.isEmpty {
            try await withThrowingTaskGroup(of: CatalogShardResult.self) { group in
                var remaining = requests.makeIterator()
                for _ in 0..<2 {
                    if let shard = remaining.next() {
                        group.addTask { try await self.fetchCatalogShard(shard, context: context) }
                    }
                }
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    let start = ProcessInfo.processInfo.systemUptime
                    parsed.merge(result.catalog)
                    metrics.mergingAndIndexing += ProcessInfo.processInfo.systemUptime - start
                    metrics.requests += result.requestTime
                    metrics.decoding += result.decodeTime
                    metrics.responseBytes += result.bytes
                    if let shard = remaining.next() {
                        group.addTask { try await self.fetchCatalogShard(shard, context: context) }
                    }
                }
            }
            let extra = parsed.dependencyChannels.subtracting(requestedChannels)
            requestedChannels.formUnion(extra)
            requests = extra.isEmpty ? [] : [CatalogShard(channels: extra.sorted(), platforms: context.platforms)]
        }
        return try await CatalogDecoder.shared.snapshot(parsed: parsed, context: context, generation: generation, measurements: metrics)
    }

    private func fetchCatalogShard(_ shard: CatalogShard, context: CatalogRequestContext) async throws -> CatalogShardResult {
        var request = URLRequest(url: try context.url(channels: shard.channels, platforms: shard.platforms))
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.ffcRequestTimeout
        context.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let start = ProcessInfo.processInfo.systemUptime
        let data = try await CatalogHTTPGate.shared.fetch(request)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try Task.checkCancellation()
        let decoded = try await CatalogDecoder.shared.decode(data: data, context: context)
        return CatalogShardResult(catalog: decoded.0, bytes: data.count, requestTime: elapsed, decodeTime: decoded.1)
    }

    func getApplicationInfo(
        buildGuid: String,
        sapCode: String? = nil,
        version: String? = nil,
        platform: String? = nil,
        catalogContext: CatalogRequestContext? = nil
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
                if let catalogContext {
                    queryItems += catalogContext.architecture.requestedPlatformIds.map { URLQueryItem(name: "platform", value: $0) }
                } else {
                    appendDefaultApplicationPlatforms(to: &queryItems)
                }
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
                let result = try await performApplicationJsonRequest(url: url, buildGuid: buildGuid, catalogContext: catalogContext)

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

    private func performApplicationJsonRequest(url: URL, buildGuid: String, catalogContext: CatalogRequestContext?) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkConstants.serviceCallTimeout

        var headers = catalogContext.map { context in
            context.headers.filter { ["x-adobe-app-id", "x-api-key", "User-Agent"].contains($0.key) }
        } ?? NetworkConstants.applicationJsonHeaders
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
