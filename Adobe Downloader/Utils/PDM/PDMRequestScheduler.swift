import Foundation

/// 所有前台下载请求共用 FIFO 预算；许可持有至网络和写盘一起收尾。
actor PDMRequestScheduler {
    static let shared: PDMRequestScheduler = {
        let stored = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        return PDMRequestScheduler(limit: stored == 0 ? 3 : stored)
    }()
    private static let configurationLock = NSLock()
    private static var publishedRevision: UInt64 = 0
    private var configurationRevision: UInt64 = 0
    private var limit: Int
    private var active = 0
    private struct Waiter {
        let id: UUID
        let cancellation: PDMTransferCancellation
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    /// 生产配置只由 StorageData 发布；异步交付乱序时不得回退到旧上限。
    static func updateSharedLimit(_ limit: Int) {
        configurationLock.lock()
        publishedRevision += 1
        let revision = publishedRevision
        configurationLock.unlock()
        Task { await shared.configure(limit: limit, revision: revision) }
    }

    func configure(limit: Int, revision: UInt64) {
        guard revision > configurationRevision else { return }
        configurationRevision = revision
        self.limit = max(1, limit)
        drain()
    }

    func withPermit<Value>(
        cancellation: PDMTransferCancellation,
        operation: () async throws -> Value
    ) async throws -> Value {
        try await acquire(cancellation: cancellation)
        do {
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire(cancellation: PDMTransferCancellation) async throws {
        let id = UUID()
        let waitingCancellation = PDMTransferCancellation()
        let observer = cancellation.register { waitingCancellation.cancel() }
        let wake = waitingCancellation.register { Task { self.cancelWaiter(id) } }
        defer {
            cancellation.unregister(observer)
            waitingCancellation.unregister(wake)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !waitingCancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, cancellation: waitingCancellation, continuation: continuation))
                drain()
            }
        } onCancel: {
            waitingCancellation.cancel()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        active -= 1
        drain()
    }

    private func drain() {
        while active < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.cancellation.isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                active += 1
                waiter.continuation.resume()
            }
        }
    }
}
