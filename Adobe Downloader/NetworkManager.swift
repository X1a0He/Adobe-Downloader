import Foundation
import Network
import Combine
import AppKit
import SwiftUI

@MainActor
class NetworkManager: ObservableObject {
    typealias ProgressUpdate = (bytesWritten: Int64, totalWritten: Int64, expectedToWrite: Int64)
    @Published var isConnected = false
    @Published var saps: [String: Sap] = [:]
    @Published var cdn: String = ""
    @Published var sapCodes: [SapCodes] = []
    @Published var loadingState: LoadingState = .idle
    @Published var downloadTasks: [NewDownloadTask] = []
    @Published var installationState: InstallationState = .idle
    @Published var installCommand: String = ""
    private let cancelTracker = CancelTracker()
    internal var downloadUtils: DownloadUtils!
    internal var progressObservers: [UUID: NSKeyValueObservation] = [:]
    internal var activeDownloadTaskId: UUID?
    internal var monitor = NWPathMonitor()
    internal var isFetchingProducts = false
    private let installManager = InstallManager()
    
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
        case failed(Error)
    }

    private let networkService: NetworkService

    init(networkService: NetworkService = NetworkService(),
         downloadUtils: DownloadUtils? = nil) {
        
        self.networkService = networkService
        self.downloadUtils = downloadUtils ?? DownloadUtils(networkManager: self, cancelTracker: cancelTracker)
        
        TaskPersistenceManager.shared.setCancelTracker(cancelTracker)
        configureNetworkMonitor()
    }

    func fetchProducts() async {
        loadingState = .loading
        do {
            let (saps, cdn, sapCodes) = try await networkService.fetchProductsData()
            await MainActor.run {
                self.saps = saps
                self.cdn = cdn
                self.sapCodes = sapCodes
                self.loadingState = .success
            }
        } catch {
            await MainActor.run {
                self.loadingState = .failed(error)
            }
        }
    }
    func startDownload(sap: Sap, selectedVersion: String, language: String, destinationURL: URL) async throws {
        guard let productInfo = self.saps[sap.sapCode]?.versions[selectedVersion] else { 
            throw NetworkError.invalidData("无法获取产品信息") 
        }
        let task = NewDownloadTask(
            sapCode: sap.sapCode,
            version: selectedVersion,
            language: language,
            displayName: sap.displayName,
            directory: destinationURL,
            productsToDownload: [],
            createAt: Date(),
            totalStatus: .preparing(DownloadStatus.PrepareInfo(
                message: "正在准备下载...",
                timestamp: Date(),
                stage: .initializing
            )),
            totalProgress: 0,
            totalDownloadedSize: 0,
            totalSize: 0,
            totalSpeed: 0,
            platform: productInfo.apPlatform
        )
        
        downloadTasks.append(task)
        updateDockBadge()
        saveTask(task)
        
        do {
            try await downloadUtils.handleDownload(task: task, productInfo: productInfo, allowedPlatform: StorageData.shared.allowedPlatform, saps: saps)
        } catch {
            await MainActor.run {
                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: error.localizedDescription,
                    error: error,
                    timestamp: Date(),
                    recoverable: true
                )))
                saveTask(task)
                objectWillChange.send()
            }
            throw error
        }
    }

    var cdnUrl: String {
        get async {
            await MainActor.run { cdn }
        }
    }

   func removeTask(taskId: UUID, removeFiles: Bool = true) {
       Task {
           await cancelTracker.cancel(taskId)
           
           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               if task.status.isActive {
                   task.setStatus(.failed(DownloadStatus.FailureInfo(
                       message: String(localized: "下载已取消"),
                       error: NetworkError.downloadCancelled,
                       timestamp: Date(),
                       recoverable: false
                   )))
                   saveTask(task)
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
                let (saps, cdn, sapCodes) = try await networkService.fetchProductsData()
                await MainActor.run {
                    self.saps = saps
                    self.cdn = cdn
                    self.sapCodes = sapCodes
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
        }
        
        do {
            try await installManager.install(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        if status.contains("完成") || status.contains("成功") {
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
            let command = await installManager.getInstallCommand(
                for: path.appendingPathComponent("driver.xml").path
            )
            
            await MainActor.run {
                self.installCommand = command
                
                if let installError = error as? InstallManager.InstallError {
                    switch installError {
                    case .installationFailed(let message):
                        if message.contains("需要重新输入密码") {
                            Task {
                                await installProduct(at: path)
                            }
                        } else {
                            installationState = .failed(InstallManager.InstallError.installationFailed(message))
                        }
                    case .cancelled:
                        installationState = .failed(InstallManager.InstallError.cancelled)
                    case .setupNotFound:
                        installationState = .failed(InstallManager.InstallError.setupNotFound)
                    case .permissionDenied:
                        installationState = .failed(InstallManager.InstallError.permissionDenied)
                    }
                } else {
                    installationState = .failed(InstallManager.InstallError.installationFailed(error.localizedDescription))
                }
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
                        if status.contains("完成") || status.contains("成功") {
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
            if case InstallManager.InstallError.installationFailed(let message) = error,
               message.contains("需要重新输入密码") {
                await installProduct(at: path)
            } else {
                await MainActor.run {
                    if let installError = error as? InstallManager.InstallError {
                        installationState = .failed(installError)
                    } else {
                        installationState = .failed(error)
                    }
                }
            }
        }
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        return try await networkService.getApplicationInfo(buildGuid: buildGuid)
    }

    func isVersionDownloaded(sap: Sap, version: String, language: String) -> URL? {
        if let task = downloadTasks.first(where: {
            $0.sapCode == sap.sapCode &&
            $0.version == version &&
            $0.language == language &&
            !$0.status.isCompleted
        }) { return task.directory }

        let platform = sap.versions[version]?.apPlatform ?? "unknown"
        let fileName = sap.sapCode == "APRO" 
            ? "Adobe Downloader \(sap.sapCode)_\(version)_\(platform).dmg"
            : "Adobe Downloader \(sap.sapCode)_\(version)-\(language)-\(platform)"

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

    func saveTask(_ task: NewDownloadTask) {
        TaskPersistenceManager.shared.saveTask(task)
        objectWillChange.send()
    }

    func loadSavedTasks() {
        let savedTasks = TaskPersistenceManager.shared.loadTasks()
        for task in savedTasks {
            for product in task.productsToDownload {
                product.updateCompletedPackages()
            }
        }
        downloadTasks.append(contentsOf: savedTasks)
        updateDockBadge()
    }
}
