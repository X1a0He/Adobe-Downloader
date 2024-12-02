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

        if isSetupBackup() {
            let command = "cp '\(backupPath)' '\(setupPath)'"
            PrivilegedHelperManager.shared.executeCommand(command) { result in
                completion(!result.starts(with: "Error:"))
            }
        } else {
            let command = "cp '\(setupPath)' '\(backupPath)'"
            PrivilegedHelperManager.shared.executeCommand(command) { result in
                completion(!result.starts(with: "Error:"))
            }
        }
    }

    static func modifySetupFile(completion: @escaping (Bool) -> Void) {
        let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"

        let commands = [
            """
            perl -0777pi -e 'BEGIN{$/=\\1e8} s|\\x55\\x48\\x89\\xE5\\x53\\x50\\x48\\x89\\xFB\\x48\\x8B\\x05\\x70\\xC7\\x03\\x00\\x48\\x8B\\x00\\x48\\x89\\x45\\xF0\\xE8\\x24\\xD7\\xFE\\xFF\\x48\\x83\\xC3\\x08\\x48\\x39\\xD8\\x0F|\\x6A\\x01\\x58\\xC3\\x53\\x50\\x48\\x89\\xFB\\x48\\x8B\\x05\\x70\\xC7\\x03\\x00\\x48\\x8B\\x00\\x48\\x89\\x45\\xF0\\xE8\\x24\\xD7\\xFE\\xFF\\x48\\x83\\xC3\\x08\\x48\\x39\\xD8\\x0F|gs' '\(setupPath)'
            """,
            """
            perl -0777pi -e 'BEGIN{$/=\\1e8} s|\\xFF\\xC3\\x00\\xD1\\xF4\\x4F\\x01\\xA9\\xFD\\x7B\\x02\\xA9\\xFD\\x83\\x00\\x91\\xF3\\x03\\x00\\xAA\\x1F\\x20\\x03\\xD5\\x68\\xA1\\x1D\\x58\\x08\\x01\\x40\\xF9\\xE8\\x07\\x00\\xF9|\\x20\\x00\\x80\\xD2\\xC0\\x03\\x5F\\xD6\\xFD\\x7B\\x02\\xA9\\xFD\\x83\\x00\\x91\\xF3\\x03\\x00\\xAA\\x1F\\x20\\x03\\xD5\\x68\\xA1\\x1D\\x58\\x08\\x01\\x40\\xF9\\xE8\\x07\\x00\\xF9|gs' '\(setupPath)'
            """,
            "codesign --remove-signature '\(setupPath)'",
            "codesign -f -s - --timestamp=none --all-architectures --deep '\(setupPath)'",
            "xattr -cr '\(setupPath)'"
        ]

        func executeNextCommand(_ index: Int) {
            guard index < commands.count else {
                completion(true)
                return
            }

            PrivilegedHelperManager.shared.executeCommand(commands[index]) { result in
                if result.starts(with: "Error:") {
                    print("Command failed: \(commands[index])")
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

        let intelPattern = Data([0x55, 0x48, 0x89, 0xE5, 0x53, 0x50, 0x48, 0x89, 0xFB, 0x48, 0x8B, 0x05, 0x70, 0xC7, 0x03, 0x00, 0x48, 0x8B, 0x00, 0x48, 0x89, 0x45, 0xF0, 0xE8, 0x24, 0xD7, 0xFE, 0xFF, 0x48, 0x83, 0xC3, 0x08, 0x48, 0x39, 0xD8, 0x0F])
        
        let armPattern = Data([0xFF, 0xC3, 0x00, 0xD1, 0xF4, 0x4F, 0x01, 0xA9, 0xFD, 0x7B, 0x02, 0xA9, 0xFD, 0x83, 0x00, 0x91, 0xF3, 0x03, 0x00, 0xAA, 0x1F, 0x20, 0x03, 0xD5, 0x68, 0xA1, 0x1D, 0x58, 0x08, 0x01, 0x40, 0xF9, 0xE8, 0x07, 0x00, 0xF9])
        
        do {
            let fileData = try Data(contentsOf: URL(fileURLWithPath: setupPath))
            if fileData.range(of: intelPattern) != nil || fileData.range(of: armPattern) != nil { return false }
            return true
            
        } catch {
            print("Error reading Setup file: \(error)")
            return false
        }
    }
}

