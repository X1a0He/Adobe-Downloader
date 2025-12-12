//
//  ModifySetup.swift
//  Adobe Downloader
//
//  Created by X1a0He on 11/5/24.
//

import Foundation
import SwiftUI

class ModifySetup {
    private static var cachedVersion: String?

    static func isSetupExists() -> Bool {
        return FileManager.default.fileExists(atPath: "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup")
    }

    static func isSetupBackup() -> Bool {
        return isSetupExists() && FileManager.default.fileExists(atPath: "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup.original")
    }

    static func checkComponentVersion() -> String {
        let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"

        guard FileManager.default.fileExists(atPath: setupPath) else {
            cachedVersion = nil
            return String(localized: "未找到 Setup 组件")
        }

        if let cachedVersion = cachedVersion {
            return cachedVersion
        }
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: setupPath)) else {
            return "Unknown"
        }

        let versionMarkers = ["Version ", "Adobe Setup Version: "]
        
        for marker in versionMarkers {
            if let markerData = marker.data(using: .utf8),
               let markerRange = data.range(of: markerData) {
                let versionStart = markerRange.upperBound
                let searchRange = versionStart..<min(versionStart + 30, data.count)

                var versionBytes: [UInt8] = []
                for i in searchRange {
                    let byte = data[i]
                    if (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x20 {
                        versionBytes.append(byte)
                    } else if byte == 0x28 {
                        break
                    } else if versionBytes.isEmpty {
                        continue
                    } else { break }
                }
                
                if let version = String(bytes: versionBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                   !version.isEmpty {
                    cachedVersion = version
                    return version
                }
            }
        }
        
        let message = String(localized: "未知 Setup 组件版本号")
        cachedVersion = message
        return message
    }

    static func clearVersionCache() {
        cachedVersion = nil
    }

    static func backupSetupFile(completion: @escaping (Bool) -> Void) {
        let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"
        let backupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup.original"

        if !FileManager.default.fileExists(atPath: setupPath) {
            print("Setup 文件不存在: \(setupPath)")
            completion(false)
            return
        }

        if isSetupBackup() {
            print("检测到备份文件，尝试从备份恢复...")
            PrivilegedHelperAdapter.shared.executeCommand("/bin/cp -f '\(backupPath)' '\(setupPath)'") { result in
                if result.starts(with: "Error:") {
                    print("从备份恢复失败: \(result)")
                }
                completion(!result.starts(with: "Error:"))
            }
        } else {
            PrivilegedHelperAdapter.shared.executeCommand("/bin/cp -f '\(setupPath)' '\(backupPath)'") { result in
                if result.starts(with: "Error:") {
                    print("创建备份失败: \(result)")
                    completion(false)
                    return
                }
                
                if !result.starts(with: "Error:") {
                    if FileManager.default.fileExists(atPath: backupPath) {
                        PrivilegedHelperAdapter.shared.executeCommand("/bin/chmod 644 '\(backupPath)'") { chmodResult in
                            if chmodResult.starts(with: "Error:") {
                                print("设置备份文件权限失败: \(chmodResult)")
                            }
                            completion(true)
                        }
                    } else {
                        print("备份文件创建失败：文件不存在")
                        completion(false)
                    }
                } else {
                    completion(false)
                }
            }
        }
    }

    static func modifySetupFile(completion: @escaping (Bool) -> Void) {
        let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"

        var commands: [String] = []

        let architecture = AppStatics.cpuArchitecture

        if architecture == "Apple Silicon" {
            commands.append("""
            perl -0777pi -e 'BEGIN{$/=\\1e8} s|\\xFF\\x43\\x02\\xD1\\xFA\\x67\\x04\\xA9\\xF8\\x5F\\x05\\xA9\\xF6\\x57\\x06\\xA9\\xF4\\x4F\\x07\\xA9\\xFD\\x7B\\x08\\xA9\\xFD\\x03\\x02\\x91\\xF3\\x03\\x00\\xAA\\x1F\\x20\\x03\\xD5|\\x20\\x00\\x80\\xD2\\xC0\\x03\\x5F\\xD6\\xF8\\x5F\\x05\\xA9\\xF6\\x57\\x06\\xA9\\xF4\\x4F\\x07\\xA9\\xFD\\x7B\\x08\\xA9\\xFD\\x03\\x02\\x91\\xF3\\x03\\x00\\xAA\\x1F\\x20\\x03\\xD5|gs' '\(setupPath)'
            """)
        } else if architecture == "Intel" {
            commands.append("""
            perl -0777pi -e 'BEGIN{$/=\\1e8} s|\\x55\\x48\\x89\\xE5\\x41\\x57\\x41\\x56\\x41\\x55\\x41\\x54\\x53\\x48\\x83\\xEC\\x48\\x48\\x89\\xFB\\x48\\x8B\\x05\\x8B\\x82\\x05\\x00\\x48\\x8B\\x00\\x48\\x89\\x45\\xD0\\x48\\x8D|\\x6A\\x01\\x58\\xC3\\x53\\x50\\x48\\x89\\xFB\\x48\\x8B\\x05\\x70\\xC7\\x03\\x00\\x48\\x8B\\x00\\x48\\x89\\x45\\xF0\\xE8\\x24\\xD7\\xFE\\xFF\\x48\\x83\\xC3\\x08\\x48\\x39\\xD8\\x0F|gs' '\(setupPath)'
            """)
        }
        
        commands.append(contentsOf: [
            "codesign --remove-signature '\(setupPath)'",
            "codesign -f -s - --timestamp=none --all-architectures --deep '\(setupPath)'",
            "xattr -cr '\(setupPath)'"
        ])

        func executeNextCommand(_ index: Int) {
            guard index < commands.count else {
                let modified = isSetupModified()
                completion(modified)
                return
            }

            PrivilegedHelperAdapter.shared.executeCommand(commands[index]) { result in
                if result.starts(with: "Error:") {
                    print("命令执行失败: \(commands[index])")
                    print("错误信息: \(result)")
                    completion(false)
                    return
                }
                executeNextCommand(index + 1)
            }
        }

        executeNextCommand(0)
    }

    static func backupAndModifySetupFile(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !isSetupExists() {
                DispatchQueue.main.async {
                    completion(false, String(localized: "未找到 Setup 组件"))
                }
                return
            }

            backupSetupFile { backupSuccess in
                if !backupSuccess {
                    DispatchQueue.main.async {
                        completion(false, String(localized: "备份 Setup 组件失败"))
                    }
                    return
                }

                modifySetupFile { modifySuccess in
                    DispatchQueue.main.async {
                        if modifySuccess {
                            completion(true, String(localized: "所有操作已成功完成"))
                        } else {
                            completion(false, String(localized: "修改 Setup 组件失败"))
                        }
                    }
                }
            }
        }
    }

    static func isSetupModified() -> Bool {
        let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"
        guard FileManager.default.fileExists(atPath: setupPath) else { return false }
        
        let intelPattern = Data([
            0x55, 0x48, 0x89, 0xE5, 0x41, 0x57, 0x41, 0x56,
            0x41, 0x55, 0x41, 0x54, 0x53, 0x48, 0x83, 0xEC,
            0x48, 0x48, 0x89, 0xFB, 0x48, 0x8B, 0x05, 0x8B,
            0x82, 0x05, 0x00, 0x48, 0x8B, 0x00, 0x48, 0x89,
            0x45, 0xD0, 0x48, 0x8D
        ])

        let armPattern = Data([
            0xFF, 0x43, 0x02, 0xD1, 0xFA, 0x67, 0x04, 0xA9,
            0xF8, 0x5F, 0x05, 0xA9, 0xF6, 0x57, 0x06, 0xA9,
            0xF4, 0x4F, 0x07, 0xA9, 0xFD, 0x7B, 0x08, 0xA9,
            0xFD, 0x03, 0x02, 0x91, 0xF3, 0x03, 0x00, 0xAA,
            0x1F, 0x20, 0x03, 0xD5
        ])

        do {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: setupPath))
            let architecture = AppStatics.cpuArchitecture

            if architecture == "Apple Silicon" {
                return fileData.range(of: armPattern) == nil
            } else if architecture == "Intel" {
                return fileData.range(of: intelPattern) == nil
            } else {
                return false;
            }
        } catch {
            print("Error reading Setup file: \(error)")
            return false
        }
    }
}
