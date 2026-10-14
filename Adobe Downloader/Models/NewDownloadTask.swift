//
//  NewDownloadTask.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//
import Foundation

class NewDownloadTask: Identifiable, ObservableObject, @unchecked Sendable  {
    let id: UUID
    let materialKind: DownloadMaterialKind
    let execution = DownloadTaskExecution()
    var productId: String
    let productVersion: String
    let language: String
    let displayName: String
    let directory: URL
    var dependenciesToDownload: [DependenciesToDownload]
    var requiredDependencies: [DependenciesToDownload]?
    var retryCount: Int
    let createAt: Date
    var displayInstallButton: Bool

    var platform: String
    var targetArchitecture: String
    var catalogSnapshot: CatalogSnapshot?

    @Published var totalStatus: DownloadStatus?
    @Published var totalProgress: Double
    @Published var totalDownloadedSize: Int64
    @Published var totalSize: Int64
    @Published var totalSpeed: Double
    @Published var completedPackages: Int = 0
    @Published var totalPackages: Int = 0
    @Published var currentPackage: Package? {
        didSet {
            objectWillChange.send()
        }
    }

    var status: DownloadStatus {
        totalStatus ?? .waiting
    }

    var isDeltaUpdate: Bool {
        dependenciesToDownload.contains { dependency in
            dependency.packages.contains { !$0.deltaBasePackageVersion.isEmpty }
        }
    }

    var currentDownloadSpeed: Double {
        guard case .downloading = status, totalSpeed.isFinite else { return 0 }
        return max(totalSpeed, 0)
    }

    var isValidatingDownload: Bool {
        guard case .downloading = status else { return false }
        let active = dependenciesToDownload.flatMap { $0.packages }.filter { $0.status == .downloading }
        return active.contains { $0.downloadPhase == .validating }
            && !active.contains { $0.downloadPhase == .transferring }
    }

    fileprivate var pendingDownloadsCanBeEstimated: Bool {
        dependenciesToDownload.flatMap { $0.packages }.filter { !$0.downloaded }.allSatisfy { package in
            guard package.downloadSize > 0, package.status != .paused else { return false }
            if case .failed = package.status { return false }
            return package.status != .downloading || package.downloadPhase != .waiting
        }
    }

    var remainingDownloadSeconds: TimeInterval? {
        guard case .downloading = status else { return nil }
        let pending = dependenciesToDownload.flatMap { $0.packages }.filter { !$0.downloaded }
        guard pendingDownloadsCanBeEstimated else { return nil }
        var slowest = 0.0
        for package in pending {
            guard package.downloadedSize < package.downloadSize else { continue }
            if package.status == .downloading && package.downloadPhase == .transferring {
                guard let seconds = DownloadTimeEstimate.seconds(
                    remaining: package.downloadSize - max(package.downloadedSize, 0), speed: package.speed
                ) else { return nil }
                slowest = max(slowest, seconds)
            }
        }
        return DownloadTimeEstimate.seconds(remaining: max(totalSize - totalDownloadedSize, 0),
                                            speed: currentDownloadSpeed, minimum: slowest)
    }

    var destinationURL: URL { directory }

    var hasUnknownDownloadSize: Bool {
        (status.isActive && totalSize <= 0)
            || dependenciesToDownload.flatMap { $0.packages }.contains { !$0.downloaded && $0.downloadSize <= 0 }
    }

    var formattedTotalSize: String {
        hasUnknownDownloadSize ? String(localized: "未知")
            : ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedDownloadedSize: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
    }

    var startTime: Date {
        switch totalStatus {
        case .downloading(let info): return info.startTime
        case .completed(let info): return info.timestamp - info.totalTime
        case .preparing(let info): return info.timestamp
        case .paused(let info): return info.timestamp
        case .failed(let info): return info.timestamp
        case .retrying(let info): return info.nextRetryDate - 60
        case .waiting, .none: return createAt
        }
    }

    func setStatus(_ newStatus: DownloadStatus) {
        let generation = execution.generation
        let apply = {
            guard self.execution.isCurrent(generation) else { return }
            self.totalStatus = newStatus
            self.objectWillChange.send()
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    func updateProgress(downloaded: Int64, total: Int64, speed: Double) {
        let generation = execution.generation
        let apply = {
            guard self.execution.accepts(generation) else { return }
            self.totalDownloadedSize = downloaded
            self.totalSize = total
            self.totalSpeed = speed
            self.totalProgress = total > 0 ? Double(downloaded) / Double(total) : 0
            self.objectWillChange.send()
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    init(id: UUID = UUID(), materialKind: DownloadMaterialKind = .download, productId: String, productVersion: String, language: String, displayName: String, directory: URL, dependenciesToDownload: [DependenciesToDownload] = [], retryCount: Int = 0, createAt: Date, totalStatus: DownloadStatus? = nil, totalProgress: Double, totalDownloadedSize: Int64 = 0, totalSize: Int64 = 0, totalSpeed: Double = 0, currentPackage: Package? = nil, platform: String, targetArchitecture: String) {
        self.id = id
        self.materialKind = materialKind
        self.productId = productId
        self.productVersion = productVersion
        self.language = language
        self.displayName = displayName
        self.directory = directory
        self.dependenciesToDownload = dependenciesToDownload
        self.retryCount = retryCount
        self.createAt = createAt
        self.totalStatus = totalStatus
        self.totalProgress = totalProgress
        self.totalDownloadedSize = totalDownloadedSize
        self.totalSize = totalSize
        self.totalSpeed = totalSpeed
        self.currentPackage = currentPackage
        self.displayInstallButton = true
        self.platform = platform
        self.targetArchitecture = targetArchitecture
    }

    
}

/// 下载倒计时只覆盖传输；校验与重试等待没有可用的完成时间估计。
enum DownloadTimeEstimate {
    static func seconds(remaining: Int64, speed: Double, minimum: TimeInterval = 0) -> TimeInterval? {
        guard remaining > 0, speed.isFinite, speed > 0 else { return nil }
        let result = max(Double(remaining) / speed, minimum)
        return result.isFinite && result < Double(Int.max) ? result : nil
    }
}

struct DownloadTaskSummary {
    let activeCount: Int
    let speed: Double
    let remainingSeconds: TimeInterval?

    init(tasks: [NewDownloadTask]) {
        // 首页、任务列表和 Dock 共用包含排队任务的范围。
        let active = tasks.filter { $0.status.isActive }
        activeCount = active.count
        speed = active.reduce(0) { $0 + $1.currentDownloadSpeed }
        let remaining = active.reduce(Int64(0)) { $0 + max($1.totalSize - $1.totalDownloadedSize, 0) }
        var canEstimate = true
        var slowest = 0.0
        for task in active {
            let pending = task.dependenciesToDownload.flatMap { $0.packages }.filter { !$0.downloaded }
            if pending.isEmpty && task.totalSize <= 0 || pending.contains(where: { $0.downloadSize <= 0 }) {
                canEstimate = false
            }
            if !task.pendingDownloadsCanBeEstimated { canEstimate = false }
            guard task.totalDownloadedSize < task.totalSize else { continue }
            switch task.status {
            case .downloading:
                if let seconds = task.remainingDownloadSeconds { slowest = max(slowest, seconds) }
                else { canEstimate = false }
            case .preparing, .retrying:
                canEstimate = false
            default: break
            }
        }
        remainingSeconds = canEstimate
            ? DownloadTimeEstimate.seconds(remaining: remaining, speed: speed, minimum: slowest) : nil
    }
}
