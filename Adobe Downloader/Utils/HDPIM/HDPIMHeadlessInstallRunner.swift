import Foundation
import Darwin

enum HDPIMHeadlessInstallRunner {
    static let installArgument = "--hdpim-install"
    static let uninstallArgument = "--hdpim-uninstall"
    static let localExecutionEnvironmentKey = "ADOBE_DOWNLOADER_LOCAL_INSTALL"
    static let userHomeEnvironmentKey = "ADOBE_DOWNLOADER_USER_HOME"
    static let cancelFileEnvironmentKey = "ADOBE_DOWNLOADER_CANCEL_FILE"
    static let stagingFolderEnvironmentKey = "ADOBE_DOWNLOADER_STAGING_FOLDER"

    static var isActive: Bool {
        productDirectoryPath() != nil || uninstallRequest() != nil
    }

    static func runIfNeeded() {
        if let productDir = productDirectoryPath() {
            runInstall(productDir: productDir)
            return
        }

        if let request = uninstallRequest() {
            runUninstall(request: request)
        }
    }

    private static func runInstall(productDir: String) {
        runOperation { cancellationState in
            let pipeline = HDPIMInstallPipeline()

            try await pipeline.install(
                productDir: URL(fileURLWithPath: productDir, isDirectory: true),
                progressHandler: { progress, status in
                    emit("PROGRESS|\(progress)|\(sanitize(status))")
                },
                logHandler: { message in
                    emit("LOG|\(sanitize(message))")
                },
                cancellationCheck: {
                    cancellationState.isCancelled
                }
            )
        }
    }

    private static func runUninstall(request: HDPIMUninstallHelperRequest) {
        runOperation { cancellationState in
            let cancellation = HDPIMOperationCancellation(externalCheck: { cancellationState.isCancelled })
            defer { cancellation.stopMonitoring() }
            try await HDPIMOperationContext.$cancellation.withValue(cancellation) {
                do {
                    if cancellationState.isCancelled { throw CancellationError() }
                    let progress: (Double, String) -> Void = { emit("PROGRESS|\($0)|\(sanitize($1))") }
                    let preserving = request.preservingUserPreferences ?? true
                    let result: HDPIMUninstallResult
                    switch request.target {
                    case .product:
                        result = try await HDPIMUninstaller.uninstall(sapCode: request.sapCode, version: request.version,
                            processorFamily: request.resolvedProcessorFamily, preservingUserPreferences: preserving,
                            progressHandler: progress)
                    case .module:
                        result = try await HDPIMUninstaller.uninstallModules(sapCode: request.sapCode, version: request.version,
                            processorFamily: request.resolvedProcessorFamily, moduleIds: Set(request.moduleIds),
                            preservingUserPreferences: preserving, progressHandler: progress)
                    case .packages:
                        result = try await HDPIMUninstaller.uninstallPackages(sapCode: request.sapCode, version: request.version,
                            processorFamily: request.resolvedProcessorFamily,
                            packageKeys: Set(request.packageKeys.map { .init(packageName: $0.packageName, packageVersion: $0.packageVersion) }),
                            preservingUserPreferences: preserving, progressHandler: progress)
                    }
                    emitUninstallResult(result)
                } catch {
                    let result = (error as? HDPIMUninstallFailure)?.result ?? HDPIMUninstallResult(
                        outcome: error is CancellationError ? .cancelled : .failed, warnings: [],
                        details: error.localizedDescription, recoveryDirectory: nil)
                    emitUninstallResult(result)
                    throw error
                }
            }
        }
    }

    private static func emitUninstallResult(_ result: HDPIMUninstallResult) {
        if let data = try? JSONEncoder().encode(result) { emit("UNINSTALL|\(data.base64EncodedString())") }
    }

    private static func runOperation(_ operation: @escaping (HDPIMHeadlessCancellationState) async throws -> Void) {
        let cancellationState = HDPIMHeadlessCancellationState(cancelFileURL: cancelFileURL())
        let signalSources = installCancellationSignalHandlers(cancellationState)

        Task.detached(priority: .userInitiated) {
            var exitCode: Int32 = 0
            do {
                try await operation(cancellationState)
                emit("RESULT|SUCCESS")
            } catch {
                emit("ERROR|\(sanitize(error.localizedDescription))")
                exitCode = 1
            }

            signalSources.forEach { $0.cancel() }
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(exitCode)
        }

        // 下载配置及系统 API 需要主队列；无界面入口也必须持续排空主队列。
        dispatchMain()
    }

    private static func productDirectoryPath() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: installArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }

    private static func uninstallRequest() -> HDPIMUninstallHelperRequest? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: uninstallArgument),
              arguments.indices.contains(index + 1),
              let data = Data(base64Encoded: arguments[index + 1]) else {
            return nil
        }

        return try? JSONDecoder().decode(HDPIMUninstallHelperRequest.self, from: data)
    }

    private static func cancelFileURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[cancelFileEnvironmentKey],
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private static func installCancellationSignalHandlers(_ state: HDPIMHeadlessCancellationState) -> [DispatchSourceSignal] {
        let signals = [SIGTERM, SIGINT]
        return signals.map { signalNumber in
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler {
                state.markCancelled()
            }
            source.resume()
            return source
        }
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

private final class HDPIMHeadlessCancellationState {
    private let lock = NSLock()
    private let cancelFileURL: URL?
    private var cancelled = false

    init(cancelFileURL: URL?) {
        self.cancelFileURL = cancelFileURL
    }

    var isCancelled: Bool {
        lock.lock()
        let localCancelled = cancelled
        lock.unlock()
        if localCancelled {
            return true
        }
        guard let cancelFileURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: cancelFileURL.path)
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if let cancelFileURL {
            try? Data([1]).write(to: cancelFileURL, options: .atomic)
        }
    }
}

enum HDPIMRuntimeEnvironment {
    static func userHomeDirectory() -> String {
        if let overridden = ProcessInfo.processInfo.environment[HDPIMHeadlessInstallRunner.userHomeEnvironmentKey],
           !overridden.isEmpty {
            return overridden
        }
        return NSHomeDirectory()
    }
}

extension HDPIMUninstallHelperRequest {
    var resolvedProcessorFamily: HDPIMProcessorFamily {
        HDPIMProcessorFamily.from(platform: processorFamily)
    }
}
