//
//  NewDownloadUtils.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//
import Foundation

actor AsyncFlag {
    private var value: Bool = false
    
    func set() {
        value = true
    }
    
    func isSet() -> Bool {
        return value
    }
    
    func reset() {
        value = false
    }
}

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.permits = value
    }
    
    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}

actor ConcurrentDownloadProgressManager {
    private var packageProgresses: [String: Double] = [:]
    private var packageSizes: [String: Int64] = [:]
    private var packageSpeeds: [String: Double] = [:]
    private var totalSize: Int64 = 0
    private var lastUpdateTime = Date()
    private var smoothedTotalSpeed: Double = 0
    private let speedSmoothingFactor: Double = 0.3
    
    func initialize(packages: [(id: String, size: Int64)]) {
        totalSize = packages.reduce(0) { $0 + $1.size }
        for package in packages {
            packageProgresses[package.id] = 0.0
            packageSizes[package.id] = package.size
            packageSpeeds[package.id] = 0.0
        }
    }

    func initializeWithProgress(packages: [(id: String, size: Int64, progress: Double)]) {
        totalSize = packages.reduce(0) { $0 + $1.size }
        for package in packages {
            packageProgresses[package.id] = package.progress
            packageSizes[package.id] = package.size
            packageSpeeds[package.id] = 0.0
        }
    }
    
    func updatePackageProgress(packageId: String, progress: Double, speed: Double = 0.0) {
        packageProgresses[packageId] = progress
        packageSpeeds[packageId] = speed
    }
    
    func markPackageCompleted(packageId: String) {
        packageProgresses[packageId] = 1.0
        packageSpeeds[packageId] = 0.0
    }
    
    func getTotalProgress() -> (progress: Double, downloadedSize: Int64, totalSpeed: Double) {
        let totalDownloaded = packageProgresses.reduce(Int64(0)) { sum, item in
            let size = packageSizes[item.key] ?? 0
            return sum + Int64(Double(size) * item.value)
        }
        let totalProgress = totalSize > 0 ? Double(totalDownloaded) / Double(totalSize) : 0
        let rawSpeed = packageSpeeds.values.reduce(0, +)

        if smoothedTotalSpeed == 0 || rawSpeed == 0 {
            smoothedTotalSpeed = rawSpeed
        } else {
            smoothedTotalSpeed = speedSmoothingFactor * rawSpeed + (1 - speedSmoothingFactor) * smoothedTotalSpeed
        }

        return (totalProgress, totalDownloaded, smoothedTotalSpeed)
    }
    
    func isAllCompleted() -> Bool {
        return packageProgresses.allSatisfy { $0.value >= 1.0 }
    }
}

class NewDownloadUtils {
    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var completionHandler: (URL?, URLResponse?, Error?) -> Void
        var progressHandler: ((Int64, Int64, Int64) -> Void)?
        var destinationDirectory: URL
        var fileName: String
        private var hasCompleted = false
        private let completionLock = NSLock()
        private var lastUpdateTime = Date()
        private var lastBytes: Int64 = 0
        private var hasReceivedData = false
        var onFirstDataReceived: (() -> Void)?

        init(destinationDirectory: URL,
             fileName: String,
             completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void,
             progressHandler: ((Int64, Int64, Int64) -> Void)? = nil) {
            self.destinationDirectory = destinationDirectory
            self.fileName = fileName
            self.completionHandler = completionHandler
            self.progressHandler = progressHandler
            super.init()
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !hasCompleted else { return }
            hasCompleted = true

            do {
                if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                }

                let destinationURL = destinationDirectory.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.moveItem(at: location, to: destinationURL)
                completionHandler(destinationURL, downloadTask.response, nil)

            } catch {
                print("File operation error in delegate: \(error.localizedDescription)")
                completionHandler(nil, downloadTask.response, error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !hasCompleted else { return }
            hasCompleted = true

            if let error = error {
                switch (error as NSError).code {
                case NSURLErrorCancelled:
                    return
                case NSURLErrorTimedOut:
                    completionHandler(nil, task.response, NetworkError.downloadError("下载超时", error))
                case NSURLErrorNotConnectedToInternet:
                    completionHandler(nil, task.response, NetworkError.noConnection)
                default:
                    completionHandler(nil, task.response, error)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                       didWriteData bytesWritten: Int64,
                       totalBytesWritten: Int64,
                       totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            guard bytesWritten > 0 else { return }

            if !hasReceivedData {
                hasReceivedData = true
                onFirstDataReceived?()
            }

            handleProgressUpdate(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }

        func cleanup() {
            completionHandler = { _, _, _ in }
            progressHandler = nil
        }

        private func handleProgressUpdate(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            let timeDiff = now.timeIntervalSince(lastUpdateTime)

            guard timeDiff >= NetworkConstants.progressUpdateInterval else { return }

            Task {
                progressHandler?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
            }

            lastUpdateTime = now
            lastBytes = totalBytesWritten
        }
    }

    func handleCustomDownload(task: NewDownloadTask, customDependencies: [DependenciesToDownload]) async throws {
        await MainActor.run {
            task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                message: String(localized: "正在准备自定义下载..."),
                timestamp: Date(),
                stage: .fetchingInfo
            )))
        }

        for dependencyToDownload in customDependencies {
            let productDir = task.directory.appendingPathComponent("\(dependencyToDownload.sapCode)")
            if !FileManager.default.fileExists(atPath: productDir.path) {
                try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
            }

            if let applicationJson = dependencyToDownload.applicationJson {
                var processedJsonString = applicationJson
                
                if let jsonData = applicationJson.data(using: .utf8),
                   var appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                    let selectedPackageNames = Set(dependencyToDownload.packages.filter { $0.isSelected }.map { $0.fullPackageName })
                    
                    if var packages = appInfo["Packages"] as? [String: Any],
                       let packageArray = packages["Package"] as? [[String: Any]] {

                        let filteredPackages = packageArray.filter { package in
                            if let packageName = package["PackageName"] as? String {
                                let fullPackageName = packageName.hasSuffix(".zip") ? packageName : "\(packageName).zip"
                                return selectedPackageNames.contains(fullPackageName)
                            }
                            if let fullPackageName = package["fullPackageName"] as? String {
                                return selectedPackageNames.contains(fullPackageName)
                            }
                            return false
                        }
                        
                        packages["Package"] = filteredPackages
                        appInfo["Packages"] = packages
                    }

                    if var modules = appInfo["Modules"] as? [String: Any],
                       let moduleArray = modules["Module"] as? [[String: Any]] {

                        let selectedPackageNamesWithoutZip = Set(dependencyToDownload.packages.filter { $0.isSelected }.compactMap { package in
                            let name = package.fullPackageName
                            return name.hasSuffix(".zip") ? String(name.dropLast(4)) : name
                        })

                        let filteredModules = moduleArray.filter { module in
                            if let referencePackages = module["ReferencePackages"] as? [String: Any],
                               let referencePackageArray = referencePackages["ReferencePackage"] as? [String] {
                                return referencePackageArray.contains { packageName in
                                    selectedPackageNamesWithoutZip.contains(packageName)
                                }
                            }
                            return false
                        }
                        
                        modules["Module"] = filteredModules
                        appInfo["Modules"] = modules
                    }
                    
                    if let processedData = try? JSONSerialization.data(withJSONObject: appInfo, options: .prettyPrinted),
                       let processedString = String(data: processedData, encoding: .utf8) {
                        processedJsonString = processedString
                    }
                }
                
                let jsonURL = productDir.appendingPathComponent("application.json")
                try processedJsonString.write(to: jsonURL, atomically: true, encoding: String.Encoding.utf8)
            }
        }

