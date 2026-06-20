//
//  NewDownloadTask.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//
import Foundation

class NewDownloadTask: Identifiable, ObservableObject, @unchecked Sendable  {
    let id = UUID()
    var productId: String
    let productVersion: String
    let language: String
    let displayName: String
    let directory: URL
    var dependenciesToDownload: [DependenciesToDownload]
    var retryCount: Int
    let createAt: Date
    var displayInstallButton: Bool

    var platform: String
    var targetArchitecture: String

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

    var destinationURL: URL { directory }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
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
        DispatchQueue.main.async {
            self.totalStatus = newStatus
            self.objectWillChange.send()
        }
    }

    func updateProgress(downloaded: Int64, total: Int64, speed: Double) {
        DispatchQueue.main.async {
            self.totalDownloadedSize = downloaded
            self.totalSize = total
            self.totalSpeed = speed
            self.totalProgress = total > 0 ? Double(downloaded) / Double(total) : 0
            self.objectWillChange.send()
        }
    }

    init(productId: String, productVersion: String, language: String, displayName: String, directory: URL, dependenciesToDownload: [DependenciesToDownload] = [], retryCount: Int = 0, createAt: Date, totalStatus: DownloadStatus? = nil, totalProgress: Double, totalDownloadedSize: Int64 = 0, totalSize: Int64 = 0, totalSpeed: Double = 0, currentPackage: Package? = nil, platform: String, targetArchitecture: String) {
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
