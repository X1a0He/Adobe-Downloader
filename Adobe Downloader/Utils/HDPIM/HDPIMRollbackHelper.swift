//
//  HDPIMRollbackHelper.swift
//  Adobe Downloader
//

import Foundation

class HDPIMRollbackHelper {

	struct UninstallPIMXPlan {
		let commands: [HDPIMCommand]
	}

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

        HDPIMUserOwnershipFixer.restoreUserOwnership(logHandler: { print("[HDPIM Rollback] \($0)") })
    }

	static func executeUninstallPIMX(
		at pimxURL: URL,
		propertyTable: HDPIMPropertyTable,
		estimatedWorkSize: Int64 = 0,
		progressHandler: ((Int64, String) -> Void)? = nil
	) async throws {
		let plan = try makeUninstallPIMXPlan(at: pimxURL, propertyTable: propertyTable)
		try await executeUninstallPIMXPlan(
			plan,
			estimatedWorkSize: estimatedWorkSize,
			progressHandler: progressHandler
		)
	}

	static func makeUninstallPIMXPlan(
		at pimxURL: URL,
		propertyTable: HDPIMPropertyTable
	) throws -> UninstallPIMXPlan {
		let parser = PIMXParser(propertyTable: propertyTable)
		let descriptors = try parser.parseUninstallCommands(pimxURL: pimxURL)
		let engine = HDPIMCommandEngine(propertyTable: propertyTable)
		let commands = engine.generateCommands(from: descriptors)
		return UninstallPIMXPlan(commands: commands)
	}

	static func executeUninstallPIMXPlan(
		_ plan: UninstallPIMXPlan,
		estimatedWorkSize: Int64 = 0,
		progressHandler: ((Int64, String) -> Void)? = nil
	) async throws {
		let commands = plan.commands
		let totalWork = max(estimatedWorkSize, 0)
		let chunkSize: Int64 = 2 * 1024 * 1024
		let commandCount = max(commands.count, 1)
		var reportedBytes: Int64 = 0

		func reportProgress(for commandIndex: Int, detail: String) {
			guard totalWork > 0 else {
				return
			}

			let rawTarget = Int64((Double(commandIndex) / Double(commandCount)) * Double(totalWork))
			let roundedTarget = min(totalWork, (rawTarget / chunkSize) * chunkSize)
			if roundedTarget > reportedBytes {
				reportedBytes = roundedTarget
				progressHandler?(reportedBytes, detail)
			}

			if commandIndex >= commandCount, reportedBytes < totalWork {
				reportedBytes = totalWork
				progressHandler?(reportedBytes, detail)
			}
		}

		for (index, command) in commands.enumerated() {
			let commandIndex = index + 1
			let detail = progressDetail(for: command, index: commandIndex, total: commands.count)
			if totalWork > 0 {
				progressHandler?(reportedBytes, detail)
			}
			do {
				try await command.execute()
				reportProgress(for: commandIndex, detail: detail)
			} catch {
				throw HDPIMInstallError.commandFailed(
					command: command.commandName,
					error: error,
					executedCommands: [],
					deleteEntries: [],
					pimxFragments: []
				)
			}
		}
	}

	private static func progressDetail(for command: HDPIMCommand, index: Int, total: Int) -> String {
		let prefix = "\(command.commandName) (\(index)/\(max(total, 1)))"
		guard let detail = command.commandDetails?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !detail.isEmpty else {
			return prefix
		}
		return "\(prefix): \(summarizedCommandDetail(detail))"
	}

	private static func summarizedCommandDetail(_ detail: String) -> String {
		let maxLength = 140
		guard detail.count > maxLength else {
			return detail
		}

		if detail.contains(" -> ") {
			let parts = detail.components(separatedBy: " -> ")
			if parts.count == 2 {
				let sideLength = (maxLength - 4) / 2
				return "\(summarizedPath(parts[0], maxLength: sideLength)) -> \(summarizedPath(parts[1], maxLength: sideLength))"
			}
		}

		return summarizedPath(detail, maxLength: maxLength)
	}

	private static func summarizedPath(_ path: String, maxLength: Int) -> String {
		guard path.count > maxLength else {
			return path
		}

		let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
		if components.count >= 4 {
			let tail = components.suffix(4).joined(separator: "/")
			let prefix = path.hasPrefix("/") ? "/.../" : ".../"
			let summary = prefix + tail
			if summary.count <= maxLength {
				return summary
			}
		}

		return "..." + path.suffix(max(maxLength - 3, 0))
	}
}
