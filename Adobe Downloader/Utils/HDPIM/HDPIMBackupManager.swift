//
//  Adobe Downloader
//  HDPIMBackupManager.swift
//
//  Created by X1a0He on 2026/03/17.
//

import Foundation
class HDPIMBackupManager {
    private let backupRoot: URL
    private var backupMap: [(original: URL, backup: URL)] = []

    private let sessionId: String

    init() {
        self.sessionId = UUID().uuidString
        let appSupport = URL(fileURLWithPath: HDPIMRuntimeEnvironment.userHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.backupRoot = appSupport
            .appendingPathComponent("Adobe Downloader")
            .appendingPathComponent("Backups")
            .appendingPathComponent(sessionId)
    }

    func backupDirectories(
        _ directories: [URL],
        progressHandler: ((Int, Int, URL) -> Void)? = nil,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        let existingDirs = directories.filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !existingDirs.isEmpty else { return }

        _ = try await HDPIMCommandExecutor.executeShell("mkdir -p \"\(backupRoot.path)\"")

        for (index, dir) in existingDirs.enumerated() {
            progressHandler?(index, existingDirs.count, dir)
            logHandler?("[HDPIM Backup] 开始备份 (\(index + 1)/\(existingDirs.count)): \(dir.path)")
            let backupDest = backupRoot.appendingPathComponent(dir.lastPathComponent + "_\(UUID().uuidString.prefix(8))")

            let result = try await HDPIMCommandExecutor.executeShell(
                "cp -R \"\(dir.path)\" \"\(backupDest.path)\""
            )

            if result.hasPrefix("Error:") {
                throw HDPIMCommandError.backupFailed
            }

            backupMap.append((original: dir, backup: backupDest))
            logHandler?("[HDPIM Backup] 备份完成 (\(index + 1)/\(existingDirs.count)): \(dir.path)")
        }
    }

    func restoreAll() async throws {
        for entry in backupMap.reversed() {
            if FileManager.default.fileExists(atPath: entry.original.path) {
                _ = try? await HDPIMCommandExecutor.executeShell("rm -rf \"\(entry.original.path)\"")
            }

            let result = try await HDPIMCommandExecutor.executeShell(
                "cp -R \"\(entry.backup.path)\" \"\(entry.original.path)\""
            )

            if result.hasPrefix("Error:") {
                print("恢复备份失败: \(entry.original.path) ← \(entry.backup.path)")
            }
        }
    }

    func cleanup() async throws {
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            _ = try? await HDPIMCommandExecutor.executeShell("rm -rf \"\(backupRoot.path)\"")
        }
        backupMap.removeAll()
    }

    var hasBackups: Bool {
        !backupMap.isEmpty
    }
}
