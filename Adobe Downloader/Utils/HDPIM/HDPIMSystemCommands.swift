//
//  HDPIMSystemCommands.swift
//  Adobe Downloader
//

import Foundation
import AppKit

private func shellQuotedSystemCommand(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func userNameForHDPIMRunProgram() -> String? {
    guard let userHome = ProcessInfo.processInfo.environment[HDPIMHeadlessInstallRunner.userHomeEnvironmentKey],
          !userHome.isEmpty else {
        return nil
    }

    let userName = URL(fileURLWithPath: userHome).lastPathComponent
    return userName.isEmpty ? nil : userName
}

private func uidForUserName(_ userName: String) -> uid_t? {
    guard let record = getpwnam(userName) else {
        return nil
    }
    return record.pointee.pw_uid
}

private func xmlEscapedPIMXValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func resolvedPIMXInvocationValues(
    _ invocation: PIMXProgramInvocation,
    workflowType: String? = nil
) -> (path: String, arguments: [String]) {
    let path = workflowType == nil
        ? invocation.pimxPath
        : invocation.pimxPath.replacingOccurrences(of: "[workflowType]", with: workflowType!)
    let arguments = invocation.pimxArguments.map {
        workflowType == nil
            ? $0
            : $0.replacingOccurrences(of: "[workflowType]", with: workflowType!)
    }
    return (path, arguments)
}

private func renderUninstallFragment(_ invocation: PIMXProgramInvocation) -> String {
    let values = resolvedPIMXInvocationValues(invocation)

    var lines = ["<UninstallCommand>"]
    lines.append("            <Path>\(xmlEscapedPIMXValue(values.path))</Path>")
    if !values.arguments.isEmpty {
        lines.append("            <Arguments>")
        lines.append(contentsOf: values.arguments.map { "                <Argument>\(xmlEscapedPIMXValue($0))</Argument>" })
        lines.append("            </Arguments>")
    }
    if invocation.hasExplicitSuccessExitCodes {
        lines.append("            <SuccessExitCodes>")
        lines.append(contentsOf: invocation.successExitCodes.map { "                <ExitCode>\($0)</ExitCode>" })
        lines.append("            </SuccessExitCodes>")
    }
    lines.append("        </UninstallCommand>")
    return lines.joined(separator: "\n")
}

private func renderRepairFragment(_ invocation: PIMXProgramInvocation) -> String {
    let workflowType = "install"
    let path = invocation.path.replacingOccurrences(of: "[workflowType]", with: workflowType)
    let arguments = invocation.arguments.map {
        $0.replacingOccurrences(of: "[workflowType]", with: workflowType)
    }

    var lines = ["<RunProgram>"]
    lines.append("            <InstallCommand>")
    lines.append("                <Path>\(xmlEscapedPIMXValue(path))</Path>")
    if !arguments.isEmpty {
        lines.append("                <Arguments>")
        lines.append(contentsOf: arguments.map { "                    <Argument>\(xmlEscapedPIMXValue($0))</Argument>" })
        lines.append("                </Arguments>")
    }
    if invocation.hasExplicitSuccessExitCodes {
        lines.append("                <SuccessExitCodes>")
        lines.append(contentsOf: invocation.successExitCodes.map { "                    <ExitCode>\($0)</ExitCode>" })
        lines.append("                </SuccessExitCodes>")
    }
    lines.append("            </InstallCommand>")
    lines.append("        </RunProgram>")
    return lines.joined(separator: "\n")
}

class RunProgramCommand: HDPIMCommand {
    let execution: PIMXProgramInvocation?
    let repair: PIMXProgramInvocation?
    let uninstall: PIMXProgramInvocation?
    var commandName: String { "RunProgram" }
    var commandDetails: String? { execution?.path ?? repair?.pimxPath ?? uninstall?.pimxPath }

    init(
        execution: PIMXProgramInvocation?,
        repair: PIMXProgramInvocation?,
        uninstall: PIMXProgramInvocation?
    ) {
        self.execution = execution
        self.repair = repair
        self.uninstall = uninstall
    }

    func execute() async throws {
        guard let execution else {
            return
        }

        var executablePath = execution.path
        if !FileManager.default.fileExists(atPath: executablePath) {
            if let stagingFolder = ProcessInfo.processInfo.environment[HDPIMHeadlessInstallRunner.stagingFolderEnvironmentKey] {
                let pathComponents = (executablePath as NSString).pathComponents
                if let commonIndex = pathComponents.firstIndex(where: { $0 == "Adobe" }),
                   commonIndex > 0 {
                    let relativeComponents = Array(pathComponents[commonIndex...])
                    let stagingPath = (stagingFolder as NSString).appendingPathComponent(relativeComponents.joined(separator: "/"))
                    if FileManager.default.fileExists(atPath: stagingPath) {
                        executablePath = stagingPath
                        print("[RunProgram] 路径调整: \(execution.path) → \(executablePath)")
                    }
                }
            }
        }

        guard FileManager.default.fileExists(atPath: executablePath) else {
            print("RunProgram '\(executablePath)' 不存在")
            throw HDPIMCommandError.runProgramFailed
        }

        try ensureExecutablePermissions(executablePath)

        print("[RunProgram] 路径: \(executablePath)")
        print("[RunProgram] 参数: \(execution.arguments)")
        print("[RunProgram] runInUserMode: \(execution.runInUserMode)")

        let result: HDPIMShellExecutionResult
        if execution.runInUserMode {
            print("[RunProgram] 使用直接执行模式（用户态）")
            if getuid() == 0,
               let userName = userNameForHDPIMRunProgram(),
               let uid = uidForUserName(userName) {
                result = try await executeAsUser(
                    userName: userName,
                    uid: uid,
                    path: executablePath,
                    arguments: execution.arguments
                )
            } else {
                result = try await executeDirectly(path: executablePath, arguments: execution.arguments)
            }
        } else {
            print("[RunProgram] 使用 Helper 执行模式（root 权限）")
            let fullCommand = ([executablePath] + execution.arguments)
                .map(shellQuotedSystemCommand)
                .joined(separator: " ")
            result = try await HDPIMCommandExecutor.executeShellResult(fullCommand)
        }

        if execution.successExitCodes.contains(result.exitCode) {
            if !result.output.isEmpty {
                print("RunProgram '\(executablePath)' 返回: \(result.output)")
            }
            return
        }

        let isOptionalPrefsManager = executablePath.contains("PrefsManager")
        if isOptionalPrefsManager && (result.exitCode == 1 || result.exitCode == 126) {
            print("⚠️ [RunProgram] PrefsManager 执行失败(exitCode=\(result.exitCode))，但继续安装（可能是首选项迁移工具）")
            return
        }

        print("RunProgram '\(executablePath)' 失败: exitCode=\(result.exitCode), output=\(result.output)")
        throw HDPIMCommandError.runProgramFailed
    }

    private func executeAsUser(
        userName: String,
        uid: uid_t,
        path: String,
        arguments: [String]
    ) async throws -> HDPIMShellExecutionResult {
        let fullCommand = ([path] + arguments)
            .map(shellQuotedSystemCommand)
            .joined(separator: " ")
        let command = "/bin/launchctl asuser \(uid) /usr/bin/sudo -u \(shellQuotedSystemCommand(userName)) \(fullCommand)"
        return try await HDPIMCommandExecutor.executeShellResult(command)
    }

    private func executeDirectly(path: String, arguments: [String]) async throws -> HDPIMShellExecutionResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                task.launchPath = path
                task.arguments = arguments
                task.standardOutput = stdout
                task.standardError = stderr
                task.environment = ProcessInfo.processInfo.environment

                do {
                    task.launch()
                    task.waitUntilExit()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    let resultOutput = [output, errorOutput]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: HDPIMShellExecutionResult(
                        output: resultOutput,
                        exitCode: task.terminationStatus
                    ))
                } catch {
                    print("[RunProgram] 执行失败: \(path)")
                    print("[RunProgram] 错误描述: \(error.localizedDescription)")
                    if let nsError = error as NSError? {
                        print("[RunProgram] 错误域: \(nsError.domain)")
                        print("[RunProgram] 错误码: \(nsError.code)")
                        print("[RunProgram] 错误信息: \(nsError.userInfo)")
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureExecutablePermissions(_ path: String) throws {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            print("[RunProgram] 无法获取文件权限: \(path)")
            return
        }

        let currentMode = statInfo.st_mode
        let isExecutable = (currentMode & S_IXUSR) != 0

        if !isExecutable {
            print("[RunProgram] 文件缺少可执行权限，正在设置: \(path)")
            let newMode = currentMode | S_IXUSR | S_IXGRP | S_IXOTH
            if chmod(path, newMode) != 0 {
                print("[RunProgram] ⚠️ 设置可执行权限失败: \(path)")
            } else {
                print("[RunProgram] ✓ 已设置可执行权限")
            }
        }
    }

    private func executeViaShell(command: String) async throws -> HDPIMShellExecutionResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                task.launchPath = "/bin/sh"
                task.arguments = ["-c", command]
                task.standardOutput = stdout
                task.standardError = stderr

                task.launch()
                task.waitUntilExit()

                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                let resultOutput = [output, errorOutput]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: HDPIMShellExecutionResult(
                    output: resultOutput,
                    exitCode: task.terminationStatus
                ))
            }
        }
    }

    func rollBack() async throws { }

    func getPimxCommandFragments() -> [HDPIMPimxCommandFragment] {
        var fragments: [HDPIMPimxCommandFragment] = []

        if let uninstall {
            fragments.append(
                HDPIMPimxCommandFragment(
                    xml: renderUninstallFragment(uninstall),
                    kind: .uninstall
                )
            )
        }

        if let repair {
            fragments.append(
                HDPIMPimxCommandFragment(
                    xml: renderRepairFragment(repair),
                    kind: .repair
                )
            )
        }

        return fragments
    }
}

class RegisterApplicationCommand: HDPIMCommand {
    let path: String
    var commandName: String { "RegisterApplication" }

    init(path: String) {
        self.path = path
    }

    func execute() async throws {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

        if FileManager.default.fileExists(atPath: lsregister) {
            _ = try await HDPIMCommandExecutor.executeShell("\"\(lsregister)\" -f \"\(path)\"")
        } else {
            _ = try? await HDPIMCommandExecutor.executeShell("open -R \"\(path)\" 2>/dev/null")
        }
    }

    func rollBack() async throws { }
}

class SetDisplayAttributesCommand: HDPIMCommand {
    let target: String
    let icon: String
    var commandName: String { "SetDisplayAttributes" }

    init(target: String, icon: String) {
        self.target = target
        self.icon = icon
    }

    func execute() async throws {
        let targetURL = URL(fileURLWithPath: target)
        let iconURL = URL(fileURLWithPath: icon)

        guard FileManager.default.fileExists(atPath: icon) else {
            print("图标文件不存在: \(icon)")
            return
        }

        if let image = NSImage(contentsOf: iconURL) {
            NSWorkspace.shared.setIcon(image, forFile: targetURL.path)
        }
    }

    func rollBack() async throws { }
}
