//
//  HDPIMSystemCommands.swift
//  Adobe Downloader
//

import Foundation
import AppKit

private func shellQuotedSystemCommand(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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

    var lines = ["<UninstallCommand runInUserMode=\"\(invocation.runInUserMode)\">"]
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
    lines.append("            <InstallCommand runInUserMode=\"\(invocation.runInUserMode)\">")
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

        try HDPIMRepairResources.validatePersistentReferences(in: execution)

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
            let user = try HDPIMUserExecutionContext.resolve()
            if geteuid() == 0 {
                result = try await executeAsUser(user: user, path: executablePath, arguments: execution.arguments)
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
        user: HDPIMUserExecutionContext,
        path: String,
        arguments: [String]
    ) async throws -> HDPIMShellExecutionResult {
        try await HDPIMProcessRunner.run(
            executable: "/bin/launchctl",
            arguments: ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-H", "-u", user.name, "--",
                        "/usr/bin/env", "HOME=\(user.home)", "USER=\(user.name)", "LOGNAME=\(user.name)",
                        path] + arguments
        )
    }

    private func executeDirectly(path: String, arguments: [String]) async throws -> HDPIMShellExecutionResult {
        try await HDPIMProcessRunner.run(executable: path, arguments: arguments)
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
        try await HDPIMProcessRunner.run(executable: "/bin/sh", arguments: ["-c", command])
    }

    func rollBack() async throws {
        guard execution != nil else { return }
        guard let uninstall else {
            throw HDPIMInstallError.rollbackFailed("RunProgram 未声明恢复动作：\(execution?.path ?? "")")
        }
        try await RunProgramCommand(execution: uninstall, repair: nil, uninstall: nil).execute()
    }

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
    private var didSetIcon = false
    var commandName: String { "SetDisplayAttributes" }

    init(target: String, icon: String) {
        self.target = target
        self.icon = icon
    }

    func execute() async throws {
        didSetIcon = false
        let targetURL = URL(fileURLWithPath: target)
        let iconURL = URL(fileURLWithPath: icon)

        guard FileManager.default.fileExists(atPath: icon) else {
            print("图标文件不存在: \(icon)")
            return
        }

        if let image = NSImage(contentsOf: iconURL) {
            didSetIcon = NSWorkspace.shared.setIcon(image, forFile: targetURL.path)
        }
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didSetIcon else { return [] }
        let path = URL(fileURLWithPath: target).appendingPathComponent("Icon\r").path
        return [HDPIMDeleteEntry(targetPath: path, isDirectory: false,
                                isRecursiveDelete: false, isUserPreferences: false, actualTargetPath: path)]
    }
}
