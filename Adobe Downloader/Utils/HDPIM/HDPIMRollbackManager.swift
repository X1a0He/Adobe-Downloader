//
//  HDPIMRollbackManager.swift
//  Adobe Downloader
//

import Foundation

struct HDPIMSnapshot: Codable {
    let sessionId: String
    let timestamp: Date
    let installedFiles: [String]
    let databaseState: [String: Any]?
    let backupPath: URL

    enum CodingKeys: String, CodingKey {
        case sessionId, timestamp, installedFiles, backupPath
    }

    init(sessionId: String, timestamp: Date, installedFiles: [String], databaseState: [String: Any]?, backupPath: URL) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.installedFiles = installedFiles
        self.databaseState = databaseState
        self.backupPath = backupPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        installedFiles = try container.decode([String].self, forKey: .installedFiles)
        databaseState = nil
        backupPath = try container.decode(URL.self, forKey: .backupPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(installedFiles, forKey: .installedFiles)
        try container.encode(backupPath, forKey: .backupPath)
    }
}

class HDPIMRollbackManager {
    private let snapshotRoot: URL
    private var currentSnapshot: HDPIMSnapshot?
    private let backupManager: HDPIMBackupManager

    init(backupManager: HDPIMBackupManager) {
        self.backupManager = backupManager
        let appSupport = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Adobe Downloader/Snapshots")
        self.snapshotRoot = appSupport
    }

    func createSnapshot(
        targetDirs: [URL],
        sapCode: String,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        let sessionId = UUID().uuidString
        let timestamp = Date()
        let snapshotDir = snapshotRoot.appendingPathComponent(sessionId)

        try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        logHandler?("[Snapshot] 创建快照: \(sessionId)")

        let existingFiles = targetDirs.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.path }

        let dbState = try? captureDatabaseState(sapCode: sapCode)

        let snapshot = HDPIMSnapshot(
            sessionId: sessionId,
            timestamp: timestamp,
            installedFiles: existingFiles,
            databaseState: dbState,
            backupPath: snapshotDir
        )

        let snapshotFile = snapshotDir.appendingPathComponent("snapshot.json")
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFile)

        currentSnapshot = snapshot
        logHandler?("[Snapshot] 快照创建完成")
    }

    func rollback(
        executedCommands: [HDPIMCommand],
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        guard let snapshot = currentSnapshot else {
            throw NSError(domain: "HDPIMRollback", code: -1, userInfo: [NSLocalizedDescriptionKey: "No snapshot available"])
        }

        logHandler?("[Rollback] 开始回滚: \(snapshot.sessionId)")

        for command in executedCommands.reversed() {
            do {
                try await command.rollBack()
            } catch {
                logHandler?("[Rollback] 命令回滚失败: \(command.commandName)")
            }
        }

        if backupManager.hasBackups {
            try await backupManager.restoreAll()
            logHandler?("[Rollback] 文件恢复完成")
        }

        logHandler?("[Rollback] 回滚完成")
    }

    func verify(logHandler: ((String) -> Void)? = nil) async -> Bool {
        guard let snapshot = currentSnapshot else { return false }

        logHandler?("[Verify] 验证回滚结果")

        var allRestored = true
        for filePath in snapshot.installedFiles {
            if !FileManager.default.fileExists(atPath: filePath) {
                logHandler?("[Verify] 文件未恢复: \(filePath)")
                allRestored = false
            }
        }

        return allRestored
    }

    func cleanupSnapshot() async throws {
        guard let snapshot = currentSnapshot else { return }

        try? FileManager.default.removeItem(at: snapshot.backupPath)
        try? await backupManager.cleanup()
        currentSnapshot = nil
    }

    private func captureDatabaseState(sapCode: String) throws -> [String: Any] {
        return [
            "sapCode": sapCode,
            "timestamp": Date().timeIntervalSince1970
        ]
    }
}
