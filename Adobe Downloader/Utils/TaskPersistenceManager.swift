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
        "\(installerOutputName(productId: productId, version: version, language: language, platform: platform))-task.json"
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
                    platform: product.platform,
                    baseVersion: product.baseVersion,
                    buildVersion: product.buildVersion,
                    selectedReason: product.selectedReason,
                    hostValidation: product.hostValidation,
                    packages: product.packages.map { package in
                        PackageData(
                            type: package.type,
                            fullPackageName: package.fullPackageName,
                            downloadSize: package.downloadSize,
                            downloadURL: package.downloadURL,
                            manifestURL: package.manifestURL,
                            validationURL: package.validationURL,
                            validationURLType1: package.validationURLType1,
                            packageHashKey: package.packageHashKey,
                            downloadedSize: package.downloadedSize,
                            progress: package.progress,
                            speed: package.speed,
                            status: package.status,
                            downloaded: package.downloaded,
                            packageVersion: package.packageVersion,
                            condition: package.condition,
                            isRequired: package.isRequired,
                            isDefaultSelected: package.isDefaultSelected,
                            isOfficiallyEligible: package.isOfficiallyEligible,
                            officialFilterReasons: package.officialFilterReasons,
                            isSelected: package.isSelected,
                            isBaselineDownloaded: package.isBaselineDownloaded,
                            hostValidation: package.hostValidation
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
            platform: task.platform,
            targetArchitecture: task.targetArchitecture
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

    func taskArtifactsAreValid(_ task: NewDownloadTask) -> Bool {
        let products = task.dependenciesToDownload
        guard products.contains(where: { !$0.packages.isEmpty }) else {
            return false
        }

        for product in products {
            for package in product.packages {
                let savedAsCompleted = package.downloaded || package.status == .completed
                guard restoredPackageArchiveSize(
                    productId: task.productId,
                    package: package,
                    taskDirectory: task.directory,
                    sapCode: product.sapCode,
                    savedAsCompleted: savedAsCompleted
                ) != nil else {
                    return false
                }
            }
        }

        return true
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
            var recoveredFromLocalArchive = false
            
            let products = taskData.productsToDownload.map { productData -> DependenciesToDownload in
                let parsedPackageMetadata = packageMetadataByFullPackageName(applicationJson: productData.applicationJson)
                let product = DependenciesToDownload(
                    sapCode: productData.sapCode,
                    version: productData.version,
                    buildGuid: productData.buildGuid,
                    applicationJson: productData.applicationJson ?? "",
                    platform: productData.platform ?? "",
                    baseVersion: productData.baseVersion ?? "",
                    buildVersion: productData.buildVersion ?? "",
                    selectedReason: productData.selectedReason ?? "",
                    hostValidation: productData.hostValidation
                )
                
                product.packages = productData.packages.map { packageData -> Package in
                    let parsedPackage = parsedPackageMetadata[packageData.fullPackageName]
                    let packageHashKey = !(packageData.packageHashKey ?? "").isEmpty
                        ? (packageData.packageHashKey ?? "")
                        : (parsedPackage?.packageHashKey ?? "")
                    let validationURL = packageData.validationURL ?? parsedPackage?.validationURLType2
                    let validationURLType1 = packageData.validationURLType1 ?? parsedPackage?.validationURLType1
                    let downloadURL = packageData.downloadURL.isEmpty ? (parsedPackage?.path ?? "") : packageData.downloadURL
                    let manifestURL = packageData.manifestURL ?? parsedPackage?.manifestURL ?? ""
                    let downloadSize = packageData.downloadSize > 0 ? packageData.downloadSize : (parsedPackage?.downloadSize ?? 0)
                    let package = Package(
                        type: packageData.type,
                        fullPackageName: packageData.fullPackageName,
                        downloadSize: downloadSize,
                        downloadURL: downloadURL,
                        manifestURL: manifestURL,
                        packageVersion: packageData.packageVersion,
                        condition: packageData.condition ?? "",
                        isRequired: packageData.isRequired ?? false,
                        isDefaultSelected: packageData.isDefaultSelected ?? false,
                        isOfficiallyEligible: packageData.isOfficiallyEligible ?? true,
                        officialFilterReasons: packageData.officialFilterReasons ?? [],
                        validationURL: validationURL,
                        validationURLType1: validationURLType1,
                        packageHashKey: packageHashKey
                    )
                    package.isSelected = package.isRequired || (packageData.isSelected ?? false) || package.isDefaultSelected || packageData.downloaded
                    package.isBaselineDownloaded = packageData.isBaselineDownloaded ?? packageData.downloaded
                    package.hostValidation = packageData.hostValidation
                    let clampedDownloadedSize = package.downloadSize > 0
                        ? min(max(packageData.downloadedSize, 0), package.downloadSize)
                        : max(packageData.downloadedSize, 0)
                    package.speed = 0

                    let savedAsCompleted = packageData.downloaded || packageData.status == .completed
                    let restoredArchiveSize = restoredPackageArchiveSize(
                        productId: taskData.sapCode,
                        package: package,
                        taskDirectory: taskData.directory,
                        sapCode: productData.sapCode,
                        savedAsCompleted: savedAsCompleted
                    )

                    if let restoredArchiveSize {
                        let originalDownloadSize = package.downloadSize
                        if package.downloadSize <= 0 || !package.manifestURL.isEmpty {
                            package.downloadSize = restoredArchiveSize
                        }
                        recoveredFromLocalArchive = recoveredFromLocalArchive || !savedAsCompleted || originalDownloadSize != package.downloadSize
                        package.downloaded = true
                        package.status = .completed
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                    } else {
                        package.downloaded = false
                        package.downloadedSize = savedAsCompleted ? 0 : clampedDownloadedSize
                        package.progress = package.downloadSize > 0
                            ? min(max(Double(package.downloadedSize) / Double(package.downloadSize), 0), 1)
                            : packageData.progress
                        package.status = (shouldNormalizePackagesToPaused || savedAsCompleted) ? .paused : packageData.status
                    }
                    return package
                }
                product.completedPackages = product.packages.filter { $0.downloaded }.count
                
                return product
            }
            
            let allPackages = products.flatMap { $0.packages }
            let hasPendingPackages = allPackages.contains { !$0.downloaded }
            let totalSize = allPackages.reduce(Int64(0)) { $0 + $1.downloadSize }
            let totalDownloadedSize = allPackages.reduce(Int64(0)) { result, package in
                result + min(max(package.downloadedSize, 0), package.downloadSize)
            }
            let initialStatus: DownloadStatus
            if !allPackages.isEmpty && !hasPendingPackages {
                switch taskData.totalStatus {
                case .completed(let info):
                    initialStatus = .completed(DownloadStatus.CompletionInfo(
                        timestamp: info.timestamp,
                        totalTime: info.totalTime,
                        totalSize: totalSize
                    ))
                default:
                    initialStatus = .completed(DownloadStatus.CompletionInfo(
                        timestamp: Date(),
                        totalTime: Date().timeIntervalSince(taskData.createAt),
                        totalSize: totalSize
                    ))
                }
            } else {
                switch taskData.totalStatus {
                case .completed:
                    initialStatus = .paused(DownloadStatus.PauseInfo(
                        reason: .other(String(localized: "下载包完整性校验未通过")),
                        timestamp: Date(),
                        resumable: true
                    ))
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
            }
            
            let restoredTargetArchitecture = taskData.targetArchitecture ?? fallbackTargetArchitecture(
                platforms: products.map(\.platform) + [taskData.platform]
            )

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
                currentPackage: allPackages.first { !$0.downloaded } ?? allPackages.first,
                platform: taskData.platform,
                targetArchitecture: restoredTargetArchitecture
            )
            task.displayInstallButton = taskData.displayInstallButton
            task.totalPackages = products.reduce(0) { $0 + $1.packages.count }
            task.completedPackages = products.reduce(0) { result, product in
                result + product.packages.filter { $0.downloaded }.count
            }
            task.totalSize = totalSize
            task.totalDownloadedSize = totalSize > 0 ? min(max(totalDownloadedSize, 0), totalSize) : 0
            task.totalProgress = totalSize > 0
                ? Double(task.totalDownloadedSize) / Double(totalSize)
                : 0

            if recoveredFromLocalArchive {
                await saveTask(task)
            }

            return task
        } catch {
            print("Error loading task from \(url): \(error)")
            return nil
        }
    }

    private func packageMetadataByFullPackageName(applicationJson: String?) -> [String: ParsedPackage] {
        guard let applicationJson,
              !applicationJson.isEmpty,
              let applicationInfo = try? ApplicationJSONParser.parse(jsonString: applicationJson) else {
            return [:]
        }

        var packages: [String: ParsedPackage] = [:]
        for package in applicationInfo.packages {
            packages[package.fullPackageName] = package
        }
        return packages
    }

    private func restoredPackageArchiveSize(productId: String, package: Package, taskDirectory: URL, sapCode: String, savedAsCompleted: Bool) -> Int64? {
        if package.fullPackageName.isEmpty {
            guard savedAsCompleted, fileManager.fileExists(atPath: taskDirectory.path) else {
                return nil
            }
            return itemSizeIfExists(at: taskDirectory)
        }

        let fileURL = isManifestInstallerProduct(productId)
            ? taskDirectory
            : taskDirectory
                .appendingPathComponent(sapCode)
                .appendingPathComponent(package.fullPackageName)

        guard let actualSize = itemSizeIfExists(at: fileURL) else {
            return nil
        }

        if package.downloadSize > 0, actualSize != package.downloadSize {
            return nil
        }
        if package.downloadSize <= 0, actualSize <= 0 {
            return nil
        }

        return actualSize
    }

    private func itemSizeIfExists(at url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return nil
        }

        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
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
        package.isSelected = true
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
            platform: platform,
            targetArchitecture: fallbackTargetArchitecture(platform: platform)
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

private func fallbackTargetArchitecture(platform: String) -> String {
    fallbackTargetArchitecture(platforms: [platform])
}

private func fallbackTargetArchitecture(platforms: [String]) -> String {
    platforms.contains(where: {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "macarm64"
    })
        ? HDPIMParityTargetArchitecture.appleSilicon.rawValue
        : HDPIMParityTargetArchitecture.intel.rawValue
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
    let targetArchitecture: String?
}

private struct ProductData: Codable {
    let sapCode: String
    let version: String
    let buildGuid: String
    let applicationJson: String?
    let platform: String?
    let baseVersion: String?
    let buildVersion: String?
    let selectedReason: String?
    let hostValidation: HDPIMHostValidationSnapshot?
    let packages: [PackageData]
}

private struct PackageData: Codable {
    let type: String
    let fullPackageName: String
    let downloadSize: Int64
    let downloadURL: String
    let manifestURL: String?
    let validationURL: String?
    let validationURLType1: String?
    let packageHashKey: String?
    let downloadedSize: Int64
    let progress: Double
    let speed: Double
    let status: PackageStatus
    let downloaded: Bool
    let packageVersion: String
    let condition: String?
    let isRequired: Bool?
    let isDefaultSelected: Bool?
    let isOfficiallyEligible: Bool?
    let officialFilterReasons: [String]?
    let isSelected: Bool?
    let isBaselineDownloaded: Bool?
    let hostValidation: HDPIMHostValidationSnapshot?
}
