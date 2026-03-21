//
//  HDPIMFileCommands.swift
//  Adobe Downloader
//

import Foundation
import Darwin

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func shouldFallbackToShell(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        return true
    }
    if nsError.domain == NSPOSIXErrorDomain {
        return true
    }
    return false
}

private func removeItemIfExists(at path: String) async throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            print("[HDPIM] FileManager.removeItem 失败: \(path), error: \(error.localizedDescription)")
            guard shouldFallbackToShell(error) else {
                throw error
            }
            try await HDPIMCommandExecutor.executeShellChecked("/bin/rm -rf -- \(shellQuoted(path))", onError: .moveFileFailed)
        }
    }
}

private func ensureParentDirectoryExists(for path: String) async throws {
    let parent = (path as NSString).deletingLastPathComponent
    guard !parent.isEmpty else { return }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw HDPIMCommandError.targetConflict
        }
        return
    }
    do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    } catch {
        print("[HDPIM] FileManager.createDirectory 失败: \(parent), error: \(error.localizedDescription)")
        guard shouldFallbackToShell(error) else {
            throw error
        }
        try await HDPIMCommandExecutor.executeShellChecked("/bin/mkdir -p -- \(shellQuoted(parent))", onError: .createDirectoryFailed)
    }
}

private func ensureDirectoryExists(at path: String) async throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw HDPIMCommandError.targetConflict
        }
        return
    }
    do {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    } catch {
        print("[HDPIM] FileManager.createDirectory 失败: \(path), error: \(error.localizedDescription)")
        guard shouldFallbackToShell(error) else {
            throw error
        }
        try await HDPIMCommandExecutor.executeShellChecked("/bin/mkdir -p -- \(shellQuoted(path))", onError: .createDirectoryFailed)
    }
}

private func copyItemReplacing(source: String, target: String) async throws {
    try await ensureParentDirectoryExists(for: target)
    try await removeItemIfExists(at: target)
    do {
        try FileManager.default.copyItem(atPath: source, toPath: target)
    } catch {
        print("[HDPIM] FileManager.copyItem 失败: \(source) -> \(target), error: \(error.localizedDescription)")
        guard shouldFallbackToShell(error) else {
            throw error
        }
        try await HDPIMCommandExecutor.executeShellChecked("/usr/bin/ditto \(shellQuoted(source)) \(shellQuoted(target))", onError: .copyFileFailed)
    }
}

private func moveItemReplacing(source: String, target: String) async throws {
    try await ensureParentDirectoryExists(for: target)
    try await removeItemIfExists(at: target)

    do {
        try FileManager.default.moveItem(atPath: source, toPath: target)
    } catch {
        print("[HDPIM] FileManager.moveItem 失败: \(source) -> \(target), error: \(error.localizedDescription)")
        guard shouldFallbackToShell(error) else {
            throw error
        }
        try await HDPIMCommandExecutor.executeShellChecked("/bin/mv -f \(shellQuoted(source)) \(shellQuoted(target))", onError: .moveFileFailed)
    }
}

private func isUserPreferencesPath(pimxPath: String, actualPath: String) -> Bool {
    let normalizedPimx = pimxPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedActual = actualPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedPimx.hasPrefix("[userpreferences]/")
        || normalizedPimx.hasPrefix("[usercommon]/")
        || normalizedActual.hasPrefix(NSHomeDirectory() + "/Library/Preferences/")
        || normalizedActual.hasPrefix(NSHomeDirectory() + "/Library/Application Support/")
}

private func makeDeleteEntry(
    pimxTargetPath: String,
    actualTargetPath: String,
    isDirectory: Bool
) -> HDPIMDeleteEntry {
    let isUserPreferences = isUserPreferencesPath(
        pimxPath: pimxTargetPath,
        actualPath: actualTargetPath
    )

    return HDPIMDeleteEntry(
        targetPath: pimxTargetPath,
        isDirectory: isDirectory,
        isRecursiveDelete: isUserPreferences,
        isUserPreferences: isUserPreferences
    )
}

class MoveFileCommand: HDPIMCommand {
    let source: String
    let target: String
    let pimxTargetPath: String
    var commandName: String { "MoveFile" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var didMove = false

    init(source: String, target: String, pimxTargetPath: String) {
        self.source = source
        self.target = target
        self.pimxTargetPath = pimxTargetPath
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try await moveItemReplacing(source: source, target: target)
        didMove = true
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didMove else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: false)]
    }
}

