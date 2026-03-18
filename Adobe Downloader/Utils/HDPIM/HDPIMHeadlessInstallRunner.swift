import Foundation
import Darwin

enum HDPIMHeadlessInstallRunner {
    static let installArgument = "--hdpim-install"
    static let localExecutionEnvironmentKey = "ADOBE_DOWNLOADER_LOCAL_INSTALL"
    static let userHomeEnvironmentKey = "ADOBE_DOWNLOADER_USER_HOME"

    static var isActive: Bool {
        productDirectoryPath() != nil
    }

    static func runIfNeeded() {
        guard let productDir = productDirectoryPath() else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task.detached(priority: .userInitiated) {
            let pipeline = HDPIMInstallPipeline()

            do {
                try await pipeline.install(
                    productDir: URL(fileURLWithPath: productDir, isDirectory: true),
                    progressHandler: { progress, status in
                        emit("PROGRESS|\(progress)|\(sanitize(status))")
                    },
                    logHandler: { message in
                        emit("LOG|\(sanitize(message))")
                    },
                    cancellationCheck: nil
                )
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

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
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
