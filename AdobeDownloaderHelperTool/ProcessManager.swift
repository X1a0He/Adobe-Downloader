import Foundation
import Darwin

final class ProcessManager {
    static let shared = ProcessManager()

    private struct RunningOperation {
        let id: UUID
        let process: Process
        let directory: URL
        let cancelFileURL: URL
        let output: FileHandle
    }

    private var running: RunningOperation?
    private var terminalResults: [UUID: HDPIMInstallProgress] = [:]
    private var terminalOrder: [UUID] = []
    private let queue = DispatchQueue(label: "com.helper.process")

    init() {}

    func startHDPIMInstall(productDir: String, userHome: String, executablePath: String?) throws -> UUID {
        try startHDPIMProcess(arguments: ["--hdpim-install", productDir], userHome: userHome, executablePath: executablePath)
    }

    func startHDPIMUninstall(request: HDPIMUninstallHelperRequest, userHome: String, executablePath: String?) throws -> UUID {
        let requestData = try JSONEncoder().encode(request)
        return try startHDPIMProcess(arguments: ["--hdpim-uninstall", requestData.base64EncodedString()], userHome: userHome,
                                    executablePath: executablePath)
    }

    private func startHDPIMProcess(arguments: [String], userHome: String, executablePath: String?) throws -> UUID {
        let executableURL = try executablePath.map { URL(fileURLWithPath: $0) } ?? locateMainAppExecutable()
        return try queue.sync {
            finishExitedOperation()
            guard running == nil else {
                throw NSError(domain: "ProcessManager", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "上一安装或卸载操作尚未完成收尾"
                ])
            }
            let id = UUID()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adobe-hdpim-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let logURL = directory.appendingPathComponent("output.log")
            let descriptor = open(logURL.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? writer.close() }
            let reader = try FileHandle(forReadingFrom: logURL)
            let cancelURL = directory.appendingPathComponent("cancel")
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = createEnvironment(userHome: userHome, cancelFileURL: cancelURL)
            // 共用文件偏移保留 stdout/stderr 的写出顺序，终态不再与管道回调争抢剩余输出。
            process.standardOutput = writer
            process.standardError = writer
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.finishExitedOperation(expectedID: id) }
            }
            running = RunningOperation(id: id, process: process, directory: directory, cancelFileURL: cancelURL, output: reader)
            do {
                try process.run()
            } catch {
                running = nil
                try? reader.close()
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            return id
        }
    }

    func getProgress(operationID: UUID?) -> HDPIMInstallProgress {
        queue.sync {
            finishExitedOperation()
            guard let operationID else { return missingOperationProgress() }
            if let terminal = terminalResults[operationID] { return terminal }
            guard let operation = running, operation.id == operationID else { return missingOperationProgress() }
            return HDPIMInstallProgress(output: readOutput(operation.output), isComplete: false, exitCode: nil)
        }
    }

    func cancel(operationID: UUID?) {
        queue.sync {
            guard let operationID, let operation = running, operation.id == operationID else { return }
            try? Data([1]).write(to: operation.cancelFileURL, options: .atomic)
            if operation.process.isRunning { operation.process.terminate() }
        }
    }

    private func finishExitedOperation(expectedID: UUID? = nil) {
        guard let operation = running, expectedID == nil || expectedID == operation.id,
              !operation.process.isRunning else { return }
        terminalResults[operation.id] = HDPIMInstallProgress(output: readOutput(operation.output), isComplete: true,
                                                           exitCode: operation.process.terminationStatus)
        terminalOrder.append(operation.id)
        while terminalOrder.count > 32 { terminalResults.removeValue(forKey: terminalOrder.removeFirst()) }
        try? operation.output.close()
        try? FileManager.default.removeItem(at: operation.directory)
        running = nil
    }

    private func readOutput(_ handle: FileHandle) -> String {
        do { return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self) }
        catch { return "LOG|读取安装输出失败：\(error.localizedDescription)\n" }
    }

    private func missingOperationProgress() -> HDPIMInstallProgress {
        HDPIMInstallProgress(output: "ERROR|安装操作不存在或终态已过期，请核对安装状态后重试\n", isComplete: true, exitCode: 1)
    }

    private func createEnvironment(userHome: String, cancelFileURL: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ADOBE_DOWNLOADER_LOCAL_INSTALL"] = "1"
        env["ADOBE_DOWNLOADER_USER_HOME"] = userHome
        env["ADOBE_DOWNLOADER_CANCEL_FILE"] = cancelFileURL.path
        // 安装进程保持自己的身份；用户路径仅通过显式安装上下文传递。
        if let account = getpwuid(geteuid()) {
            env["HOME"] = String(cString: account.pointee.pw_dir)
            env["USER"] = String(cString: account.pointee.pw_name)
            env["LOGNAME"] = env["USER"]
        }
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