class MergeDirectoryCommand: HDPIMCommand {
    let source: String
    let target: String
    let pimxTargetPath: String
    var commandName: String { "MergeDirectory" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var didMerge = false

    init(source: String, target: String, pimxTargetPath: String) {
        self.source = source
        self.target = target
        self.pimxTargetPath = pimxTargetPath
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try await ensureDirectoryExists(at: target)

        guard let enumerator = FileManager.default.enumerator(atPath: source) else {
            return
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard !relativePath.isEmpty else { continue }

            let itemURL = URL(fileURLWithPath: source, isDirectory: true).appendingPathComponent(relativePath)
            let targetURL = URL(fileURLWithPath: target, isDirectory: true).appendingPathComponent(relativePath)
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false

            if isDirectory {
                try await ensureDirectoryExists(at: targetURL.path)
                continue
            }

            try await moveItemReplacing(source: itemURL.path, target: targetURL.path)
        }
        didMerge = true
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didMerge else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: true)]
    }
}

class CopyFileCommand: HDPIMCommand {
    let source: String
    let target: String
    let pimxTargetPath: String
    var commandName: String { "CopyFile" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var didCopy = false

    init(source: String, target: String, pimxTargetPath: String) {
        self.source = source
        self.target = target
        self.pimxTargetPath = pimxTargetPath
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try await copyItemReplacing(source: source, target: target)
        didCopy = true
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didCopy else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: false)]
    }
}

class BlindCopyCommand: HDPIMCommand {
    let source: String
    let target: String
    let pimxTargetPath: String
    var commandName: String { "BlindCopy" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var didCopy = false

    init(source: String, target: String, pimxTargetPath: String) {
        self.source = source
        self.target = target
        self.pimxTargetPath = pimxTargetPath
    }

    func execute() async throws {
        if HDPIMCommandExecutor.pathExists(source) {
            try? await copyItemReplacing(source: source, target: target)
            didCopy = true
        }
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didCopy else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: false)]
    }
}

class CreateDirectoryCommand: HDPIMCommand {
    let path: String
    let pimxPath: String
    var commandName: String { "CreateDirectory" }
    var commandDetails: String? { path }
    private var created = false

    init(path: String, pimxPath: String) {
        self.path = path
        self.pimxPath = pimxPath
    }

    func execute() async throws {
        if HDPIMCommandExecutor.pathExists(path) {
            return
        }
        try await ensureDirectoryExists(at: path)
        created = true
    }

    func rollBack() async throws {
        if created {
            try? await removeItemIfExists(at: path)
        }
    }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        return [makeDeleteEntry(pimxTargetPath: pimxPath, actualTargetPath: path, isDirectory: true)]
    }
}

class DeleteFileCommand: HDPIMCommand {
    let target: String
    var commandName: String { "DeleteFile" }
    var commandDetails: String? { target }

    init(target: String) {
        self.target = target
    }

    func execute() async throws {
        try? await removeItemIfExists(at: target)
    }

    func rollBack() async throws { }
}

class DeleteDirectoryCommand: HDPIMCommand {
    let source: String
    var commandName: String { "DeleteDirectory" }
    var commandDetails: String? { source }

    init(source: String) {
        self.source = source
    }

    func execute() async throws {
        try? await removeItemIfExists(at: source)
    }

    func rollBack() async throws { }
}

class CreateSymlinkCommand: HDPIMCommand {
    let source: String  // 链接目标
    let target: String  // 链接路径
    let pimxTargetPath: String
    var commandName: String { "CreateSymlink" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var created = false

    init(source: String, target: String, pimxTargetPath: String) {
        self.source = source
        self.target = target
        self.pimxTargetPath = pimxTargetPath
    }

    func execute() async throws {
        try await ensureParentDirectoryExists(for: target)
        try? await removeItemIfExists(at: target)
        do {
            try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
        } catch {
            print("[HDPIM] FileManager.createSymbolicLink 失败: \(source) -> \(target), error: \(error.localizedDescription)")
            guard shouldFallbackToShell(error) else {
                throw error
            }
            try await HDPIMCommandExecutor.executeShellChecked("/bin/ln -sfn \(shellQuoted(source)) \(shellQuoted(target))", onError: .createSymlinkFailed)
        }
        created = true
    }

    func rollBack() async throws {
        if created {
            try? await removeItemIfExists(at: target)
        }
    }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard created else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: false)]
    }
}
