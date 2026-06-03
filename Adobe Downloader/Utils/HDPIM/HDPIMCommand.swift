//
//  HDPIMCommand.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2026/03/18.
//

import Foundation

protocol HDPIMCommand {
    var commandName: String { get }

    var commandDetails: String? { get }

    func execute() async throws

    func rollBack() async throws

    func getDeleteEntries() -> [HDPIMDeleteEntry]

    func getPimxCommandFragments() -> [HDPIMPimxCommandFragment]
}

extension HDPIMCommand {
    var commandDetails: String? { nil }

    func getDeleteEntries() -> [HDPIMDeleteEntry] { [] }

    func getPimxCommandFragments() -> [HDPIMPimxCommandFragment] { [] }
}

enum HDPIMCommandError: Int, Error, LocalizedError {
    case success = 0
    case pimxInvalid = 3
    case fileNotFound = 7
    case targetConflict = 9
    case moveFileFailed = 10
    case copyFileFailed = 11
    case createDirectoryFailed = 15
    case getPermissionFailed = 17
    case setPermissionFailed = 18
    case getOwnerFailed = 19
    case setOwnerFailed = 20
    case createSymlinkFailed = 21
    case setDisplayAttributesFailed = 35
    case runProgramFailed = 38
    case fileLockedByProcess = 39
    case registerApplicationFailed = 41
    case patchFailed = 58
    case conflictingProcess = 131
    case xmlHashMismatch = 134
    case backupFailed = 198

    var errorDescription: String? {
        "HDPIM 命令错误 (\(rawValue)): \(description)"
    }

    var description: String {
        switch self {
        case .success: return "成功"
        case .pimxInvalid: return "PIMX 无效/损坏"
        case .fileNotFound: return "文件未找到"
        case .targetConflict: return "目标路径冲突"
        case .moveFileFailed: return "无法移动文件"
        case .copyFileFailed: return "无法复制文件"
        case .createDirectoryFailed: return "创建目录失败"
        case .getPermissionFailed: return "无法获取权限"
        case .setPermissionFailed: return "无法设置权限"
        case .getOwnerFailed: return "无法获取所有者"
        case .setOwnerFailed: return "无法设置所有者"
        case .createSymlinkFailed: return "无法创建符号链接"
        case .setDisplayAttributesFailed: return "无法设置显示属性"
        case .runProgramFailed: return "程序运行失败"
        case .fileLockedByProcess: return "文件被进程锁定"
        case .registerApplicationFailed: return "注册应用失败"
        case .patchFailed: return "补丁应用失败"
        case .conflictingProcess: return "冲突进程运行中"
        case .xmlHashMismatch: return "XML 哈希校验失败"
        case .backupFailed: return "备份失败"
        }
    }

    var isFatal: Bool {
        self != .success
    }
}

enum HDPIMCommandExecutor {
    private static var useLocalExecution: Bool {
        ProcessInfo.processInfo.environment[HDPIMHeadlessInstallRunner.localExecutionEnvironmentKey] == "1"
    }

    static func executeShell(_ command: String) async throws -> String {
        if useLocalExecution {
            return try await executeLocalShell(command)
        }

        return try await HelperManager.shared.executeShell(command)
    }

    static func executeShellChecked(
        _ command: String,
        onError error: HDPIMCommandError = .moveFileFailed
    ) async throws {
        let result = try await executeShell(command)
        if result.hasPrefix("Error:") {
            print("[HDPIM] Shell 命令失败: \(command)")
            print("[HDPIM] 错误输出: \(result)")
            throw error
        }
    }

