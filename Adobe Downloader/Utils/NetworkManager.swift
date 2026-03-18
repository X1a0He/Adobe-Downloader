import Foundation
import Network
import Combine
import AppKit
import SwiftUI

@MainActor
class NetworkManager: ObservableObject {
    typealias ProgressUpdate = (bytesWritten: Int64, totalWritten: Int64, expectedToWrite: Int64)
    @Published var isConnected = false
    @Published var loadingState: LoadingState = .idle
    @Published var downloadTasks: [NewDownloadTask] = []
    @Published var installationState: InstallationState = .idle
    @Published var installCommand: String = ""
    @Published var installLogs: [String] = []
    internal var progressObservers: [UUID: NSKeyValueObservation] = [:]
    internal var activeDownloadTaskId: UUID?
    internal var monitor = NWPathMonitor()
    internal var isFetchingProducts = false
    private let installManager = InstallManager()
    private var hasLoadedSavedTasks = false
    
    private var defaultDirectory: String {
        get { StorageData.shared.defaultDirectory }
        set { StorageData.shared.defaultDirectory = newValue }
    }
    
    private var useDefaultDirectory: Bool {
        get { StorageData.shared.useDefaultDirectory }
        set { StorageData.shared.useDefaultDirectory = newValue }
    }
    
    private var apiVersion: String {
        get { StorageData.shared.apiVersion }
        set { StorageData.shared.apiVersion = newValue }
    }
    
    enum InstallationState {
        case idle
        case installing(progress: Double, status: String)
        case completed
        case failed(Error, String? = nil)
    }

    init() {
        TaskPersistenceManager.shared.setCancelTracker(globalCancelTracker)
        configureNetworkMonitor()
    }

    func fetchProducts() async {
        loadingState = .loading
        do {
            let (products, uniqueProducts) = try await globalNetworkService.fetchProductsData()
            await MainActor.run {
                globalProducts = products
                globalUniqueProducts = uniqueProducts.sorted { $0.displayName < $1.displayName }
                self.loadingState = .success
            }
        } catch {
            await MainActor.run {
                self.loadingState = .failed(error)
            }
        }
    }
    
    func startCustomDownload(productId: String, selectedVersion: String, language: String, destinationURL: URL, customDependencies: [DependenciesToDownload]) async throws {
        guard let productInfo = globalCcmResult.products.first(where: { $0.id == productId && $0.version == selectedVersion }) else {
            throw NetworkError.productNotFound
        }

        let task = NewDownloadTask(
            productId: productInfo.id,
            productVersion: selectedVersion,
            language: language,
            displayName: productInfo.displayName,
            directory: destinationURL,
            dependenciesToDownload: [],
            createAt: Date(),
            totalStatus: .preparing(DownloadStatus.PrepareInfo(
                message: "正在准备自定义下载...",
                timestamp: Date(),
                stage: .initializing
            )),
            totalProgress: 0,
            totalDownloadedSize: 0,
            totalSize: 0,
            totalSpeed: 0,
            platform: globalProducts.first(where: { $0.id == productId })?.platforms.first?.id ?? "unknown")

        downloadTasks.append(task)
        updateDockBadge()
        await saveTask(task)
        
        do {
            if productId == "APRO" {
                try await globalNewDownloadUtils.downloadAPRO(task: task, productInfo: productInfo)
            } else {
                try await globalNewDownloadUtils.handleCustomDownload(task: task, customDependencies: customDependencies)
            }
        } catch {
            task.setStatus(.failed(DownloadStatus.FailureInfo(
                message: error.localizedDescription,
                error: error,
                timestamp: Date(),
                recoverable: true
            )))
            await saveTask(task)
            await MainActor.run {
                objectWillChange.send()
            }
        }
    }