        let filteredDependencies = customDependencies.map { dependency in
            let selectedPackages = dependency.packages.filter { $0.isSelected }
            let filteredDependency = DependenciesToDownload(
                sapCode: dependency.sapCode,
                version: dependency.version,
                buildGuid: dependency.buildGuid,
                applicationJson: dependency.applicationJson ?? "",
                isSoftDependency: dependency.isSoftDependency,
                platform: dependency.platform,
                baseVersion: dependency.baseVersion,
                buildVersion: dependency.buildVersion,
                selectedReason: dependency.selectedReason,
                hostValidation: nil
            )
            filteredDependency.packages = selectedPackages
            return filteredDependency
        }.filter { !$0.packages.isEmpty }
        
        let totalSize = filteredDependencies.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }
        
        await MainActor.run {
            task.dependenciesToDownload = filteredDependencies
            task.totalSize = totalSize
        }
        
        await startConcurrentDownloadProcess(task: task)
    }

    private func startConcurrentDownloadProcess(task: NewDownloadTask) async {
        let maxConcurrency = StorageData.shared.maxConcurrentDownloads

        let isCancelled = await globalCancelTracker.isCancelled(task.id)
        let isPaused = await globalCancelTracker.isPaused(task.id)

        if isCancelled || isPaused {
            return
        }

        await rebuildTaskPackages(task: task, inactiveStatus: .waiting)

        var allPackages: [(package: Package, dependency: DependenciesToDownload, originalIndex: Int)] = []
        var currentIndex = 0

        for dependency in task.dependenciesToDownload {
            for package in dependency.packages where !package.downloaded {
                allPackages.append((package: package, dependency: dependency, originalIndex: currentIndex))
                currentIndex += 1
            }
        }

        allPackages.sort { $0.originalIndex < $1.originalIndex }

        if allPackages.isEmpty {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            }
            await globalNetworkManager.saveTask(task)
            cleanupCompletedPackageMetadata(task: task)
            return
        }

        let packagesSnapshot = allPackages
        await MainActor.run {
            let totalPackages = packagesSnapshot.count
            task.totalPackages = totalPackages
            task.currentPackage = packagesSnapshot.first?.package
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: packagesSnapshot.first?.package.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        await prepareDownloadEnvironment(task: task)

        await withTaskGroup(of: Void.self) { group in
            let semaphore = AsyncSemaphore(value: maxConcurrency)
            let totalCount = allPackages.count

            for (index, (package, dependency, _)) in allPackages.enumerated() {
                group.addTask { [weak self] in
                    guard let self = self else { return }

                    await semaphore.wait()
                    defer {
                        Task { await semaphore.signal() }
                    }

                    let isCancelled = await globalCancelTracker.isCancelled(task.id)
                    let isPaused = await globalCancelTracker.isPaused(task.id)
                    if isCancelled || isPaused {
                        await MainActor.run {
                            if package.status != .completed && !package.downloaded {
                                package.status = isPaused ? .paused : .waiting
                            }
                        }
                        return
                    }

                    await MainActor.run {
                        package.status = .downloading
                        task.currentPackage = package
                        task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                            fileName: package.fullPackageName,
                            currentPackageIndex: index,
                            totalPackages: totalCount,
                            startTime: Date(),
                            estimatedTimeRemaining: nil
                        )))
                        task.objectWillChange.send()
                    }

                    let result = await self.downloadPackageWithPDM(
                        package: package,
                        task: task,
                        product: dependency
                    )

                    switch result {
                    case .completed:
                        await MainActor.run {
                            package.downloadedSize = package.downloadSize
                            package.progress = 1.0
                            package.speed = 0
                            package.status = .completed
                            package.downloaded = true
                            dependency.completedPackages = dependency.packages.filter { $0.downloaded }.count
                            dependency.objectWillChange.send()
                            task.completedPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.completedPackages }
                        }
                        await self.updateTaskProgressDirect(task: task)
                        await globalNetworkManager.saveTask(task)
                        self.cleanupCompletedPackageMetadata(task: task)

                    case .paused:
                        await MainActor.run {
                            package.speed = 0
                            package.status = .paused
                        }

                    case .cancelled:
                        await MainActor.run {
                            package.speed = 0
                            package.status = .waiting
                        }

                    case .error(let err):
                        await MainActor.run {
                            package.speed = 0
                            package.status = .failed(err.localizedDescription ?? "Download error")
                        }
                    }
                }
            }
        }

        let allCompleted = task.dependenciesToDownload.flatMap { $0.packages }.allSatisfy { $0.downloaded }
        if allCompleted {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            }
            await globalNetworkManager.saveTask(task)
            cleanupCompletedPackageMetadata(task: task)
        }
    }

    private func prepareDownloadEnvironment(task: NewDownloadTask) async {
        let driverPath = task.directory.appendingPathComponent("driver.xml")
        if !FileManager.default.fileExists(atPath: driverPath.path) {
            if let productInfo = globalCcmResult.products.first(where: { $0.id == task.productId && $0.version == task.productVersion }) {
                
                var selectedModules: [[String: Any]] = []
                if let mainDependency = task.dependenciesToDownload.first(where: { $0.sapCode == task.productId }) {
                    let productDir = task.directory.appendingPathComponent(mainDependency.sapCode)
                    let jsonURL = productDir.appendingPathComponent("application.json")
                    
                    if let jsonString = try? String(contentsOf: jsonURL, encoding: .utf8),
                       let jsonData = jsonString.data(using: .utf8),
                       let appInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let modules = appInfo["Modules"] as? [String: Any],
                       let moduleArray = modules["Module"] as? [[String: Any]] {
                        selectedModules = moduleArray
                    }
                }
                
                let driverXml = generateDriverXML(
                    version: task.productVersion,
                    language: task.language,
                    productInfo: productInfo,
                    dependencies: task.dependenciesToDownload,
                    targetArchitecture: task.targetArchitecture,
                    modules: selectedModules
                )
                do {
                    try driverXml.write(to: driverPath, atomically: true, encoding: String.Encoding.utf8)
                } catch {
                    print("Error generating driver.xml:", error.localizedDescription)
                    await MainActor.run {
                        task.setStatus(.failed(DownloadStatus.FailureInfo(
                            message: "生成 driver.xml 失败: \(error.localizedDescription)",
                            error: error,
                            timestamp: Date(),
                            recoverable: false
                        )))
                    }
                    return
                }
            }
        }

        for dependencyToDownload in task.dependenciesToDownload {
            let productDir = task.directory.appendingPathComponent(dependencyToDownload.sapCode)
            if !FileManager.default.fileExists(atPath: productDir.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: productDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    print("Error creating directory for \(dependencyToDownload.sapCode): \(error)")
                    continue
                }
            }
        }
    }

    private func generatePackageIdentifier(package: Package, task: NewDownloadTask, dependency: DependenciesToDownload) -> String {
        "AdobeDownloader|\(task.productId)|\(task.productVersion)|\(task.language)|\(task.platform)|\(dependency.sapCode)|\(package.id.uuidString)"
    }

    private func normalizedProgress(downloadedSize: Int64, totalSize: Int64) -> Double {
        guard totalSize > 0 else { return 0 }
        return min(max(Double(downloadedSize) / Double(totalSize), 0), 1)
    }

    private func packageDestinationURL(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package) -> URL {
        task.directory
            .appendingPathComponent(dependency.sapCode)
            .appendingPathComponent(package.fullPackageName)
    }

    private func restoredDownloadedSize(package: Package, destinationURL: URL) -> Int64? {
        let aamd = AAMDFileManager(downloadFileURL: destinationURL)
        guard aamd.exists(), aamd.validateAAMDFile() else {
            return nil
        }

        let aamdHeaders = aamd.readHeaders()
        let segmentSize = Int64(aamdHeaders?["SEGMENT_SIZE"] ?? "") ?? (2 * 1024 * 1024)
        let fileSize = Int64(aamdHeaders?["FILE_SIZE"] ?? "") ?? package.downloadSize
        let expectedSize = max(fileSize, package.downloadSize)
        let segmentCount = max(1, Int((expectedSize + segmentSize - 1) / segmentSize))
        let resumedBytes = aamd.getTotalBytesDownloaded(segmentCount: segmentCount)
        return min(max(resumedBytes, 0), expectedSize)
    }

    private func shouldTreatPackageAsCompleted(package: Package, destinationURL: URL) -> Bool {
        if package.downloaded || package.status == .completed {
            return true
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        if package.downloadSize > 0, package.downloadedSize >= package.downloadSize {
            return true
        }

        return package.progress >= 1.0
    }

    private func rebuildTaskPackages(task: NewDownloadTask, inactiveStatus: PackageStatus) async {
        var completedTaskPackages = 0
        var totalTaskPackages = 0

        for dependency in task.dependenciesToDownload {
            var completedDependencyPackages = 0

            for package in dependency.packages {
                totalTaskPackages += 1

                let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
                let restoredBytes = restoredDownloadedSize(package: package, destinationURL: destinationURL)
                let restoredIsCompleted = (restoredBytes ?? 0) >= package.downloadSize && package.downloadSize > 0
                let savedIsCompleted = restoredBytes == nil && shouldTreatPackageAsCompleted(package: package, destinationURL: destinationURL)

                await MainActor.run {
                    package.speed = 0

                    if restoredIsCompleted || savedIsCompleted {
                        package.downloaded = true
                        package.status = .completed
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                        completedDependencyPackages += 1
                        completedTaskPackages += 1
                        return
                    }

                    package.downloaded = false
                    package.status = inactiveStatus

                    if let restoredBytes {
                        let normalizedDownloadedSize = min(max(restoredBytes, 0), package.downloadSize)
                        package.downloadedSize = normalizedDownloadedSize
                        package.progress = normalizedProgress(
                            downloadedSize: normalizedDownloadedSize,
                            totalSize: package.downloadSize
                        )
                    } else {
                        package.downloadedSize = 0
                        package.progress = 0
                    }
                }
            }

            await MainActor.run {
                dependency.completedPackages = completedDependencyPackages
                dependency.objectWillChange.send()
            }
        }

        await MainActor.run {
            task.completedPackages = completedTaskPackages
            task.totalPackages = totalTaskPackages
            task.currentPackage = task.dependenciesToDownload
                .flatMap { $0.packages }
                .first(where: { !$0.downloaded })
                ?? task.dependenciesToDownload.flatMap { $0.packages }.first
            task.objectWillChange.send()
        }

        await updateTaskProgressDirect(task: task)
    }

    private func cleanupCompletedPackageMetadata(task: NewDownloadTask) {
        for dependency in task.dependenciesToDownload {
            for package in dependency.packages where package.downloaded {
                let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
                AAMDFileManager(downloadFileURL: destinationURL).remove()
            }
        }
    }

    private func waitForTaskDownloadsToSettle(task: NewDownloadTask, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let hasRunningPackage = await MainActor.run {
                task.dependenciesToDownload.contains { dependency in
                    dependency.packages.contains { package in
                        package.status == .downloading
                    }
                }
            }

            if !hasRunningPackage {
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func downloadPackageWithPDM(
        package: Package,
        task: NewDownloadTask,
        product: DependenciesToDownload
    ) async -> PDMDownloadResult {
        guard !package.fullPackageName.isEmpty,
              !package.downloadURL.isEmpty,
              package.downloadSize > 0 else {
            return .completed
        }

        let cleanCdn = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
        let cleanPath = package.downloadURL.hasPrefix("/") ? package.downloadURL : "/\(package.downloadURL)"
        let downloadURL = cleanCdn + cleanPath

        guard let url = URL(string: downloadURL) else { return .completed }

        let destinationURL = packageDestinationURL(task: task, dependency: product, package: package)
        let packageId = generatePackageIdentifier(package: package, task: task, dependency: product)

        let result = await PDMDownloadEngine.shared.downloadFile(
            packageId: packageId,
            url: url,
            destinationURL: destinationURL,
            headers: NetworkConstants.downloadHeaders,
            validationURL: nil,
            progressHandler: { [weak self] downloadedBytes, totalBytes, speed in
                Task {
                    await MainActor.run {
                        let normalizedDownloadedBytes = totalBytes > 0
                            ? min(max(downloadedBytes, 0), totalBytes)
                            : max(downloadedBytes, 0)
                        package.downloadedSize = normalizedDownloadedBytes
                        package.progress = self?.normalizedProgress(
                            downloadedSize: normalizedDownloadedBytes,
                            totalSize: totalBytes
                        ) ?? 0
                        package.speed = speed
                        package.objectWillChange.send()
                    }
                    await self?.updateTaskProgressDirect(task: task)
                }
            }
        )

        return result
    }

    private func updateTaskProgressDirect(task: NewDownloadTask) async {
        let allPackages = task.dependenciesToDownload.flatMap { $0.packages }
        let totalSize = allPackages.reduce(Int64(0)) { $0 + $1.downloadSize }
        let totalDownloaded = allPackages.reduce(Int64(0)) { partialResult, package in
            partialResult + min(max(package.downloadedSize, 0), package.downloadSize)
        }
        let clampedDownloaded = totalSize > 0 ? min(max(totalDownloaded, 0), totalSize) : 0
        let totalSpeed = allPackages.reduce(0.0) { partialResult, package in
            guard package.status == .downloading else { return partialResult }
            return partialResult + package.speed
        }
        let totalProgress = normalizedProgress(downloadedSize: clampedDownloaded, totalSize: totalSize)

        await MainActor.run {
            task.totalSize = totalSize
            task.totalDownloadedSize = clampedDownloaded
            task.totalProgress = totalProgress
            task.totalSpeed = totalSpeed
            task.objectWillChange.send()
        }
    }

    private func startDownloadProcess(task: NewDownloadTask) async {
        actor DownloadProgress {
            var currentPackageIndex: Int = 0
            func increment() { currentPackageIndex += 1 }
            func get() -> Int { return currentPackageIndex }
        }

        let progress = DownloadProgress()

        await MainActor.run {
            let totalPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count }
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: task.currentPackage?.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        let driverPath = task.directory.appendingPathComponent("driver.xml")
        if !FileManager.default.fileExists(atPath: driverPath.path) {
            if let productInfo = globalCcmResult.products.first(where: { $0.id == task.productId && $0.version == task.productVersion }) {

                var selectedModules: [[String: Any]] = []
                if let mainDependency = task.dependenciesToDownload.first(where: { $0.sapCode == task.productId }) {
                    let productDir = task.directory.appendingPathComponent(mainDependency.sapCode)
                    let jsonURL = productDir.appendingPathComponent("application.json")
                    
                    if let jsonString = try? String(contentsOf: jsonURL, encoding: .utf8),
                       let jsonData = jsonString.data(using: .utf8),
                       let appInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let modules = appInfo["Modules"] as? [String: Any],
                       let moduleArray = modules["Module"] as? [[String: Any]] {
                        selectedModules = moduleArray
                    }
                }
                
                let driverXml = generateDriverXML(
                    version: task.productVersion,
                    language: task.language,
                    productInfo: productInfo,
                    dependencies: task.dependenciesToDownload,
                    targetArchitecture: task.targetArchitecture,
                    modules: selectedModules
                )
                do {
                    try driverXml.write(to: driverPath, atomically: true, encoding: String.Encoding.utf8)
                } catch {
                    print("Error generating driver.xml:", error.localizedDescription)
                    await MainActor.run {
                        task.setStatus(.failed(DownloadStatus.FailureInfo(
                            message: "生成 driver.xml 失败: \(error.localizedDescription)",
                            error: error,
                            timestamp: Date(),
                            recoverable: false
                        )))
                    }
                    return
                }
            }
        }

        for dependencyToDownload in task.dependenciesToDownload {
            let productDir = task.directory.appendingPathComponent(dependencyToDownload.sapCode)
            if !FileManager.default.fileExists(atPath: productDir.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: productDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    print("Error creating directory for \(dependencyToDownload.sapCode): \(error)")
                    continue
                }
            }
        }

        for dependencyToDownload in task.dependenciesToDownload {
            for package in dependencyToDownload.packages where !package.downloaded {
                let currentIndex = await progress.get()

                await MainActor.run {
                    task.currentPackage = package
                    task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                        fileName: package.fullPackageName,
                        currentPackageIndex: currentIndex,
                        totalPackages: task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count },
                        startTime: Date(),
                        estimatedTimeRemaining: nil
                    )))
                }
                await globalNetworkManager.saveTask(task)

                await progress.increment()

                guard !package.fullPackageName.isEmpty,
                      !package.downloadURL.isEmpty,
                      package.downloadSize > 0 else {
                    continue
                }

                let cleanCdn = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
                let cleanPath = package.downloadURL.hasPrefix("/") ? package.downloadURL : "/\(package.downloadURL)"
                let downloadURL = cleanCdn + cleanPath

                guard let url = URL(string: downloadURL) else { continue }

                do {
                    try await downloadPackage(package: package, task: task, product: dependencyToDownload, url: url)
                } catch {
                    print("Error downloading package \(package.fullPackageName): \(error.localizedDescription)")
                    await handleError(task.id, error)
                    return
                }
            }
        }

        let allPackagesDownloaded = task.dependenciesToDownload.allSatisfy { product in
            product.packages.allSatisfy { $0.downloaded }
        }

        if allPackagesDownloaded {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            }
            await globalNetworkManager.saveTask(task)
        }
    }

    func handleError(_ taskId: UUID, _ error: Error) async {
        let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId })
        guard let task = task else { return }

        let (errorMessage, isRecoverable) = classifyError(error)

        if isRecoverable && task.retryCount < NetworkConstants.maxRetryAttempts {
            task.retryCount += 1
            let nextRetryDate = Date().addingTimeInterval(TimeInterval(NetworkConstants.retryDelay / 1_000_000_000))
            task.setStatus(.retrying(DownloadStatus.RetryInfo(
                attempt: task.retryCount,
                maxAttempts: NetworkConstants.maxRetryAttempts,
                reason: errorMessage,
                nextRetryDate: nextRetryDate
            )))

            Task {
                do {
                    try await Task.sleep(nanoseconds: NetworkConstants.retryDelay)
                    if await globalCancelTracker.isCancelled(taskId) == false {
                        await resumeDownloadTask(taskId: taskId)
                    }
                } catch {
                    print("Retry cancelled for task: \(taskId)")
                }
            }
        } else {
            task.setStatus(.failed(DownloadStatus.FailureInfo(
                message: errorMessage,
                error: error,
                timestamp: Date(),
                recoverable: isRecoverable
            )))

            
            if !isRecoverable, let currentPackage = task.currentPackage {
                let destinationDir = task.directory.appendingPathComponent("\(task.productId)")
                let fileURL = destinationDir.appendingPathComponent(currentPackage.fullPackageName)
                try? FileManager.default.removeItem(at: fileURL)
            }

            await globalNetworkManager.saveTask(task)
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
                globalNetworkManager.objectWillChange.send()
            }
        }
    }

    func resumeDownloadTask(taskId: UUID) async {
        
        let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId })
        guard let task = task else {
            return 
        }

        await globalCancelTracker.resume(taskId)
        await rebuildTaskPackages(task: task, inactiveStatus: .waiting)

        let hasPendingPackages = await MainActor.run {
            task.dependenciesToDownload.flatMap { $0.packages }.contains { !$0.downloaded }
        }

        if !hasPendingPackages {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            }
            await globalNetworkManager.saveTask(task)
            cleanupCompletedPackageMetadata(task: task)
            return
        }

        await MainActor.run {
            let totalPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count }
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: task.currentPackage?.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        await globalNetworkManager.saveTask(task)
        await MainActor.run {
            globalNetworkManager.objectWillChange.send()
        }

        if task.productId == "APRO" {
            if let currentPackage = task.currentPackage,
               let product = task.dependenciesToDownload.first {
                try? await downloadPackage(
                    package: currentPackage,
                    task: task,
                    product: product,
                    url: URL(string: currentPackage.downloadURL)
                )
            }
        } else {
            await startConcurrentDownloadProcess(task: task)
        }
    }

    private func classifyError(_ error: Error) -> (message: String, recoverable: Bool) {
        switch error {
        case let networkError as NetworkError:
            switch networkError {
            case .noConnection:
                return (String(localized: "网络连接已断开"), true)
            case .timeout:
                return (String(localized: "下载超时"), true)
            case .serverUnreachable:
                return (String(localized: "服务器无法访问"), true)
            case .insufficientStorage:
                return (String(localized: "存储空间不足"), false)
            case .filePermissionDenied:
                return (String(localized: "没有写入权限"), false)
            default:
                return (networkError.localizedDescription, false)
            }
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return (String(localized: "网络连接已断开"), true)
            case .timedOut:
                return (String(localized: "连接超时"), true)
            case .cancelled:
                return (String(localized: "下载已取消"), false)
            case .cannotConnectToHost, .dnsLookupFailed:
                return (String(localized: "无法连接到服务器"), true)
            default:
                return (urlError.localizedDescription, true)
            }
        default:
            return (error.localizedDescription, false)
        }
    }


    private func downloadPackage(package: Package, task: NewDownloadTask, product: DependenciesToDownload, url: URL? = nil) async throws {
        var lastUpdateTime = Date()
        var lastBytes: Int64 = 0

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            let delegate = DownloadDelegate(
                destinationDirectory: task.directory.appendingPathComponent(product.sapCode),
                fileName: package.fullPackageName,
                completionHandler: { [weak globalNetworkManager] (localURL: URL?, response: URLResponse?, error: Error?) in
                    if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    Task { @MainActor in
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                        package.status = .completed
                        package.downloaded = true

                        var totalDownloaded: Int64 = 0
                        var totalSize: Int64 = 0

                        for prod in task.dependenciesToDownload {
                            for pkg in prod.packages {
                                totalSize += pkg.downloadSize
                                if pkg.downloaded {
                                    totalDownloaded += pkg.downloadSize
                                }
                            }
                        }

                        task.totalSize = totalSize
                        task.totalDownloadedSize = totalDownloaded
                        task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                        task.totalSpeed = 0

                        let allCompleted = task.dependenciesToDownload.allSatisfy {
                            product in product.packages.allSatisfy { $0.downloaded }
                        }

                        if allCompleted {
                            task.setStatus(.completed(DownloadStatus.CompletionInfo(
                                timestamp: Date(),
                                totalTime: Date().timeIntervalSince(task.createAt),
                                totalSize: totalSize
                            )))
                        }

                        product.updateCompletedPackages()
                        await globalNetworkManager?.saveTask(task)
                        globalNetworkManager?.objectWillChange.send()
                        continuation.resume()
                    }
                },
                progressHandler: { [weak globalNetworkManager] (bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) in
                    Task { @MainActor in
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(lastUpdateTime)

                        if timeDiff >= 1.0 {
                            let bytesDiff = totalBytesWritten - lastBytes
                            let speed = Double(bytesDiff) / timeDiff

                            package.updateProgress(
                                downloadedSize: totalBytesWritten,
                                speed: speed
                            )

                            var totalDownloaded: Int64 = 0
                            var totalSize: Int64 = 0
                            var currentSpeed: Double = 0

                            for prod in task.dependenciesToDownload {
                                for pkg in prod.packages {
                                    totalSize += pkg.downloadSize
                                    if pkg.downloaded {
                                        totalDownloaded += pkg.downloadSize
                                    } else if pkg.id == package.id {
                                        totalDownloaded += totalBytesWritten
                                        currentSpeed = speed
                                    }
                                }
                            }

                            task.totalSize = totalSize
                            task.totalDownloadedSize = totalDownloaded
                            task.totalProgress = totalSize > 0 ? Double(totalDownloaded) / Double(totalSize) : 0
                            task.totalSpeed = currentSpeed

                            lastUpdateTime = now
                            lastBytes = totalBytesWritten

                            globalNetworkManager?.objectWillChange.send()
                        }
                    }
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            Task {
                let downloadTask: URLSessionDownloadTask
                if let url = url {
                    var request = URLRequest(url: url)
                    NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                    downloadTask = session.downloadTask(with: request)
                } else {
                    continuation.resume(throwing: NetworkError.invalidData("No URL provided"))
                    return
                }

                await globalCancelTracker.registerTask(task.id, task: downloadTask, session: session)
                downloadTask.resume()
            }
        }
    }

    func generateDriverXML(version: String, language: String, productInfo: Product, dependencies: [DependenciesToDownload], targetArchitecture: String, modules: [[String: Any]] = []) -> String {
        guard let mainDependency = dependencies.first(where: { $0.sapCode == productInfo.id }) else {
            return ""
        }

        let fallbackPlatform = globalProducts
            .first(where: { $0.id == productInfo.id && $0.version == version })?
            .platforms
            .first?
            .id
            ?? "unknown"

        let platform = mainDependency.platform.isEmpty ? fallbackPlatform : mainDependency.platform
        let buildGuid = mainDependency.buildGuid
        let buildVersion = mainDependency.buildVersion.isEmpty ? version : mainDependency.buildVersion
        let baseVersion = mainDependency.baseVersion.isEmpty ? version : mainDependency.baseVersion

        let dependencyXML = dependencies
            .filter { $0.sapCode != productInfo.id }
            .map { dependency in
                let dependencyBuildVersion = dependency.buildVersion.isEmpty ? dependency.version : dependency.buildVersion
                let dependencyBaseVersion = dependency.baseVersion.isEmpty ? dependency.version : dependency.baseVersion

                return """
                <Dependency>
                    <SapCode>\(dependency.sapCode)</SapCode>
                    <CodexVersion>\(dependency.version)</CodexVersion>
                    <BaseVersion>\(dependencyBaseVersion)</BaseVersion>
                    <BuildVersion>\(dependencyBuildVersion)</BuildVersion>
                    <EsdDirectory>\(dependency.sapCode)</EsdDirectory>
                    <Platform>\(dependency.platform)</Platform>
                    <BuildGuid>\(dependency.buildGuid)</BuildGuid>
                </Dependency>
                """
            }
            .joined(separator: "\n")

        let moduleXml = modules.compactMap { module in
            if let moduleId = module["Id"] as? String {
                return """
                    <Module>
                        <Id>\(moduleId)</Id>
                        <Baseline>false</Baseline>
                    </Module>
                """
            }
            return nil
        }.joined(separator: "\n")

        return """
        <DriverInfo>
            <ProductInfo>
                <SapCode>\(productInfo.id)</SapCode>
                <CodexVersion>\(productInfo.version)</CodexVersion>
                <BaseVersion>\(baseVersion)</BaseVersion>
                <BuildVersion>\(buildVersion)</BuildVersion>
                <EsdDirectory>\(productInfo.id)</EsdDirectory>
                <Platform>\(platform)</Platform>
                <BuildGuid>\(buildGuid)</BuildGuid>
                <Dependencies>
                    \(dependencyXML)
                </Dependencies>
                <Modules>
                    \(moduleXml.isEmpty ? "" : moduleXml)
                </Modules>
            </ProductInfo>
            <RequestInfo>
                <InstallDir>/Applications</InstallDir>
                <InstallLanguage>\(language)</InstallLanguage>
                <TargetArchitecture>\(targetArchitecture)</TargetArchitecture>
            </RequestInfo>
        </DriverInfo>
        """
    }

    func downloadAPRO(task: NewDownloadTask, productInfo: Product) async throws {
        guard let selectedPlatform = HDPIMParityDecisionEngine.shared.preferredPlatform(for: productInfo),
              let selectedLanguageSet = selectedPlatform.languageSet.first else {
            throw NetworkError.unsupportedPlatform("APRO 没有可用平台")
        }
        let productManifestURL = selectedLanguageSet.manifestURL

        let manifestURL = globalCdn + productManifestURL
        print("manifestURL")
        print(manifestURL)
        guard let url = URL(string: manifestURL) else {
            throw NetworkError.invalidURL(manifestURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let headers = NetworkConstants.adobeRequestHeaders

        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (manifestData, _) = try await URLSession.shared.data(for: request)

        let manifestDoc = try XMLDocument(data: manifestData)

        guard let downloadPath = try manifestDoc.nodes(forXPath: "//asset_list/asset/asset_path").first?.stringValue,
              let assetSizeStr = try manifestDoc.nodes(forXPath: "//asset_list/asset/asset_size").first?.stringValue,
              let assetSize = Int64(assetSizeStr) else {
            throw NetworkError.invalidData("无法从manifest中获取下载信息")
        }

        guard let downloadURL = URL(string: downloadPath) else {
            throw NetworkError.invalidURL(downloadPath)
        }

        print("downloadURL \(downloadURL)")

        let aproPackage = Package(
            type: "dmg",
            fullPackageName: "Adobe Downloader \(task.productId)_\(selectedLanguageSet.productVersion.isEmpty ? task.productVersion : selectedLanguageSet.productVersion)_\(selectedPlatform.id).dmg",
            downloadSize: assetSize,
            downloadURL: downloadPath,
            packageVersion: ""
        )
        aproPackage.isSelected = true

        print(aproPackage)

        await MainActor.run {
            let product = DependenciesToDownload(
                sapCode: task.productId,
                version: selectedLanguageSet.productVersion.isEmpty ? task.productVersion : selectedLanguageSet.productVersion,
                buildGuid: "",
                platform: selectedPlatform.id
            )
            product.packages = [aproPackage]
            task.dependenciesToDownload = [product]
            task.totalSize = assetSize
            task.currentPackage = aproPackage
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: aproPackage.fullPackageName,
                currentPackageIndex: 0,
                totalPackages: 1,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
        }

        let tempDownloadDir = task.directory.deletingLastPathComponent()
        var lastUpdateTime = Date()
        var lastBytes: Int64 = 0

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
            let delegate = DownloadDelegate(
                destinationDirectory: tempDownloadDir,
                fileName: aproPackage.fullPackageName,
                completionHandler: { [weak globalNetworkManager] (localURL: URL?, response: URLResponse?, error: Error?) in
                    if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume()
                        } else {
                            print("Download error:", error)
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    Task { @MainActor in
                        aproPackage.downloadedSize = aproPackage.downloadSize
                        aproPackage.progress = 1.0
                        aproPackage.status = .completed
                        aproPackage.downloaded = true

                        var totalDownloaded: Int64 = 0
                        var totalSize: Int64 = 0

                        totalSize += aproPackage.downloadSize
                        if aproPackage.downloaded {
                            totalDownloaded += aproPackage.downloadSize
                        }

                        task.totalSize = totalSize
                        task.totalDownloadedSize = totalDownloaded
                        task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                        task.totalSpeed = 0

                        task.setStatus(.completed(DownloadStatus.CompletionInfo(
                            timestamp: Date(),
                            totalTime: Date().timeIntervalSince(task.createAt),
                            totalSize: totalSize
                        )))

                        task.objectWillChange.send()
                        await globalNetworkManager?.saveTask(task)
                        globalNetworkManager?.updateDockBadge()
                        globalNetworkManager?.objectWillChange.send()
                        continuation.resume()
                    }
                },
                progressHandler: { [weak globalNetworkManager] (bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) in
                    Task { @MainActor in
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(lastUpdateTime)

                        if timeDiff >= 1.0 {
                            let bytesDiff = totalBytesWritten - lastBytes
                            let speed = Double(bytesDiff) / timeDiff

                            aproPackage.updateProgress(
                                downloadedSize: totalBytesWritten,
                                speed: speed
                            )

                            task.totalDownloadedSize = totalBytesWritten
                            task.totalProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                            task.totalSpeed = speed

                            lastUpdateTime = now
                            lastBytes = totalBytesWritten

                            task.objectWillChange.send()
                            globalNetworkManager?.objectWillChange.send()

                            Task {
                                await globalNetworkManager?.saveTask(task)
                            }
                        }
                    }
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            var downloadRequest = URLRequest(url: downloadURL)
            NetworkConstants.downloadHeaders.forEach { downloadRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

            let downloadTask = session.downloadTask(with: downloadRequest)

            Task {
                await globalCancelTracker.registerTask(task.id, task: downloadTask, session: session)
                
                if await globalCancelTracker.isCancelled(task.id) {
                    continuation.resume(throwing: NetworkError.cancelled)
                    return
                }
                downloadTask.resume()
            }
        }
    }

    func pauseDownloadTask(taskId: UUID, reason: DownloadStatus.PauseInfo.PauseReason) async {
        await globalCancelTracker.pause(taskId)

        guard let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId }) else {
            return
        }

        for dependency in task.dependenciesToDownload {
            for package in dependency.packages where !package.downloaded {
                let packageId = generatePackageIdentifier(package: package, task: task, dependency: dependency)
                PDMDownloadEngine.shared.pause(packageId: packageId)
            }
        }

        await waitForTaskDownloadsToSettle(task: task)
        await rebuildTaskPackages(task: task, inactiveStatus: .paused)

        await MainActor.run {
            task.setStatus(.paused(DownloadStatus.PauseInfo(
                reason: reason,
                timestamp: Date(),
                resumable: true
            )))

            globalNetworkManager.objectWillChange.send()
        }
        await globalNetworkManager.saveTask(task)
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        guard let url = URL(string: NetworkConstants.applicationJsonURL) else {
            throw NetworkError.invalidURL(NetworkConstants.applicationJsonURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        var headers = NetworkConstants.adobeRequestHeaders
        headers["x-adobe-build-guid"] = buildGuid

        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData(String(localized: "无法将响应数据转换为json字符串"))
        }

        return jsonString
    }

    private func compareVersions(current: Double, required: Double, operator: String) -> Bool {
        switch `operator` {
        case ">=":
            return current >= required
        case "<=":
            return current <= required
        case ">":
            return current > required
        case "<":
            return current < required
        case "==":
            return current == required
        default:
            return false
        }
    }

    private func executePrivilegedCommand(_ command: String) async -> String {
        return await withCheckedContinuation { continuation in
            PrivilegedHelperAdapter.shared.executeCommand(command) { result in
                if result.starts(with: "Error:") {
                    print("命令执行失败: \(command)")
                    print("错误信息: \(result)")
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    func downloadX1a0HeCCPackages(
        progressHandler: @escaping (Double, String) -> Void,
        cancellationHandler: @escaping () -> Bool,
        shouldProcess: Bool = true
    ) async throws {
        let baseUrl = "https://cdn-ffc.oobesaas.adobe.com/core/v1/applications?name=CreativeCloud&platform=\(AppStatics.isAppleSilicon ? "macarm64" : "osx10")"

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = NetworkConstants.downloadHeaders
        let session = URLSession(configuration: configuration)

        do {
            var request = URLRequest(url: URL(string: baseUrl)!)
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.invalidResponse
            }

            let xmlDoc = try XMLDocument(data: data)

            let packageSets = try xmlDoc.nodes(forXPath: "//packageSet[name='ADC']")
            guard let adcPackageSet = packageSets.first else {
                throw NetworkError.invalidData("找不到ADC包集")
            }

            let targetPackages = ["HDBox", "IPCBox"]
            var packagesToDownload: [(name: String, url: URL, size: Int64)] = []

            for packageName in targetPackages {
                let packageNodes = try adcPackageSet.nodes(forXPath: ".//package[name='\(packageName)']")
                guard let package = packageNodes.first else {
                    print("未找到包: \(packageName)")
                    continue
                }

                guard let manifestUrl = try package.nodes(forXPath: ".//manifestUrl").first?.stringValue,
                      let cdnBase = try xmlDoc.nodes(forXPath: "//cdn/secure").first?.stringValue else {
                    print("无法获取manifest URL或CDN基础URL")
                    continue
                }

                let manifestFullUrl = cdnBase + manifestUrl
                print(manifestFullUrl)

                var manifestRequest = URLRequest(url: URL(string: manifestFullUrl)!)
                NetworkConstants.downloadHeaders.forEach { manifestRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (manifestData, manifestResponse) = try await session.data(for: manifestRequest)

                guard let manifestHttpResponse = manifestResponse as? HTTPURLResponse,
                      (200...299).contains(manifestHttpResponse.statusCode) else {
                    print("获取manifest失败: HTTP \(String(describing: (manifestResponse as? HTTPURLResponse)?.statusCode))")
                    continue
                }

                let manifestDoc = try XMLDocument(data: manifestData)
                let assetPathNodes = try manifestDoc.nodes(forXPath: "//asset_path")
                let sizeNodes = try manifestDoc.nodes(forXPath: "//asset_size")
                guard let assetPath = assetPathNodes.first?.stringValue,
                      let sizeStr = sizeNodes.first?.stringValue,
                      let size = Int64(sizeStr),
                      let downloadUrl = URL(string: assetPath) else {
                    continue
                }
                packagesToDownload.append((packageName, downloadUrl, size))
            }

            guard !packagesToDownload.isEmpty else {
                throw NetworkError.invalidData("没有找到可下载的包")
            }

            let totalCount = packagesToDownload.count
            for (index, package) in packagesToDownload.enumerated() {
                if cancellationHandler() {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.cancelled
                }

                await MainActor.run {
                    progressHandler(Double(index) / Double(totalCount), "正在下载 \(package.name)...")
                }

                let destinationURL = tempDirectory.appendingPathComponent("\(package.name).zip")
                var downloadRequest = URLRequest(url: package.url)
                print(downloadRequest)
                NetworkConstants.downloadHeaders.forEach { downloadRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (downloadURL, downloadResponse) = try await session.download(for: downloadRequest)

                guard let httpResponse = downloadResponse as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("下载失败: HTTP \(String(describing: (downloadResponse as? HTTPURLResponse)?.statusCode))")
                    continue
                }

                try FileManager.default.moveItem(at: downloadURL, to: destinationURL)
            }

            await MainActor.run {
                progressHandler(0.9, shouldProcess ? "正在安装组件..." : "正在完成下载...")
            }

            let targetDirectory = "/Library/Application\\ Support/Adobe/Adobe\\ Desktop\\ Common"
            let rawTargetDirectory = "/Library/Application Support/Adobe/Adobe Desktop Common"

            if !FileManager.default.fileExists(atPath: rawTargetDirectory) {
                let createDirResult = await executePrivilegedCommand("/bin/mkdir -p \(targetDirectory)")
                if createDirResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("创建目录失败: \(createDirResult)")
                }

                let chmodResult = await executePrivilegedCommand("/bin/chmod 755 \(targetDirectory)")
                if chmodResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("设置权限失败: \(chmodResult)")
                }
            }

            for package in packagesToDownload {
                let packageDir = "\(rawTargetDirectory)/\(package.name)"
                let packageExtractDir = tempDirectory.appendingPathComponent("\(package.name)-extract", isDirectory: true)

                try? FileManager.default.removeItem(at: packageExtractDir)
                try await ZIPAssetExtractor.extract(
                    zipURL: tempDirectory.appendingPathComponent("\(package.name).zip"),
                    to: packageExtractDir
                )

                let removeResult = await executePrivilegedCommand("/bin/rm -rf '\(packageDir)'")
                if removeResult.starts(with: "Error:") {
                    print("移除旧目录失败: \(removeResult)")
                }

                let mkdirResult = await executePrivilegedCommand("/bin/mkdir -p '\(packageDir)'")
                if mkdirResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("创建 \(package.name) 目录失败")
                }

                let copyResult = await executePrivilegedCommand("/usr/bin/ditto '\(packageExtractDir.path)' '\(packageDir)'")
                if copyResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("复制 \(package.name) 解压结果失败: \(copyResult)")
                }

                let chmodResult = await executePrivilegedCommand("/bin/chmod -R 755 '\(packageDir)'")
                if chmodResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("设置 \(package.name) 权限失败: \(chmodResult)")
                }

                let chownResult = await executePrivilegedCommand("/usr/sbin/chown -R root:wheel '\(packageDir)'")
                if chownResult.starts(with: "Error:") {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.installError("设置 \(package.name) 所有者失败: \(chownResult)")
                }
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)

            if shouldProcess {
                try await withCheckedThrowingContinuation { continuation in
                    ModifySetup.backupAndModifySetupFile { success, message in
                        if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: NetworkError.installError(message))
                        }
                    }
                }
                ModifySetup.clearVersionCache()
            }

            try? FileManager.default.removeItem(at: tempDirectory)

            await MainActor.run {
                progressHandler(1.0, shouldProcess ? "安装完成" : "下载完成")
            }
        } catch {
            print("发生错误: \(error.localizedDescription)")
            throw error
        }
    }

    func cancelDownloadTask(taskId: UUID, removeFiles: Bool = false) async {
        await globalCancelTracker.cancel(taskId)

        if let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId }) {
            for dependency in task.dependenciesToDownload {
                for package in dependency.packages where !package.downloaded {
                    let packageId = generatePackageIdentifier(package: package, task: task, dependency: dependency)
                    PDMDownloadEngine.shared.cancelDownload(packageId: packageId)
                }
            }

            if removeFiles {
                try? FileManager.default.removeItem(at: task.directory)
            }

            task.setStatus(.failed(DownloadStatus.FailureInfo(
                message: String(localized: "下载已取消"),
                error: NetworkError.downloadCancelled,
                timestamp: Date(),
                recoverable: false
            )))

            await globalNetworkManager.saveTask(task)
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
                globalNetworkManager.objectWillChange.send()
            }
        }
    }

}