    static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func executeLocalShell(_ command: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", command]
                task.standardOutput = stdout
                task.standardError = stderr

                do {
                    try task.run()
                    task.waitUntilExit()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                    if task.terminationStatus == 0 {
                        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: result.isEmpty ? "Success" : result)
                    } else {
                        let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: "Error: Command failed with exit code \(task.terminationStatus): \(message)")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

class HDPIMCommandEngine {

    private let propertyTable: HDPIMPropertyTable

    init(propertyTable: HDPIMPropertyTable) {
        self.propertyTable = propertyTable
    }

    func generateCommands(from descriptors: [PIMXCommandDescriptor]) -> [HDPIMCommand] {
        descriptors.compactMap { descriptor -> HDPIMCommand? in
            switch descriptor {
            case .moveFile(let source, let target, let pimxTarget):
                return MoveFileCommand(source: source, target: target, pimxTargetPath: pimxTarget)
            case .mergeDirectory(let source, let target, let pimxTarget):
                return MergeDirectoryCommand(source: source, target: target, pimxTargetPath: pimxTarget)
            case .copyFile(let source, let target, let pimxTarget):
                return CopyFileCommand(source: source, target: target, pimxTargetPath: pimxTarget)
            case .blindCopy(let source, let target, let pimxTarget):
                return BlindCopyCommand(source: source, target: target, pimxTargetPath: pimxTarget)
            case .createDirectory(let path, let pimxPath):
                return CreateDirectoryCommand(path: path, pimxPath: pimxPath)
            case .deleteFile(let target):
                return DeleteFileCommand(target: target)
            case .deleteDirectory(let source):
                return DeleteDirectoryCommand(source: source)
            case .createSymlink(let source, let target, let pimxTarget):
                return CreateSymlinkCommand(source: source, target: target, pimxTargetPath: pimxTarget)
            case .permission(let path, let mode):
                return ChmodCommand(path: path, mode: mode)
            case .owner(let path, let uid, let gid):
                return ChownerCommand(path: path, uid: uid, gid: gid)
            case .runProgram(let execution, let repair, let uninstall):
                return RunProgramCommand(execution: execution, repair: repair, uninstall: uninstall)
            case .registerApplication(let path):
                return RegisterApplicationCommand(path: path)
            case .setDisplayAttributes(let target, let icon):
                return SetDisplayAttributesCommand(target: target, icon: icon)
            case .touch(let path):
                return TouchCommand(path: path)
            case .folderIcon(let folderPath, let iconPath):
                return SetDisplayAttributesCommand(target: folderPath, icon: iconPath)
            }
        }
    }

    func executeAll(
        commands: [HDPIMCommand],
        progressHandler: ((Int, Int, String) -> Void)? = nil
    ) async throws -> (
        executedCommands: [HDPIMCommand],
        deleteEntries: [HDPIMDeleteEntry],
        pimxFragments: [HDPIMPimxCommandFragment]
    ) {
        var executed: [HDPIMCommand] = []
        var deleteEntries: [HDPIMDeleteEntry] = []
        var pimxFragments: [HDPIMPimxCommandFragment] = []

        for (index, command) in commands.enumerated() {
            progressHandler?(index, commands.count, command.commandName)
            let heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { break }
                    let detail = command.commandDetails ?? command.commandName
                    progressHandler?(index, commands.count, "\(command.commandName) 正在处理: \(detail)")
                }
            }

            do {
                try await command.execute()
                heartbeatTask.cancel()
                executed.append(command)
                deleteEntries.append(contentsOf: command.getDeleteEntries())
                pimxFragments.append(contentsOf: command.getPimxCommandFragments())
            } catch {
                heartbeatTask.cancel()
                let cmdError = error as? HDPIMCommandError

                if cmdError?.isFatal ?? true {
                    throw HDPIMInstallError.commandFailed(
                        command: command.commandName,
                        error: error,
                        executedCommands: executed,
                        deleteEntries: deleteEntries,
                        pimxFragments: pimxFragments
                    )
                } else {
                    print("命令 '\(command.commandName)' 执行失败 (非致命): \(error.localizedDescription)")
                }
            }
        }

        return (executed, deleteEntries, pimxFragments)
    }
}

enum HDPIMInstallError: Error, LocalizedError {
    case commandFailed(
        command: String,
        error: Error,
        executedCommands: [HDPIMCommand],
        deleteEntries: [HDPIMDeleteEntry],
        pimxFragments: [HDPIMPimxCommandFragment]
    )
    case extractionFailed(String)
    case pimxNotFound(String)
    case packageNameMismatch(expected: String, actual: String)
    case rollbackFailed(String)
    case databaseError(String)
    case cancelled
    case conflictingProcessDetected([String])
    case hostValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let err, _, _, _):
            return "安装命令 '\(cmd)' 执行失败: \(err.localizedDescription)"
        case .extractionFailed(let msg): return "解压失败: \(msg)"
        case .pimxNotFound(let path): return "PIMX 文件不存在: \(path)"
        case .packageNameMismatch(let expected, let actual):
            return "包名不匹配: 期望 \(expected), 实际 \(actual)"
        case .rollbackFailed(let msg): return "回滚失败: \(msg)"
        case .databaseError(let msg): return "数据库错误: \(msg)"
        case .cancelled: return "安装已取消"
        case .conflictingProcessDetected(let processes):
            return "检测到冲突进程正在运行: \(processes.joined(separator: ", "))，请关闭后重试"
        case .hostValidationFailed(let msg):
            return msg
        }
    }
}

class TouchCommand: HDPIMCommand {
    let path: String
    var commandName: String { "Touch" }

    init(path: String) {
        self.path = path
    }

    func execute() async throws {
        _ = try await HDPIMCommandExecutor.executeShell("touch \"\(path)\"")
    }

    func rollBack() async throws {  }
}
