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
	internal var isFetchingProducts = false
	private let installManager = InstallManager()
    private var hasLoadedSavedTasks = false
	private var lastInstallationProgress = 0.0
	private var lastInstallationStatus = String(localized: "准备安装...")
	private var lastInstallationPhase: InstallProgressPhase = .preparing
	private var installationCancelledByUser = false
	private var installationSessionID = UUID()
	private var lastUninstallProgress = 0.0
	private var lastUninstallStatus = String(localized: "准备卸载...")
	private var lastUninstallPhase: InstallProgressPhase = .preparing
    
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

        let task = downloadTasks.first {
            $0.productId == productInfo.id &&
            $0.productVersion == selectedVersion &&
            $0.language == language &&
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
                ?? installerSelectedPlatformId(
                    productId: productId,
                    version: selectedVersion
                )
                ?? "unknown",
            targetArchitecture: HDPIMParityTargetArchitecture.currentSelection.rawValue)

        if !downloadTasks.contains(where: { $0.id == task.id }) {
            downloadTasks.append(task)
        }
        task.setStatus(.preparing(DownloadStatus.PrepareInfo(
            message: "正在准备自定义下载...",
            timestamp: Date(),
            stage: .initializing
        )))
        updateDockBadge()
        await saveTask(task)
        
        do {
            if isManifestInstallerProduct(productId) {
                try await globalNewDownloadUtils.downloadAPRO(task: task, productInfo: productInfo)
            } else {
                try await globalNewDownloadUtils.handleCustomDownload(task: task, customDependencies: customDependencies)
            }
        } catch NetworkError.cancelled {
            if isManifestInstallerProduct(productId), await globalCancelTracker.isPaused(task.id) {
                task.setStatus(.paused(DownloadStatus.PauseInfo(
                    reason: .userRequested,
                    timestamp: Date(),
                    resumable: true
                )))
                await saveTask(task)
                await MainActor.run {
                    updateDockBadge()
                    objectWillChange.send()
                }
            } else {
                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: NetworkError.cancelled.localizedDescription,
                    error: NetworkError.cancelled,
                    timestamp: Date(),
                    recoverable: true
                )))
                await saveTask(task)
                await MainActor.run {
                    objectWillChange.send()
                }
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
               globalNewDownloadUtils.stopActiveDownloads(for: task)
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
            installationCancelledByUser = false
            installationState = .installing(progress: 0, status: String(localized: "准备安装..."))
            installLogs = []
            installCommand = ""
            lastInstallationPhase = .preparing
            updateInstallationSnapshot(progress: 0, status: String(localized: "准备安装..."))
        }

        do {
            try await installManager.install(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        self.updateInstallationSnapshot(progress: progress, status: status)
                        if status == String(localized: "安装完成") || status == "安装完成" {
							self.completeInstallation()
                        } else {
                            self.installationState = .installing(progress: progress, status: status)
                        }
                    }
                },
                logHandler: { message in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        self.appendInstallLog(message)
                    }
                }
            )
            
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                updateInstallationSnapshot(progress: 1.0, status: String(localized: "安装完成"))
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
        installationState = .idle
        installLogs = []
        installCommand = ""
        lastInstallationProgress = 0
        lastInstallationStatus = String(localized: "准备安装...")
        lastInstallationPhase = .preparing
        installationCancelledByUser = false
    }

    func retryInstallation(at path: URL) async {
        let sessionID = UUID()
        await MainActor.run {
            installationSessionID = sessionID
            installationCancelledByUser = false
            installationState = .installing(progress: 0, status: String(localized: "正在重试安装..."))
            installLogs = []
            installCommand = ""
            lastInstallationPhase = .preparing
            updateInstallationSnapshot(progress: 0, status: String(localized: "正在重试安装..."))
        }
        
        do {
            try await installManager.retry(
                at: path,
                progressHandler: { progress, status in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        self.updateInstallationSnapshot(progress: progress, status: status)
                        if status == String(localized: "安装完成") || status == "安装完成" {
                            self.completeInstallation()
                        } else {
                            self.installationState = .installing(progress: progress, status: status)
                        }
                    }
                },
                logHandler: { message in
                    Task { @MainActor in
                        guard self.installationSessionID == sessionID else { return }
                        self.appendInstallLog(message)
                    }
                }
            )
            
            await MainActor.run {
                guard installationSessionID == sessionID else { return }
                updateInstallationSnapshot(progress: 1.0, status: String(localized: "安装完成"))
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
                status: String(localized: "准备安装..."),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: nil,
                phase: .preparing,
                outcome: .running
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
                outcome: .running
            )
        case .completed:
            return InstallProgressViewData(
                productName: productName,
                progress: 1.0,
                status: String(localized: "安装完成"),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: nil,
                phase: lastInstallationPhase,
                outcome: .completed
            )
        case .failed(let error, let errorDetails):
            let fallbackStatus = lastInstallationStatus
            let cancelledByUser = installationCancelledByUser
            return InstallProgressViewData(
                productName: productName,
                progress: lastInstallationProgress,
                status: cancelledByUser ? String(localized: "安装已取消") : normalizedInstallFailureStatus(from: error),
                logs: installLogs,
                installCommand: installCommand,
                errorDetails: cancelledByUser ? nil : errorDetails,
                phase: lastInstallationPhase,
                outcome: .failed,
                contextStatus: fallbackStatus,
                isUserCancelled: cancelledByUser
            )
        }
	}

	func uninstallProduct(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		productName: String
	) async {
		let request = HDPIMUninstallHelperRequest(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily.rawValue,
			target: .product,
			moduleIds: [],
			packageKeys: []
		)
		await runUninstall(productName: productName) {
			try await self.executeHDPIMUninstall(request)
		}
	}

	func uninstallModule(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleId: String,
		productName: String
	) async {
		await uninstallModules(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			moduleIds: [moduleId],
			productName: productName
		)
	}

	func uninstallModules(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleIds: Set<String>,
		productName: String
	) async {
		let request = HDPIMUninstallHelperRequest(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily.rawValue,
			target: .module,
			moduleIds: Array(moduleIds).sorted(),
			packageKeys: []
		)
		await runUninstall(productName: productName) {
			try await self.executeHDPIMUninstall(request)
		}
	}

	func uninstallPackages(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		packageKeys: Set<HDPIMPackageUninstallKey>,
		productName: String
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
				}
		)
		await runUninstall(productName: productName) {
			try await self.executeHDPIMUninstall(request)
		}
	}

	func makeUninstallProgressViewData(productName: String) -> InstallProgressViewData {
		switch uninstallState {
		case .idle:
			return InstallProgressViewData(
				productName: productName,
				progress: 0,
				status: String(localized: "准备卸载..."),
				logs: uninstallLogs,
				installCommand: String(localized: "HDPIM Engine (内置卸载引擎)"),
				errorDetails: nil,
				phase: .preparing,
				outcome: .running,
				operation: .uninstall
			)
		case .installing(let progress, let status):
			return InstallProgressViewData(
				productName: productName,
				progress: progress,
				status: status,
				logs: uninstallLogs,
				installCommand: String(localized: "HDPIM Engine (内置卸载引擎)"),
				errorDetails: nil,
				phase: lastUninstallPhase,
				outcome: .running,
				operation: .uninstall
			)
		case .completed:
			return InstallProgressViewData(
				productName: productName,
				progress: 1.0,
				status: String(localized: "卸载完成"),
				logs: uninstallLogs,
				installCommand: String(localized: "HDPIM Engine (内置卸载引擎)"),
				errorDetails: nil,
				phase: .finishing,
				outcome: .completed,
				operation: .uninstall
			)
		case .failed(let error, let errorDetails):
			return InstallProgressViewData(
				productName: productName,
				progress: lastUninstallProgress,
				status: normalizedUninstallFailureStatus(from: error),
				logs: uninstallLogs,
				installCommand: String(localized: "HDPIM Engine (内置卸载引擎)"),
				errorDetails: errorDetails,
				phase: lastUninstallPhase,
				outcome: .failed,
				operation: .uninstall,
				contextStatus: lastUninstallStatus
			)
		}
	}

	private func runUninstall(
		productName: String,
		operation: @escaping () async throws -> Void
	) async {
		await MainActor.run {
			uninstallState = .installing(progress: 0, status: String(localized: "准备卸载..."))
			uninstallLogs = []
			lastUninstallProgress = 0
			lastUninstallStatus = String(localized: "准备卸载...")
			lastUninstallPhase = .preparing
			appendUninstallLog(String(format: String(localized: "准备卸载 %@"), productName))
		}

		do {
			await MainActor.run {
				let snapshot = updateUninstallSnapshot(progress: 0.05, status: String(localized: "正在准备 HDPIM 卸载流程..."))
				uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
				appendUninstallLog(String(localized: "正在执行 HDPIM 卸载流程"))
			}

			try await operation()

			await MainActor.run {
				let snapshot = updateUninstallSnapshot(progress: 1.0, status: String(localized: "卸载完成"))
				appendUninstallLog(String(localized: "卸载完成"))
				uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
				uninstallState = .completed
				notifyInstallStateChanged()
				objectWillChange.send()
			}
		} catch {
			await MainActor.run {
				let message = error.localizedDescription
				appendUninstallLog(String(format: String(localized: "卸载失败: %@"), message))
				uninstallState = .failed(error, String(describing: error))
				objectWillChange.send()
			}
		}
	}

	private func executeHDPIMUninstall(_ request: HDPIMUninstallHelperRequest) async throws {
		let outputState = InstallManager.InstallOutputState()
		let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]

		do {
			try await HelperManager.shared.executeHDPIMUninstall(
				request: request,
				userHome: NSHomeDirectory(),
				executablePath: executablePath
			) { [weak self] output in
				InstallManager.consumeHelperOutput(
					output,
					state: outputState,
					progressHandler: { progress, status in
						Task { @MainActor in
							guard let self else { return }
							let snapshot = self.updateUninstallSnapshot(progress: progress, status: status)
							self.uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
						}
					},
					logHandler: { message in
						Task { @MainActor in
							self?.appendUninstallLog(message)
						}
					},
					failureStatusPrefix: String(localized: "卸载失败"),
					includeUnstructuredOutput: false
				)
			}
		} catch {
			InstallManager.consumeHelperOutput(
				"\n",
				state: outputState,
				progressHandler: { progress, status in
					Task { @MainActor in
						let snapshot = self.updateUninstallSnapshot(progress: progress, status: status)
						self.uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
					}
				},
				logHandler: { [weak self] message in
					Task { @MainActor in
						self?.appendUninstallLog(message)
					}
				},
				failureStatusPrefix: String(localized: "卸载失败"),
				includeUnstructuredOutput: false
			)
			if let lastStructuredError = outputState.lastStructuredError {
				throw NSError(
					domain: "HDPIMUninstall",
					code: 1,
					userInfo: [NSLocalizedDescriptionKey: lastStructuredError]
				)
			}
			throw error
		}

		InstallManager.consumeHelperOutput(
			"\n",
			state: outputState,
			progressHandler: { progress, status in
				Task { @MainActor in
					let snapshot = self.updateUninstallSnapshot(progress: progress, status: status)
					self.uninstallState = .installing(progress: snapshot.progress, status: snapshot.status)
				}
			},
			logHandler: { [weak self] message in
				Task { @MainActor in
					self?.appendUninstallLog(message)
				}
			},
			failureStatusPrefix: String(localized: "卸载失败"),
			includeUnstructuredOutput: false
		)

		if let lastStructuredError = outputState.lastStructuredError {
			throw NSError(
				domain: "HDPIMUninstall",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: lastStructuredError]
			)
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
		let prefix = String(localized: "卸载失败")
		if message.hasPrefix(prefix) || message.hasPrefix("卸载失败") {
			return message
		}
		return String(format: String(localized: "卸载失败: %@"), message)
	}

	private func updateInstallationSnapshot(progress: Double, status: String) {
        lastInstallationProgress = progress
        lastInstallationStatus = status

        if status == String(localized: "安装完成") || status == "安装完成" {
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
        let failurePrefix = String(localized: "安装失败")
        if message.hasPrefix(failurePrefix) || message.hasPrefix("安装失败") {
            return message
        }
        return String(format: String(localized: "安装失败: %@"), message)
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

        if message.contains("正在解压 ") || message.contains("正在安装 ") {
            return true
        }

        return false
    }

    private func isProcessingInstallLog(_ message: String) -> Bool {
        message.contains("正在处理:")
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
        return HDPIMDatabase.shared.isProductReallyInstalled(
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
        let totalSpeed = activeTasks.reduce(0.0) { $0 + max($1.totalSpeed, 0) }
        let progress = totalSize > 0 ? Double(downloadedSize) / Double(totalSize) : 0

        DockProgressIndicator.shared.update(
            progress: progress,
            taskCount: activeTasks.count,
            speed: totalSpeed,
            isCompleted: false
        )
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
