import Foundation

final class HDPIMConcurrencyManager {
    static let shared = HDPIMConcurrencyManager()

    private let lockQueue = DispatchQueue(label: "com.hdpim.lock", attributes: .concurrent)
    private var locks: [String: NSLock] = [:]
    private let locksLock = NSLock()

    private init() {}

    func acquireLock(_ key: String) {
        let lock = getLock(key)
        lock.lock()
    }

    func releaseLock(_ key: String) {
        let lock = getLock(key)
        lock.unlock()
    }

    func executeInTransaction<T>(_ key: String, operation: () throws -> T) rethrows -> T {
        acquireLock(key)
        defer { releaseLock(key) }
        return try operation()
    }

    private func getLock(_ key: String) -> NSLock {
        locksLock.lock()
        defer { locksLock.unlock() }

        if let lock = locks[key] {
            return lock
        }

        let lock = NSLock()
        locks[key] = lock
        return lock
    }
}
