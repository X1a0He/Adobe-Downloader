import Foundation
import Darwin

enum DeltaCommandType {
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

    private let patcher = HDBSPatch()
    private let maxConcurrency = 3

    func generateCommands(from diffJsonURL: URL, installDir: String, extractDir: String) throws -> [DeltaCommand] {
        let data = try Data(contentsOf: diffJsonURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        let entries = try resolveEntries(from: jsonObject)

        var commands: [DeltaCommand] = []

        for (index, entry) in entries.enumerated() {
            if boolValue(entry["ignoreAsset"]) {
                continue
            }

            let action = stringValue(entry["deltaAction"]).uppercased()
            let legacyAction = stringValue(entry["action"]).uppercased()
            let deltaAction = action.isEmpty ? legacyAction : action
            if deltaAction.isEmpty {
                continue
            }

            let sourcePath = resolveSourcePath(stringValue(entry["source"]), extractDir: extractDir, installDir: installDir)
            let destinationPath = resolveInstallPath(stringValue(entry["destination"]).isEmpty ? stringValue(entry["target"]) : stringValue(entry["destination"]), installDir: installDir)
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
                        index: index
                    )
                )

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
                continue
            }
        }

        return commands
    }

    func executeCommands(_ commands: [DeltaCommand], progressHandler: ((Double) -> Void)? = nil) async throws {
        let totalCount = commands.count
        guard totalCount > 0 else { return }

        let patchCommands = commands.filter {
            if case .patchFile = $0.type { return true }
            return false
        }
        let otherCommands = commands.filter {
            if case .patchFile = $0.type { return false }
            return true
        }

        for (index, cmd) in otherCommands.enumerated() {
            try executeCommand(cmd)
            progressHandler?(Double(index + 1) / Double(totalCount))
        }

        var completedCount = otherCommands.count

        try await withThrowingTaskGroup(of: Void.self) { group in
            var active = 0
            var patchIndex = 0

            while patchIndex < patchCommands.count || active > 0 {
                while patchIndex < patchCommands.count && active < maxConcurrency {
                    let cmd = patchCommands[patchIndex]
                    patchIndex += 1
                    active += 1

                    group.addTask { [self] in
                        try self.executeCommand(cmd)
                    }
                }

                try await group.next()
                active -= 1
                completedCount += 1
                progressHandler?(Double(completedCount) / Double(totalCount))
            }
        }
    }

    private func executeCommand(_ cmd: DeltaCommand) throws {
        do {
            switch cmd.type {
            case .patchFile(let patch, let target):
                try executePatch(patch: patch, target: target)

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
        } catch let error as DeltaCommandError {
            throw error
        } catch {
            throw DeltaCommandError.commandFailed(cmd.index, error.localizedDescription)
        }
    }

    private func executePatch(patch: String, target: String) throws {
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
        for localizedName in localeMap.values {
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

    private func resolveInstallPath(_ rawPath: String, installDir: String) -> String {
        guard !rawPath.isEmpty else { return "" }

        let replaced = rawPath
            .replacingOccurrences(of: "[INSTALLDIR]", with: installDir)
            .replacingOccurrences(of: "[InstallDir]", with: installDir)

        if replaced.hasPrefix("/") {
            return URL(fileURLWithPath: replaced).standardizedFileURL.path
        }

        return URL(fileURLWithPath: replaced, relativeTo: URL(fileURLWithPath: installDir)).standardizedFileURL.path
    }

    private func resolveSourcePath(_ rawPath: String, extractDir: String, installDir: String) -> String {
        guard !rawPath.isEmpty else { return "" }

        let normalized = rawPath
            .replacingOccurrences(of: "[INSTALLDIR]", with: installDir)
            .replacingOccurrences(of: "[InstallDir]", with: installDir)

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
