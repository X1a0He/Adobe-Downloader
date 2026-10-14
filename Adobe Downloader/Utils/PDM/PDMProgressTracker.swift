//
//  PDMProgressTracker.swift
//  Adobe Downloader
//

import Foundation

enum PDMDownloadPhase {
    case waiting, transferring, validating
}

/// 写盘线程直接累计；只按间隔通知，避免每个数据块创建异步任务。
final class PDMProgressTracker {
    private let lock = NSRecursiveLock()
    private static let reportingQueue = DispatchQueue(label: "com.adobe.downloader.progress", qos: .utility)
    private let clock: () -> TimeInterval
    private let automaticallyReports: Bool
    private var timer: DispatchSourceTimer?
    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var phase: PDMDownloadPhase = .waiting
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var lastActivity: TimeInterval = 0
    private let reportInterval = NetworkConstants.progressUpdateInterval
    private let sampleWindow: TimeInterval = 5
    private let idleInterval: TimeInterval = 3

    typealias ProgressCallback = (Int64, Int64, Double, PDMDownloadPhase) -> Void
    private var callback: ProgressCallback?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticallyReports: Bool = true) {
        self.clock = clock
        self.automaticallyReports = automaticallyReports
    }

    deinit { timer?.cancel() }

    func configure(totalBytes: Int64, callback: ProgressCallback?, initialBytes: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        self.totalBytes = totalBytes
        self.callback = callback
        downloadedBytes = max(0, totalBytes > 0 ? min(initialBytes, totalBytes) : initialBytes)
        phase = .waiting
        resetSamples()
        if automaticallyReports {
            let source = DispatchSource.makeTimerSource(queue: Self.reportingQueue)
            source.schedule(deadline: .now() + reportInterval, repeating: reportInterval)
            source.setEventHandler { [weak self] in self?.reportTick() }
            timer = source
            source.resume()
        }
    }

    func addDownloadedBytes(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        downloadedBytes = max(0, downloadedBytes + bytes)
        if totalBytes > 0 { downloadedBytes = min(downloadedBytes, totalBytes) }
        if bytes < 0 {
            // 校验回退只修改完成量，不能变成负吞吐或继续发布回退前的速度。
            resetSamples()
            report()
        } else if bytes > 0 {
            lastActivity = clock()
        }
    }

    func setDownloadedBytes(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        downloadedBytes = max(0, totalBytes > 0 ? min(bytes, totalBytes) : bytes)
        resetSamples()
        report()
    }

    func setPhase(_ phase: PDMDownloadPhase) {
        lock.lock()
        defer { lock.unlock() }
        guard self.phase != phase else { return }
        self.phase = phase
        resetSamples()
        report()
    }

    var currentDownloadedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return downloadedBytes
    }

    var currentTotalBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    func updateTotalBytes(_ totalBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        self.totalBytes = totalBytes
    }

    private func resetSamples() {
        let now = clock()
        samples = [(now, downloadedBytes)]
        lastActivity = now
    }

    private func reportTick() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .transferring else { return }
        report()
    }

    private func report() {
        let now = clock()
        var speed = 0.0
        if phase == .transferring, now - lastActivity < idleInterval {
            while samples.count > 1 && samples[1].time <= now - sampleWindow { samples.removeFirst() }
            if let first = samples.first, now - first.time >= reportInterval {
                speed = max(0, Double(downloadedBytes - first.bytes) / (now - first.time))
            }
            if samples.last?.time != now { samples.append((now, downloadedBytes)) }
        } else {
            samples = [(now, downloadedBytes)]
        }
        callback?(downloadedBytes, totalBytes, speed, phase)
    }

    func forceReport() {
        lock.lock()
        defer { lock.unlock() }
        report()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        phase = .waiting
        resetSamples()
        report()
        callback = nil
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        downloadedBytes = 0
        resetSamples()
        report()
    }
}
