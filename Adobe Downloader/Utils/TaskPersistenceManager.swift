import Foundation
import CryptoKit

class TaskPersistenceManager: @unchecked Sendable {
    static let shared = TaskPersistenceManager()
    
    private let fileManager = FileManager.default
    private let tasksDirectory: URL
    @MainActor private weak var cancelTracker: CancelTracker?
    private let ioQueue = DispatchQueue(label: "com.x1a0he.macOS.Adobe-Downloader.taskPersistence", qos: .utility)
    private var taskCache: [UUID: NewDownloadTask] = [:]
    private var sourceFiles: [UUID: Set<URL>] = [:]
    private var removedTaskIDs: Set<UUID> = []
    private var hasLoadedRemovedTaskIDs = false

    private init() {
        let containerURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        tasksDirectory = containerURL.appendingPathComponent("Adobe Downloader/tasks", isDirectory: true)
    }

    @MainActor
    func setCancelTracker(_ tracker: CancelTracker) {
        self.cancelTracker = tracker
    }

    func taskFileURL(for id: UUID) -> URL {
        tasksDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    @MainActor
    func saveTask(_ task: NewDownloadTask) async {
        let taskData = TaskData(
            id: task.id,
            materialKind: task.materialKind,
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
                            deltaBasePackageVersion: package.deltaBasePackageVersion,
                            baselinePackageName: package.baselinePackageName,
                            hostValidation: package.hostValidation
                        )
                    }
                )
            },
            requiredDependencies: task.requiredDependencies,
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
        
        await withCheckedContinuation { continuation in
            // 快照捕获与入队都在 MainActor 上完成，同一任务的保存顺序不会倒置。
            ioQueue.async {
                self.persist(taskData, task: task)
                continuation.resume()
            }
        }
    }

    private func persist(_ data: TaskData, task: NewDownloadTask) {
        loadRemovedTaskIDsIfNeeded()
        guard !removedTaskIDs.contains(task.id) else { return }
        let fileURL = taskFileURL(for: task.id)
        do {
            try fileManager.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let encoded = try encoder.encode(data)
            // print("保存数据")
            try encoded.write(to: fileURL, options: .atomic)
            taskCache[task.id] = task
            let legacyFiles = sourceFiles[task.id, default: []].filter { $0 != fileURL }
            for legacyFile in legacyFiles where fileManager.fileExists(atPath: legacyFile.path) {
                try archiveRecord(legacyFile, id: task.id, collection: ".legacy-records")
            }
            sourceFiles[task.id] = [fileURL]
        } catch {
            print("Error saving task \(task.id): \(error)")
        }
    }

    func loadTasks() async -> [NewDownloadTask] {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                self.loadRemovedTaskIDsIfNeeded()
                do {
                    guard self.fileManager.fileExists(atPath: self.tasksDirectory.path) else {
                        continuation.resume(returning: [])
                        return
                    }
                    let files = try self.fileManager.contentsOfDirectory(at: self.tasksDirectory, includingPropertiesForKeys: nil)
                    let records = files.filter { $0.pathExtension == "json" }.compactMap { self.readRecord(from: $0) }
                    for record in records {
                        self.sourceFiles[record.id, default: []].insert(record.url)
                    }
                    // 原子写完成但旧名归档尚未完成时，优先读取 UUID 文件。
                    let orderedRecords = records.sorted { lhs, rhs in
                        let lhsCanonical = lhs.url == self.taskFileURL(for: lhs.id)
                        let rhsCanonical = rhs.url == self.taskFileURL(for: rhs.id)
                        if lhsCanonical != rhsCanonical { return lhsCanonical }
                        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
                    }
                    var seen: Set<UUID> = []
                    var tasks: [NewDownloadTask] = []
                    for record in orderedRecords {
                        guard !self.removedTaskIDs.contains(record.id), seen.insert(record.id).inserted else { continue }
                        let task = self.taskCache[record.id] ?? self.restoreTask(record.data, id: record.id)
                        self.taskCache[record.id] = task
                        tasks.append(task)
                    }
                    continuation.resume(returning: tasks)
                } catch {
                    print("Error loading tasks: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private struct DiskRecord {
        let url: URL
        let id: UUID
        let data: TaskData
    }

    private func readRecord(from url: URL) -> DiskRecord? {
        do {
            let data = try JSONDecoder().decode(TaskData.self, from: Data(contentsOf: url))
            return DiskRecord(url: url, id: data.id ?? legacyTaskID(data), data: data)
        } catch {
            print("Error loading task from \(url): \(error)")
            return nil
        }
    }

    private func legacyTaskID(_ data: TaskData) -> UUID {
        let fields = [data.sapCode, data.version, data.language, data.platform,
                      data.directory.standardizedFileURL.path, String(data.createAt.timeIntervalSinceReferenceDate)]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func loadRemovedTaskIDsIfNeeded() {
        guard !hasLoadedRemovedTaskIDs else { return }
        let directory = tasksDirectory.appendingPathComponent(".removed-records", isDirectory: true)
        if let records = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            removedTaskIDs.formUnion(records.compactMap { UUID(uuidString: $0.lastPathComponent) })
        }
        hasLoadedRemovedTaskIDs = true
    }

    private func archiveRecord(_ url: URL, id: UUID, collection: String) throws {
        let directory = tasksDirectory.appendingPathComponent(collection, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try fileManager.moveItem(at: url, to: destination)
    }

    @MainActor
    func taskArtifactsAreValid(_ task: NewDownloadTask) -> Bool {
        if task.materialKind == .importedDirectory {
            return importedDirectoryIsValid(task.directory)
        }
        let products = task.dependenciesToDownload
        let metadataDirectory = isManifestInstallerProduct(task.productId)
            ? DownloadArtifactStore.specialMetadataDirectory(for: task) : nil
        guard products.contains(where: { !$0.packages.isEmpty }) else { return false }
        for product in products {
            for package in product.packages {
                guard !package.fullPackageName.isEmpty else { return false }
                let fileURL = packageURL(productId: task.productId, package: package,
                                         taskDirectory: task.directory, sapCode: product.sapCode)
                let inspection = DownloadArtifactStore.inspect(
                    fileURL: fileURL, identity: DownloadArtifactStore.identity(for: package),
                    expectedSize: package.manifestURL.isEmpty ? package.downloadSize : 0,
                    metadataDirectory: metadataDirectory
                )
                guard inspection.verifiedSize != nil else { return false }
            }
        }
        return true
    }

    private func restoreTask(_ taskData: TaskData, id: UUID) -> NewDownloadTask {
        let materialKind = taskData.materialKind ?? inferredMaterialKind(taskData)
        let metadataDirectory = isManifestInstallerProduct(taskData.sapCode)
            ? DownloadArtifactStore.specialMetadataDirectory(
                productId: taskData.sapCode, version: taskData.version, language: taskData.language,
                platform: taskData.platform, directory: taskData.directory
            ) : nil
        let isImportedDirectory = materialKind == .importedDirectory
        let importedDirectoryIsPresent = isImportedDirectory && importedDirectoryIsValid(taskData.directory)
        let shouldNormalizePackagesToPaused: Bool = {
            switch taskData.totalStatus {
            case .completed, .failed:
                return false
            default:
                return true
            }
        }()
        
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
                package.deltaBasePackageVersion = packageData.deltaBasePackageVersion ?? inferredDeltaBasePackageVersion(from: package.fullPackageName)
                package.baselinePackageName = packageData.baselinePackageName ?? inferredBaselinePackageName(from: package.fullPackageName)
                package.hostValidation = packageData.hostValidation
                package.speed = 0
                let savedAsCompleted = packageData.downloaded || packageData.status == .completed
                let inspection: DownloadArtifactStore.Inspection
                if isImportedDirectory {
                    inspection = importedDirectoryIsPresent ? .verified(0) : .missing
                } else if package.fullPackageName.isEmpty {
                    inspection = .unverified
                } else {
                    inspection = DownloadArtifactStore.restore(
                        fileURL: packageURL(productId: taskData.sapCode, package: package,
                                            taskDirectory: taskData.directory, sapCode: productData.sapCode),
                        identity: DownloadArtifactStore.identity(for: package),
                        expectedSize: package.manifestURL.isEmpty ? package.downloadSize : 0,
                        metadataDirectory: metadataDirectory,
                        allowLegacy: savedAsCompleted
                    )
                }

                if let verifiedSize = inspection.verifiedSize {
                    if package.downloadSize <= 0 || !package.manifestURL.isEmpty {
                        package.downloadSize = verifiedSize
                    }
                    package.downloaded = true
                    package.isBaselineDownloaded = packageData.isBaselineDownloaded ?? packageData.downloaded
                    package.status = .completed
                    package.downloadedSize = package.downloadSize
                    package.progress = 1.0
                } else {
                    package.downloaded = false
                    package.isBaselineDownloaded = false
                    package.downloadedSize = package.downloadSize > 0
                        ? min(max(inspection.downloadedBytes, 0), package.downloadSize)
                        : max(inspection.downloadedBytes, 0)
                    package.progress = package.downloadSize > 0
                        ? min(Double(package.downloadedSize) / Double(package.downloadSize), 1)
                        : 0
                    if !shouldNormalizePackagesToPaused, case .failed = packageData.status {
                        package.status = packageData.status
                    } else {
                        package.status = .paused
                    }
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
            result + max(package.downloadedSize, 0)
        }
        let initialStatus: DownloadStatus
        if isImportedDirectory && !importedDirectoryIsPresent {
            initialStatus = .failed(DownloadStatus.FailureInfo(
                message: AppLocalized("导入目录缺少 driver.xml，请重新选择完整安装目录"),
                error: nil, timestamp: Date(), recoverable: false
            ))
        } else if importedDirectoryIsPresent || (!allPackages.isEmpty && !hasPendingPackages) {
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
                    reason: .other(AppLocalized("下载包完整性校验未通过")),
                    timestamp: Date(),
                    resumable: true
                ))
            case .failed(let info):
                initialStatus = .failed(info)
            case .downloading:
                initialStatus = .paused(DownloadStatus.PauseInfo(
                    reason: .other(AppLocalized("程序退出")),
                    timestamp: Date(),
                    resumable: true
                ))
            default:
                initialStatus = .paused(DownloadStatus.PauseInfo(
                    reason: .other(AppLocalized("程序重启后自动暂停")),
                    timestamp: Date(),
                    resumable: true
                ))
            }
        }
        
        let restoredTargetArchitecture = taskData.targetArchitecture ?? fallbackTargetArchitecture(
            platforms: products.map(\.platform) + [taskData.platform]
        )

        let task = NewDownloadTask(
            id: id,
            materialKind: materialKind,
            productId: taskData.sapCode,
            productVersion: taskData.version,
            language: taskData.language,
            displayName: taskData.displayName,
            directory: taskData.directory,
            dependenciesToDownload: products,
            retryCount: taskData.retryCount,
            createAt: taskData.createAt,
            totalStatus: initialStatus,
            totalProgress: 0,
            totalDownloadedSize: totalDownloadedSize,
            totalSize: totalSize,
            totalSpeed: 0,
            currentPackage: allPackages.first { !$0.downloaded } ?? allPackages.first,
            platform: taskData.platform,
            targetArchitecture: restoredTargetArchitecture
        )
        task.requiredDependencies = taskData.requiredDependencies
        task.displayInstallButton = taskData.displayInstallButton
        task.totalPackages = products.reduce(0) { $0 + $1.packages.count }
        task.completedPackages = products.reduce(0) { result, product in
            result + product.packages.filter { $0.downloaded }.count
        }
        task.totalSize = totalSize
        task.totalDownloadedSize = totalSize > 0 ? min(max(totalDownloadedSize, 0), totalSize) : max(totalDownloadedSize, 0)
        task.totalProgress = importedDirectoryIsPresent ? 1 : (totalSize > 0
            ? Double(task.totalDownloadedSize) / Double(totalSize)
            : 0)
        return task
    }

    private func inferredMaterialKind(_ data: TaskData) -> DownloadMaterialKind {
        guard case .completed = data.totalStatus,
              data.productsToDownload.flatMap({ $0.packages }).allSatisfy({ $0.fullPackageName.isEmpty }),
              importedDirectoryIsValid(data.directory) else { return .download }
        return .importedDirectory
    }

    private func importedDirectoryIsValid(_ directory: URL) -> Bool {
        let driverURL = directory.appendingPathComponent("driver.xml")
        let values = try? driverURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
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

    private func inferredDeltaBasePackageVersion(from fullPackageName: String) -> String {
        let name = fullPackageName
            .replacingOccurrences(of: ".zip", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = name.range(of: "_delta_", options: [.caseInsensitive, .backwards]) else {
            return ""
        }
        return name[range.upperBound...].replacingOccurrences(of: "_", with: ".")
    }

    private func inferredBaselinePackageName(from fullPackageName: String) -> String {
        let name = fullPackageName
            .replacingOccurrences(of: ".zip", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = name.range(of: "_delta_", options: [.caseInsensitive, .backwards]) else {
            return ""
        }
        return String(name[..<range.lowerBound])
    }

    private func packageURL(productId: String, package: Package, taskDirectory: URL, sapCode: String) -> URL {
        isManifestInstallerProduct(productId)
            ? taskDirectory
            : taskDirectory.appendingPathComponent(sapCode).appendingPathComponent(package.fullPackageName)
    }

    @MainActor
    func removeTask(_ task: NewDownloadTask) {
        let id = task.id
        ioQueue.async {
            self.loadRemovedTaskIDsIfNeeded()
            self.removedTaskIDs.insert(id)
            self.taskCache.removeValue(forKey: id)
            do {
                // 目录同时作为持久 tombstone，即使有迟到保存也不能重新创建任务。
                let archive = self.tasksDirectory.appendingPathComponent(".removed-records", isDirectory: true)
                    .appendingPathComponent(id.uuidString, isDirectory: true)
                try self.fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
                let files = self.sourceFiles[id, default: []].union([self.taskFileURL(for: id)])
                for file in files where self.fileManager.fileExists(atPath: file.path) {
                    try self.archiveRecord(file, id: id, collection: ".removed-records")
                }
                self.sourceFiles.removeValue(forKey: id)
            } catch {
                print("Error archiving removed task \(id): \(error)")
            }
        }
    }

    @MainActor
    func createExistingProgramTask(productId: String, version: String, language: String, displayName: String, platform: String, directory: URL) async {
        guard importedDirectoryIsValid(directory) else {
            print("Cannot import task without driver.xml: \(directory.path)")
            return
        }

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
            materialKind: .importedDirectory,
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
    let id: UUID?
    let materialKind: DownloadMaterialKind?
    let sapCode: String
    let version: String
    let language: String
    let displayName: String
    let directory: URL
    let productsToDownload: [ProductData]
    let requiredDependencies: [DependenciesToDownload]?
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
    let deltaBasePackageVersion: String?
    let baselinePackageName: String?
    let hostValidation: HDPIMHostValidationSnapshot?
}
