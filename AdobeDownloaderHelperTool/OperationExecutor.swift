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
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return .success(output.isEmpty ? "Success" : output)
            } else {
                let message = errorOutput.isEmpty ? "Unknown error" : errorOutput
                return .failure(message, exitCode: process.terminationStatus)
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
}
