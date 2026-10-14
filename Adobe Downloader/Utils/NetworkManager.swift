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
	@Published var uninstallState: InstallationState = .idle
	@Published var installCommand: String = ""
	@Published var installLogs: [String] = []
	@Published var uninstallLogs: [String] = []
	@Published var installStateRevision: Int = 0
	internal var progressObservers: [UUID: NSKeyValueObservation] = [:]
	internal var activeDownloadTaskId: UUID?
	internal var monitor = NWPathMonitor()
    @Published private(set) var isFetchingProducts = false
    @Published private(set) var catalogGeneration = UUID()
    @Published private(set) var catalogRefreshError: String?
    private var catalogTask: Task<CatalogSnapshot, Error>?
    private var requestedContext: CatalogRequestContext?
    private var requestGeneration = UUID()
	private let installManager = InstallManager()
    private var hasLoadedSavedTasks = false
	private var lastInstallationProgress = 0.0
	private var lastInstallationStatus = AppLocalized("准备安装...")
	private var lastInstallationPhase: InstallProgressPhase = .preparing
	private var installationCancelledByUser = false
	private var installationSessionID = UUID()
    private var installationSessionFinished = false
    @Published private var installationPackages: [HDPIMPackageProgress] = []
	private var lastUninstallProgress = 0.0
	private var lastUninstallStatus = AppLocalized("准备卸载...")
	private var lastUninstallPhase: InstallProgressPhase = .preparing
    private var uninstallSessionID = UUID()
    private var uninstallSessionFinished = true
    private var uninstallCancellation: HDPIMOperationCancellation?
    private var uninstallResult: HDPIMUninstallResult?
    @Published private(set) var uninstallCancellationRequested = false
    
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

	func notifyInstallStateChanged() {
		installStateRevision += 1
	}

	private func completeInstallation() {
        installationSessionFinished = true
		if case .completed = installationState {
			return
		}
		installationState = .completed
		notifyInstallStateChanged()
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

    func fetchProducts(forceRefresh: Bool = true) async {
        let context = CatalogRequestContext.capture()
        if let task = catalogTask, requestedContext == context {
            _ = await task.result
            return
        }
        if !forceRefresh, CatalogStore.shared.snapshot?.context == context {
            loadingState = .success
            return
        }
        catalogTask?.cancel()
        let generation = UUID()
        requestGeneration = generation
        requestedContext = context
        let retainsList = CatalogStore.shared.snapshot?.context == context
        if !retainsList {
            CatalogStore.shared.replace(with: nil)
            catalogGeneration = generation
            loadingState = .loading
        }
        isFetchingProducts = true
        catalogRefreshError = nil
        let service = globalNetworkService
        let task = Task.detached(priority: .userInitiated) {
            try await service.fetchProductsData(context: context, generation: generation)
        }
        catalogTask = task
        do {
            let snapshot = try await task.value
            guard requestGeneration == generation, !task.isCancelled else { return }
            let start = ProcessInfo.processInfo.systemUptime
            CatalogStore.shared.replace(with: snapshot)
            catalogGeneration = snapshot.generation
            loadingState = .success
            #if DEBUG
            let m = snapshot.measurements
            print("[Catalog] v\(context.apiVersion) bytes=\(m.responseBytes) request=\(m.requests)s decode=\(m.decoding)s merge/index=\(m.mergingAndIndexing)s dependencies=\(m.dependencies)s projection=\(m.projection)s publish=\(ProcessInfo.processInfo.systemUptime - start)s processPeakRSS=\(m.peakResidentBytes)")
            #endif
        } catch {
            guard requestGeneration == generation else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                loadingState = retainsList ? .success : .idle
            } else if retainsList {
                catalogRefreshError = error.localizedDescription
                loadingState = .success
            } else {
                loadingState = .failed(error)
            }
        }
        guard requestGeneration == generation else { return }
        catalogTask = nil
        isFetchingProducts = false
    }

    func cancelCatalogRequest() {
        catalogTask?.cancel()
        catalogTask = nil
        requestGeneration = UUID()
        isFetchingProducts = false
        loadingState = CatalogStore.shared.snapshot == nil ? .idle : .success
    }

    func validateDownloadDestination(_ destination: URL, excluding taskID: UUID? = nil) throws {
        let path = destination.standardizedFileURL.resolvingSymlinksInPath()
        if let owner = downloadTasks.first(where: {
            $0.id != taskID && $0.status.isActive
                && $0.directory.standardizedFileURL.resolvingSymlinksInPath() == path
        }) {
            throw NetworkError.invalidData("下载目录正由 \(owner.displayName) 的活动任务使用，请暂停或完成该任务后重试")
        }
    }

    func startCustomDownload(productId: String, selectedVersion: String, language: String, destinationURL: URL, customDependencies: [DependenciesToDownload], catalogSnapshot: CatalogSnapshot? = nil) async throws {
        guard let snapshot = customDependencies.compactMap(\.catalogSnapshot).first ?? catalogSnapshot ?? CatalogStore.shared.snapshot,
              let productInfo = snapshot.product(id: productId, version: selectedVersion) else {
            throw NetworkError.productNotFound
        }

        try validateDownloadDestination(destinationURL)
        let language = customDependencies.compactMap(\.catalogLanguage).first ?? language
        let selectedPlatform = try CatalogSelection.productCandidate(productInfo, architecture: snapshot.context.architecture, locale: language).platform.id
        let task = downloadTasks.first {
            $0.productId == productInfo.id &&
            $0.productVersion == selectedVersion &&
            $0.language == language &&
            $0.platform == selectedPlatform &&
            $0.targetArchitecture == snapshot.context.architecture.rawValue &&
            $0.directory.standardizedFileURL == destinationURL.standardizedFileURL
        } ?? NewDownloadTask(
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
            platform: customDependencies.first(where: { $0.sapCode == productId })?.platform
                ?? selectedPlatform,
            targetArchitecture: snapshot.context.architecture.rawValue)
        guard let generation = task.execution.begin() else {
            throw NetworkError.invalidData("该任务仍在运行或停止中，请稍后重试")
        }
        defer { task.execution.finish(generation) }
        task.catalogSnapshot = snapshot

        if !downloadTasks.contains(where: { $0.id == task.id }) {
            downloadTasks.append(task)
        }
        task.totalStatus = .preparing(DownloadStatus.PrepareInfo(
            message: "正在准备自定义下载...",
            timestamp: Date(),
            stage: .initializing
        ))
        updateDockBadge()

        do {
            await globalCancelTracker.reset(task.id)
            guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
            await saveTask(task)
            guard task.execution.accepts(generation) else { throw NetworkError.cancelled }
            if isManifestInstallerProduct(productId) {
                try await globalNewDownloadUtils.downloadAPRO(task: task, productInfo: productInfo, generation: generation)
            } else {
                try await globalNewDownloadUtils.handleCustomDownload(task: task, customDependencies: customDependencies, generation: generation)
            }
        } catch {
            guard task.execution.isCurrent(generation) else { return }
            let cancelled = !task.execution.accepts(generation) || Task.isCancelled
                || DownloadTaskExecution.isCancellation(error)
            let paused = await globalCancelTracker.isPaused(task.id)
            guard task.execution.isCurrent(generation) else { return }
            if cancelled && paused {
                task.setStatus(.paused(DownloadStatus.PauseInfo(
                    reason: .userRequested, timestamp: Date(), resumable: true
                )))
            } else {
                let reportedError: Error = cancelled ? NetworkError.cancelled : error
                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: reportedError.localizedDescription, error: reportedError,
                    timestamp: Date(), recoverable: true
                )))
            }
            await saveTask(task)
            updateDockBadge()
            objectWillChange.send()
        }
    }

   func removeTask(taskId: UUID, removeFiles: Bool = true) {
       Task {
           await globalCancelTracker.cancel(taskId)

           if let task = downloadTasks.first(where: { $0.id == taskId }) {
               await globalNewDownloadUtils.stopActiveDownloads(for: task)
               if task.status.isActive {
                   task.setStatus(.failed(DownloadStatus.FailureInfo(
                       message: AppLocalized("下载已取消"),
                       error: NetworkError.downloadCancelled,
                       timestamp: Date(),
                       recoverable: false
                   )))
                   await saveTask(task)
               }
               
               if removeFiles {
                   removeFilesForTask(task, includeDownloadedFile: true)
               } else {
                   removeFilesForTask(task, includeDownloadedFile: false)
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
        for attempt in 0..<3 {
            await fetchProducts()
            if loadingState == .success && catalogRefreshError == nil { return }
            if Task.isCancelled { return }
            if attempt < 2 {
                do { try await Task.sleep(nanoseconds: UInt64(1 << (attempt + 1)) * 1_000_000_000) }
                catch { return }
            }
        }
    }

   private func clearCompletedDownloadTasks() async {
       await MainActor.run {
           downloadTasks.removeAll { task in
               if task.status.isCompleted || task.status.isFailed {
                   let shouldRemoveDownloadedFile = StorageData.shared.deleteCompletedTasksWithFiles
                   removeFilesForTask(task, includeDownloadedFile: shouldRemoveDownloadedFile)
                   return true
               }
               return false
           }
           updateDockBadge()
           objectWillChange.send()
       }
   }

   private func removeFilesForTask(_ task: NewDownloadTask, includeDownloadedFile: Bool) {
       for url in globalNewDownloadUtils.removableArtifacts(for: task, includeDownloadedFile: includeDownloadedFile) {
           try? FileManager.default.removeItem(at: url)
       }
   }

    func installProduct(at path: URL) async {
        let sessionID = UUID()
        await MainActor.run {
            installationSessionID = sessionID
            installationSessionFinished = false
            installationCancelledByUser = false
            installationState = .installing(progress: 0, status: AppLocalized("准备安装..."))
            installLogs = []
            installationPackages = []
            installCommand = ""
            lastInstallationPhase = .preparing
            updateInstallationSnapshot(progress: 0, status: AppLocalized("准备安装..."))
        }

        do {
            try await installManager.install(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID, !self.installationSessionFinished else { return }
                        self.updateInstallationSnapshot(progress: progress, status: status)
                        self.installationState = .installing(progress: progress, status: status)
                    }
                },
                logHandler: { message in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        if self.consumePackageProgress(message) { return }
                        guard !self.installationSessionFinished else { return }
                        self.appendInstallLog(message)
                    }
                }
            )
            
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                updateInstallationSnapshot(progress: 1.0, status: AppLocalized("安装完成"))
				completeInstallation()
            }
        } catch {
            let command = await installManager.getInstallCommand(
                for: path.appendingPathComponent("driver.xml").path
            )
            
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                self.installCommand = command
                
                var errorDetails: String? = nil
                var mainError = error
                
                if let installError = error as? InstallManager.InstallError {
                    switch installError {
                    case .installationFailedWithDetails(let message, let details):
                        errorDetails = details
                        mainError = InstallManager.InstallError.installationFailed(message)
                    case .installerOpened(let message):
                        updateInstallationSnapshot(progress: 0.8, status: message)
                        installationState = .installing(progress: 0.8, status: message)
                        return
                    default:
                        break
                    }
                }
                
                installationSessionFinished = true
                installationState = .failed(mainError, errorDetails)
            }
        }
    }

    func cancelInstallation() {
        installationCancelledByUser = true
        Task {
            await installManager.cancel()
        }
    }

    func clearInstallationSheetState() {
        if case .installing = installationState {
            cancelInstallation()
        }
        installationSessionID = UUID()
        installationSessionFinished = true
        installationState = .idle
        installLogs = []
        installationPackages = []
        installCommand = ""
        lastInstallationProgress = 0
        lastInstallationStatus = AppLocalized("准备安装...")
        lastInstallationPhase = .preparing
        installationCancelledByUser = false
    }

    func retryInstallation(at path: URL) async {
        let sessionID = UUID()
        await MainActor.run {
            installationSessionID = sessionID
            installationSessionFinished = false
            installationCancelledByUser = false
            installationState = .installing(progress: 0, status: AppLocalized("正在重试安装..."))
            installLogs = []
            installationPackages = []
            installCommand = ""
            lastInstallationPhase = .preparing
            updateInstallationSnapshot(progress: 0, status: AppLocalized("正在重试安装..."))
        }
        
        do {
            try await installManager.retry(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID, !self.installationSessionFinished else { return }
                        self.updateInstallationSnapshot(progress: progress, status: status)
                        self.installationState = .installing(progress: progress, status: status)
                    }
                },
                logHandler: { message in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        if self.consumePackageProgress(message) { return }
                        guard !self.installationSessionFinished else { return }
                        self.appendInstallLog(message)
                    }
                }
            )
            
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                updateInstallationSnapshot(progress: 1.0, status: AppLocalized("安装完成"))
                completeInstallation()
            }
        } catch {
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                var errorDetails: String? = nil
                var mainError = error
                
                if let installError = error as? InstallManager.InstallError {
                    if case .installationFailedWithDetails(let message, let details) = installError {
                        errorDetails = details
                        mainError = InstallManager.InstallError.installationFailed(message)
                    } else if case .installerOpened(let message) = installError {
                        updateInstallationSnapshot(progress: 0.8, status: message)
                        installationState = .installing(progress: 0.8, status: message)
                        return
                    }
                }
                
                installationSessionFinished = true
                installationState = .failed(mainError, errorDetails)
            }
        }
    }

	func makeInstallProgressViewData(productName: String) -> InstallProgressViewData {
        switch installationState {
        case .idle:
            return InstallProgressViewData(
                productName: productName,
                progress: 0,
                status: AppLocalized("准备安装..."),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: nil,
                phase: .preparing,
                outcome: .running,
                packages: installationPackages
            )
        case .installing(let progress, let status):
            return InstallProgressViewData(
                productName: productName,
                progress: progress,
                status: status,
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: nil,
                phase: lastInstallationPhase,
                outcome: .running,
                packages: installationPackages
            )
        case .completed:
            return InstallProgressViewData(
                productName: productName,
                progress: 1.0,
                status: AppLocalized("安装完成"),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: nil,
                phase: lastInstallationPhase,
                outcome: .completed,
                packages: installationPackages
            )
        case .failed(let error, let errorDetails):
            let fallbackStatus = lastInstallationStatus
            let cancelledByUser = installationCancelledByUser
            return InstallProgressViewData(
                productName: productName,
                progress: lastInstallationProgress,
                status: cancelledByUser ? AppLocalized("安装已取消") : normalizedInstallFailureStatus(from: error),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: cancelledByUser ? nil : errorDetails,
                phase: lastInstallationPhase,
                outcome: .failed,
                contextStatus: fallbackStatus,
                isUserCancelled: cancelledByUser,
                packages: installationPackages
            )
        }
	}

	func uninstallProduct(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		productName: String,
        preservingUserPreferences: Bool = true
	) async {
		let request = HDPIMUninstallHelperRequest(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily.rawValue,
			target: .product,
			moduleIds: [],
			packageKeys: [],
            preservingUserPreferences: preservingUserPreferences
		)
        await runUninstall(productName: productName, request: request)
	}

	func uninstallModule(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleId: String,
		productName: String,
        preservingUserPreferences: Bool = true
	) async {
		await uninstallModules(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			moduleIds: [moduleId],
			productName: productName,
            preservingUserPreferences: preservingUserPreferences
		)
	}

	func uninstallModules(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleIds: Set<String>,
		productName: String,
        preservingUserPreferences: Bool = true
	) async {
		let request = HDPIMUninstallHelperRequest(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily.rawValue,
			target: .module,
			moduleIds: Array(moduleIds).sorted(),
			packageKeys: [],
            preservingUserPreferences: preservingUserPreferences
		)
        await runUninstall(productName: productName, request: request)
	}

	func uninstallPackages(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		packageKeys: Set<HDPIMPackageUninstallKey>,
		productName: String,
        preservingUserPreferences: Bool = true
	) async {
		let request = HDPIMUninstallHelperRequest(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily.rawValue,
			target: .packages,
			moduleIds: [],
			packageKeys: packageKeys
				.sorted { $0.id < $1.id }
				.map {
					HDPIMUninstallHelperRequest.PackageKey(
						packageName: $0.packageName,
						packageVersion: $0.packageVersion
					)
				},
            preservingUserPreferences: preservingUserPreferences
		)
        await runUninstall(productName: productName, request: request)
	}

    func makeUninstallProgressViewData(productName: String) -> InstallProgressViewData {
        let status: String
        let progress: Double
        let outcome: InstallProgressOutcome
        let details: String?
        switch uninstallState {
        case .idle:
            status = AppLocalized("准备卸载...")
            progress = 0
            outcome = .running
            details = nil
        case .installing(let currentProgress, let currentStatus):
            status = currentStatus
            progress = currentProgress
            outcome = .running
            details = nil
        case .completed:
            status = uninstallResult?.outcome == .warnings
                ? AppLocalized("卸载已完成，请查看警告事项") : AppLocalized("卸载完成")
            progress = 1
            outcome = .completed
            details = nil
        case .failed(let error, let errorDetails):
            switch uninstallResult?.outcome {
            case .cancelled:
                status = AppLocalized("卸载已取消")
            case .partial:
                status = AppLocalized("卸载部分失败，请保留恢复目录并查看详细信息")
            default:
                status = normalizedUninstallFailureStatus(from: error)
            }
            progress = lastUninstallProgress
            outcome = .failed
            details = errorDetails
        }
        return InstallProgressViewData(
            productName: productName,
            progress: progress,
            status: status,
            logs: uninstallLogs,
            installCommand: AppLocalized("HDPIM Engine (内置卸载引擎)"),
            errorDetails: details,
            phase: lastUninstallPhase,
            outcome: outcome,
            operation: .uninstall,
            contextStatus: lastUninstallStatus,
            isUserCancelled: uninstallResult?.outcome == .cancelled,
            warnings: uninstallResult?.warnings ?? [],
            isPartialFailure: uninstallResult?.outcome == .partial,
            recoveryDirectory: uninstallResult?.recoveryDirectory,
            isCancellationPending: uninstallCancellationRequested && !uninstallSessionFinished
        )
    }

    func cancelUninstallation() {
        guard !uninstallSessionFinished, let cancellation = uninstallCancellation,
              !uninstallCancellationRequested else { return }
        uninstallCancellationRequested = true
        cancellation.cancel()
        let status = AppLocalized("正在取消卸载，等待恢复和收尾...")
        uninstallState = .installing(progress: lastUninstallProgress, status: status)
        appendUninstallLog(status)
    }

    private func runUninstall(productName: String, request: HDPIMUninstallHelperRequest) async {
        guard uninstallCancellation == nil else {
            appendUninstallLog(AppLocalized("上一卸载操作仍在运行或恢复，请等待收尾完成"))
            return
        }
        let sessionID = UUID()
        let cancellation = HDPIMOperationCancellation()
        uninstallSessionID = sessionID
        uninstallSessionFinished = false
        uninstallCancellation = cancellation
        uninstallCancellationRequested = false
        uninstallResult = nil
        uninstallLogs = []
        lastUninstallProgress = 0
        lastUninstallStatus = AppLocalized("准备卸载...")
        lastUninstallPhase = .preparing
        uninstallState = .installing(progress: 0, status: lastUninstallStatus)
        appendUninstallLog(String(format: AppLocalized("准备卸载 %@"), productName))
        defer {
            cancellation.stopMonitoring()
            if uninstallSessionID == sessionID { uninstallCancellation = nil }
        }

        let result: HDPIMUninstallResult
        do {
            result = try await withTaskCancellationHandler {
                try await HDPIMOperationContext.$cancellation.withValue(cancellation) {
                    try HDPIMOperationContext.checkCancellation()
                    let lease = try await X1a0HeCCInstaller.shared.reserveForProductInstallation()
                    do {
                        try HDPIMOperationContext.checkCancellation()
                        let result = try await executeHDPIMUninstall(request, sessionID: sessionID)
                        await X1a0HeCCInstaller.shared.releaseProductInstallation(lease)
                        return result
                    } catch {
                        await X1a0HeCCInstaller.shared.releaseProductInstallation(lease)
                        throw error
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch let failure as HDPIMUninstallFailure {
            result = failure.result
        } catch {
            result = HDPIMUninstallResult(
                outcome: error is CancellationError ? .cancelled : .failed,
                warnings: [],
                details: error.localizedDescription,
                recoveryDirectory: nil
            )
        }
        guard uninstallSessionID == sessionID else { return }
        uninstallSessionFinished = true
        uninstallResult = result
        for diagnostic in result.diagnostics ?? [] { appendUninstallLog("诊断：" + diagnostic) }
        for warning in result.warnings { appendUninstallLog("警告：" + warning) }
        if let details = result.details { appendUninstallLog(details) }
        if let directory = result.recoveryDirectory { appendUninstallLog("恢复目录：" + directory) }
        switch result.outcome {
        case .completed, .warnings:
            lastUninstallProgress = 1
            lastUninstallPhase = .finishing
            lastUninstallStatus = result.outcome == .warnings ? "卸载完成（有警告）" : "卸载完成"
            appendUninstallLog(lastUninstallStatus)
            uninstallState = .completed
        case .cancelled, .failed, .partial:
            let failure = HDPIMUninstallFailure(result: result)
            uninstallState = .failed(failure, result.details)
        }
        notifyInstallStateChanged()
    }

    private func executeHDPIMUninstall(
        _ request: HDPIMUninstallHelperRequest,
        sessionID: UUID
    ) async throws -> HDPIMUninstallResult {
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { continuation = $0 }
        let outputContinuation = continuation!
        // 同一消费任务处理完整行，并在发布终态前排空，避免迟到的进度覆盖结果。
        let consumer = Task { @MainActor in
            var state = UninstallOutputState()
            for await output in stream {
                self.consumeUninstallOutput(output, sessionID: sessionID, state: &state)
            }
            self.consumeUninstallOutput("\n", sessionID: sessionID, state: &state)
            return state
        }
        var helperError: Error?
        do {
            try await HelperManager.shared.executeHDPIMUninstall(
                request: request,
                userHome: NSHomeDirectory(),
                executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            ) { output in
                outputContinuation.yield(output)
            }
        } catch {
            helperError = error
        }
        outputContinuation.finish()
        let state = await consumer.value
        if let result = state.result { return result }
        if let error = state.lastError {
            throw NSError(domain: "HDPIMUninstall", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        let details = helperError.map { "\n" + $0.localizedDescription } ?? ""
        throw NSError(domain: "HDPIMUninstall", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "卸载进程未返回完整结果，无法确认卸载或恢复是否完成，请检查安装状态和日志。" + details])
    }

    private struct UninstallOutputState {
        var pending = ""
        var result: HDPIMUninstallResult?
        var lastError: String?
        var lastProgressPhase: String?
        var lastProgressLogTime = -Double.infinity
    }

    private func consumeUninstallOutput(
        _ output: String,
        sessionID: UUID,
        state: inout UninstallOutputState
    ) {
        guard uninstallSessionID == sessionID, !uninstallSessionFinished else { return }
        state.pending.append(output)
        while let newline = state.pending.firstIndex(of: "\n") {
            let line = String(state.pending[..<newline]).trimmingCharacters(in: .newlines)
            state.pending.removeSubrange(...newline)
            if line.hasPrefix("UNINSTALL|") {
                do {
                    guard let data = Data(base64Encoded: String(line.dropFirst(10))) else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    state.result = try JSONDecoder().decode(HDPIMUninstallResult.self, from: data)
                } catch {
                    state.lastError = "无法读取卸载结果：" + error.localizedDescription
                }
            } else if line.hasPrefix("PROGRESS|") {
                let fields = line.split(separator: "|", maxSplits: 2).map(String.init)
                guard fields.count == 3, let progress = Double(fields[1]), progress.isFinite else { continue }
                let status = fields[2]
                let phase = status.components(separatedBy: "...").first ?? status
                let now = ProcessInfo.processInfo.systemUptime
                if state.lastProgressPhase != phase || now - state.lastProgressLogTime >= 5 || progress >= 1 {
                    state.lastProgressPhase = phase
                    state.lastProgressLogTime = now
                    appendUninstallLog(status)
                }
                let snapshot = updateUninstallSnapshot(progress: progress, status: status)
                if !uninstallCancellationRequested {
                    uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
                }
            } else if line.hasPrefix("LOG|") {
                let message = String(line.dropFirst(4))
                #if DEBUG
                appendUninstallLog(message)
                #else
                if message.contains("警告") || message.localizedCaseInsensitiveContains("warning") || message.contains("失败") ||
                    message.contains("恢复") || message.contains("耗时") ||
                    message.localizedCaseInsensitiveContains("failed") ||
                    message.localizedCaseInsensitiveContains("recovery") ||
                    message.localizedCaseInsensitiveContains("elapsed") {
                    appendUninstallLog(message)
                }
                #endif
            } else if line.hasPrefix("ERROR|") {
                state.lastError = String(line.dropFirst(6))
                appendUninstallLog(state.lastError ?? "")
            }
        }
    }

	@discardableResult
	private func updateUninstallSnapshot(progress: Double, status: String) -> (progress: Double, status: String) {
		let clampedProgress = min(max(progress, lastUninstallProgress), 1.0)
		lastUninstallProgress = clampedProgress
		lastUninstallStatus = status
		if clampedProgress >= 0.95 {
			lastUninstallPhase = .finishing
		} else if clampedProgress >= 0.08 {
			lastUninstallPhase = .installing
		} else {
			lastUninstallPhase = .preparing
		}
		return (clampedProgress, status)
	}

	private func appendUninstallLog(_ message: String) {
		let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedMessage.isEmpty else {
			return
		}
		guard uninstallLogs.last != trimmedMessage else {
			return
		}
		uninstallLogs.append(trimmedMessage)
	}

	private func normalizedUninstallFailureStatus(from error: Error) -> String {
		let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
		let prefix = AppLocalized("卸载失败")
		if message.hasPrefix(prefix) || message.hasPrefix("卸载失败") || message.hasPrefix("Uninstall failed") {
			return message
		}
		return String(format: AppLocalized("卸载失败: %@"), message)
	}

	private func updateInstallationSnapshot(progress: Double, status: String) {
        lastInstallationProgress = progress
        lastInstallationStatus = status

        if status == AppLocalized("安装完成") || status == "安装完成" || status == "Installation completed" {
            lastInstallationPhase = .finishing
            return
        }

        let detectedPhase = InstallProgressTextParser.phase(from: status, logs: installLogs, outcome: .running)
        if detectedPhase.rawValue >= lastInstallationPhase.rawValue {
            lastInstallationPhase = detectedPhase
        }
    }

    private func normalizedInstallFailureStatus(from error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let failurePrefix = AppLocalized("安装失败")
        if message.hasPrefix(failurePrefix) || message.hasPrefix("安装失败") || message.hasPrefix("Install failed") {
            return message
        }
        return String(format: AppLocalized("安装失败: %@"), message)
    }

    private func consumePackageProgress(_ message: String) -> Bool {
        guard message.hasPrefix(HDPIMPackageProgress.messagePrefix) else { return false }
        guard let package = HDPIMPackageProgress.decode(message) else { return true }
        if let index = installationPackages.firstIndex(where: { $0.id == package.id }) {
            guard package.revision > installationPackages[index].revision else { return true }
            installationPackages[index] = package
        } else {
            installationPackages.append(package)
            installationPackages.sort { $0.id < $1.id }
        }
        return true
    }

    private func appendInstallLog(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return
        }
        guard !shouldFilterInstallLog(trimmedMessage) else {
            return
        }
        if isProcessingInstallLog(trimmedMessage),
           !installLogs.isEmpty,
           isProcessingInstallLog(installLogs[installLogs.count - 1]) {
            installLogs[installLogs.count - 1] = trimmedMessage
            return
        }
        guard installLogs.last != trimmedMessage else {
            return
        }
        installLogs.append(trimmedMessage)
    }

    private func shouldFilterInstallLog(_ message: String) -> Bool {
        guard message.contains("%") else {
            return false
        }

        if message.contains("正在解压 ") || message.contains("正在安装 ") ||
            message.contains("Extracting ") || message.contains("Installing ") {
            return true
        }

        return false
    }

    private func isProcessingInstallLog(_ message: String) -> Bool {
        message.contains("正在处理:") || message.localizedCaseInsensitiveContains("processing:")
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        return try await globalNetworkService.getApplicationInfo(buildGuid: buildGuid)
    }

    func isVersionDownloaded(productId: String, version: String, language: String) -> URL? {
        if let task = downloadTasks.first(where: {
            $0.productId == productId &&
            $0.productVersion == version &&
            $0.language == language
        }) {
            if task.status.isCompleted {
                return TaskPersistenceManager.shared.taskArtifactsAreValid(task) ? task.directory : nil
            }
            return task.directory
        }

        let platform = installerSelectedPlatformId(
            productId: productId,
            version: version
        ) ?? "unknown"
        let fileName = installerOutputName(
            productId: productId,
            version: version,
            language: language,
            platform: platform
        )

        if useDefaultDirectory && !defaultDirectory.isEmpty {
            let defaultPath = URL(fileURLWithPath: defaultDirectory)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: defaultPath.path) {
                return defaultPath
            }
        }

        return nil
    }

    func isProductInstalled(productId: String, version: String, platform: String) -> Bool {
        guard let database = try? HDPIMDatabase.shared.makeReadOnlyConnection() else { return false }
        defer { database.close() }
        return database.isProductReallyInstalled(
            sapCode: productId,
            version: version,
            platform: platform,
            validateFiles: true
        )
    }

    func updateDockBadge() {
        let activeTasks = downloadTasks.filter { $0.status.isActive }
        let totalSize = activeTasks.reduce(Int64(0)) { $0 + max($1.totalSize, 0) }
        let downloadedSize = activeTasks.reduce(Int64(0)) {
            $0 + min(max($1.totalDownloadedSize, 0), max($1.totalSize, 0))
        }
        let totalSpeed = DownloadTaskSummary(tasks: downloadTasks).speed
        let hasUnknownSize = activeTasks.contains { $0.hasUnknownDownloadSize }
        let progress = !hasUnknownSize && totalSize > 0 ? Double(downloadedSize) / Double(totalSize) : 0

        DockProgressIndicator.shared.update(
            progress: progress,
            taskCount: activeTasks.count,
            speed: totalSpeed,
            isCompleted: false
        )
    }

    func retryFetchData() {
        Task {
            await fetchProducts()
        }
    }

    func loadSavedTasks() {
        guard !hasLoadedSavedTasks else { return }
        hasLoadedSavedTasks = true
        Task {
            let savedTasks = await TaskPersistenceManager.shared.loadTasks()
            await MainActor.run {
                for task in savedTasks {
                    for product in task.dependenciesToDownload {
                        product.updateCompletedPackages()
                    }
                }
                let existing = Set(downloadTasks.map(\.id))
                downloadTasks.append(contentsOf: savedTasks.filter { !existing.contains($0.id) })
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
