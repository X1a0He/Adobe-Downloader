import Foundation
import Darwin

/// 写入和断点提交有共同顺序；整包校验单独排队，避免阻塞正在下载的包落盘。
enum PDMDownloadIO {
    static let queue = DispatchQueue(label: "com.x1a0he.macOS.Adobe-Downloader.downloadIO", qos: .utility)
    private static let validationQueue = DispatchQueue(label: "com.x1a0he.macOS.Adobe-Downloader.downloadValidation", qos: .utility)

    static func run<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        try await execute(on: queue, operation)
    }

    static func validate<Value>(_ operation: @escaping () throws -> Value) async throws -> Value {
        try await execute(on: validationQueue, operation)
    }

    private static func execute<Value>(on queue: DispatchQueue, _ operation: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

/// 只在 downloadIO 队列访问；每个分片持有自己的句柄，写入范围不会依赖共享 seek 游标。
final class PDMSegmentWriter {
    private let handle: FileHandle
    private let aamd: AAMDFileManager
    private let segmentIndex: Int
    private let start: Int64
    private let length: Int64?
    private let progress: (Int64) -> Void
    private var closed = false
    private var invalidResponse = false
    private var checkpointBytes: Int64
    private var checkpointTime = ProcessInfo.processInfo.systemUptime
    private(set) var writtenBytes: Int64

    init(fileURL: URL, aamd: AAMDFileManager, segmentIndex: Int, start: Int64,
         length: Int64?, initialBytes: Int64, progress: @escaping (Int64) -> Void) throws {
        handle = try FileHandle(forWritingTo: fileURL)
        self.aamd = aamd
        self.segmentIndex = segmentIndex
        self.start = start
        self.length = length
        self.writtenBytes = initialBytes
        self.checkpointBytes = initialBytes
        self.progress = progress
    }

    func append(_ data: Data) throws {
        guard !closed, start >= 0, writtenBytes >= 0,
              writtenBytes <= Int64.max - start,
              Int64(data.count) <= Int64.max - start - writtenBytes,
              length.map({ writtenBytes <= $0 && Int64(data.count) <= $0 - writtenBytes }) ?? true else {
            invalidResponse = true
            throw PDMDownloadError.downloadFailed("Response exceeds the remaining segment range")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var consumed = 0
            while consumed < data.count {
                let count = Darwin.pwrite(handle.fileDescriptor, base.advanced(by: consumed),
                                         data.count - consumed, off_t(start + writtenBytes))
                if count > 0 {
                    consumed += count
                    writtenBytes += Int64(count)
                    progress(Int64(count))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw PDMDownloadError.downloadFailed("File write failed: \(String(cString: strerror(errno)))")
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if writtenBytes - checkpointBytes >= 4 * 1024 * 1024 || now - checkpointTime >= 2 {
            try checkpoint()
        }
    }

    func finish(succeeded: Bool) throws {
        guard !closed else { return }
        defer { closed = true; try? handle.close() }
        try checkpoint(allowComplete: succeeded)
    }

    private func checkpoint(allowComplete: Bool = false) throws {
        // 完整计数同时证明网络成功结束；周期保存和异常收尾必须保留未完成状态。
        let savedBytes: Int64
        if invalidResponse {
            savedBytes = 0
        } else if let length, !allowComplete {
            savedBytes = min(writtenBytes, max(0, length - 1))
        } else {
            savedBytes = writtenBytes
        }
        try handle.synchronize()
        guard aamd.updateSegmentData(segment: segmentIndex, bytesDownloaded: savedBytes), aamd.synchronize() else {
            throw PDMDownloadError.downloadFailed("Cannot persist segment checkpoint")
        }
        checkpointBytes = writtenBytes
        checkpointTime = ProcessInfo.processInfo.systemUptime
    }
}
