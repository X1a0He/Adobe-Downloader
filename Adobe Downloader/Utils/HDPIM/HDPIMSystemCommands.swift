//
//  HDPIMSystemCommands.swift
//  Adobe Downloader
//

import Foundation
import AppKit

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

        let quotedArgs = execution.arguments.map { "\"\($0)\"" }.joined(separator: " ")
        let fullCommand = "\"\(execution.path)\" \(quotedArgs)"

        let result = try await HDPIMCommandExecutor.executeShell(fullCommand)

        if result.hasPrefix("Error:") {
            print("RunProgram '\(execution.path)' 返回: \(result)")
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
