import Foundation
import Darwin
import CryptoKit

enum DeltaCommandType {
    case exists(path: String)
    case patchFile(patch: String, target: String)
    case copyFile(source: String, target: String)
    case deletePath(path: String)
    case createDirectory(path: String)
    case moveFile(source: String, target: String)
    case createSymlink(targetPath: String, linkPath: String)
    case updatePermission(path: String, externalAttributes: UInt32)
    case renameLocalized(destination: String, localeMap: [String: String])
}

struct DeltaCommand {
    let type: DeltaCommandType
    let index: Int
    var oldFileHash: String? = nil
    var oldFilePath: String? = nil
    var newFileHash: String? = nil
}

enum DeltaPreflightError: Error, LocalizedError {
    case invalidBase(String)
    case patchUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidBase(let reason): return "差分旧文件校验失败：\(reason)"
        case .patchUnavailable(let reason): return "差分补丁无法应用：\(reason)"
        }
    }
}

enum DeltaCommandError: Error, LocalizedError {
    case diffJsonParseFailed(String)
    case commandFailed(Int, String)
    case patchFailed(String)

    var errorDescription: String? {
        switch self {
        case .diffJsonParseFailed(let s): return "Failed to parse diff.json: \(s)"
        case .commandFailed(let idx, let s): return "Command \(idx) failed: \(s)"
        case .patchFailed(let s): return "Patch failed: \(s)"
        }
    }
}

final class HDPIMDeltaCommandEngine {

    var propertyTable: HDPIMPropertyTable?
    private let patcher = HDBSPatch()
    private let maxConcurrency = 3