   func removeTask(taskId: UUID, removeFiles: Bool = true) {
       Task {
           await globalCancelTracker.cancel(taskId)

           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               if task.status.isActive {
                   task.setStatus(.failed(DownloadStatus.FailureInfo(
                       message: String(localized: "下载已取消"),
                       error: NetworkError.downloadCancelled,
                       timestamp: Date(),
                       recoverable: false
                   )))
                   await saveTask(task)
               }
               
               if removeFiles {
                   try? FileManager.default.removeItem(at: task.directory)
               }
               
               TaskPersistenceManager.shared.removeTask(task)
               
               await MainActor.run {
                   downloadTasks.removeAll { $0.id == taskId }
                   updateDockBadge()
                   objectWillChange.send()
               }
           }
       }
   }

    private func fetchProductsWithRetry() async {
        guard !isFetchingProducts else { return }
        
        isFetchingProducts = true
        loadingState = .loading
        
        let maxRetries = 3
        var retryCount = 0
        
        while retryCount < maxRetries {
            do {
                let (products, uniqueProducts) = try await globalNetworkService.fetchProductsData()
                await MainActor.run {
                    globalProducts = products
                    globalUniqueProducts = uniqueProducts
                    self.loadingState = .success
                    self.isFetchingProducts = false
                }

                return
            } catch {
                retryCount += 1
                if retryCount == maxRetries {
                    await MainActor.run {
                        self.loadingState = .failed(error)
                        self.isFetchingProducts = false
                    }
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000)
                }
            }
        }
    }

   private func clearCompletedDownloadTasks() async {
       await MainActor.run {
           downloadTasks.removeAll { task in
               if task.status.isCompleted || task.status.isFailed {
                   try? FileManager.default.removeItem(at: task.directory)
                   return true
               }
               return false
           }
           updateDockBadge()
           objectWillChange.send()
       }
   }

    func installProduct(at path: URL) async {
        await MainActor.run {
            installationState = .installing(progress: 0, status: "准备安装...")
            installLogs = []
        }

        do {
            try await installManager.install(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        if status == "安装完成" {
                            self.installationState = .completed
                        } else {
                            self.installationState = .installing(progress: progress, status: status)
                        }
                    }
                },
                logHandler: { message in
                    Task { @MainActor in
                        self.installLogs.append(message)
                    }
                }
            )
            
            await MainActor.run {
                installationState = .completed
            }
        } catch {
            let command = await installManager.getInstallCommand(
                for: path.appendingPathComponent("driver.xml").path
            )
            
            await MainActor.run {
                self.installCommand = command
                
                var errorDetails: String? = nil
                var mainError = error
                
                if let installError = error as? InstallManager.InstallError {
                    switch installError {
                    case .installationFailedWithDetails(let message, let details):
                        errorDetails = details
                        mainError = InstallManager.InstallError.installationFailed(message)
                    default:
                        break
                    }
                }
                
                installationState = .failed(mainError, errorDetails)
            }
        }
    }

    func cancelInstallation() {
        Task {
            await installManager.cancel()
        }
    }

    func retryInstallation(at path: URL) async {
        await MainActor.run {
            installationState = .installing(progress: 0, status: "正在重试安装...")
        }
        
        do {
            try await installManager.retry(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        if status == "安装完成" {
                            self.installationState = .completed
                        } else {
                            self.installationState = .installing(progress: progress, status: status)
                        }
                    }
                }
            )
            
            await MainActor.run {
                installationState = .completed
            }
        } catch {
            await MainActor.run {
                var errorDetails: String? = nil
                var mainError = error
                
                if let installError = error as? InstallManager.InstallError {
                    if case .installationFailedWithDetails(let message, let details) = installError {
                        errorDetails = details
                        mainError = InstallManager.InstallError.installationFailed(message)
                    }
                }
                
                installationState = .failed(mainError, errorDetails)
            }
        }
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        return try await globalNetworkService.getApplicationInfo(buildGuid: buildGuid)
    }

    func isVersionDownloaded(productId: String, version: String, language: String) -> URL? {
        if let task = downloadTasks.first(where: {
            $0.productId == productId &&
            $0.productVersion == version &&
            $0.language == language &&
            !$0.status.isCompleted
        }) { return task.directory }

        let platform = globalProducts.first(where: { $0.id == productId && $0.version == version })?.platforms.first?.id ?? "unknown"
        let fileName = productId == "APRO"
            ? "Adobe Downloader \(productId)_\(version)_\(platform).dmg"
            : "Adobe Downloader \(productId)_\(version)-\(language)-\(platform)"

        if useDefaultDirectory && !defaultDirectory.isEmpty {
            let defaultPath = URL(fileURLWithPath: defaultDirectory)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: defaultPath.path) {
                return defaultPath
            }
        }

        return nil
    }

    func updateDockBadge() {
        let activeCount = downloadTasks.filter { task in
            if case .completed = task.totalStatus {
                return false
            }
            return true
        }.count

        if activeCount > 0 {
            NSApplication.shared.dockTile.badgeLabel = "\(activeCount)"
        } else {
            NSApplication.shared.dockTile.badgeLabel = nil
        }
    }

    func retryFetchData() {
        Task {
            isFetchingProducts = false
            loadingState = .idle
            await fetchProducts()
        }
    }

    func loadSavedTasks() {
        guard !hasLoadedSavedTasks else { return }
        
        Task {
            let savedTasks = await TaskPersistenceManager.shared.loadTasks()
            await MainActor.run {
                for task in savedTasks {
                    for product in task.dependenciesToDownload {
                        product.updateCompletedPackages()
                    }
                }
                downloadTasks.append(contentsOf: savedTasks)
                updateDockBadge()
                hasLoadedSavedTasks = true
            }
        }
    }

    func saveTask(_ task: NewDownloadTask) async {
        await TaskPersistenceManager.shared.saveTask(task)
        objectWillChange.send()
    }

    func configureNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let task = { @MainActor @Sendable [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                switch (wasConnected, self.isConnected) {
                    case (false, true): 
                        await self.resumePausedTasks()
                    case (true, false): 
                        await self.pauseActiveTasks()
                    default: break
                }
            }
            Task(operation: task)
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func resumePausedTasks() async {
        for task in downloadTasks {
            if case .paused(let info) = task.status,
               info.reason == .networkIssue {
                await globalNewDownloadUtils.resumeDownloadTask(taskId: task.id)
            }
        }
    }
    
    private func pauseActiveTasks() async {
        for task in downloadTasks {
            if case .downloading = task.status {
                await globalNewDownloadUtils.pauseDownloadTask(taskId: task.id, reason: .networkIssue)
            }
        }
    }
}
