import Foundation

private struct CatalogWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
}

actor CatalogHTTPGate {
    static let shared = CatalogHTTPGate()
    private var active = 0
    private var waiters: [CatalogWaiter] = []

    func fetch(_ request: URLRequest) async throws -> Data {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < 2 {
                active += 1
            } else {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(CatalogWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        defer { release() }
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw NetworkError.httpError(http.statusCode, nil) }
        return data
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

struct CatalogShard {
    let channels: [String]
    let platforms: [String]
}

struct CatalogShardResult {
    let catalog: ParsedCatalog
    let bytes: Int
    let requestTime: TimeInterval
    let decodeTime: TimeInterval
}

actor CatalogDecoder {
    static let shared = CatalogDecoder()

    func decode(data: Data, context: CatalogRequestContext) throws -> (ParsedCatalog, TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try autoreleasepool { try NewJSONParser.parse(data: data, context: context) }
        return (result, ProcessInfo.processInfo.systemUptime - start)
    }

    func snapshot(
        parsed: ParsedCatalog, context: CatalogRequestContext, generation: UUID,
        measurements: CatalogMeasurements
    ) throws -> CatalogSnapshot {
        try Task.checkCancellation()
        return try CatalogSnapshot(parsed: parsed, context: context, generation: generation, measurements: measurements)
    }
}
