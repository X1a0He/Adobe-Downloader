import Foundation

class TaskPersistenceManager: @unchecked Sendable {
    static let shared = TaskPersistenceManager()
    
    private let fileManager = FileManager.default
    private var tasksDirectory: URL
    private weak var cancelTracker: CancelTracker?
    private var taskCache: [String: NewDownloadTask] = [:]
    private let taskCacheQueue = DispatchQueue(label: "com.x1a0he.macOS.Adobe-Downloader.taskCache", attributes: .concurrent)

    private init() {
        let containerURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        tasksDirectory = containerURL.appendingPathComponent("Adobe Downloader/tasks", isDirectory: true)
        try? fileManager.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
    }
    
    func setCancelTracker(_ tracker: CancelTracker) {
        self.cancelTracker = tracker
    }
    
    private func getTaskFileName(productId: String, version: String, language: String, platform: String) -> String {
        return productId == "APRO"
        ? "Adobe Downloader \(productId)_\(version)_\(platform)-task.json"
            : "Adobe Downloader \(productId)_\(version)-\(language)-\(platform)-task.json"
    }
    
    func saveTask(_ task: NewDownloadTask) async {
        let fileName = getTaskFileName(
            productId: task.productId,
            version: task.productVersion,
            language: task.language,
            platform: task.platform
        )

        await withCheckedContinuation { [weak self] continuation in
            self?.taskCacheQueue.async(flags: .barrier) { [weak self] in
                self?.taskCache[fileName] = task
                continuation.resume()
            }
        }
        
        let fileURL = tasksDirectory.appendingPathComponent(fileName)
        
        let taskData = TaskData(
            sapCode: task.productId,
            version: task.productVersion,
            language: task.language,
            displayName: task.displayName,
            directory: task.directory,
            productsToDownload: task.dependenciesToDownload.map { product in
                ProductData(
                    sapCode: product.sapCode,
                    version: product.version,
                    buildGuid: product.buildGuid,
                    applicationJson: product.applicationJson,
                    packages: product.packages.map { package in
                        PackageData(
                            type: package.type,
                            fullPackageName: package.fullPackageName,
                            downloadSize: package.downloadSize,
                            downloadURL: package.downloadURL,
                            downloadedSize: package.downloadedSize,
                            progress: package.progress,
                            speed: package.speed,
                            status: package.status,
                            downloaded: package.downloaded,
                            packageVersion: package.packageVersion
                        )
                    }
                )
            },
            retryCount: task.retryCount,
            createAt: task.createAt,
            totalStatus: task.totalStatus ?? .waiting,
            totalProgress: task.totalProgress,
            totalDownloadedSize: task.totalDownloadedSize,
            totalSize: task.totalSize,
            totalSpeed: task.totalSpeed,
            displayInstallButton: task.displayInstallButton,
            platform: task.platform
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(taskData)
            // print("保存数据")
            try data.write(to: fileURL)
        } catch {
            print("Error saving task: \(error)")
        }
    }
    
    func loadTasks() async -> [NewDownloadTask] {
        var tasks: [NewDownloadTask] = []
        
        do {
            let files = try fileManager.contentsOfDirectory(at: tasksDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let fileName = file.lastPathComponent

                let cachedTask = await withCheckedContinuation { [weak self] continuation in
                    self?.taskCacheQueue.sync { [weak self] in
                        continuation.resume(returning: self?.taskCache[fileName])
                    }
                }
                
                if let cachedTask = cachedTask {
                    tasks.append(cachedTask)
                } else if let task = await loadTask(from: file) {
                    await withCheckedContinuation { [weak self] continuation in
                        self?.taskCacheQueue.async(flags: .barrier) { [weak self] in
                            self?.taskCache[fileName] = task
                            continuation.resume()
                        }
                    }
                    tasks.append(task)
                }
            }
        } catch {
            print("Error loading tasks: \(error)")
        }
        
        return tasks
    }
    
    private func loadTask(from url: URL) async -> NewDownloadTask? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let taskData = try decoder.decode(TaskData.self, from: data)
            let shouldNormalizePackagesToPaused: Bool = {
                switch taskData.totalStatus {
                case .completed, .failed:
                    return false
                default:
                    return true
                }
            }()
            
            let products = taskData.productsToDownload.map { productData -> DependenciesToDownload in
                let product = DependenciesToDownload(
                    sapCode: productData.sapCode,
                    version: productData.version,
                    buildGuid: productData.buildGuid,
                    applicationJson: productData.applicationJson ?? ""
                )
                
                product.packages = productData.packages.map { packageData -> Package in
                    let package = Package(
                        type: packageData.type,
                        fullPackageName: packageData.fullPackageName,
                        downloadSize: packageData.downloadSize,
                        downloadURL: packageData.downloadURL,
                        packageVersion: packageData.packageVersion
                    )
                    let clampedDownloadedSize = packageData.downloadSize > 0
                        ? min(max(packageData.downloadedSize, 0), packageData.downloadSize)
                        : max(packageData.downloadedSize, 0)
                    package.speed = 0

                    if packageData.downloaded || packageData.status == .completed {
                        package.downloaded = true
                        package.status = .completed
                        package.downloadedSize = packageData.downloadSize
                        package.progress = 1.0
                    } else {
                        package.downloaded = false
                        package.downloadedSize = clampedDownloadedSize
                        package.progress = package.downloadSize > 0
                            ? min(max(Double(clampedDownloadedSize) / Double(package.downloadSize), 0), 1)
                            : packageData.progress
                        package.status = shouldNormalizePackagesToPaused ? .paused : packageData.status
                    }
                    return package
                }
                
                return product
            }
            
