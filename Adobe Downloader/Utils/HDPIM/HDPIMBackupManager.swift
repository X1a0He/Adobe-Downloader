//
//  Adobe Downloader
//  HDPIMBackupManager.swift
//
//  Created by X1a0He on 2026/03/17.
//

import Foundation
import Darwin

class HDPIMBackupManager {
    private struct Snapshot: Codable {
        let original: String
        let backup: String?
        let kind: HDPIMFileChange.Kind
        let existed: Bool
    }

    private struct Journal: Codable {
        let phase: String
        let entries: [Snapshot]
        let quarantinedPaths: [String]
    }

    private let backupRoot: URL
    private var snapshots: [Snapshot] = []
    private var capturedPaths = Set<String>()
    private var capturedContents = Set<String>()
    private var quarantinedPaths: [String] = []

    init(recoveryRoot: URL? = nil) {
        backupRoot = (recoveryRoot ?? URL(fileURLWithPath: HDPIMRuntimeEnvironment.userHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Adobe Downloader/Backups")
        )
            .appendingPathComponent(UUID().uuidString)
    }

    var recoveryDirectory: URL { backupRoot }
    var hasBackups: Bool { !snapshots.isEmpty }

    func backupDirectories(
        _ directories: [URL],
        progressHandler: ((Int, Int, URL) -> Void)? = nil,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        try await capture(directories.map { HDPIMFileChange(path: $0.path, kind: .contents) },
                          progressHandler: progressHandler)
    }

    func capture(_ changes: [HDPIMFileChange],
                 progressHandler: ((Int, Int, URL) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let normalized = try normalizedChanges(changes)
        for (index, change) in normalized.enumerated() {
            try HDPIMOperationContext.checkCancellation()
            if capturedPaths.contains(change.path) || hasContentAncestor(change.path, in: capturedContents) { continue }
            let original = URL(fileURLWithPath: change.path)
            var info = stat()
            let existed = lstat(change.path, &info) == 0
            if !existed && errno != ENOENT && errno != ENOTDIR { throw posixError() }
            var backup: URL?
            if existed {
                let destination = backupRoot.appendingPathComponent(UUID().uuidString)
                try copy(original, to: destination, kind: change.kind)
                backup = destination
            }
            snapshots.append(Snapshot(original: change.path, backup: backup?.path, kind: change.kind, existed: existed))
            capturedPaths.insert(change.path)
            if change.kind == .contents { capturedContents.insert(change.path) }
            progressHandler?(index, normalized.count, original)
        }
        try writeJournal(phase: "prepared")
    }

    func restoreAll() async throws {
        var failures: [String] = []
        for entry in snapshots.reversed() {
            let original = URL(fileURLWithPath: entry.original)
            do {
                if entry.existed && entry.kind == .metadata {
                    guard let path = entry.backup else {
                        throw HDPIMInstallError.rollbackFailed("元数据目标已丢失：\(entry.original)")
                    }
                    if !exists(entry.original) {
                        var info = stat()
                        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                            throw HDPIMInstallError.rollbackFailed("元数据目标已丢失：\(entry.original)")
                        }
                        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
                    }
                    try copyMetadata(URL(fileURLWithPath: path), to: original)
                } else {
                    var replacement: URL?
                    if entry.existed, let path = entry.backup {
                        let staging = original.deletingLastPathComponent().appendingPathComponent(".adobe-restore-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try copy(URL(fileURLWithPath: path), to: staging, kind: .contents)
                        replacement = staging
                    }
                    if exists(entry.original) {
                        let quarantine = original.deletingLastPathComponent().appendingPathComponent(".adobe-rollback-\(UUID().uuidString)")
                        quarantinedPaths.append(quarantine.path)
                        try writeJournal(phase: "restoring")
                        try movePreservingFlags(original, to: quarantine)
                    }
                    if let replacement { try movePreservingFlags(replacement, to: original) }
                }
            } catch {
                failures.append("\(entry.original)：\(error.localizedDescription)")
            }
        }
        try writeJournal(phase: failures.isEmpty ? "restored" : "restore-incomplete")
        if !failures.isEmpty {
            throw HDPIMInstallError.rollbackFailed(failures.joined(separator: "\n") + "\n恢复记录：\(backupRoot.path)")
        }
    }

    func cleanup() async throws {
        try writeJournal(phase: "committed")
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            do { try FileManager.default.removeItem(at: backupRoot) }
            catch {
                let cleanupFailure = error
                guard try unlockBackupForCleanup(backupRoot) else { throw cleanupFailure }
                try FileManager.default.removeItem(at: backupRoot)
            }
        }
        snapshots.removeAll()
        capturedPaths.removeAll()
        capturedContents.removeAll()
    }

    private func normalizedChanges(_ changes: [HDPIMFileChange]) throws -> [HDPIMFileChange] {
        var byPath: [String: HDPIMFileChange.Kind] = [:]
        var existingParents: [String: Bool] = [:]
        func parentExists(_ path: String) -> Bool {
            if let value = existingParents[path] { return value }
            let value = exists(path)
            existingParents[path] = value
            return value
        }
        for change in changes {
            try HDPIMFileChange.validate(change.path)
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            if change.kind == .contents || byPath[path] == nil { byPath[path] = change.kind }
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            var missingParent: URL?
            while parent.path != "/" && !parentExists(parent.path) {
                missingParent = parent
                parent = parent.deletingLastPathComponent()
            }
            if let missingParent { byPath[missingParent.path] = .contents }
        }
        let protected = Set(["/Applications", "/Applications/Utilities", "/Library", "/Library/Application Support",
                             "/Library/Application Support/Adobe", "/Users", HDPIMRuntimeEnvironment.userHomeDirectory()])
        var result: [HDPIMFileChange] = []
        var contentRoots = Set<String>()
        for path in byPath.keys.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            let kind = byPath[path]!
            if kind == .contents && protected.contains(path) && exists(path) {
                throw HDPIMMaterialError.invalid("拒绝整体替换共享目录：\(path)")
            }
            if hasContentAncestor(path, in: contentRoots) { continue }
            result.append(HDPIMFileChange(path: path, kind: kind))
            if kind == .contents { contentRoots.insert(path) }
        }
        return result
    }

