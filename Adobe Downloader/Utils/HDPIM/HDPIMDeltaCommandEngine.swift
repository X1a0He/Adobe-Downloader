import Foundation

enum DeltaCommandType {
    case patchFile(source: String, patch: String, target: String, inPlace: Bool)
    case copyFile(source: String, target: String)
    case deleteFile(path: String)
    case createDirectory(path: String)
    case moveFile(source: String, target: String)
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeltaCommandError.diffJsonParseFailed("Invalid JSON")
        }

        var commands: [DeltaCommand] = []
        var index = 0

        if let files = json["files"] as? [[String: Any]] {
            for file in files {
                guard let action = file["action"] as? String else { continue }
                let sourcePath = file["source"] as? String ?? ""
                let targetPath = file["target"] as? String ?? ""
                let patchPath = file["patch"] as? String ?? ""

                let resolvedSource = sourcePath.replacingOccurrences(of: "[INSTALLDIR]", with: installDir)
                let resolvedTarget = targetPath.replacingOccurrences(of: "[INSTALLDIR]", with: installDir)
                let resolvedPatch = patchPath.isEmpty ? "" : extractDir + "/" + patchPath

                switch action.lowercased() {
                case "patch", "patch_file":
                    let inPlace = file["mode"] as? String == "in_place"
                    commands.append(DeltaCommand(
                        type: .patchFile(source: resolvedSource, patch: resolvedPatch, target: resolvedTarget, inPlace: inPlace),
                        index: index
                    ))
                case "copy", "copy_file":
                    commands.append(DeltaCommand(
                        type: .copyFile(source: resolvedSource, target: resolvedTarget),
                        index: index
                    ))
                case "delete", "delete_file":
                    commands.append(DeltaCommand(
                        type: .deleteFile(path: resolvedTarget.isEmpty ? resolvedSource : resolvedTarget),
                        index: index
                    ))
                case "mkdir", "create_directory":
                    commands.append(DeltaCommand(
                        type: .createDirectory(path: resolvedTarget),
                        index: index
                    ))
                case "move", "move_file":
                    commands.append(DeltaCommand(
                        type: .moveFile(source: resolvedSource, target: resolvedTarget),
                        index: index
                    ))
                default:
                    break
                }
                index += 1
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

        for cmd in otherCommands {
            try executeCommand(cmd)
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
        switch cmd.type {
        case .patchFile(let source, let patch, let target, let inPlace):
            try executePatch(source: source, patch: patch, target: target, inPlace: inPlace)

        case .copyFile(let source, let target):
            let targetDir = (target as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.copyItem(atPath: source, toPath: target)

        case .deleteFile(let path):
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }

        case .createDirectory(let path):
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        case .moveFile(let source, let target):
            let targetDir = (target as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.moveItem(atPath: source, toPath: target)
        }
    }

    private func executePatch(source: String, patch: String, target: String, inPlace: Bool) throws {
        guard FileManager.default.fileExists(atPath: source) else {
            throw DeltaCommandError.patchFailed("Source file not found: \(source)")
        }
        guard FileManager.default.fileExists(atPath: patch) else {
            throw DeltaCommandError.patchFailed("Patch file not found: \(patch)")
        }

        if inPlace {
            try patcher.applyPatch(sourceFile: source, outputFile: source, patchFile: patch)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("delta_patch_\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent((source as NSString).lastPathComponent).path

            try FileManager.default.copyItem(atPath: source, toPath: tempFile)
            try patcher.applyPatch(sourceFile: tempFile, outputFile: tempFile, patchFile: patch)

            let targetDir = (target as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.moveItem(atPath: tempFile, toPath: target)
            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}
