import Foundation

/// 取消状态与观察者原子登记；回调在锁外执行，网络和排队请求均可立即停止。
final class PDMTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            handlers[id] = handler
            lock.unlock()
        }
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        for callback in callbacks { callback() }
    }
}

final class PDMDownloadExecution {
    let id = UUID()
    let packageId: String
    let destinationPath: String
    let state = PDMAtomicState(.running)
    let cancellation = PDMTransferCancellation()

    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(packageId: String, destinationURL: URL) {
        self.packageId = packageId
        destinationPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func requestStop(_ requestedState: PDMDownloadState) {
        if state.requestStop(requestedState) {
            cancellation.cancel()
        }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
