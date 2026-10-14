//
//  NewDownloadUtils.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//
import Foundation

actor TaskProgressPublishLimiter {
    private var lastPublishTimes: [UUID: TimeInterval] = [:]

    func shouldPublish(taskId: UUID, force: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime

        if force {
            lastPublishTimes[taskId] = now
            return true
        }

        guard let lastPublishTime = lastPublishTimes[taskId] else {
            lastPublishTimes[taskId] = now
            return true
        }

        guard now - lastPublishTime >= NetworkConstants.progressUpdateInterval else {
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

actor PackageDownloadQueue {
    typealias Item = (package: Package, dependency: DependenciesToDownload, originalIndex: Int)

    private var items: [Item]
    private var index = 0

    init(items: [Item]) {
        self.items = items
    }

    func next() -> Item? {
        guard index < items.count else {
            return nil
        }

        let item = items[index]
        index += 1
        return item
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

    func handleCustomDownload(task: NewDownloadTask, customDependencies: [DependenciesToDownload], generation: UUID) async throws {
        guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
        await MainActor.run {
            task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                message: AppLocalized("正在准备自定义下载..."),
                timestamp: Date(),
                stage: .fetchingInfo
            )))
        }

        if task.requiredDependencies == nil {
            let decision = try await HDPIMParityDecisionEngine.shared.resolveDownloadDecision(
                productId: task.productId, version: task.productVersion,
                requestedLanguage: task.language, catalogSnapshot: task.catalogSnapshot
            )
            guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
            let requirements = decision.dependencies.map { dependency in
                DependenciesToDownload(
                    sapCode: dependency.sapCode, version: dependency.version,
                    buildGuid: dependency.buildGuid, applicationJson: dependency.applicationInfo.rawJSON,
                    isSoftDependency: dependency.isSoftDependency, platform: dependency.platform,
                    baseVersion: dependency.baseVersion, buildVersion: dependency.buildVersion
                )
            }
            await MainActor.run { task.requiredDependencies = requirements }
        }

        let mergedDependencies = await makeMergedCustomDependencies(
            task: task,
            customDependencies: customDependencies
        )
        guard task.execution.accepts(generation) else { throw NetworkError.cancelled }

        for requirement in task.requiredDependencies ?? [] where
            !mergedDependencies.contains(where: { dependencyIdentity($0) == dependencyIdentity(requirement) }) {
            guard let json = requirement.applicationJson, !json.isEmpty,
                  HDPIMPackageMaterial.isLeafName(requirement.sapCode) else {
                throw NetworkError.invalidData("依赖材料不完整：\(requirement.sapCode)，请重新选择下载")
            }
            let directory = task.directory.appendingPathComponent(requirement.sapCode)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: directory.appendingPathComponent("application.json"),
                           atomically: true, encoding: .utf8)
        }
        try writeApplicationJSONs(for: task, dependencies: mergedDependencies)

        let totalSize = mergedDependencies.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }

        await MainActor.run {
            guard task.execution.accepts(generation) else { return }
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
        let clone = DependenciesToDownload(
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
        clone.catalogSnapshot = dependency.catalogSnapshot
        clone.catalogCDN = dependency.catalogCDN
        clone.catalogLanguage = dependency.catalogLanguage
        return clone
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

                    let deltaPackagesByBaseline = Dictionary(
                        dependencyToDownload.packages
                            .filter { !$0.deltaBasePackageVersion.isEmpty && !$0.baselinePackageName.isEmpty }
                            .map { ($0.baselinePackageName, $0) },
                        uniquingKeysWith: { current, _ in current }
                    )
                    let selectedPackageNames = Set(dependencyToDownload.packages.flatMap { package -> [String] in
                        package.baselinePackageName.isEmpty
                            ? packageReferenceNames(package.fullPackageName)
                            : packageReferenceNames(package.baselinePackageName)
                    })
                    
                    if var packages = appInfo["Packages"] as? [String: Any],
                       let packageArray = packages["Package"] as? [[String: Any]] {

                        let filteredPackages = try packageArray.compactMap { package -> [String: Any]? in
                            let logicalName = (package["PackageName"] as? String) ?? ""
                            let derivedFullName = logicalName.hasSuffix(".zip") ? logicalName : "\(logicalName).zip"
                            let nodeFullName = (package["fullPackageName"] as? String) ?? derivedFullName
                            let isSelected = !logicalName.isEmpty
                                ? (selectedPackageNames.contains(derivedFullName) || selectedPackageNames.contains(logicalName))
                                : selectedPackageNames.contains(nodeFullName)
                            guard isSelected else { return nil }

                            let original = ApplicationJSONParser.parsePackage(package)
                            let selected = deltaPackagesByBaseline[logicalName]
                            let material = try HDPIMPackageMaterial.recording(
                                original: original,
                                selectedFileName: selected?.fullPackageName ?? original.fullPackageName,
                                deltaBaseVersion: selected?.deltaBasePackageVersion ?? "",
                                compressionType: appInfo["CompressionType"] as? String ?? "",
                                sourceBaseURL: dependencyToDownload.catalogCDN ?? task.catalogSnapshot?.cdn
                            )
                            var materialNode = package
                            materialNode[HDPIMPackageMaterial.jsonKey] = try material.jsonObject()

                            if let deltaPackage = deltaPackagesByBaseline[logicalName] {
                                var deltaNode = materialNode
                                deltaNode["fullPackageName"] = deltaPackage.fullPackageName
                                deltaNode["Path"] = deltaPackage.downloadURL
                                deltaNode["DownloadSize"] = deltaPackage.downloadSize
                                deltaNode["ExtractSize"] = material.selected.extractSize
                                return deltaNode
                            }
                            return materialNode
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
        let generation = task.execution.generation
        guard task.execution.accepts(generation) else { return }
        let maxConcurrency = await MainActor.run { max(1, StorageData.shared.maxConcurrentDownloads) }

        let isCancelled = await globalCancelTracker.isCancelled(task.id)
        let isPaused = await globalCancelTracker.isPaused(task.id)

        if isCancelled || isPaused {
            return
        }

        await rebuildTaskPackages(task: task, inactiveStatus: .waiting)
        await prepareDownloadEnvironment(task: task)
        guard task.execution.accepts(generation) else { return }

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
            let packageQueue = PackageDownloadQueue(items: allPackages)
            let workerCount = min(max(maxConcurrency, 1), allPackages.count)

            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    guard let self = self else { return }

                    while let (package, dependency, _) = await packageQueue.next() {
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
                            package.speed = 0
                            package.downloadPhase = .waiting
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

                        guard task.execution.accepts(generation) else { return }
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
                            return

                        case .cancelled:
                            await MainActor.run {
                                package.speed = 0
                                package.status = .waiting
                            }
                            await self.updateTaskProgressDirect(task: task, force: true)
                            return

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
        }

        guard task.execution.accepts(generation) else { return }
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
        if let productInfo = task.catalogSnapshot?.product(id: task.productId, version: task.productVersion) {
            let selectedModules = selectedDriverModules(for: task)

            let driverXml = generateDriverXML(
                version: task.productVersion,
                language: task.language,
                productInfo: productInfo,
                dependencies: task.dependenciesToDownload,
                targetArchitecture: task.targetArchitecture,
                modules: selectedModules,
                requiredDependencies: task.requiredDependencies
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
        "AdobeDownloader|\(task.id.uuidString)|\(dependencyIdentity(dependency))|\(packageIdentity(package))"
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
        isManifestInstallerProduct(task.productId) ? DownloadArtifactStore.specialMetadataDirectory(for: task) : nil
    }

    private func aamdFileManager(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package, destinationURL: URL) -> AAMDFileManager {
        AAMDFileManager(downloadFileURL: destinationURL, metadataDirectory: metadataDirectory(for: task, dependency: dependency, package: package))
    }

    private func restoredDownloadedSize(task: NewDownloadTask, dependency: DependenciesToDownload, package: Package, destinationURL: URL) -> Int64? {
        aamdFileManager(task: task, dependency: dependency, package: package, destinationURL: destinationURL)
            .resumeSnapshot()?.downloadedBytes
    }

    private func isPackageArchiveValidForCompletion(package: Package, destinationURL: URL) -> Bool {
        DownloadArtifactStore.inspect(fileURL: destinationURL, identity: DownloadArtifactStore.identity(for: package),
                                      expectedSize: package.manifestURL.isEmpty ? package.downloadSize : 0).verifiedSize != nil
    }

    private func shouldTreatPackageAsCompleted(package: Package, destinationURL: URL) -> Bool {
        isPackageArchiveValidForCompletion(package: package, destinationURL: destinationURL)
    }

    private func resetFailedPackageArchive(task: NewDownloadTask, package: Package) {
        guard let dependency = task.dependenciesToDownload.first(where: { $0.packages.contains(where: { $0.id == package.id }) }) else { return }
        let url = packageDestinationURL(task: task, dependency: dependency, package: package)
        do { try DownloadArtifactStore.preserveForRetry(url) }
        catch { print("保留失败下载材料失败：\(error.localizedDescription)") }
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
                let inspection = DownloadArtifactStore.restore(
                    fileURL: destinationURL, identity: DownloadArtifactStore.identity(for: package),
                    expectedSize: package.manifestURL.isEmpty ? package.downloadSize : 0,
                    metadataDirectory: metadataDirectory(for: task, dependency: dependency, package: package),
                    allowLegacy: package.downloaded || package.status == .completed
                )
                let verifiedSize = inspection.verifiedSize

                await MainActor.run {
                    if let verifiedSize {
                        package.downloadSize = verifiedSize
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
                    package.isBaselineDownloaded = false
                    package.status = inactiveStatus
                    package.speed = 0
                    package.downloadPhase = .waiting

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
        // 保留已校验断点；完成记录已原子落盘，重启不再依赖清空断点表示完成。
    }

    private func waitForTaskDownloadsToSettle(task: NewDownloadTask) async {
        for dependency in task.dependenciesToDownload {
            for package in dependency.packages {
                await PDMDownloadEngine.shared.pauseAndWait(
                    packageId: generatePackageIdentifier(package: package, task: task, dependency: dependency)
                )
            }
        }
        await task.execution.waitUntilStopped()
    }

    private func downloadPackageWithPDM(
        package: Package,
        task: NewDownloadTask,
        product: DependenciesToDownload
    ) async -> PDMDownloadResult {
        let generation = task.execution.generation
        guard task.execution.accepts(generation) else { return .cancelled }
        guard !package.fullPackageName.isEmpty,
              (!package.downloadURL.isEmpty || !package.manifestURL.isEmpty) else {
            return .error(PDMDownloadError(code: .downloadFailed, message: "下载材料缺少包名或有效地址"))
        }

        let snapshot = product.catalogSnapshot ?? task.catalogSnapshot
        let source = snapshot?.index.candidatesBySAP[product.sapCode]?.first {
            $0.platform.id == product.platform && (
                !product.buildGuid.isEmpty ? $0.languageSet.buildGuid == product.buildGuid
                    : $0.product.version == product.version && $0.languageSet.baseVersion == product.baseVersion
            )
        }
        let cdn = product.catalogCDN ?? source?.cdn ?? snapshot?.cdn ?? ""
        let cleanCdn = cdn.hasSuffix("/") ? String(cdn.dropLast()) : cdn
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
                let workspace = task.directory.appendingPathComponent(product.sapCode)
                    .appendingPathComponent(".pdm", isDirectory: true)
                    .appendingPathComponent(self.stableDirectoryToken(packageId), isDirectory: true)
                let workflow = PDMWorkflowManager(
                    tempDirectory: workspace,
                    validationServiceBaseURL: validationServiceBaseURL ?? pdmValidationServiceBaseURL
                )
                let manifestURL = self.normalizedPackageURL(package.manifestURL, cdn: cleanCdn)
                let downloadedURL = try await task.execution.runThrowing(generation: generation) {
                    try await workflow.execute(
                        manifestURL: manifestURL,
                        cdnBaseURL: cleanCdn,
                        headers: NetworkConstants.downloadHeaders,
                        destinationDirectory: workspace,
                        packageIdentifier: packageId,
                        artifactIdentity: DownloadArtifactStore.identity(for: package),
                        progressHandler: { state, _ in
                            self.receiveWorkflowProgress(task: task, package: package, generation: generation, state: state)
                        },
                        assetInfoHandler: { _, assetSize in
                            guard assetSize > 0 else { return }
                            Task { [weak self] in
                                await MainActor.run {
                                    guard task.execution.accepts(generation) else { return }
                                    package.downloadSize = assetSize
                                    package.downloadedSize = min(max(package.downloadedSize, 0), assetSize)
                                    package.objectWillChange.send()
                                }
                                await self?.updateTaskProgressDirect(task: task, force: true)
                            }
                        },
                        downloadProgressHandler: { downloadedBytes, totalBytes, speed, phase in
                            self.receiveDownloadProgress(task: task, package: package, generation: generation,
                                                          downloaded: downloadedBytes, total: totalBytes, speed: speed, phase: phase)
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

                guard task.execution.accepts(generation) else { return .cancelled }
                let finalURL = destinationURL
                if downloadedURL.path != finalURL.path {
                    try await PDMDownloadIO.run {
                        try self.prepareCompletedWorkflowDownload(from: downloadedURL, to: finalURL)
                    }
                }
                if let completedSize = self.fileSizeIfExists(finalURL), completedSize > 0 {
                    await MainActor.run {
                        guard task.execution.accepts(generation) else { return }
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

            return await task.execution.run(generation: generation) {
                await PDMDownloadEngine.shared.downloadFile(
                    packageId: packageId,
                    url: url,
                    destinationURL: destinationURL,
                    headers: NetworkConstants.downloadHeaders,
                    expectedTotalSize: package.downloadSize,
                    validationURL: validationURLs.first,
                    validationURLs: validationURLs,
                    artifactIdentity: DownloadArtifactStore.identity(for: package),
                    progressHandler: { downloadedBytes, totalBytes, speed, phase in
                        self.receiveDownloadProgress(task: task, package: package, generation: generation,
                                                          downloaded: downloadedBytes, total: totalBytes, speed: speed, phase: phase)
                        }
                )
            }
        }

        let result = package.manifestURL.isEmpty ? await startDirectDownload() : await startWorkflowDownload()
        guard task.execution.accepts(generation) else {
            return await globalCancelTracker.isPaused(task.id)
                ? .paused(bytesDownloaded: package.downloadedSize) : .cancelled
        }
        if case .completed = result {
            await markDownloadValidating(task: task, package: package, generation: generation)
            do {
                try await PDMDownloadIO.validate { [self] in
                    try DownloadArtifactStore.recordCompletion(
                        fileURL: destinationURL, identity: DownloadArtifactStore.identity(for: package),
                        expectedSize: package.manifestURL.isEmpty ? package.downloadSize : 0,
                        metadataDirectory: metadataDirectory(for: task, dependency: product, package: package),
                        cancellationCheck: { !task.execution.accepts(generation) }
                    )
                }
            } catch {
                return .error(PDMDownloadError(code: .signatureValidationFailed, message: error.localizedDescription, underlying: error))
            }
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
        let manager = FileManager.default
        try manager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destinationURL.deletingLastPathComponent().appendingPathComponent(".download-final-\(UUID().uuidString)")
        try manager.copyItem(at: sourceURL, to: staging)
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        try DownloadArtifactStore.preserveForRetry(destinationURL)
        try manager.moveItem(at: staging, to: destinationURL)
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

    private func receiveWorkflowProgress(task: NewDownloadTask, package: Package, generation: UUID?, state: PDMState) {
        guard state == .checkDownloadedBits || state == .assetSignatureValidation || state == .executeAsset else { return }
        DispatchQueue.main.async {
            guard task.execution.accepts(generation), package.status == .downloading else { return }
            package.downloadPhase = .validating
            package.speed = 0
            Task { await self.updateTaskProgressDirect(task: task, force: true) }
        }
    }

    private func receiveDownloadProgress(task: NewDownloadTask, package: Package, generation: UUID?,
                                         downloaded: Int64, total: Int64, speed: Double, phase: PDMDownloadPhase) {
        DispatchQueue.main.async {
            guard task.execution.accepts(generation), package.status == .downloading else { return }
            if total > 0 { package.downloadSize = total }
            package.downloadedSize = package.downloadSize > 0
                ? min(max(downloaded, 0), package.downloadSize) : max(downloaded, 0)
            package.progress = self.normalizedProgress(downloadedSize: package.downloadedSize, totalSize: package.downloadSize)
            package.downloadPhase = phase
            package.speed = phase == .transferring && speed.isFinite ? max(speed, 0) : 0
            Task { await self.updateTaskProgressDirect(task: task, force: true) }
        }
    }

    private func markDownloadValidating(task: NewDownloadTask, package: Package, generation: UUID?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                if task.execution.accepts(generation) {
                    package.downloadPhase = .validating
                    package.speed = 0
                }
                continuation.resume()
            }
        }
        await updateTaskProgressDirect(task: task, force: true)
    }

    @MainActor
    private func clearDownloadSpeeds(_ task: NewDownloadTask) {
        task.totalSpeed = 0
        for package in task.dependenciesToDownload.flatMap({ $0.packages }) {
            package.speed = 0
            package.downloadPhase = .waiting
        }
        globalNetworkManager.updateDockBadge()
    }

    private func updateTaskProgressDirect(task: NewDownloadTask, force: Bool = false) async {
        let generation = task.execution.generation
        let shouldPublish = await taskProgressPublishLimiter.shouldPublish(taskId: task.id, force: force)
        guard shouldPublish else { return }
        await MainActor.run {
            guard task.execution.isCurrent(generation), task.status.isActive else { return }
            let allPackages = task.dependenciesToDownload.flatMap { $0.packages }
            let totalSize = allPackages.reduce(Int64(0)) { $0 + max($1.downloadSize, 0) }
            let totalDownloaded = allPackages.reduce(Int64(0)) {
                $0 + ($1.downloadSize > 0 ? min(max($1.downloadedSize, 0), $1.downloadSize) : max($1.downloadedSize, 0))
            }
            task.totalSize = totalSize
            task.totalDownloadedSize = totalDownloaded
            task.totalProgress = task.hasUnknownDownloadSize ? 0
                : normalizedProgress(downloadedSize: totalDownloaded, totalSize: totalSize)
            task.totalSpeed = task.execution.accepts(generation) ? allPackages.reduce(0.0) {
                $0 + ($1.status == .downloading && $1.downloadPhase == .transferring ? $1.speed : 0)
            } : 0
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

        let wasActive = task.status.isActive
        await pauseDownloadTask(taskId: task.id, reason: .userRequested)
        let packageIdentifier = generatePackageIdentifier(package: package, task: task, dependency: dependency)
        await PDMDownloadEngine.shared.cancelAndWait(packageId: packageIdentifier)
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
        if wasActive { await resumeDownloadTask(taskId: task.id) }
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

        let wasActive = task.status.isActive
        await pauseDownloadTask(taskId: task.id, reason: .userRequested)
        for package in removablePackages {
            let packageIdentifier = generatePackageIdentifier(package: package, task: task, dependency: dependency)
            await PDMDownloadEngine.shared.cancelAndWait(packageId: packageIdentifier)
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
        if wasActive { await resumeDownloadTask(taskId: task.id) }
    }

    private func handleError(_ taskId: UUID, _ error: Error, generation: UUID) async {
        let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId })
        guard let task, task.execution.isCurrent(generation) else { return }

        if !task.execution.accepts(generation) || Task.isCancelled || DownloadTaskExecution.isCancellation(error) {
            let paused = await globalCancelTracker.isPaused(taskId)
            if paused { await rebuildTaskPackages(task: task, inactiveStatus: .paused) }
            await MainActor.run {
                guard task.execution.isCurrent(generation) else { return }
                if paused {
                    task.setStatus(.paused(DownloadStatus.PauseInfo(
                        reason: .userRequested, timestamp: Date(), resumable: true
                    )))
                } else {
                    task.setStatus(.failed(DownloadStatus.FailureInfo(
                        message: NetworkError.cancelled.localizedDescription, error: NetworkError.cancelled,
                        timestamp: Date(), recoverable: true
                    )))
                }
                globalNetworkManager.updateDockBadge()
                globalNetworkManager.objectWillChange.send()
            }
            await taskProgressPublishLimiter.reset(taskId: task.id)
            await globalNetworkManager.saveTask(task)
            return
        }

        let (errorMessage, isRecoverable) = classifyError(error)

        if isRecoverable && task.retryCount < NetworkConstants.maxRetryAttempts {
            await MainActor.run { clearDownloadSpeeds(task) }
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

        if let running = task.execution.generation, task.execution.accepts(running) { return }
        await task.execution.waitUntilStopped()
        let startedGeneration = await MainActor.run { () -> UUID? in
            guard globalNetworkManager.downloadTasks.contains(where: { $0 === task }) else { return nil }
            return task.execution.begin()
        }
        guard let generation = startedGeneration else { return }
        defer { task.execution.finish(generation) }
        do {
            try await MainActor.run {
                try globalNetworkManager.validateDownloadDestination(task.directory, excluding: task.id)
                clearDownloadSpeeds(task)
                task.totalStatus = .preparing(DownloadStatus.PrepareInfo(
                    message: "正在恢复下载...", timestamp: Date(), stage: .initializing
                ))
                if task.catalogSnapshot == nil { task.catalogSnapshot = CatalogStore.shared.snapshot }
            }
        } catch {
            await MainActor.run {
                task.totalStatus = .failed(DownloadStatus.FailureInfo(
                    message: error.localizedDescription, error: error, timestamp: Date(), recoverable: true
                ))
            }
            await globalNetworkManager.saveTask(task)
            return
        }
        await globalCancelTracker.reset(taskId)
        guard task.execution.accepts(generation) else { return }
        await rebuildTaskPackages(task: task, inactiveStatus: .waiting)
        guard task.execution.accepts(generation) else { return }

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
                guard let productInfo = task.catalogSnapshot?.product(id: task.productId, version: task.productVersion) else {
                    throw NetworkError.invalidData("找不到 \(task.productId) 产品信息")
                }
                try await performAPRODownload(task: task, productInfo: productInfo)
            } catch {
                await handleError(task.id, error, generation: generation)
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
                return (AppLocalized("网络连接已断开"), true)
            case .timeout:
                return (AppLocalized("下载超时"), true)
            case .serverUnreachable:
                return (AppLocalized("服务器无法访问"), true)
            case .insufficientStorage:
                return (AppLocalized("存储空间不足"), false)
            case .filePermissionDenied:
                return (AppLocalized("没有写入权限"), false)
            default:
                return (networkError.localizedDescription, false)
            }
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return (AppLocalized("网络连接已断开"), true)
            case .timedOut:
                return (AppLocalized("连接超时"), true)
            case .cancelled:
                return (AppLocalized("下载已取消"), false)
            case .cannotConnectToHost, .dnsLookupFailed:
                return (AppLocalized("无法连接到服务器"), true)
            default:
                return (urlError.localizedDescription, true)
            }
        default:
            return (error.localizedDescription, false)
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

    func generateDriverXML(version: String, language: String, productInfo: Product, dependencies: [DependenciesToDownload], targetArchitecture: String, modules: [[String: Any]] = [], requiredDependencies: [DependenciesToDownload]? = nil) -> String {
        guard let mainDependency = dependencies.first(where: { $0.sapCode == productInfo.id }) else {
            return ""
        }

        let fallbackPlatform = productInfo.platforms.first?.id ?? "unknown"

        let platform = mainDependency.platform.isEmpty ? fallbackPlatform : mainDependency.platform
        let buildGuid = mainDependency.buildGuid
        let buildVersion = mainDependency.buildVersion.isEmpty ? version : mainDependency.buildVersion
        let baseVersion = mainDependency.baseVersion.isEmpty ? version : mainDependency.baseVersion

        let dependencyXML = (requiredDependencies ?? dependencies)
            .filter { $0.sapCode != productInfo.id }
            .map { dependency in
                let dependencyBuildVersion = dependency.buildVersion.isEmpty ? dependency.version : dependency.buildVersion
                let dependencyBaseVersion = dependency.baseVersion.isEmpty ? dependency.version : dependency.baseVersion

                return """
                <Dependency>
                    <SapCode>\(dependency.sapCode)</SapCode>
                    <ReuseInstalled>\(!dependencies.contains { dependencyIdentity($0) == dependencyIdentity(dependency) })</ReuseInstalled>
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

    func downloadAPRO(task: NewDownloadTask, productInfo: Product, generation: UUID) async throws {
        guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
        try await performAPRODownload(task: task, productInfo: productInfo)
    }

    private func performAPRODownload(task: NewDownloadTask, productInfo: Product) async throws {
        let generation = task.execution.generation
        guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
        let architecture = HDPIMParityTargetArchitecture(rawValue: task.targetArchitecture)
            ?? task.catalogSnapshot?.context.architecture ?? .intel
        let match = try catalogInstallerMatch(
            product: productInfo, targetArchitecture: architecture, requestedLanguage: task.language
        )

        let selectedPlatform = match.platform
        let selectedLanguageSet = match.languageSet
        let productManifestURL = selectedLanguageSet.manifestURL
        let productDownloadURL = selectedLanguageSet.lbsURL
        guard !productManifestURL.isEmpty || !productDownloadURL.isEmpty else {
            throw NetworkError.invalidData("\(task.productId) 下载地址为空")
        }

        let cdn = productInfo.channelCDN ?? task.catalogSnapshot?.cdn ?? ""
        let cleanCdn = cdn.hasSuffix("/") ? String(cdn.dropLast()) : cdn
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
        aproPackage.speed = 0
        aproPackage.status = .downloading

        let product = DependenciesToDownload(
            sapCode: task.productId,
            version: task.productVersion,
            buildGuid: selectedLanguageSet.buildGuid,
            platform: selectedPlatform.id
        )
        product.catalogSnapshot = task.catalogSnapshot
        product.catalogCDN = cdn
        product.catalogLanguage = task.language
        product.packages = [aproPackage]
        if let restoredBytes = restoredDownloadedSize(task: task, dependency: product, package: aproPackage, destinationURL: outputURL) {
            aproPackage.downloadedSize = min(max(restoredBytes, 0), max(aproPackage.downloadSize, 0))
            aproPackage.progress = normalizedProgress(downloadedSize: aproPackage.downloadedSize, totalSize: aproPackage.downloadSize)
        } else {
            aproPackage.downloadedSize = 0
            aproPackage.progress = 0
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

            let result = await task.execution.run(generation: generation) {
                await PDMDownloadEngine.shared.downloadFile(
                    packageId: packageId,
                    url: url,
                    destinationURL: outputURL,
                    metadataDirectory: metadataDirectory,
                    headers: NetworkConstants.downloadHeaders,
                    expectedTotalSize: 0,
                    validationURL: nil,
                    validationURLs: [],
                    artifactIdentity: DownloadArtifactStore.identity(for: aproPackage),
                    progressHandler: { downloadedBytes, totalBytes, speed, phase in
                        self.receiveDownloadProgress(task: task, package: aproPackage, generation: generation,
                                                          downloaded: downloadedBytes, total: totalBytes, speed: speed, phase: phase)
                        }
                )
            }
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

            completedURL = try await task.execution.runThrowing(generation: generation) {
                try await workflow.execute(
                    manifestURL: manifestURL,
                    cdnBaseURL: cleanCdn,
                    headers: NetworkConstants.downloadHeaders,
                    destinationDirectory: outputURL.deletingLastPathComponent(),
                    packageIdentifier: packageId,
                    artifactIdentity: DownloadArtifactStore.identity(for: aproPackage),
                    returnExecutedAsset: true,
                    skipAssetActions: true,
                    outputAssetURL: outputURL,
                    assetMetadataDirectory: metadataDirectory,
                    progressHandler: { state, _ in
                        self.receiveWorkflowProgress(task: task, package: aproPackage, generation: generation, state: state)
                    },
                    assetInfoHandler: { _, assetSize in
                        guard assetSize > 0 else { return }
                        Task {
                            await MainActor.run {
                                guard task.execution.accepts(generation), task.status.isActive else { return }
                                aproPackage.downloadSize = assetSize
                                aproPackage.downloadedSize = min(max(aproPackage.downloadedSize, 0), assetSize)
                                task.totalSize = assetSize
                                task.totalDownloadedSize = min(max(task.totalDownloadedSize, 0), assetSize)
                                task.objectWillChange.send()
                            }
                            await self.updateTaskProgressDirect(task: task, force: true)
                        }
                    },
                    downloadProgressHandler: { downloadedBytes, totalBytes, speed, phase in
                            self.receiveDownloadProgress(task: task, package: aproPackage, generation: generation,
                                                          downloaded: downloadedBytes, total: totalBytes, speed: speed, phase: phase)
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
        }

        guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
        guard completedURL.path == outputURL.path else {
            throw NetworkError.fileSystemError("\(task.productId) 下载输出路径不一致", nil)
        }

        await markDownloadValidating(task: task, package: aproPackage, generation: generation)
        try await PDMDownloadIO.validate {
            try DownloadArtifactStore.recordCompletion(
                fileURL: outputURL, identity: DownloadArtifactStore.identity(for: aproPackage),
                metadataDirectory: metadataDirectory,
                cancellationCheck: { !task.execution.accepts(generation) }
            )
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

        task.execution.requestStop()
        await MainActor.run { self.clearDownloadSpeeds(task) }
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
            throw NetworkError.invalidData(AppLocalized("无法将响应数据转换为json字符串"))
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
        do {
            try await X1a0HeCCInstaller.shared.install(
                force: true,
                progress: { progress, status in
                    Task { @MainActor in progressHandler(progress, status) }
                },
                log: { print($0) },
                cancellationCheck: cancellationHandler
            )
        } catch is CancellationError {
            throw NetworkError.cancelled
        }
    }

    func stopActiveDownloads(for task: NewDownloadTask) async {
        task.execution.requestStop()
        await MainActor.run { self.clearDownloadSpeeds(task) }
        for dependency in task.dependenciesToDownload {
            for package in dependency.packages where !package.downloaded {
                let packageId = generatePackageIdentifier(package: package, task: task, dependency: dependency)
                PDMDownloadEngine.shared.cancelDownload(packageId: packageId)
            }
        }
        for dependency in task.dependenciesToDownload {
            for package in dependency.packages {
                await PDMDownloadEngine.shared.cancelAndWait(packageId: generatePackageIdentifier(package: package, task: task, dependency: dependency))
            }
        }
        await task.execution.waitUntilStopped()
    }

    func cancelDownloadTask(taskId: UUID, removeFiles: Bool = false) async {
        await globalCancelTracker.cancel(taskId)

        if let task = await globalNetworkManager.downloadTasks.first(where: { $0.id == taskId }) {
            await stopActiveDownloads(for: task)

            if removeFiles {
                try? FileManager.default.removeItem(at: task.directory)
            }

            task.setStatus(.failed(DownloadStatus.FailureInfo(
                message: AppLocalized("下载已取消"),
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
