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
            guard !cancellationState.isCancelled else {
                throw CancellationError()
            }

            let progressHandler: (Double, String) -> Void = { progress, status in
                emit("PROGRESS|\(progress)|\(sanitize(status))")
            }

            progressHandler(0.02, "正在准备 HDPIM 卸载流程")
            switch request.target {
            case .product:
                try await HDPIMUninstaller.uninstall(
                    sapCode: request.sapCode,
                    version: request.version,
                    processorFamily: request.resolvedProcessorFamily,
                    progressHandler: progressHandler
                )
            case .module:
                try await HDPIMUninstaller.uninstallModules(
                    sapCode: request.sapCode,
                    version: request.version,
                    processorFamily: request.resolvedProcessorFamily,
                    moduleIds: Set(request.moduleIds),
                    progressHandler: progressHandler
                )
            case .packages:
                try await HDPIMUninstaller.uninstallPackages(
                    sapCode: request.sapCode,
                    version: request.version,
                    processorFamily: request.resolvedProcessorFamily,
                    packageKeys: Set(request.packageKeys.map {
                        HDPIMPackageUninstallKey(
                            packageName: $0.packageName,
                            packageVersion: $0.packageVersion
                        )
                    }),
                    progressHandler: progressHandler
                )
            }
            progressHandler(1.0, "卸载完成")
        }
    }

    private static func runOperation(_ operation: @escaping (HDPIMHeadlessCancellationState) async throws -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        let cancellationState = HDPIMHeadlessCancellationState(cancelFileURL: cancelFileURL())
        let signalSources = installCancellationSignalHandlers(cancellationState)
        var exitCode: Int32 = 0
        defer {
            signalSources.forEach { $0.cancel() }
        }

        Task.detached(priority: .userInitiated) {
            do {
                try await operation(cancellationState)
                emit("RESULT|SUCCESS")
            } catch {
                emit("ERROR|\(sanitize(error.localizedDescription))")
                exitCode = 1
            }

            semaphore.signal()
        }

        semaphore.wait()
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
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