    private func hasContentAncestor(_ path: String, in roots: Set<String>) -> Bool {
        var parent = path[...]
        while let slash = parent.lastIndex(of: "/"), slash != parent.startIndex {
            parent = parent[..<slash]
            if roots.contains(String(parent)) { return true }
        }
        return false
    }

    private func movePreservingFlags(_ source: URL, to destination: URL) throws {
        let originalFlags = try clearBlockingFlags(source)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            let moveFailure = error
            if let originalFlags {
                do { try setFlags(originalFlags, at: source) }
                catch {
                    throw HDPIMInstallError.rollbackFailed("移动恢复文件失败：\(moveFailure.localizedDescription)；恢复来源标志失败：\(source.path)，\(error.localizedDescription)")
                }
            }
            throw moveFailure
        }
        if let originalFlags { try setFlags(originalFlags, at: destination) }
    }

    private func unlockBackupForCleanup(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        var unlocked = try clearBlockingFlags(url) != nil
        if info.st_mode & S_IFMT == S_IFDIR {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let childUnlocked = try unlockBackupForCleanup(child)
                unlocked = childUnlocked || unlocked
            }
        }
        return unlocked
    }

    private func clearBlockingFlags(_ url: URL) throws -> UInt32? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        let blocking = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        guard info.st_flags & blocking != 0 else { return nil }
        try setFlags(info.st_flags & ~blocking, at: url)
        return info.st_flags
    }

    private func setFlags(_ flags: UInt32, at url: URL) throws {
        guard lchflags(url.path, flags) == 0 else { throw posixError() }
    }

    private func copy(_ source: URL, to destination: URL, kind: HDPIMFileChange.Kind) throws {
        if kind == .metadata {
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw posixError() }
            if info.st_mode & S_IFMT == S_IFDIR {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } else if info.st_mode & S_IFMT == S_IFLNK {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            } else {
                guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else { throw HDPIMCommandError.backupFailed }
            }
            try copyMetadata(source, to: destination)
        } else {
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw posixError() }
            if info.st_mode & S_IFMT == S_IFDIR {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try copy(child, to: destination.appendingPathComponent(child.lastPathComponent), kind: .contents)
                }
                try copyMetadata(source, to: destination)
            } else {
                let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
                guard copyfile(source.path, destination.path, nil, flags) == 0 else { throw posixError() }
            }
        }
    }

    private func copyMetadata(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else { throw posixError() }
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func writeJournal(phase: String) throws {
        let journal = Journal(phase: phase, entries: snapshots, quarantinedPaths: quarantinedPaths)
        try JSONEncoder().encode(journal).write(to: backupRoot.appendingPathComponent("journal.json"), options: .atomic)
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
