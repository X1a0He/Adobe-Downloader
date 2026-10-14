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

private func removeEmptyDirectoryIfExists(at path: String) async throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return
        }
        if rmdir(path) != 0 {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            guard error.code != Int(ENOENT) && error.code != Int(ENOTEMPTY) else {
                return
            }
            throw error
        }
    }
}

enum HDPIMRemovalPolicy {
    struct PreflightChecker {
        private let protectedRoots: Set<String>

        init() {
            let table = HDPIMPropertyTable()
            table.setupSystemDirectories()
            var roots = Set(["/", "/Applications", "/Library", "/System", "/Users", "/usr", "/var", "/bin", "/sbin",
                             "/etc", "/private", "/usr/local", "/tmp", "/private/tmp", "/Volumes"])
            var visited = Set<String>()
            for value in table.allProperties.values where value.hasPrefix("/") {
                var parent = URL(fileURLWithPath: value).standardizedFileURL
                while parent.path != "/" {
                    guard visited.insert(parent.path).inserted else { break }
                    roots.insert(parent.path)
                    roots.insert(parent.resolvingSymlinksInPath().path)
                    parent.deleteLastPathComponent()
                }
            }
            protectedRoots = Set(roots.map { $0.lowercased() })
        }

        func isProtected(_ path: String) -> Bool {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            if protectedRoots.contains(url.path.lowercased()) || protectedRoots.contains(resolved.path.lowercased()) { return true }
            var info = stat()
            var parentInfo = stat()
            let parent = resolved.deletingLastPathComponent().path
            return stat(resolved.path, &info) == 0 && stat(parent, &parentInfo) == 0 && info.st_dev != parentInfo.st_dev
        }
    }

    static func isProtected(_ path: String) -> Bool {
        PreflightChecker().isProtected(path)
    }
}

private func isProtectedRecursiveDeleteRoot(_ path: String) -> Bool {
    HDPIMRemovalPolicy.isProtected(path)
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
        || normalizedActual.hasPrefix(HDPIMRuntimeEnvironment.userHomeDirectory() + "/Library/Preferences/")
        || normalizedActual.hasPrefix(HDPIMRuntimeEnvironment.userHomeDirectory() + "/Library/Application Support/")
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
        isRecursiveDelete: false,
        isUserPreferences: isUserPreferences,
        actualTargetPath: actualTargetPath
    )
}

private func isDirectoryDeleteTarget(_ path: String) -> Bool {
    var info = stat()
    if lstat(path, &info) == 0 {
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    return URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
        || path.hasSuffix("/")
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
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: isDirectoryDeleteTarget(target))]
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
            throw HDPIMCommandError.fileNotFound
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard !relativePath.isEmpty else { continue }

            let itemURL = URL(fileURLWithPath: source, isDirectory: true).appendingPathComponent(relativePath)
            let targetURL = URL(fileURLWithPath: target, isDirectory: true).appendingPathComponent(relativePath)
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = resourceValues.isSymbolicLink == true
            let isDirectory = resourceValues.isDirectory == true && !isSymbolicLink

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
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: isDirectoryDeleteTarget(target))]
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
            try await copyItemReplacing(source: source, target: target)
            didCopy = true
        }
    }

    func rollBack() async throws { }

    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard didCopy else {
            return []
        }
        return [makeDeleteEntry(pimxTargetPath: pimxTargetPath, actualTargetPath: target, isDirectory: isDirectoryDeleteTarget(target))]
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
        guard !HDPIMRemovalPolicy.isProtected(target) else { throw HDPIMCommandError.targetConflict }
        var info = stat()
        if lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            throw HDPIMCommandError.targetConflict
        }
        try await removeItemIfExists(at: target)
    }

    func rollBack() async throws { }
}

class DeleteDirectoryCommand: HDPIMCommand {
    let source: String
    let isRecursiveDelete: Bool
    let isUserPreferences: Bool
    var commandName: String { "DeleteDirectory" }
    var commandDetails: String? { source }

    init(source: String, isRecursiveDelete: Bool, isUserPreferences: Bool) {
        self.source = source
        self.isRecursiveDelete = isRecursiveDelete
        self.isUserPreferences = isUserPreferences
    }

    func execute() async throws {
        guard !isProtectedRecursiveDeleteRoot(source) else { throw HDPIMCommandError.targetConflict }
        if isRecursiveDelete {
            try await removeItemIfExists(at: source)
            return
        }

        try await removeEmptyDirectoryIfExists(at: source)
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

final class UnlockPathCommand: HDPIMCommand {
    let path: String
    let active: Bool
    var commandName: String { "UnlockPath" }
    var commandDetails: String? { path }
    init(path: String, active: Bool) { self.path = path; self.active = active }
    func execute() async throws {
        guard active, FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
    }
    func rollBack() async throws { }
    func getPimxCommandFragments() -> [HDPIMPimxCommandFragment] {
        let value = path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return [.init(xml: "<UnlockPath><Path>\(value)</Path></UnlockPath>", kind: .uninstall)]
    }
}

final class LocalizeFileCommand: HDPIMCommand {
    let source: String
    let target: String
    var commandName: String { "LocalizeFileName" }
    var commandDetails: String? { "\(source) → \(target)" }
    init(source: String, target: String) { self.source = source; self.target = target }
    func execute() async throws {
        guard FileManager.default.fileExists(atPath: source) else { throw HDPIMCommandError.fileNotFound }
        guard !FileManager.default.fileExists(atPath: target) else { throw HDPIMCommandError.targetConflict }
        try FileManager.default.moveItem(atPath: source, toPath: target)
    }
    func rollBack() async throws { }
}

final class MacAliasCommand: HDPIMCommand {
    let target: String
    let path: String
    let isPermanent: Bool
    private var created = false
    var commandName: String { "Shortcut" }
    var commandDetails: String? { path }
    init(target: String, path: String, isPermanent: Bool) {
        self.target = target; self.path = path; self.isPermanent = isPermanent
    }
    func execute() async throws {
        try await ensureParentDirectoryExists(for: path)
        let bookmark = try URL(fileURLWithPath: target).bookmarkData(options: .suitableForBookmarkFile,
                                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        try await removeItemIfExists(at: path)
        try URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: path))
        created = true
    }
    func rollBack() async throws { }
    func getDeleteEntries() -> [HDPIMDeleteEntry] {
        guard created, !isPermanent else { return [] }
        return [makeDeleteEntry(pimxTargetPath: path, actualTargetPath: path, isDirectory: false)]
    }
}