            let initialStatus: DownloadStatus
            switch taskData.totalStatus {
            case .completed(let info):
                initialStatus = .completed(info)
            case .failed(let info):
                initialStatus = .failed(info)
            case .downloading:
                initialStatus = .paused(DownloadStatus.PauseInfo(
                    reason: .other(String(localized: "程序退出")),
                    timestamp: Date(),
                    resumable: true
                ))
            default:
                initialStatus = .paused(DownloadStatus.PauseInfo(
                    reason: .other(String(localized: "程序重启后自动暂停")),
                    timestamp: Date(),
                    resumable: true
                ))
            }
            
            let task = NewDownloadTask(
                productId: taskData.sapCode,
                productVersion: taskData.version,
                language: taskData.language,
                displayName: taskData.displayName,
                directory: taskData.directory,
                dependenciesToDownload: products,
                retryCount: taskData.retryCount,
                createAt: taskData.createAt,
                totalStatus: initialStatus,
                totalProgress: taskData.totalProgress,
                totalDownloadedSize: taskData.totalDownloadedSize,
                totalSize: taskData.totalSize,
                totalSpeed: 0,
                currentPackage: products.first?.packages.first,
                platform: taskData.platform
            )
            task.displayInstallButton = taskData.displayInstallButton
            task.totalPackages = products.reduce(0) { $0 + $1.packages.count }
            task.completedPackages = products.reduce(0) { result, product in
                result + product.packages.filter { $0.downloaded }.count
            }
            let totalSize = products
                .flatMap { $0.packages }
                .reduce(Int64(0)) { $0 + $1.downloadSize }
            let totalDownloadedSize = products
                .flatMap { $0.packages }
                .reduce(Int64(0)) { result, package in
                    result + min(max(package.downloadedSize, 0), package.downloadSize)
                }
            task.totalSize = totalSize
            task.totalDownloadedSize = totalSize > 0 ? min(max(totalDownloadedSize, 0), totalSize) : 0
            task.totalProgress = totalSize > 0
                ? Double(task.totalDownloadedSize) / Double(totalSize)
                : 0
            
            return task
        } catch {
            print("Error loading task from \(url): \(error)")
            return nil
        }
    }
    
    func removeTask(_ task: NewDownloadTask) {
        let fileName = getTaskFileName(
            productId: task.productId,
            version: task.productVersion,
            language: task.language,
            platform: task.platform
        )
        let fileURL = tasksDirectory.appendingPathComponent(fileName)

        taskCacheQueue.async(flags: .barrier) { [weak self] in
            self?.taskCache.removeValue(forKey: fileName)
        }
        
        try? fileManager.removeItem(at: fileURL)
    }
    
    func createExistingProgramTask(productId: String, version: String, language: String, displayName: String, platform: String, directory: URL) async {
        let fileName = getTaskFileName(
            productId: productId,
            version: version,
            language: language,
            platform: platform
        )
        
        let product = DependenciesToDownload(
            sapCode: productId,
            version: version,
            buildGuid: "",
            applicationJson: ""
        )
        
        let package = Package(
            type: "",
            fullPackageName: "",
            downloadSize: 0,
            downloadURL: "",
            packageVersion: version
        )
        package.downloaded = true
        package.progress = 1.0
        package.status = .completed
        
        product.packages = [package]
        
        let task = NewDownloadTask(
            productId: productId,
            productVersion: version,
            language: language,
            displayName: displayName,
            directory: directory,
            dependenciesToDownload: [product],
            retryCount: 0,
            createAt: Date(),
            totalStatus: .completed(DownloadStatus.CompletionInfo(
                timestamp: Date(),
                totalTime: 0,
                totalSize: 0
            )),
            totalProgress: 1.0,
            totalDownloadedSize: 0,
            totalSize: 0,
            totalSpeed: 0,
            currentPackage: package,
            platform: platform
        )
        task.displayInstallButton = true

        await withCheckedContinuation { [weak self] continuation in
            self?.taskCacheQueue.async(flags: .barrier) { [weak self] in
                self?.taskCache[fileName] = task
                continuation.resume()
            }
        }
        
        await saveTask(task)
    }

}

private struct TaskData: Codable {
    let sapCode: String
    let version: String
    let language: String
    let displayName: String
    let directory: URL
    let productsToDownload: [ProductData]
    let retryCount: Int
    let createAt: Date
    let totalStatus: DownloadStatus
    let totalProgress: Double
    let totalDownloadedSize: Int64
    let totalSize: Int64
    let totalSpeed: Double
    let displayInstallButton: Bool
    let platform: String
}

private struct ProductData: Codable {
    let sapCode: String
    let version: String
    let buildGuid: String
    let applicationJson: String?
    let packages: [PackageData]
}

private struct PackageData: Codable {
    let type: String
    let fullPackageName: String
    let downloadSize: Int64
    let downloadURL: String
    let downloadedSize: Int64
    let progress: Double
    let speed: Double
    let status: PackageStatus
    let downloaded: Bool
    let packageVersion: String
} 
