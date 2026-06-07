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

actor TaskProgressPublishLimiter {
    private var lastPublishTimes: [UUID: Date] = [:]

    func shouldPublish(taskId: UUID, force: Bool) -> Bool {
        let now = Date()

        if force {
            lastPublishTimes[taskId] = now
            return true
        }

        guard let lastPublishTime = lastPublishTimes[taskId] else {
            lastPublishTimes[taskId] = now
            return true
        }

        guard now.timeIntervalSince(lastPublishTime) >= NetworkConstants.progressUpdateInterval else {
            return false
        }

        lastPublishTimes[taskId] = now
        return true
    }

    func reset(taskId: UUID) {
        lastPublishTimes.removeValue(forKey: taskId)
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
    private let taskProgressPublishLimiter = TaskProgressPublishLimiter()
    private let pdmValidationServiceBaseURL = "https://cdn-ffc.oobesaas.adobe.com/core/v1/validation"

    func removableArtifacts(for task: NewDownloadTask, includeDownloadedFile: Bool) -> [URL] {
        var urls: [URL] = []

        if includeDownloadedFile {
            urls.append(task.directory)
        }

        if isManifestInstallerProduct(task.productId) {
            urls.append(aproPDMWorkingDirectory(for: task))

            if task.directory.pathExtension.lowercased() == "dmg" {
                urls.append(task.directory.deletingPathExtension().appendingPathExtension("pdm"))
            }
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func aproPDMWorkingDirectory(for task: NewDownloadTask) -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Adobe Downloader/PDM/\(task.productId)", isDirectory: true)
        let token = stableDirectoryToken([
            task.productId,
            task.productVersion,
            task.language,
            task.platform,
            task.directory.standardizedFileURL.path
        ].joined(separator: "|"))
        return supportDirectory.appendingPathComponent(token, isDirectory: true)
    }

    private func stableDirectoryToken(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

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

                try Self.copyFileContents(from: location, to: destinationURL)
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

        private static func copyFileContents(from sourceURL: URL, to destinationURL: URL) throws {
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            }

            let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            let destinationHandle = try FileHandle(forWritingTo: destinationURL)

            defer {
                try? sourceHandle.close()
                try? destinationHandle.close()
            }

            destinationHandle.truncateFile(atOffset: 0)

            while true {
                let data = sourceHandle.readData(ofLength: 1024 * 1024)
                if data.isEmpty {
                    break
                }
                destinationHandle.write(data)
            }
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

        let mergedDependencies = await makeMergedCustomDependencies(
            task: task,
            customDependencies: customDependencies
        )

        try writeApplicationJSONs(for: task, dependencies: mergedDependencies)

        let totalSize = mergedDependencies.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }

        await MainActor.run {
            task.dependenciesToDownload = mergedDependencies
            task.totalSize = totalSize
            task.totalDownloadedSize = mergedDependencies.reduce(0) { productSum, product in
                productSum + product.packages.reduce(0) { packageSum, package in
                    packageSum + (package.downloaded ? max(package.downloadSize, 0) : min(max(package.downloadedSize, 0), max(package.downloadSize, 0)))
                }
            }
            task.totalProgress = totalSize > 0 ? Double(task.totalDownloadedSize) / Double(totalSize) : 0
            task.objectWillChange.send()
        }

        await startConcurrentDownloadProcess(task: task)
    }

    private func makeMergedCustomDependencies(
        task: NewDownloadTask,
        customDependencies: [DependenciesToDownload]
    ) async -> [DependenciesToDownload] {
        let existingDependencies = task.dependenciesToDownload
        let existingDependencyByKey = dependencyLookup(existingDependencies)

        var mergedDependencies: [DependenciesToDownload] = []
        var handledKeys = Set<String>()

        for dependency in customDependencies {
            let key = dependencyIdentity(dependency)
            guard !handledKeys.contains(key) else {
                continue
            }
            handledKeys.insert(key)
            let existingDependency = existingDependencyByKey[key]
            let mergedDependency = cloneDependencyMetadata(from: dependency)
            mergedDependency.packages = await mergedPackages(
                task: task,
                dependency: dependency,
                existingDependency: existingDependency
            )

            if !mergedDependency.packages.isEmpty {
                mergedDependencies.append(mergedDependency)
            }
        }

        for existingDependency in existingDependencies where !handledKeys.contains(dependencyIdentity(existingDependency)) {
            var downloadedPackages: [Package] = []
            for package in existingDependency.packages {
                let destinationURL = packageDestinationURL(task: task, dependency: existingDependency, package: package)
                guard isPackageArchiveValidForCompletion(package: package, destinationURL: destinationURL) else {
                    continue
                }
                await MainActor.run {
                    package.isSelected = true
                    package.downloaded = true
                    package.isBaselineDownloaded = true
                    package.status = .completed
                    package.downloadedSize = package.downloadSize
                    package.progress = 1
                    package.speed = 0
                }
                downloadedPackages.append(package)
            }
            guard !downloadedPackages.isEmpty else {
                continue
            }
            let mergedDependency = cloneDependencyMetadata(from: existingDependency)
            mergedDependency.packages = downloadedPackages
            mergedDependencies.append(mergedDependency)
        }

        return mergedDependencies
    }

    private func dependencyLookup(_ dependencies: [DependenciesToDownload]) -> [String: DependenciesToDownload] {
        var lookup: [String: DependenciesToDownload] = [:]
        for dependency in dependencies {
            lookup[dependencyIdentity(dependency)] = dependency
        }
        return lookup
    }

    private func packageLookup(_ packages: [Package]) -> [String: Package] {
        var lookup: [String: Package] = [:]
        for package in packages {
            lookup[packageIdentity(package)] = package
        }
        return lookup
    }

    private func dependencyIdentity(_ dependency: DependenciesToDownload) -> String {
        [
            dependency.sapCode,
            dependency.version,
            dependency.platform,
            dependency.buildGuid
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "|")
    }

    private func packageIdentity(_ package: Package) -> String {
        let rawName = package.fullPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = rawName.hasSuffix(".zip") ? rawName : "\(rawName).zip"
        let packageVersion = package.packageVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashKey = package.packageHashKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if !packageVersion.isEmpty {
            return "\(normalizedName)|\(packageVersion)"
        }
        if !hashKey.isEmpty {
            return "\(normalizedName)|\(hashKey)"
        }
        return normalizedName
    }

    private func cloneDependencyMetadata(from dependency: DependenciesToDownload) -> DependenciesToDownload {
        DependenciesToDownload(
            sapCode: dependency.sapCode,
            version: dependency.version,
            buildGuid: dependency.buildGuid,
            applicationJson: dependency.applicationJson ?? "",
            isSoftDependency: dependency.isSoftDependency,
            platform: dependency.platform,
            baseVersion: dependency.baseVersion,
            buildVersion: dependency.buildVersion,
            selectedReason: dependency.selectedReason,
            hostValidation: dependency.hostValidation
        )
    }

    private func mergedPackages(
        task: NewDownloadTask,
        dependency: DependenciesToDownload,
        existingDependency: DependenciesToDownload?
    ) async -> [Package] {
        let existingPackagesByName = packageLookup(existingDependency?.packages ?? [])

        var packages: [Package] = []
        for package in dependency.packages {
            let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
            let localArchiveIsValid = isPackageArchiveValidForCompletion(package: package, destinationURL: destinationURL)
            let existingPackage = existingPackagesByName[packageIdentity(package)]
            let shouldKeep = package.isSelected
                || localArchiveIsValid
                || existingPackage?.isSelected == true
                || existingPackage?.downloaded == true

            guard shouldKeep else {
                continue
            }

            await MainActor.run {
                package.isSelected = true
                if localArchiveIsValid {
                    package.downloaded = true
                    package.isBaselineDownloaded = true
                    package.status = .completed
                    package.downloadedSize = package.downloadSize
                    package.progress = 1
                    package.speed = 0
                } else if let existingPackage {
                    package.downloaded = false
                    package.status = existingPackage.status == .completed ? .waiting : existingPackage.status
                    package.downloadedSize = existingPackage.status == .completed ? 0 : existingPackage.downloadedSize
                    package.progress = existingPackage.status == .completed ? 0 : existingPackage.progress
                    package.speed = 0
                }
            }

            packages.append(package)
        }

        return packages
    }

    private func writeApplicationJSONs(
        for task: NewDownloadTask,
        dependencies: [DependenciesToDownload]
    ) throws {
        for dependencyToDownload in dependencies {
            let productDir = task.directory.appendingPathComponent("\(dependencyToDownload.sapCode)")
            if !FileManager.default.fileExists(atPath: productDir.path) {
                try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
            }

            if let applicationJson = dependencyToDownload.applicationJson {
                var processedJsonString = applicationJson
                
                if let jsonData = applicationJson.data(using: .utf8),
                   var appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                    let selectedPackageNames = Set(dependencyToDownload.packages.flatMap { packageReferenceNames($0.fullPackageName) })
                    
                    if var packages = appInfo["Packages"] as? [String: Any],
                       let packageArray = packages["Package"] as? [[String: Any]] {

                        let filteredPackages = packageArray.filter { package in
                            if let packageName = package["PackageName"] as? String {
                                let fullPackageName = packageName.hasSuffix(".zip") ? packageName : "\(packageName).zip"
                                return selectedPackageNames.contains(fullPackageName) || selectedPackageNames.contains(packageName)
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

                        let filteredModules = moduleArray.filter { module in
                            if let referencePackages = module["ReferencePackages"] as? [String: Any],
                               let referencePackageArray = referencePackageValues(referencePackages["ReferencePackage"]) {
                                return referencePackageArray.contains { packageName in
                                    selectedPackageNames.contains(packageName)
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
    }

    private func startConcurrentDownloadProcess(task: NewDownloadTask) async {
        let maxConcurrency = StorageData.shared.maxConcurrentDownloads

        let isCancelled = await globalCancelTracker.isCancelled(task.id)
        let isPaused = await globalCancelTracker.isPaused(task.id)

        if isCancelled || isPaused {
            return
        }

        await rebuildTaskPackages(task: task, inactiveStatus: .waiting)
        await prepareDownloadEnvironment(task: task)

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
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
            cleanupCompletedPackageMetadata(task: task)
            return
        }

        let packagesSnapshot = allPackages
        await MainActor.run {
            let totalPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count }
            let firstPackage = packagesSnapshot.first?.package
            task.totalPackages = totalPackages
            task.currentPackage = firstPackage
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: firstPackage?.fullPackageName ?? "",
                currentPackageIndex: firstPackage.map { packageIndexInTask(task: task, package: $0) } ?? 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        await withTaskGroup(of: Void.self) { group in
            let semaphore = AsyncSemaphore(value: maxConcurrency)

            for (_, (package, dependency, _)) in allPackages.enumerated() {
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
                        let currentPackageIndex = self.packageIndexInTask(task: task, package: package)
                        let totalPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count }
                        task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                            fileName: package.fullPackageName,
                            currentPackageIndex: currentPackageIndex,
                            totalPackages: totalPackages,
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
                        await self.updateTaskProgressDirect(task: task, force: true)
                        await globalNetworkManager.saveTask(task)
                        self.cleanupCompletedPackageMetadata(task: task)

                    case .paused:
                        await MainActor.run {
                            package.speed = 0
                            package.status = .paused
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)

                    case .cancelled:
                        await MainActor.run {
                            package.speed = 0
                            package.status = .waiting
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)

                    case .error(let err):
                        await MainActor.run {
                            package.speed = 0
                            package.status = .failed(err.localizedDescription ?? "Download error")
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)
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
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
            cleanupCompletedPackageMetadata(task: task)
        } else {
            let failedPackages = task.dependenciesToDownload.flatMap { $0.packages }.filter {
                if case .failed = $0.status { return true }
                return false
            }
            if !failedPackages.isEmpty {
                let failureMessages = failedPackages.compactMap { pkg -> String? in
                    if case .failed(let msg) = pkg.status {
                        return msg
                    }
                    return nil
                }
                let message = failureMessages.first ?? "Download failed"
                await MainActor.run {
                    task.setStatus(.failed(DownloadStatus.FailureInfo(
                        message: message,
                        error: nil,
                        timestamp: Date(),
                        recoverable: true
                    )))
                }
                await globalNetworkManager.saveTask(task)
            }
        }
    }

    private func prepareDownloadEnvironment(task: NewDownloadTask) async {
        let driverPath = task.directory.appendingPathComponent("driver.xml")
        if let productInfo = globalCcmResult.products.first(where: { $0.id == task.productId && $0.version == task.productVersion }) {
            let selectedModules = selectedDriverModules(for: task)

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
        if isManifestInstallerProduct(task.productId) {
            return "AdobeDownloader|\(task.productId)|\(task.productVersion)|\(task.language)|\(task.platform)|\(task.directory.standardizedFileURL.path)"
        }
        return "AdobeDownloader|\(task.productId)|\(task.productVersion)|\(task.language)|\(task.platform)|\(dependency.sapCode)|\(package.id.uuidString)"
    }

    private func normalizedProgress(downloadedSize: Int64, totalSize: Int64) -> Double {
        guard totalSize > 0 else { return 0 }
        return min(max(Double(downloadedSize) / Double(totalSize), 0), 1)
    }

    private func packageDestinationURL(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package) -> URL {
        if isManifestInstallerProduct(task.productId) {
            return task.directory
        }
        return task.directory
            .appendingPathComponent(dependency.sapCode)
            .appendingPathComponent(package.fullPackageName)
    }

    private func packageIndexInTask(task: NewDownloadTask, package: Package) -> Int {
        let packages = task.dependenciesToDownload.flatMap { $0.packages }
        return packages.firstIndex { $0.id == package.id } ?? 0
    }

    private func recalculatePackageCounts(task: NewDownloadTask) {
        var completedTaskPackages = 0
        var totalTaskPackages = 0

        for dependency in task.dependenciesToDownload {
            let completedDependencyPackages = dependency.packages.filter { $0.downloaded }.count
            dependency.completedPackages = completedDependencyPackages
            totalTaskPackages += dependency.packages.count
            completedTaskPackages += completedDependencyPackages
            dependency.objectWillChange.send()
        }

        task.completedPackages = completedTaskPackages
        task.totalPackages = totalTaskPackages
    }

    private func nextPendingPackage(task: NewDownloadTask) -> Package? {
        task.dependenciesToDownload
            .flatMap { $0.packages }
            .first { !$0.downloaded }
    }

    private func removeEmptyDependencies(task: NewDownloadTask) {
        task.dependenciesToDownload.removeAll { $0.packages.isEmpty }
    }

    private func resetTaskAfterPackageRemoval(task: NewDownloadTask) async {
        await MainActor.run {
            removeEmptyDependencies(task: task)
            recalculatePackageCounts(task: task)
            task.currentPackage = nextPendingPackage(task: task) ?? task.dependenciesToDownload.flatMap { $0.packages }.first
            task.objectWillChange.send()
        }

        await updateTaskProgressDirect(task: task, force: true)

        await MainActor.run {
            let pendingPackage = nextPendingPackage(task: task)
            task.currentPackage = pendingPackage ?? task.dependenciesToDownload.flatMap { $0.packages }.first

            if pendingPackage == nil {
                task.totalSpeed = 0
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            } else if task.status.isActive, let pendingPackage {
                let totalPackages = task.dependenciesToDownload.reduce(0) { $0 + $1.packages.count }
                task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                    fileName: pendingPackage.fullPackageName,
                    currentPackageIndex: packageIndexInTask(task: task, package: pendingPackage),
                    totalPackages: totalPackages,
                    startTime: Date(),
                    estimatedTimeRemaining: nil
                )))
            } else {
                task.setStatus(.paused(DownloadStatus.PauseInfo(
                    reason: .userRequested,
                    timestamp: Date(),
                    resumable: true
                )))
            }

            task.objectWillChange.send()
        }
    }

    private func metadataDirectory(for task: NewDownloadTask, dependency: DependenciesToDownload, package: Package) -> URL? {
        isManifestInstallerProduct(task.productId) ? aproPDMWorkingDirectory(for: task).appendingPathComponent("Metadata", isDirectory: true) : nil
    }

    private func aamdFileManager(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package, destinationURL: URL) -> AAMDFileManager {
        AAMDFileManager(downloadFileURL: destinationURL, metadataDirectory: metadataDirectory(for: task, dependency: dependency, package: package))
    }

    private func restoredDownloadedSize(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package, destinationURL: URL) -> Int64? {
        let aamd = aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL)
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

    private func packageArchiveValidationError(package: Package, destinationURL: URL) -> PDMDownloadError? {
        if !package.manifestURL.isEmpty {
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            if package.downloadSize > 0, actualSize != package.downloadSize {
                return PDMDownloadError(
                    code: .signatureValidationFailed,
                    message: "\(package.fullPackageName) 大小不一致，期望 \(package.downloadSize)，实际 \(actualSize)"
                )
            }

            return nil
        } catch {
            return PDMDownloadError(
                code: .signatureValidationFailed,
                message: "\(package.fullPackageName) 完整性校验失败: \(error.localizedDescription)",
                underlying: error
            )
        }
    }

    private func isPackageArchiveValidForCompletion(package: Package, destinationURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        return packageArchiveValidationError(package: package, destinationURL: destinationURL) == nil
    }

    private func shouldTreatPackageAsCompleted(package: Package, destinationURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        let hasCompletedState = package.downloaded
            || package.status == .completed
            || (package.downloadSize > 0 && package.downloadedSize >= package.downloadSize)
            || package.progress >= 1.0

        return hasCompletedState && isPackageArchiveValidForCompletion(package: package, destinationURL: destinationURL)
    }

    private func resetPackageArchiveResumeState(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package, destinationURL: URL) {
        let aamd = aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL)
        if aamd.exists(), let headers = aamd.readHeaders() {
            let segmentSize = Int64(headers["SEGMENT_SIZE"] ?? "") ?? (2 * 1024 * 1024)
            let fileSize = Int64(headers["FILE_SIZE"] ?? "") ?? package.downloadSize
            let expectedSize = max(fileSize, package.downloadSize)
            let segmentCount = max(1, Int((expectedSize + segmentSize - 1) / segmentSize))

            for segment in 0..<segmentCount {
                aamd.updateSegmentData(segment: segment, bytesDownloaded: 0)
            }
        }

        if FileManager.default.fileExists(atPath: destinationURL.path),
           let fileHandle = try? FileHandle(forWritingTo: destinationURL) {
            fileHandle.truncateFile(atOffset: UInt64(max(package.downloadSize, 0)))
            try? fileHandle.close()
        }
    }

    private func resetFailedPackageArchive(task: NewDownloadTask, package: Package) {
        var destinationURL: URL?

        for dependency in task.dependenciesToDownload {
            if let candidate = dependency.packages.first(where: {
                $0.id == package.id || $0.fullPackageName == package.fullPackageName
            }) {
                destinationURL = packageDestinationURL(task: task, dependency: dependency, package: candidate)
                break
            }
        }

        let resolvedURL = destinationURL
            ?? task.directory
                .appendingPathComponent(task.productId)
                .appendingPathComponent(package.fullPackageName)

        AAMDFileManager(downloadFileURL: resolvedURL).remove()

        if FileManager.default.fileExists(atPath: resolvedURL.path),
           let fileHandle = try? FileHandle(forWritingTo: resolvedURL) {
            fileHandle.truncateFile(atOffset: 0)
            try? fileHandle.close()
        }
    }

    private func rebuildTaskPackages(task: NewDownloadTask, inactiveStatus: PackageStatus) async {
        var completedTaskPackages = 0
        var totalTaskPackages = 0

        for dependency in task.dependenciesToDownload {
            var completedDependencyPackages = 0

            for package in dependency.packages {
                totalTaskPackages += 1

                let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
                let restoredBytes = restoredDownloadedSize(task: task, dependency: dependency, package: package, destinationURL: destinationURL)
                let restoredIsCompleted = (restoredBytes ?? 0) >= package.downloadSize
                    && package.downloadSize > 0
                    && isPackageArchiveValidForCompletion(package: package, destinationURL: destinationURL)
                let savedIsCompleted = restoredBytes == nil && shouldTreatPackageAsCompleted(package: package, destinationURL: destinationURL)

                await MainActor.run {
                    if restoredIsCompleted || savedIsCompleted {
                        package.downloaded = true
                        package.status = .completed
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                        package.speed = 0
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
                        package.speed = 0
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

        await updateTaskProgressDirect(task: task, force: true)
    }

    private func cleanupCompletedPackageMetadata(task: NewDownloadTask) {
        for dependency in task.dependenciesToDownload {
            for package in dependency.packages where package.downloaded {
                let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
                aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL).remove()
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
              (!package.downloadURL.isEmpty || !package.manifestURL.isEmpty) else {
            return .completed
        }

        let cleanCdn = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
        let destinationURL = packageDestinationURL(task: task, dependency: product, package: package)
        let packageId = generatePackageIdentifier(package: package, task: task, dependency: product)
        let validationServiceBaseURL = pdmValidationServiceBaseURL(for: product)
        let validationURLs = normalizedValidationURLs(
            [package.validationURL, package.validationURLType1],
            cdn: cleanCdn,
            validationServiceBaseURL: validationServiceBaseURL
        )

        let startWorkflowDownload: () async -> PDMDownloadResult = { [weak self] in
            guard let self else {
                return .error(PDMDownloadError(code: .criticalError, message: "Download manager released"))
            }

            do {
                let workflow = PDMWorkflowManager(
                    tempDirectory: task.directory.appendingPathComponent(product.sapCode),
                    validationServiceBaseURL: validationServiceBaseURL ?? pdmValidationServiceBaseURL
                )
                let manifestURL = self.normalizedPackageURL(package.manifestURL, cdn: cleanCdn)
                let downloadedURL = try await workflow.execute(
                    manifestURL: manifestURL,
                    cdnBaseURL: cleanCdn,
                    headers: NetworkConstants.downloadHeaders,
                    destinationDirectory: task.directory.appendingPathComponent(product.sapCode),
                    packageIdentifier: packageId,
                    progressHandler: { state, progress in
                        Task {
                            await MainActor.run {
                                if state == .downloadAssetBits {
                                    let normalizedProgress = min(max(progress, 0), 1)
                                    package.progress = normalizedProgress
                                    package.downloadedSize = Int64(Double(max(package.downloadSize, 0)) * normalizedProgress)
                                }
                                package.objectWillChange.send()
                            }
                            await self.updateTaskProgressDirect(task: task)
                        }
                    },
                    assetInfoHandler: { _, assetSize in
                        guard assetSize > 0 else { return }
                        Task { [weak self] in
                            await MainActor.run {
                                package.downloadSize = assetSize
                                package.downloadedSize = min(max(package.downloadedSize, 0), assetSize)
                                package.objectWillChange.send()
                            }
                            await self?.updateTaskProgressDirect(task: task, force: true)
                        }
                    },
                    downloadProgressHandler: { downloadedBytes, totalBytes, speed in
                        Task { [weak self] in
                            await MainActor.run {
                                let normalizedTotalBytes = totalBytes > 0 ? totalBytes : package.downloadSize
                                if normalizedTotalBytes > 0 {
                                    package.downloadSize = normalizedTotalBytes
                                }
                                package.downloadedSize = min(max(downloadedBytes, 0), max(package.downloadSize, 0))
                                package.progress = self?.normalizedProgress(
                                    downloadedSize: package.downloadedSize,
                                    totalSize: package.downloadSize
                                ) ?? 0
                                package.speed = speed
                                package.status = .downloading
                                package.objectWillChange.send()
                            }
                            await self?.updateTaskProgressDirect(task: task, force: true)
                        }
                    },
                    cancellationCheck: {
                        let isCancelled = await globalCancelTracker.isCancelled(task.id)
                        if isCancelled {
                            return true
                        }
                        return await globalCancelTracker.isPaused(task.id)
                    }
                )

                let finalURL = destinationURL
                if downloadedURL.path != finalURL.path {
                    try self.prepareCompletedWorkflowDownload(from: downloadedURL, to: finalURL)
                }
                if let completedSize = self.fileSizeIfExists(finalURL), completedSize > 0 {
                    await MainActor.run {
                        package.downloadSize = completedSize
                        package.downloadedSize = completedSize
                        package.progress = 1.0
                    }
                    await self.updateTaskProgressDirect(task: task, force: true)
                }
                return .completed
            } catch let error as PDMDownloadError {
                return .error(error)
            } catch NetworkError.cancelled {
                return .cancelled
            } catch {
                return .error(PDMDownloadError(code: .downloadFailed, message: error.localizedDescription, underlying: error))
            }
        }

        let startDirectDownload: () async -> PDMDownloadResult = {
            let downloadURL = self.normalizedPackageURL(package.downloadURL, cdn: cleanCdn)
            guard let url = URL(string: downloadURL) else {
                return .error(PDMDownloadError(code: .downloadFailed, message: "Invalid package download URL"))
            }

            return await PDMDownloadEngine.shared.downloadFile(
                packageId: packageId,
                url: url,
                destinationURL: destinationURL,
                headers: NetworkConstants.downloadHeaders,
                expectedTotalSize: package.downloadSize,
                validationURL: validationURLs.first,
                validationURLs: validationURLs,
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
        }

        let result = package.manifestURL.isEmpty ? await startDirectDownload() : await startWorkflowDownload()
        if package.manifestURL.isEmpty,
           case .completed = result,
           packageArchiveValidationError(package: package, destinationURL: destinationURL) != nil {
            resetPackageArchiveResumeState(task: task, dependency: product, package: package, destinationURL: destinationURL)

            await MainActor.run {
                package.downloadedSize = 0
                package.progress = 0
                package.speed = 0
                package.status = .downloading
            }

            let retryResult = package.manifestURL.isEmpty ? await startDirectDownload() : await startWorkflowDownload()
            if case .completed = retryResult,
               let retryValidationError = packageArchiveValidationError(package: package, destinationURL: destinationURL) {
                return .error(retryValidationError)
            }

            return retryResult
        }

        return result
    }

    private func fileSizeIfExists(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func normalizedPackageURL(_ value: String, cdn: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed)?.scheme == nil else {
            return trimmed
        }

        let cleanPath = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return cdn + cleanPath
    }

    private func prepareCompletedWorkflowDownload(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)

        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        destinationHandle.truncateFile(atOffset: 0)

        while true {
            let data = sourceHandle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            destinationHandle.write(data)
        }
    }

    private func normalizedValidationURLs(
        _ validationURLs: [String?],
        cdn: String,
        validationServiceBaseURL: String? = nil
    ) -> [String] {
        var result: [String] = []
        for rawURL in validationURLs {
            guard let validationURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !validationURL.isEmpty else {
                continue
            }

            let normalized: String
            if URL(string: validationURL)?.scheme != nil {
                normalized = validationURL
            } else {
                let cleanPath = validationURL.hasPrefix("/") ? validationURL : "/\(validationURL)"
                normalized = cdn + cleanPath
            }

            if let validationServiceBaseURL {
                for serviceCandidate in validationServiceFallbackURLs(for: normalized, baseURL: validationServiceBaseURL)
                    + validationServiceFallbackURLs(for: validationURL, baseURL: validationServiceBaseURL) {
                    appendValidationCandidate(serviceCandidate, to: &result)
                }
            }

            appendValidationCandidate(normalized, to: &result)

            if validationServiceBaseURL == nil {
                let fallbackCandidates = validationServiceFallbackURLs(for: normalized, baseURL: pdmValidationServiceBaseURL)
                    + validationServiceFallbackURLs(for: validationURL, baseURL: pdmValidationServiceBaseURL)
                for fallbackCandidate in fallbackCandidates {
                    appendValidationCandidate(fallbackCandidate, to: &result)
                }
            }
        }
        return result
    }

    private func appendValidationCandidate(_ candidate: String, to result: inout [String]) {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !result.contains(normalized) else {
            return
        }
        result.append(normalized)
    }

    private func validationServiceFallbackURLs(for value: String, baseURL: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let fileName: String
        if let url = URL(string: trimmed), !url.lastPathComponent.isEmpty {
            fileName = url.lastPathComponent
        } else {
            fileName = URL(fileURLWithPath: trimmed).lastPathComponent
        }

        guard !fileName.isEmpty else {
            return []
        }

        let cleanBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return ["\(cleanBaseURL)/\(fileName)"]
    }

    private func pdmValidationServiceBaseURL(for product: DependenciesToDownload) -> String? {
        guard let applicationJson = product.applicationJson,
              let appInfo = try? ApplicationJSONParser.parse(jsonString: applicationJson) else {
            return nil
        }

        let keys = ["AusstValidationURL", "PackageServiceValidationURL"]
        for key in keys {
            if let value = appInfo.properties[key] {
                let value = "\(value)"
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        for (key, value) in appInfo.properties {
            guard keys.contains(where: { key.split(separator: ".").last?.caseInsensitiveCompare($0) == .orderedSame }) else {
                continue
            }
            let value = "\(value)"
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func updateTaskProgressDirect(task: NewDownloadTask, force: Bool = false) async {
        let shouldPublish = await taskProgressPublishLimiter.shouldPublish(taskId: task.id, force: force)
        guard shouldPublish else { return }

        let isActive = await MainActor.run { task.status.isActive }
        guard isActive else { return }

        let allPackages = task.dependenciesToDownload.flatMap { $0.packages }
        let totalSize = allPackages.reduce(Int64(0)) { $0 + $1.downloadSize }
        let totalDownloaded = allPackages.reduce(Int64(0)) { partialResult, package in
            partialResult + min(max(package.downloadedSize, 0), package.downloadSize)
        }
        let clampedDownloaded = totalSize > 0 ? min(max(totalDownloaded, 0), totalSize) : 0
        let totalSpeed = allPackages.reduce(0.0) { partialResult, package in
            guard package.status == .downloading || package.status == .paused else { return partialResult }
            return partialResult + package.speed
        }
        let totalProgress = normalizedProgress(downloadedSize: clampedDownloaded, totalSize: totalSize)

        await MainActor.run {
            task.totalSize = totalSize
            task.totalDownloadedSize = clampedDownloaded
            task.totalProgress = totalProgress
            task.totalSpeed = totalSpeed
            task.objectWillChange.send()
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }
    }

    private func hasBaselinePackages(task: NewDownloadTask) -> Bool {
        task.dependenciesToDownload.flatMap { $0.packages }.contains { $0.isBaselineDownloaded }
    }

    func canRemoveIncrementalPackage(task: NewDownloadTask, package: Package) -> Bool {
        hasBaselinePackages(task: task) && !package.isBaselineDownloaded
    }

    func canRemoveIncrementalDependency(task: NewDownloadTask, dependency: DependenciesToDownload) -> Bool {
        hasBaselinePackages(task: task) && dependency.packages.contains { canRemoveIncrementalPackage(task: task, package: $0) }
    }

    func removeIncrementalPackage(taskId: UUID, dependencySapCode: String, packageId: UUID) async {
        guard let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId }) else {
            return
        }

        guard let dependency = task.dependenciesToDownload.first(where: { $0.sapCode == dependencySapCode }),
              let package = dependency.packages.first(where: { $0.id == packageId && canRemoveIncrementalPackage(task: task, package: $0) }) else {
            return
        }

        let packageIdentifier = generatePackageIdentifier(package: package, task: task, dependency: dependency)
        PDMDownloadEngine.shared.cancelDownload(packageId: packageIdentifier)
        let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)

        await MainActor.run {
            if package.downloaded || package.downloadedSize > 0 || package.status == .downloading || package.status == .paused {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL).remove()
            dependency.packages.removeAll { $0.id == packageId }
        }

        await resetTaskAfterPackageRemoval(task: task)
        await globalNetworkManager.saveTask(task)
        await MainActor.run {
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }
    }

    func removeIncrementalDependency(taskId: UUID, dependencySapCode: String) async {
        guard let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId }) else {
            return
        }

        guard let dependency = task.dependenciesToDownload.first(where: { $0.sapCode == dependencySapCode }) else {
            return
        }

        let removablePackages = dependency.packages.filter { canRemoveIncrementalPackage(task: task, package: $0) }
        guard !removablePackages.isEmpty else {
            return
        }

        for package in removablePackages {
            let packageIdentifier = generatePackageIdentifier(package: package, task: task, dependency: dependency)
            PDMDownloadEngine.shared.cancelDownload(packageId: packageIdentifier)
            let destinationURL = packageDestinationURL(task: task, dependency: dependency, package: package)
            await MainActor.run {
                if package.downloaded || package.downloadedSize > 0 || package.status == .downloading || package.status == .paused {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL).remove()
            }
        }

        await MainActor.run {
            let removableIds = Set(removablePackages.map(\.id))
            dependency.packages.removeAll { removableIds.contains($0.id) }
        }

        await resetTaskAfterPackageRemoval(task: task)
        await globalNetworkManager.saveTask(task)
        await MainActor.run {
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
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
                let selectedModules = selectedDriverModules(for: task)
                
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
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
        }
    }

    func handleError(_ taskId: UUID, _ error: Error) async {
        let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId })
        guard let task = task else { return }

        if case NetworkError.cancelled = error,
           await globalCancelTracker.isPaused(taskId) {
            await rebuildTaskPackages(task: task, inactiveStatus: .paused)
            await MainActor.run {
                task.setStatus(.paused(DownloadStatus.PauseInfo(
                    reason: .userRequested,
                    timestamp: Date(),
                    resumable: true
                )))
                globalNetworkManager.updateDockBadge()
                globalNetworkManager.objectWillChange.send()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
            await globalNetworkManager.saveTask(task)
            return
        }

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
                resetFailedPackageArchive(task: task, package: currentPackage)
            }

            await globalNetworkManager.saveTask(task)
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
                globalNetworkManager.objectWillChange.send()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
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
            await MainActor.run {
                globalNetworkManager.updateDockBadge()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
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

        if isManifestInstallerProduct(task.productId) {
            do {
                guard let productInfo = findProduct(id: task.productId, version: task.productVersion) ?? findProduct(id: task.productId) else {
                    throw NetworkError.invalidData("找不到 \(task.productId) 产品信息")
                }
                try await downloadAPRO(task: task, productInfo: productInfo)
            } catch NetworkError.cancelled {
                if await globalCancelTracker.isPaused(task.id) {
                    await rebuildTaskPackages(task: task, inactiveStatus: .paused)
                    await MainActor.run {
                        task.setStatus(.paused(DownloadStatus.PauseInfo(
                            reason: .userRequested,
                            timestamp: Date(),
                            resumable: true
                        )))
                        globalNetworkManager.updateDockBadge()
                        globalNetworkManager.objectWillChange.send()
                    }
                    await taskProgressPublishLimiter.reset(taskId: task.id)
                    await globalNetworkManager.saveTask(task)
                }
            } catch {
                await handleError(task.id, error)
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

                            globalNetworkManager?.updateDockBadge()
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

    private func selectedDriverModules(for task: NewDownloadTask) -> [[String: Any]] {
        guard let mainDependency = task.dependenciesToDownload.first(where: { $0.sapCode == task.productId }) else {
            return []
        }

        let productDir = task.directory.appendingPathComponent(mainDependency.sapCode)
        let jsonURL = productDir.appendingPathComponent("application.json")
        let jsonString = (try? String(contentsOf: jsonURL, encoding: .utf8)) ?? mainDependency.applicationJson ?? ""
        guard let jsonData = jsonString.data(using: .utf8),
              let appInfo = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let modules = appInfo["Modules"] as? [String: Any],
              let moduleArray = modules["Module"] as? [[String: Any]] else {
            return []
        }

        let selectedPackageNames = Set(mainDependency.packages.filter { $0.isSelected || $0.downloaded }.flatMap { package in
            packageReferenceNames(package.fullPackageName)
        })

        guard !selectedPackageNames.isEmpty else {
            return []
        }

        return moduleArray.filter { module in
            guard let referencePackages = module["ReferencePackages"] as? [String: Any],
                  let referencePackageArray = referencePackageValues(referencePackages["ReferencePackage"]) else {
                return false
            }
            return referencePackageArray.contains { selectedPackageNames.contains($0) }
        }
    }

    private func packageReferenceNames(_ fullPackageName: String) -> [String] {
        let trimmed = fullPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var names = [trimmed]
        if trimmed.hasSuffix(".zip") {
            names.append(String(trimmed.dropLast(4)))
        } else {
            names.append("\(trimmed).zip")
        }
        return Array(Set(names))
    }

    private func referencePackageValues(_ value: Any?) -> [String]? {
        if let array = value as? [String] {
            return array
        }
        if let single = value as? String {
            return [single]
        }
        return nil
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
        guard let match = installerPlatformMatch(product: productInfo, selectedVersion: task.productVersion) else {
            throw NetworkError.unsupportedPlatform("\(task.productId) 没有可用平台")
        }

        let selectedPlatform = match.platform
        let selectedLanguageSet = match.languageSet
        let productManifestURL = selectedLanguageSet.manifestURL
        let productDownloadURL = selectedLanguageSet.lbsURL
        guard !productManifestURL.isEmpty || !productDownloadURL.isEmpty else {
            throw NetworkError.invalidData("\(task.productId) 下载地址为空")
        }

        let cleanCdn = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
        let manifestURL = normalizedPackageURL(productManifestURL, cdn: cleanCdn)
        let productVersion = installerProductVersion(
            product: productInfo,
            languageSet: selectedLanguageSet,
            selectedVersion: task.productVersion
        )
        let outputURL = task.directory
        let workingDirectory = aproPDMWorkingDirectory(for: task)
        let metadataDirectory = workingDirectory.appendingPathComponent("Metadata", isDirectory: true)
        let existingPackage = await MainActor.run {
            task.currentPackage ?? task.dependenciesToDownload.flatMap { $0.packages }.first
        }

        let aproPackage = Package(
            type: "dmg",
            fullPackageName: installerOutputName(
                productId: task.productId,
                version: task.productVersion,
                language: task.language,
                platform: selectedPlatform.id
            ),
            downloadSize: max(existingPackage?.downloadSize ?? 0, Int64(max(selectedLanguageSet.installSize, 0))),
            downloadURL: productDownloadURL,
            manifestURL: productManifestURL,
            packageVersion: productVersion
        )
        aproPackage.isSelected = true
        aproPackage.downloadedSize = min(max(existingPackage?.downloadedSize ?? 0, 0), max(aproPackage.downloadSize, 0))
        aproPackage.progress = normalizedProgress(downloadedSize: aproPackage.downloadedSize, totalSize: aproPackage.downloadSize)
        aproPackage.speed = existingPackage?.speed ?? task.totalSpeed
        aproPackage.status = .downloading

        let product = DependenciesToDownload(
            sapCode: task.productId,
            version: task.productVersion,
            buildGuid: selectedLanguageSet.buildGuid,
            platform: selectedPlatform.id
        )
        product.packages = [aproPackage]
        if let restoredBytes = restoredDownloadedSize(task: task, dependency: product, package: aproPackage, destinationURL: outputURL) {
            aproPackage.downloadedSize = min(max(restoredBytes, 0), max(aproPackage.downloadSize, 0))
            aproPackage.progress = normalizedProgress(downloadedSize: aproPackage.downloadedSize, totalSize: aproPackage.downloadSize)
        } else if let existingSize = fileSizeIfExists(outputURL), existingSize > 0, aproPackage.downloadSize > 0 {
            aproPackage.downloadedSize = min(existingSize, aproPackage.downloadSize)
            aproPackage.progress = normalizedProgress(downloadedSize: aproPackage.downloadedSize, totalSize: aproPackage.downloadSize)
        }

        await MainActor.run {
            task.dependenciesToDownload = [product]
            task.totalSize = aproPackage.downloadSize
            task.totalDownloadedSize = aproPackage.downloadedSize
            task.totalProgress = aproPackage.progress
            task.totalSpeed = aproPackage.speed
            task.currentPackage = aproPackage
            task.totalPackages = 1
            task.completedPackages = 0
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: aproPackage.fullPackageName,
                currentPackageIndex: 0,
                totalPackages: 1,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        let packageId = generatePackageIdentifier(
            package: aproPackage,
            task: task,
            dependency: task.dependenciesToDownload[0]
        )

        let completedURL: URL
        if productManifestURL.isEmpty {
            let downloadURL = normalizedPackageURL(productDownloadURL, cdn: cleanCdn)
            guard let url = URL(string: downloadURL) else {
                throw NetworkError.invalidURL(downloadURL)
            }

            let result = await PDMDownloadEngine.shared.downloadFile(
                packageId: packageId,
                url: url,
                destinationURL: outputURL,
                headers: NetworkConstants.downloadHeaders,
                expectedTotalSize: aproPackage.downloadSize,
                validationURL: nil,
                validationURLs: [],
                progressHandler: { downloadedBytes, totalBytes, speed in
                    Task {
                        await MainActor.run {
                            guard task.status.isActive else { return }
                            let normalizedTotalBytes = totalBytes > 0 ? totalBytes : aproPackage.downloadSize
                            if normalizedTotalBytes > 0 {
                                aproPackage.downloadSize = normalizedTotalBytes
                                task.totalSize = normalizedTotalBytes
                            }
                            aproPackage.status = .downloading
                            aproPackage.downloadedSize = min(max(downloadedBytes, 0), max(aproPackage.downloadSize, 0))
                            aproPackage.progress = self.normalizedProgress(
                                downloadedSize: aproPackage.downloadedSize,
                                totalSize: aproPackage.downloadSize
                            )
                            aproPackage.speed = speed
                            task.totalDownloadedSize = aproPackage.downloadedSize
                            task.totalProgress = aproPackage.progress
                            task.totalSpeed = speed
                            task.objectWillChange.send()
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)
                    }
                }
            )
            switch result {
            case .completed:
                completedURL = outputURL
            case .cancelled, .paused:
                throw NetworkError.cancelled
            case .error(let error):
                throw error
            }
        } else {
            let workflow = PDMWorkflowManager(
                tempDirectory: metadataDirectory,
                validationServiceBaseURL: pdmValidationServiceBaseURL
            )

            completedURL = try await workflow.execute(
                manifestURL: manifestURL,
                cdnBaseURL: cleanCdn,
                headers: NetworkConstants.downloadHeaders,
                destinationDirectory: outputURL.deletingLastPathComponent(),
                packageIdentifier: packageId,
                returnExecutedAsset: true,
                skipAssetActions: true,
                outputAssetURL: outputURL,
                assetMetadataDirectory: metadataDirectory,
                progressHandler: { state, progress in
                    Task {
                        await MainActor.run {
                            guard task.status.isActive else { return }
                            let normalizedProgress = min(max(progress, 0), 1)
                            switch state {
                            case .downloadAssetBits:
                                aproPackage.status = .downloading
                                aproPackage.progress = normalizedProgress
                                if aproPackage.downloadSize > 0 {
                                    aproPackage.downloadedSize = Int64(Double(aproPackage.downloadSize) * normalizedProgress)
                                }
                            case .executeAsset:
                                task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                                    message: "正在校验 \(task.displayName) 安装镜像...",
                                    timestamp: Date(),
                                    stage: .creatingInstaller
                                )))
                            default:
                                break
                            }
                            task.totalDownloadedSize = aproPackage.downloadedSize
                            task.totalProgress = aproPackage.progress
                            task.objectWillChange.send()
                        }
                        await self.updateTaskProgressDirect(task: task)
                    }
                },
                assetInfoHandler: { _, assetSize in
                    guard assetSize > 0 else { return }
                    Task {
                        await MainActor.run {
                            guard task.status.isActive else { return }
                            aproPackage.downloadSize = assetSize
                            aproPackage.downloadedSize = min(max(aproPackage.downloadedSize, 0), assetSize)
                            task.totalSize = assetSize
                            task.totalDownloadedSize = min(max(task.totalDownloadedSize, 0), assetSize)
                            task.objectWillChange.send()
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)
                    }
                },
                downloadProgressHandler: { downloadedBytes, totalBytes, speed in
                    Task {
                        await MainActor.run {
                            guard task.status.isActive else { return }
                            let normalizedTotalBytes = totalBytes > 0 ? totalBytes : aproPackage.downloadSize
                            if normalizedTotalBytes > 0 {
                                aproPackage.downloadSize = normalizedTotalBytes
                                task.totalSize = normalizedTotalBytes
                            }
                            aproPackage.status = .downloading
                            aproPackage.downloadedSize = min(max(downloadedBytes, 0), max(aproPackage.downloadSize, 0))
                            aproPackage.progress = self.normalizedProgress(
                                downloadedSize: aproPackage.downloadedSize,
                                totalSize: aproPackage.downloadSize
                            )
                            aproPackage.speed = speed
                            task.totalDownloadedSize = aproPackage.downloadedSize
                            task.totalProgress = aproPackage.progress
                            task.totalSpeed = speed
                            task.objectWillChange.send()
                        }
                        await self.updateTaskProgressDirect(task: task, force: true)
                    }
                },
                cancellationCheck: {
                    let isCancelled = await globalCancelTracker.isCancelled(task.id)
                    if isCancelled {
                        return true
                    }
                    return await globalCancelTracker.isPaused(task.id)
                }
            )
        }

        guard completedURL.path == outputURL.path else {
            throw NetworkError.fileSystemError("\(task.productId) 下载输出路径不一致", nil)
        }

        if let completedSize = fileSizeIfExists(outputURL), completedSize > 0 {
            aproPackage.downloadSize = completedSize
        }

        await MainActor.run {
            aproPackage.downloadedSize = aproPackage.downloadSize
            aproPackage.progress = 1.0
            aproPackage.speed = 0
            aproPackage.status = .completed
            aproPackage.downloaded = true
            product.completedPackages = product.packages.filter { $0.downloaded }.count
            task.completedPackages = 1
            task.totalPackages = 1
            task.totalDownloadedSize = aproPackage.downloadSize
            task.totalSize = aproPackage.downloadSize
            task.totalProgress = 1.0
            task.totalSpeed = 0
            task.setStatus(.completed(DownloadStatus.CompletionInfo(
                timestamp: Date(),
                totalTime: Date().timeIntervalSince(task.createAt),
                totalSize: task.totalSize
            )))
            product.objectWillChange.send()
            task.objectWillChange.send()
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }

        cleanupCompletedPackageMetadata(task: task)
        await taskProgressPublishLimiter.reset(taskId: task.id)
        await globalNetworkManager.saveTask(task)
    }

    private func prepareCompletedWorkflowOutput(from sourceURL: URL, to destinationURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw NetworkError.fileSystemError("复制 PDM 输出", NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSLocalizedDescriptionKey: "PDM 输出不存在: \(sourceURL.path)"]
            ))
        }

        if isDirectory.boolValue {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let contents = try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
            for item in contents {
                let destinationItem = destinationURL.appendingPathComponent(item.lastPathComponent)
                if FileManager.default.fileExists(atPath: destinationItem.path) {
                    try FileManager.default.removeItem(at: destinationItem)
                }
                try FileManager.default.copyItem(at: item, to: destinationItem)
            }
            return
        }

        try prepareCompletedWorkflowDownload(from: sourceURL, to: destinationURL)
    }

    private func directorySizeIfExists(_ url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
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

            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }
        await taskProgressPublishLimiter.reset(taskId: task.id)
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
        do {
            let result = try await HelperManager.shared.executeShell(command)
            if result.starts(with: "Error:") {
                print("命令执行失败: \(command)")
                print("错误信息: \(result)")
            }
            return result
        } catch {
            let result = "Error: \(error.localizedDescription)"
            print("命令执行失败: \(command)")
            print("错误信息: \(result)")
            return result
        }
    }

    func downloadX1a0HeCCPackages(
        progressHandler: @escaping (Double, String) -> Void,
        cancellationHandler: @escaping () -> Bool
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
                progressHandler(0.9, "正在完成下载...")
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

            try? FileManager.default.removeItem(at: tempDirectory)

            await MainActor.run {
                progressHandler(1.0, "下载完成")
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
            await taskProgressPublishLimiter.reset(taskId: task.id)
        }
    }

}
