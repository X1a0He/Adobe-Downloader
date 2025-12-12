//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
/*
    Adobe Exit Code
    107: 架构不一致或安装文件被损坏
    103: 权限问题
    182: 表示创建的包不包含要安装的包
    133: 磁盘空间不足
 */
import Foundation

actor InstallManager {
    enum InstallError: Error, LocalizedError {
        case setupNotFound
        case installationFailed(String)
        case cancelled
        case permissionDenied
        case installationFailedWithDetails(String, String)
        
        var errorDescription: String? {
            switch self {
                case .setupNotFound: return String(localized: "找不到安装程序")
                case .installationFailed(let message): return message
                case .cancelled: return String(localized: "安装已取消")
                case .permissionDenied: return String(localized: "权限被拒绝")
                case .installationFailedWithDetails(let message, _): return message
            }
        }
    }
    
    private var installationProcess: Process?
    private var progressHandler: ((Double, String) -> Void)?
    private let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"
    
    private func terminateSetupProcesses() async {
        let _ = await withCheckedContinuation { continuation in
            PrivilegedHelperAdapter.shared.executeCommand("pkill -f Setup") { result in
                continuation.resume(returning: result)
            }
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    
    actor InstallationState {
        var isCompleted = false
        var error: Error?
        var hasExitCode0 = false
        var lastOutputTime = Date()
        
        func markCompleted() {
            isCompleted = true
        }
        
        func setError(_ error: Error) {
            if !isCompleted {
                self.error = error
                isCompleted = true
            }
        }
        
        func setExitCode0() {
            hasExitCode0 = true
        }
        
        func updateLastOutputTime() {
            lastOutputTime = Date()
        }
        
        func getTimeSinceLastOutput() -> TimeInterval {
            return Date().timeIntervalSince(lastOutputTime)
        }
        
        var shouldContinue: Bool {
            !isCompleted
        }
        
        var hasReceivedExitCode0: Bool {
            hasExitCode0
        }
    }
    
    private func getAdobeInstallLogDetails() async -> String? {
        let logPath = "/Library/Logs/Adobe/Installers/Install.log"
        guard FileManager.default.fileExists(atPath: logPath) else {
            return nil
        }
        
        do {
            let logContent = try String(contentsOfFile: logPath, encoding: .utf8)
            let lines = logContent.components(separatedBy: .newlines)

            let fatalLines = lines.filter { 
                line in line.contains("FATAL:") 
            }

            var uniqueLines: [String] = []
            var seen = Set<String>()
            
            for line in fatalLines {
                if !seen.contains(line) {
                    seen.insert(line)
                    uniqueLines.append(line)
                }
            }

            if uniqueLines.isEmpty, lines.count > 10 {
                uniqueLines = Array(lines.suffix(10))
            }

            if !uniqueLines.isEmpty {
                return uniqueLines.joined(separator: "\n")
            }
            
            return nil
        } catch {
            print("读取安装日志失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func executeInstallation(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void,
        allowAutoFixX1a0HeCC: Bool = true
    ) async throws {
        guard FileManager.default.fileExists(atPath: setupPath) else {
            throw InstallError.setupNotFound
        }

        let driverPath = appPath.appendingPathComponent("driver.xml").path
        guard FileManager.default.fileExists(atPath: driverPath) else {
            throw InstallError.installationFailed("找不到 driver.xml 文件")
        }
        
        let attributes = try? FileManager.default.attributesOfItem(atPath: driverPath)
        if let permissions = attributes?[.posixPermissions] as? NSNumber {
            if permissions.int16Value & 0o444 == 0 {
                throw InstallError.installationFailed("driver.xml 文件没有读取权限")
            }
        }
        
        await MainActor.run {
            progressHandler(0.0, String(localized: "正在清理安装环境..."))
        }
        
        await terminateSetupProcesses()

        let logFiles = [
            "/Library/Logs/Adobe/Installers/Install.log",
        ]
        
        for logFile in logFiles {
            let removeCommand = "rm -f '\(logFile)'"
            let result = await withCheckedContinuation { continuation in
                PrivilegedHelperAdapter.shared.executeCommand(removeCommand) { result in
                    continuation.resume(returning: result)
                }
            }
            
            if result.contains("Error") {
                print("清理安装日志失败: \(logFile) - \(result)")
            }
        }

        let installCommand = "sudo \"\(setupPath)\" --install=1 --driverXML=\"\(driverPath)\""
        
        await MainActor.run {
            progressHandler(0.0, String(localized: "正在准备安装..."))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached {
                do {
                    try await PrivilegedHelperAdapter.shared.executeInstallation(installCommand) { output in
                        Task {
                            await self.handleInstallationOutput(
                                output: output,
                                appPath: appPath,
                                allowAutoFixX1a0HeCC: allowAutoFixX1a0HeCC,
                                progressHandler: progressHandler,
                                continuation: continuation
                            )
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func handleInstallationOutput(
        output: String,
        appPath: URL,
        allowAutoFixX1a0HeCC: Bool,
        progressHandler: @escaping (Double, String) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) async {
        if let range = output.range(of: "Exit Code:\\s*(-?[0-9]+)", options: .regularExpression),
           let codeStr = output[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           let exitCode = Int(codeStr) {
            
            if exitCode == 0 {
                await MainActor.run {
                    progressHandler(1.0, String(localized: "安装完成"))
                }
                PrivilegedHelperAdapter.shared.executeCommand("pkill -f Setup") { _ in }
                continuation.resume()
                return
            } else if exitCode == 255 && allowAutoFixX1a0HeCC {
                // 检测到错误代码 255，尝试自动重新下载并处理 X1a0He CC，然后重新安装一次
                Task.detached {
                    do {
                        try await self.handleExitCode255AndRetry(
                            at: appPath,
                            progressHandler: progressHandler
                        )
                        continuation.resume()
                    } catch {
                        let finalError: Error

                        if let installError = error as? InstallError {
                            switch installError {
                            case .installationFailedWithDetails(let message, let details):
                                // 仅当第二次安装仍然是 255 时追加提示文案，其它错误保持不变
                                if message.contains("错误代码(255)") {
                                    let newMessage = String(
                                        localized: "\(message)；已尝试重新下载并处理 X1a0He CC"
                                    )
                                    finalError = InstallError.installationFailedWithDetails(newMessage, details)
                                } else {
                                    finalError = installError
                                }
                            case .installationFailed(let message):
                                if message.contains("错误代码(255)") {
                                    let newMessage = String(
                                        localized: "\(message)；已尝试重新下载并处理 X1a0He CC"
                                    )
                                    finalError = InstallError.installationFailed(newMessage)
                                } else {
                                    finalError = installError
                                }
                            default:
                                finalError = installError
                            }
                        } else {
                            finalError = error
                        }
                        
                        continuation.resume(throwing: finalError)
                    }
                }
                return
            } else {
                let errorMessage = String(localized: "错误代码(\(exitCode))，请查看日志详情并向开发者汇报")
                if let logDetails = await self.getAdobeInstallLogDetails() {
                    continuation.resume(throwing: InstallError.installationFailedWithDetails(errorMessage, logDetails))
                } else {
                    continuation.resume(throwing: InstallError.installationFailed(errorMessage))
                }
                return
            }
        }
        
        if let progress = await self.parseProgress(from: output) {
            await MainActor.run {
                progressHandler(progress, String(localized: "正在安装..."))
            }
        }
    }
    
    private func handleExitCode255AndRetry(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        await MainActor.run {
            progressHandler(0.0, String(localized: "检测到安装错误代码(255)，正在重新下载并处理 X1a0He CC..."))
        }
        
        try await globalNewDownloadUtils.downloadX1a0HeCCPackages(
            progressHandler: { progress, status in
                Task { @MainActor in
                    // 将下载进度映射到安装进度的 0%~80%
                    let combinedProgress = 0.8 * progress
                    progressHandler(combinedProgress, status)
                }
            },
            cancellationHandler: { false },
            shouldProcess: true
        )
        
        await MainActor.run {
            progressHandler(0.9, String(localized: "X1a0He CC 处理完成，正在重新尝试安装..."))
        }
        
        try await executeInstallation(
            at: appPath,
            progressHandler: progressHandler,
            allowAutoFixX1a0HeCC: false
        )
    }
	    
    private func parseProgress(from output: String) -> Double? {
        if let range = output.range(of: "Exit Code:\\s*(-?[0-9]+)", options: .regularExpression),
           let codeStr = output[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           let exitCode = Int(codeStr) {
            if exitCode == 0 {
                return 1.0
            }
        }
        
        if output.range(of: "Progress:\\s*[0-9]+/[0-9]+", options: .regularExpression) != nil {
            return nil
        }
        
        if let range = output.range(of: "Progress:\\s*([0-9]{1,3})%", options: .regularExpression),
           let progressStr = output[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           let progressValue = Double(progressStr.replacingOccurrences(of: "%", with: "")) {
            return progressValue / 100.0
        }
        return nil
    }
    
    func install(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        try await executeInstallation(
            at: appPath,
            progressHandler: progressHandler
        )
    }
    
    func cancel() {
        PrivilegedHelperAdapter.shared.executeCommand("pkill -f Setup") { _ in }
    }

    func getInstallCommand(for driverPath: String) -> String {
        return "sudo \"\(setupPath)\" --install=1 --driverXML=\"\(driverPath)\""
    }

    func retry(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        cancel()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        try await executeInstallation(
            at: appPath,
            progressHandler: progressHandler
        )
    }
}
