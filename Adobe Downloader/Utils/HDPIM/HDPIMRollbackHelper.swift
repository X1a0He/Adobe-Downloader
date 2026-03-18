//
//  HDPIMRollbackHelper.swift
//  Adobe Downloader
//

import Foundation

class HDPIMRollbackHelper {

    static func rollback(
        executedCommands: [HDPIMCommand],
        backupManager: HDPIMBackupManager
    ) async {
        for command in executedCommands.reversed() {
            do {
                try await command.rollBack()
            } catch {
                print("Warning: 回滚命令 '\(command.commandName)' 失败: \(error.localizedDescription)")
            }
        }

        if backupManager.hasBackups {
            do {
                try await backupManager.restoreAll()
            } catch {
                print("Warning: 恢复备份失败: \(error.localizedDescription)")
            }
        }
    }

    static func executeUninstallPIMX(
        at pimxURL: URL,
        propertyTable: HDPIMPropertyTable
    ) async throws {
        let parser = PIMXParser(propertyTable: propertyTable)
        let packageInfo = try parser.parse(pimxURL: pimxURL, extractDir: URL(fileURLWithPath: "/"))

        let engine = HDPIMCommandEngine(propertyTable: propertyTable)
        let commands = engine.generateCommands(from: packageInfo.commands)

        for command in commands {
            do {
                try await command.execute()
            } catch {
                print("Warning: 卸载命令 '\(command.commandName)' 失败: \(error.localizedDescription)")
            }
        }
    }
}