    struct GeneratedPlan {
        let commands: [DeltaCommand]
        let uninstallManifest: [HDPIMDeleteEntry]
        let literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath]
    }

    func generateCommands(from diffJsonURL: URL, installDir: String, extractDir: String) throws -> [DeltaCommand] {
        try generatePlan(from: diffJsonURL, installDir: installDir, extractDir: extractDir).commands
    }

    func generatePlan(from diffJsonURL: URL, installDir: String, extractDir: String) throws -> GeneratedPlan {
        let data = try Data(contentsOf: diffJsonURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        let entries = try resolveEntries(from: jsonObject)

        var commands: [DeltaCommand] = []
        var uninstallManifest: [HDPIMDeleteEntry] = []
        var literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath] = [:]

        for (index, entry) in entries.enumerated() {
            if boolValue(entry["ignoreAsset"]) {
                continue
            }

            let action = stringValue(entry["deltaAction"]).uppercased()
            let legacyAction = stringValue(entry["action"]).uppercased()
            let deltaAction = action.isEmpty ? legacyAction : action
            guard !deltaAction.isEmpty else {
                throw DeltaCommandError.diffJsonParseFailed("缺少 deltaAction，index=\(index)")
            }

            let sourcePath = try resolveSourcePath(stringValue(entry["source"]), extractDir: extractDir, installDir: installDir)
            let rawDestination = stringValue(entry["destination"]).isEmpty
                ? stringValue(entry["target"]) : stringValue(entry["destination"])
            let destinationPath = try resolveInstallPath(rawDestination, installDir: installDir)
            let fileType = stringValue(entry["fileType"]).uppercased()
            let targetLinkPath = stringValue(entry["targetLinkPath"])
            let localeMap = stringDictionary(entry["localeMap"])
            let externalAttributes = parseExternalAttributes(entry["externalAttributes"])
            let isUserPreferences = boolValue(entry["isUserPreferences"])

            switch deltaAction {
            case "PATCH", "PATCH_FILE":
                guard !sourcePath.isEmpty, !destinationPath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("PATCH entry missing source or destination at index \(index)")
                }
                commands.append(
                    DeltaCommand(
                        type: .patchFile(patch: sourcePath, target: destinationPath),
                        index: index,
                        newFileHash: stringValue(entry["hash"])
                    )
                )

            case "EXISTS":
                guard !destinationPath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("EXISTS 缺少 destination，index=\(index)")
                }
                commands.append(DeltaCommand(type: .exists(path: destinationPath), index: index,
                                             oldFileHash: stringValue(entry["hash"])))

            case "ADD", "OVERWRITE", "COPY", "COPY_FILE", "MOVE", "MOVE_FILE":
                guard !destinationPath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("file entry missing destination at index \(index)")
                }
                let resolvedFileType = resolvedFileType(fileType, sourcePath: sourcePath, targetLinkPath: targetLinkPath)
                switch resolvedFileType {
                case "DIRECTORY":
                    commands.append(
                        DeltaCommand(
                            type: .createDirectory(path: destinationPath),
                            index: index
                        )
                    )
                case "SYMLINK":
                    guard !targetLinkPath.isEmpty else {
                        throw DeltaCommandError.diffJsonParseFailed("symlink entry missing targetLinkPath at index \(index)")
                    }
                    commands.append(
                        DeltaCommand(
                            type: .createSymlink(targetPath: targetLinkPath, linkPath: destinationPath),
                            index: index
                        )
                    )
                default:
                    guard !sourcePath.isEmpty else {
                        throw DeltaCommandError.diffJsonParseFailed("file entry missing source at index \(index)")
                    }
                    let commandType: DeltaCommandType
                    if deltaAction == "MOVE" || deltaAction == "MOVE_FILE" || deltaAction == "ADD" || deltaAction == "OVERWRITE" {
                        commandType = .moveFile(source: sourcePath, target: destinationPath)
                    } else {
                        commandType = .copyFile(source: sourcePath, target: destinationPath)
                    }
                    commands.append(DeltaCommand(type: commandType, index: index))
                }

                if let externalAttributes {
                    commands.append(
                        DeltaCommand(
                            type: .updatePermission(path: destinationPath, externalAttributes: externalAttributes),
                            index: index
                        )
                    )
                }

            case "DELETE", "DELETE_FILE":
                if isUserPreferences {
                    continue
                }
                let deletePath = destinationPath.isEmpty ? sourcePath : destinationPath
                guard !deletePath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("DELETE entry missing path at index \(index)")
                }
                commands.append(
                    DeltaCommand(
                        type: .deletePath(path: deletePath),
                        index: index
                    )
                )

            case "UPDATE_PERMISSION":
                guard !destinationPath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("UPDATE_PERMISSION missing destination at index \(index)")
                }
                guard let externalAttributes else {
                    throw DeltaCommandError.diffJsonParseFailed("UPDATE_PERMISSION missing externalAttributes at index \(index)")
                }
                commands.append(
                    DeltaCommand(
                        type: .updatePermission(path: destinationPath, externalAttributes: externalAttributes),
                        index: index
                    )
                )

            case "RENAME_LOCALIZED":
                guard !destinationPath.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("RENAME_LOCALIZED missing destination at index \(index)")
                }
                guard !localeMap.isEmpty else {
                    throw DeltaCommandError.diffJsonParseFailed("RENAME_LOCALIZED missing localeMap at index \(index)")
                }
                commands.append(
                    DeltaCommand(
                        type: .renameLocalized(destination: destinationPath, localeMap: localeMap),
                        index: index
                    )
                )

            default:
                throw DeltaCommandError.diffJsonParseFailed("不支持的 deltaAction=\(deltaAction)，index=\(index)")
            }

            let recordsAsset = ["EXISTS", "PATCH", "PATCH_FILE", "ADD", "OVERWRITE", "COPY", "COPY_FILE", "MOVE", "MOVE_FILE"]
                .contains(deltaAction)
            if recordsAsset && !boolValue(entry["isPermanent"]) {
                let isDirectory = fileType == "DIRECTORY"
                let materialPath = uninstallMaterialPath(rawDestination: rawDestination, actualPath: destinationPath,
                                                        installDir: installDir)
                uninstallManifest.append(HDPIMDeleteEntry(
                    targetPath: materialPath.path, isDirectory: isDirectory,
                    isRecursiveDelete: isDirectory && boolValue(entry["isRecursiveDelete"]),
                    isUserPreferences: isUserPreferences, actualTargetPath: destinationPath
                ))
                if let literal = materialPath.literal {
                    literalPaths[PIMXLiteralPath.Key(actualTarget: destinationPath, targetTemplate: materialPath.path)] = literal
                }
            }
        }

        _ = try HDPIMFileChange.from(commands)
        let payloadRoot = URL(fileURLWithPath: extractDir).resolvingSymlinksInPath().path
        for command in commands {
            let source: String
            switch command.type {
            case .patchFile(let path, _), .copyFile(let path, _), .moveFile(let path, _): source = path
            default: continue
            }
            let resolved = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(payloadRoot + "/") else {
                throw DeltaCommandError.diffJsonParseFailed("差分载荷超出解压目录：\(source)")
            }
        }
        return GeneratedPlan(commands: try resolveLocalizedBases(associateOldFileHashes(commands)),
                             uninstallManifest: uninstallManifest, literalPaths: literalPaths)
    }

    private func uninstallMaterialPath(
        rawDestination: String, actualPath: String, installDir: String
    ) -> (path: String, literal: PIMXLiteralPath?) {
        let template = rawDestination.hasPrefix("/") || rawDestination.hasPrefix("[")
            ? rawDestination : ("[INSTALLDIR]" as NSString).appendingPathComponent(rawDestination)
        guard actualPath.contains("[") || actualPath.contains(":x0D") else { return (template, nil) }

        let context = propertyTable ?? HDPIMPropertyTable()
        context.setInstallDir(installDir)
        context.setProductInstallDir(installDir)
        let firstComponent = template.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if firstComponent.hasPrefix("["), firstComponent.hasSuffix("]") {
            let root = context.expandPath(firstComponent)
            if root.hasPrefix("/"), actualPath.hasPrefix(root + "/") {
                let literal = PIMXLiteralPath(template: firstComponent,
                                              relativePath: String(actualPath.dropFirst(root.count + 1)))
                return (literal.targetPath, literal)
            }
        }

        let components = actualPath.split(separator: "/").map(String.init)
        if let index = components.firstIndex(where: { $0.contains("[") || $0.contains(":x0D") }), index > 0 {
            let literal = PIMXLiteralPath(template: "/" + components[..<index].joined(separator: "/"),
                                          relativePath: components[index...].joined(separator: "/"))
            return (literal.targetPath, literal)
        }
        return (template, nil)
    }

    private func associateOldFileHashes(_ commands: [DeltaCommand]) throws -> [DeltaCommand] {
        var hashes: [String: String] = [:]
        for command in commands {
            guard case .exists(let path) = command.type,
                  let hash = command.oldFileHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !hash.isEmpty else { continue }
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            if let previous = hashes[key], previous != hash {
                throw DeltaCommandError.diffJsonParseFailed("EXISTS 摘要冲突：\(path)")
            }
            hashes[key] = hash
        }
        return commands.map { command in
            guard case .patchFile(_, let target) = command.type,
                  let hash = hashes[URL(fileURLWithPath: target).standardizedFileURL.path] else { return command }
            var result = command
            result.oldFileHash = hash
            return result
        }
    }

    private func resolveLocalizedBases(_ commands: [DeltaCommand]) throws -> [DeltaCommand] {
        var aliases: [(destination: String, source: String)] = []
        for command in commands {
            guard case .renameLocalized(let destination, let localeMap) = command.type,
                  !FileManager.default.fileExists(atPath: destination) else { continue }
            let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
            let candidates = localeMap.keys.sorted().compactMap { localeMap[$0] }.map {
                parent.appendingPathComponent($0).path
            }
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                throw DeltaPreflightError.invalidBase("找不到本地化旧目录：\(destination)")
            }
            aliases.append((destination, source))
        }
        aliases.sort { $0.destination.count > $1.destination.count }
        return commands.map { command in
            var result = command
            let target: String
            switch command.type {
            case .patchFile(_, let path), .exists(let path): target = path
            default: return command
            }
            if let alias = aliases.first(where: { target == $0.destination || target.hasPrefix($0.destination + "/") }) {
                result.oldFilePath = alias.source + target.dropFirst(alias.destination.count)
            } else {
                result.oldFilePath = target
            }
            return result
        }
    }

    func validateBeforeExecution(_ commands: [DeltaCommand]) throws {
        var patchTargets = Set<String>()
        for command in commands {
            try HDPIMOperationContext.checkCancellation()
            switch command.type {
            case .patchFile(let patch, let target):
                guard patchTargets.insert(target).inserted else {
                    throw DeltaCommandError.diffJsonParseFailed("同一目标重复 PATCH：\(target)")
                }
                guard FileManager.default.fileExists(atPath: patch) else {
                    throw DeltaCommandError.diffJsonParseFailed("差分载荷缺失：\(patch)")
                }
                try validateOldFile(command.oldFilePath ?? target, hash: command.oldFileHash, requiresHash: true)
            case .exists(let path):
                try validateOldFile(command.oldFilePath ?? path, hash: command.oldFileHash, requiresHash: false)
            case .copyFile(let source, _), .moveFile(let source, _):
                guard FileManager.default.fileExists(atPath: source) else {
                    throw DeltaCommandError.diffJsonParseFailed("差分新文件缺失：\(source)")
                }
            default:
                break
            }
            if case .copyFile(let source, _) = command.type, let base = command.oldFilePath {
                try validateOldFile(base, hash: command.oldFileHash, requiresHash: true)
                try validateNewFile(source, hash: command.newFileHash)
            }
        }
    }

    func preparePatches(_ commands: [DeltaCommand], in directory: URL) async throws -> [DeltaCommand] {
        try validateBeforeExecution(commands)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let patches = commands.filter { if case .patchFile = $0.type { return true }; return false }
        var prepared: [Int: DeltaCommand] = [:]
        var failed: [DeltaCommand] = []
        func prepare(_ command: DeltaCommand) throws -> DeltaCommand {
            guard case .patchFile(let patch, let target) = command.type else { return command }
            try HDPIMOperationContext.checkCancellation()
            let output = directory.appendingPathComponent(String(command.index)).path
            let source = command.oldFilePath ?? target
            try patcher.applyPatch(sourceFile: source, outputFile: output, patchFile: patch)
            try validateNewFile(output, hash: command.newFileHash)
            guard copyfile(source, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return DeltaCommand(type: .copyFile(source: output, target: target), index: command.index,
                                oldFileHash: command.oldFileHash, oldFilePath: source, newFileHash: command.newFileHash)
        }
        await withTaskGroup(of: (DeltaCommand, DeltaCommand?).self) { group in
            var next = 0
            func enqueue(_ command: DeltaCommand) {
                group.addTask { (command, try? prepare(command)) }
            }
            while next < min(maxConcurrency, patches.count) { enqueue(patches[next]); next += 1 }
            while let (original, result) = await group.next() {
                if let result { prepared[original.index] = result } else { failed.append(original) }
                if Task.isCancelled || HDPIMOperationContext.cancellation?.isCancelled == true {
                    group.cancelAll()
                } else if next < patches.count { enqueue(patches[next]); next += 1 }
            }
        }
        try HDPIMOperationContext.checkCancellation()
        for command in failed.sorted(by: { $0.index < $1.index }) {
            do { prepared[command.index] = try prepare(command) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if case .patchFile(let patch, let target) = command.type {
                    throw DeltaPreflightError.patchUnavailable("\(target)（补丁 \((patch as NSString).lastPathComponent)）：\(error.localizedDescription)")
                }
                throw DeltaPreflightError.patchUnavailable(error.localizedDescription)
            }
        }
        let renames = commands.filter { if case .renameLocalized = $0.type { return true }; return false }
        let others = commands.filter {
            switch $0.type { case .renameLocalized, .patchFile: return false; default: return true }
        }
        return renames + patches.compactMap { prepared[$0.index] } + others
    }

    private func validateOldFile(_ path: String, hash: String?, requiresHash: Bool) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DeltaPreflightError.invalidBase("旧文件不存在：\(path)")
        }
        let expected = (hash ?? "").lowercased()
        if expected.isEmpty && !requiresHash { return }
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw DeltaPreflightError.invalidBase("缺少 SHA-256：\(path)")
        }
        guard try fileHash(path) == expected else {
            throw DeltaPreflightError.invalidBase("SHA-256 不匹配：\(path)")
        }
    }

    private func validateNewFile(_ path: String, hash: String?) throws {
        let expected = (hash ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else { return }
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw DeltaPreflightError.patchUnavailable("补丁结果 SHA-256 格式无效：\(path)")
        }
        guard try fileHash(path) == expected else {
            throw DeltaPreflightError.patchUnavailable("补丁结果 SHA-256 不匹配：\(path)")
        }
    }

    private func fileHash(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try HDPIMOperationContext.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func executeCommands(_ commands: [DeltaCommand], progressHandler: ((Double) -> Void)? = nil) async throws {
        try HDPIMOperationContext.checkCancellation()
        guard !commands.isEmpty else { return }
        let patches = commands.filter { if case .patchFile = $0.type { return true }; return false }
        let others = commands.filter { if case .patchFile = $0.type { return false }; return true }
        var completed = 0
        var failed: [DeltaCommand] = []

        await withTaskGroup(of: (DeltaCommand, Bool).self) { group in
            var next = 0
            func enqueue(_ command: DeltaCommand) {
                group.addTask {
                    do {
                        try self.executeCommand(command)
                        return (command, true)
                    } catch {
                        return (command, false)
                    }
                }
            }
            while next < min(maxConcurrency, patches.count) {
                enqueue(patches[next])
                next += 1
            }
            while let (command, succeeded) = await group.next() {
                completed += 1
                if !succeeded { failed.append(command) }
                progressHandler?(Double(completed) / Double(commands.count))
                if Task.isCancelled || HDPIMOperationContext.cancellation?.isCancelled == true {
                    group.cancelAll()
                } else if next < patches.count {
                    enqueue(patches[next])
                    next += 1
                }
            }
        }
        try HDPIMOperationContext.checkCancellation()
        for command in failed.sorted(by: { $0.index < $1.index }) {
            try executeCommand(command)
        }
        for command in others {
            try executeCommand(command)
            completed += 1
            progressHandler?(Double(completed) / Double(commands.count))
        }
    }

    private func executeCommand(_ cmd: DeltaCommand) throws {
        try HDPIMOperationContext.checkCancellation()
        do {
            switch cmd.type {
            case .exists(let path):
                guard FileManager.default.fileExists(atPath: path) else {
                    throw DeltaPreflightError.invalidBase("旧文件不存在：\(path)")
                }
            case .patchFile(let patch, let target):
                try executePatch(patch: patch, target: target, newFileHash: cmd.newFileHash)

            case .copyFile(let source, let target):
                try ensureParentDirectoryExists(for: target)
                try removeItemIfExists(at: target)
                try copyFilePreservingMetadata(from: source, to: target)

            case .deletePath(let path):
                try removeItemIfExists(at: path)

            case .createDirectory(let path):
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

            case .moveFile(let source, let target):
                try ensureParentDirectoryExists(for: target)
                try removeItemIfExists(at: target)
                do {
                    try FileManager.default.moveItem(atPath: source, toPath: target)
                } catch {
                    try FileManager.default.copyItem(atPath: source, toPath: target)
                    try removeItemIfExists(at: source)
                }

            case .createSymlink(let targetPath, let linkPath):
                try ensureParentDirectoryExists(for: linkPath)
                try removeItemIfExists(at: linkPath)
                try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)

            case .updatePermission(let path, let externalAttributes):
                try updatePermission(at: path, externalAttributes: externalAttributes)

            case .renameLocalized(let destination, let localeMap):
                try executeRenameLocalized(destination: destination, localeMap: localeMap)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeltaCommandError {
            throw error
        } catch {
            throw DeltaCommandError.commandFailed(cmd.index, error.localizedDescription)
        }
    }

    private func executePatch(patch: String, target: String, newFileHash: String?) throws {
        guard FileManager.default.fileExists(atPath: target) else {
            throw DeltaCommandError.patchFailed("Target file not found: \(target)")
        }
        guard FileManager.default.fileExists(atPath: patch) else {
            throw DeltaCommandError.patchFailed("Patch file not found: \(patch)")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delta_patch_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempFile = tempDir.appendingPathComponent((target as NSString).lastPathComponent).path
        try FileManager.default.copyItem(atPath: target, toPath: tempFile)
        try patcher.applyPatch(sourceFile: tempFile, outputFile: tempFile, patchFile: patch)
        try validateNewFile(tempFile, hash: newFileHash)

        try ensureParentDirectoryExists(for: target)
        try removeItemIfExists(at: target)
        try FileManager.default.moveItem(atPath: tempFile, toPath: target)
    }

    private func ensureParentDirectoryExists(for path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    private func removeItemIfExists(at path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            return
        }

        var info = stat()
        if lstat(path, &info) == 0 {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func updatePermission(at path: String, externalAttributes: UInt32) throws {
        let unixMode = (externalAttributes >> 16) & 0xFFFF
        guard unixMode > 1 else { return }

        let permissions = mode_t(unixMode & 0x01FF)
        let isSymlink = (unixMode & 0xF000) == 0xA000
        let result: Int32
        if isSymlink {
            result = lchmod(path, permissions)
        } else {
            result = chmod(path, permissions)
        }

        if result != 0 {
            throw DeltaCommandError.commandFailed(0, "chmod failed for \(path)")
        }
    }

    private func executeRenameLocalized(destination: String, localeMap: [String: String]) throws {
        if FileManager.default.fileExists(atPath: destination) {
            return
        }

        let parent = (destination as NSString).deletingLastPathComponent
        for localizedName in localeMap.keys.sorted().compactMap({ localeMap[$0] }) {
            let candidate = (parent as NSString).appendingPathComponent(localizedName)
            if FileManager.default.fileExists(atPath: candidate) {
                try ensureParentDirectoryExists(for: destination)
                try removeItemIfExists(at: destination)
                try FileManager.default.moveItem(atPath: candidate, toPath: destination)
                return
            }
        }

        throw DeltaCommandError.commandFailed(0, "localized source not found for \(destination)")
    }

    private func resolveEntries(from jsonObject: Any) throws -> [[String: Any]] {
        if let array = jsonObject as? [[String: Any]] {
            return array
        }

        if let object = jsonObject as? [String: Any],
           let files = object["files"] as? [[String: Any]] {
            return files
        }

        throw DeltaCommandError.diffJsonParseFailed("Invalid diff.json root")
    }

    private func resolveInstallPath(_ rawPath: String, installDir: String) throws -> String {
        guard !rawPath.isEmpty else { return "" }

        let context = propertyTable ?? HDPIMPropertyTable()
        context.setInstallDir(installDir)
        context.setProductInstallDir(installDir)
        let replaced = try context.expandPathForInstallation(rawPath)

        if replaced.hasPrefix("/") {
            return URL(fileURLWithPath: replaced).standardizedFileURL.path
        }

        return URL(fileURLWithPath: replaced, relativeTo: URL(fileURLWithPath: installDir)).standardizedFileURL.path
    }

    private func resolveSourcePath(_ rawPath: String, extractDir: String, installDir: String) throws -> String {
        guard !rawPath.isEmpty else { return "" }

        let context = propertyTable ?? HDPIMPropertyTable()
        context.setInstallDir(installDir)
        context.setProductInstallDir(installDir)
        let normalized = try context.expandPathForInstallation(rawPath)

        if normalized.hasPrefix("/") {
            return URL(fileURLWithPath: normalized).standardizedFileURL.path
        }

        return URL(fileURLWithPath: normalized, relativeTo: URL(fileURLWithPath: extractDir)).standardizedFileURL.path
    }

    private func resolvedFileType(_ fileType: String, sourcePath: String, targetLinkPath: String) -> String {
        if !fileType.isEmpty {
            return fileType
        }

        if !targetLinkPath.isEmpty {
            return "SYMLINK"
        }

        var isDirectory: ObjCBool = false
        if !sourcePath.isEmpty && FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue {
            return "DIRECTORY"
        }

        return "FILE"
    }

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSNumber:
            return value.stringValue
        default:
            return ""
        }
    }

    private func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    private func stringDictionary(_ value: Any?) -> [String: String] {
        if let map = value as? [String: String] {
            return map
        }

        if let map = value as? [String: Any] {
            var result: [String: String] = [:]
            for (key, item) in map {
                let normalized = stringValue(item)
                if !normalized.isEmpty {
                    result[key] = normalized
                }
            }
            return result
        }

        return [:]
    }

    private func parseExternalAttributes(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            return number.uint32Value
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            if let decimal = UInt32(trimmed) {
                return decimal
            }
            if trimmed.lowercased().hasPrefix("0x"),
               let hex = UInt32(trimmed.dropFirst(2), radix: 16) {
                return hex
            }
            return nil
        default:
            return nil
        }
    }
}

private func copyFilePreservingMetadata(from source: String, to target: String) throws {
    let result = copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL))
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
