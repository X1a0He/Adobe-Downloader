//
//  HDPIMSystemCommands.swift
//  Adobe Downloader
//

import Foundation
import AppKit

class RunProgramCommand: HDPIMCommand {
    let path: String
    let arguments: [String]
    let successExitCodes: [Int32]
    var commandName: String { "RunProgram" }

    init(path: String, arguments: [String], successExitCodes: [Int32] = [0]) {
        self.path = path
        self.arguments = arguments
        self.successExitCodes = successExitCodes
    }

    func execute() async throws {
        let quotedArgs = arguments.map { "\"\($0)\"" }.joined(separator: " ")
        let fullCommand = "\"\(path)\" \(quotedArgs)"

        let result = try await HDPIMCommandExecutor.executeShell(fullCommand)

        if result.hasPrefix("Error:") {
            print("RunProgram '\(path)' 返回: \(result)")
        }
    }

    func rollBack() async throws { }

    func getReverseCommandXML() -> String? { nil }
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
    func getReverseCommandXML() -> String? { nil }
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
    func getReverseCommandXML() -> String? { nil }
}
