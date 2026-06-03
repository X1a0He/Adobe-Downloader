import Foundation

final class ProcessManager {
    static let shared = ProcessManager()

    private var currentProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = ""
    private let queue = DispatchQueue(label: "com.helper.process")

    private init() {}

    func startHDPIMInstall(
        productDir: String,
        userHome: String,
        executablePath: String?
    ) throws {
        let executableURL: URL
        if let path = executablePath {
            executableURL = URL(fileURLWithPath: path)
        } else {
            executableURL = try locateMainAppExecutable()
        }

        queue.sync {
            cleanup()
        }

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["--hdpim-install", productDir]
        process.environment = createEnvironment(userHome: userHome)
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.handleOutput(handle)
        }

        try process.run()

        queue.sync {
            currentProcess = process
            outputPipe = outPipe
            errorPipe = errPipe
        }
    }

    func getProgress() -> HDPIMInstallProgress {
        queue.sync {
            guard let process = currentProcess else {
                return HDPIMInstallProgress(output: "", isComplete: true, exitCode: nil)
            }

            if !process.isRunning {
                let remaining = drainOutput()
                let exitCode = process.terminationStatus
                let finalOutput = outputBuffer + remaining
                cleanup()
                return HDPIMInstallProgress(
                    output: finalOutput,
                    isComplete: true,
                    exitCode: exitCode
                )
            }

            let output = outputBuffer
            outputBuffer = ""
            return HDPIMInstallProgress(output: output, isComplete: false, exitCode: nil)
        }
    }

    func cancel() {
        queue.sync {
            currentProcess?.terminate()
            cleanup()
        }
    }

    private func handleOutput(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return
        }
        queue.async {
            self.outputBuffer += text
        }
    }

    private func drainOutput() -> String {
        var result = ""
        if let pipe = outputPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                result += text
            }
        }
        if let pipe = errorPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                result += text
            }
        }
        return result
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer = ""
    }

    private func createEnvironment(userHome: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ADOBE_DOWNLOADER_LOCAL_INSTALL"] = "1"
        env["ADOBE_DOWNLOADER_USER_HOME"] = userHome
        env["HOME"] = userHome
        return env
    }

    private func locateMainAppExecutable() throws -> URL {
        let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var cursor = helperURL.deletingLastPathComponent()

        while cursor.path != "/" {
            if cursor.pathExtension == "app",
               let bundle = Bundle(url: cursor),
               let executableURL = bundle.executableURL {
                return executableURL
            }
            cursor.deleteLastPathComponent()
        }

        throw NSError(domain: "ProcessManager", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "无法定位主程序"
        ])
    }
}
