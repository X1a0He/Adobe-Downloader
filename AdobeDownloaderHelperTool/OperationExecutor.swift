import Foundation

final class OperationExecutor {

    static func execute(_ operation: HelperOperation) -> HelperOperationResult {
        switch operation {
        case .installPackage(let packagePath, let targetPath):
            return executeShellCommand("/usr/sbin/installer -pkg \"\(packagePath)\" -target \(targetPath)")

        case .uninstallPath(let path):
            guard SecurityValidator.validatePath(path) else {
                return .failure("路径验证失败: \(path)")
            }
            return removeItem(at: path)

        case .copyFile(let source, let destination):
            guard SecurityValidator.validatePath(source),
                  SecurityValidator.validatePath(destination) else {
                return .failure("路径验证失败")
            }
            return executeShellCommand("/bin/cp -R \"\(source)\" \"\(destination)\"")

        case .setPermissions(let path, let mode):
            guard SecurityValidator.validatePath(path) else {
                return .failure("路径验证失败: \(path)")
            }
            return executeShellCommand("/bin/chmod \(mode) \"\(path)\"")

        case .executeShell(let command):
            return executeShellCommand(command)

        case .triggerTCCPrompt:
            return triggerTCCRegistration()

        case .getVersion:
            let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            return .success(version)

        default:
            return .failure("不支持的操作")
        }
    }

    private static func executeShellCommand(_ command: String) -> HelperOperationResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            let outputCapture = ShellOutputCapture()
            let errorCapture = ShellOutputCapture()
            let readers = DispatchGroup()
            for (pipe, capture) in [(outputPipe, outputCapture), (errorPipe, errorCapture)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    capture.read(pipe.fileHandleForReading)
                    readers.leave()
                }
            }
            process.waitUntilExit()
            readers.wait()

            let output = outputCapture.text
            let errorOutput = errorCapture.text
            if process.terminationStatus == 0 {
                return .success(output.isEmpty ? "Success" : output)
            } else {
                return .failure(errorOutput.isEmpty ? "Unknown error" : errorOutput, exitCode: process.terminationStatus)
            }
        } catch {
            return .failure("执行失败: \(error.localizedDescription)")
        }
    }

    private static func removeItem(at path: String) -> HelperOperationResult {
        let cleanPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))

        guard !isProtectedRemovalRoot(cleanPath) else {
            return .failure("禁止删除共享根目录: \(cleanPath)")
        }

        guard FileManager.default.fileExists(atPath: cleanPath) else {
            return .success("Success")
        }

        do {
            try FileManager.default.removeItem(atPath: cleanPath)
            return .success("Success")
        } catch {
            return .failure("删除失败: \(error.localizedDescription)")
        }
    }

    private static func isProtectedRemovalRoot(_ path: String) -> Bool {
        [
            "/Applications",
            "/Library/Application Support/Adobe",
            "/Library/Application Support",
            "/Library",
            "/tmp",
            "/"
        ].contains(path)
    }

    private static func triggerTCCRegistration() -> HelperOperationResult {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        let protectedPaths = [
            "\(home)/Library/Safari",
            "\(home)/Library/Messages",
            "\(home)/Library/Mail",
            "\(home)/Library/Application Support/com.apple.TCC"
        ]

        for path in protectedPaths where fm.fileExists(atPath: path) {
            _ = try? fm.contentsOfDirectory(atPath: path)
            break
        }

        return .success("triggered")
    }
}

/// 每条输出管道由独立读取任务消费，调用方在 DispatchGroup 完成后读取结果。
private final class ShellOutputCapture {
    private var data = Data()

    func read(_ handle: FileHandle) {
        data = handle.readDataToEndOfFile()
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}
