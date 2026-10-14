import Foundation

enum DownloadMaterialKind: String, Codable {
    case download
    case importedDirectory
}

/// 一次任务从准备到完成共用代次；停止请求不释放写入所有权。
final class DownloadTaskExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UUID?
    private var stopping = false
    private var operations: [UUID: () -> Void] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        if case NetworkError.cancelled = error { return true }
        return false
    }

    var generation: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return identifier
    }

    func begin() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard identifier == nil else { return nil }
        let generation = UUID()
        identifier = generation
        stopping = false
        return generation
    }

    func accepts(_ generation: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation != nil && identifier == generation && !stopping
    }

    func isCurrent(_ generation: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifier == generation
    }

    func requestStop() {
        lock.lock()
        stopping = true
        let cancellations = Array(operations.values)
        lock.unlock()
        for cancel in cancellations { cancel() }
    }

    private func registerOperation(_ id: UUID, generation: UUID?, cancel: @escaping () -> Void) {
        lock.lock()
        if generation == nil || identifier != generation || stopping {
            lock.unlock()
            cancel()
        } else {
            operations[id] = cancel
            lock.unlock()
        }
    }

    private func finishOperation(_ id: UUID) {
        lock.lock()
        operations.removeValue(forKey: id)
        lock.unlock()
    }

    func run<Value>(generation: UUID?, operation: @escaping () async -> Value) async -> Value {
        let operationID = UUID()
        let task = Task { await operation() }
        registerOperation(operationID, generation: generation) { task.cancel() }
        defer { finishOperation(operationID) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func runThrowing<Value>(generation: UUID?, operation: @escaping () async throws -> Value) async throws -> Value {
        let operationID = UUID()
        let task = Task { try Task.checkCancellation(); return try await operation() }
        registerOperation(operationID, generation: generation) { task.cancel() }
        defer { finishOperation(operationID) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func finish(_ generation: UUID) {
        lock.lock()
        guard identifier == generation else { lock.unlock(); return }
        identifier = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if identifier == nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
