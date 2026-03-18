//
//  HDPIMFileCommands.swift
//  Adobe Downloader
//

import Foundation
import Darwin

private func removeItemIfExists(at path: String) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        try FileManager.default.removeItem(atPath: path)
    }
}

private func ensureParentDirectoryExists(for path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    guard !parent.isEmpty else { return }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw HDPIMCommandError.targetConflict
        }
        return
    }
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
}

private func ensureDirectoryExists(at path: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw HDPIMCommandError.targetConflict
        }
        return
    }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func copyItemReplacing(source: String, target: String) throws {
    try ensureParentDirectoryExists(for: target)
    try removeItemIfExists(at: target)
    try FileManager.default.copyItem(atPath: source, toPath: target)
}

private func moveItemReplacing(source: String, target: String) throws {
    try ensureParentDirectoryExists(for: target)
    try removeItemIfExists(at: target)

    do {
        try FileManager.default.moveItem(atPath: source, toPath: target)
    } catch {
        try FileManager.default.copyItem(atPath: source, toPath: target)
        try FileManager.default.removeItem(atPath: source)
    }
}

class MoveFileCommand: HDPIMCommand {
    let source: String
    let target: String
    var commandName: String { "MoveFile" }
    var commandDetails: String? { "\(source) -> \(target)" }

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try moveItemReplacing(source: source, target: target)
    }

    func rollBack() async throws { }

    func getReverseCommandXML() -> String? {
        "<DeleteFile target=\"\(target)\"/>"
    }
}

class MergeDirectoryCommand: HDPIMCommand {
    let source: String
    let target: String
    var commandName: String { "MergeDirectory" }
    var commandDetails: String? { "\(source) -> \(target)" }

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try ensureDirectoryExists(at: target)

        guard let enumerator = FileManager.default.enumerator(atPath: source) else {
            return
        }

        for case let relativePath as String in enumerator {
            guard !relativePath.isEmpty else { continue }

            let itemURL = URL(fileURLWithPath: source, isDirectory: true).appendingPathComponent(relativePath)
            let targetURL = URL(fileURLWithPath: target, isDirectory: true).appendingPathComponent(relativePath)
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false

            if isDirectory {
                try ensureDirectoryExists(at: targetURL.path)
                continue
            }

            try moveItemReplacing(source: itemURL.path, target: targetURL.path)
        }
    }

    func rollBack() async throws { }

    func getReverseCommandXML() -> String? {
        "<DeleteDirectory source=\"\(target)\"/>"
    }
}

class CopyFileCommand: HDPIMCommand {
    let source: String
    let target: String
    var commandName: String { "CopyFile" }
    var commandDetails: String? { "\(source) -> \(target)" }

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func execute() async throws {
        guard HDPIMCommandExecutor.pathExists(source) else {
            throw HDPIMCommandError.fileNotFound
        }

        try copyItemReplacing(source: source, target: target)
    }

    func rollBack() async throws { }

    func getReverseCommandXML() -> String? {
        "<DeleteFile target=\"\(target)\"/>"
    }
}

class BlindCopyCommand: HDPIMCommand {
    let source: String
    let target: String
    var commandName: String { "BlindCopy" }
    var commandDetails: String? { "\(source) -> \(target)" }

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func execute() async throws {
        if HDPIMCommandExecutor.pathExists(source) {
            try? copyItemReplacing(source: source, target: target)
        }
    }

    func rollBack() async throws { }

    func getReverseCommandXML() -> String? {
        "<DeleteFile target=\"\(target)\"/>"
    }
}

class CreateDirectoryCommand: HDPIMCommand {
    let path: String
    var commandName: String { "CreateDirectory" }
    var commandDetails: String? { path }
    private var created = false

    init(path: String) {
        self.path = path
    }

    func execute() async throws {
        if HDPIMCommandExecutor.pathExists(path) {
            return
        }
        try ensureDirectoryExists(at: path)
        created = true
    }

    func rollBack() async throws {
        if created {
            try? removeItemIfExists(at: path)
        }
    }

    func getReverseCommandXML() -> String? {
        "<DeleteDirectory source=\"\(path)\"/>"
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
        try? removeItemIfExists(at: target)
    }

    func rollBack() async throws { }
    func getReverseCommandXML() -> String? { nil }
}

class DeleteDirectoryCommand: HDPIMCommand {
    let source: String
    var commandName: String { "DeleteDirectory" }
    var commandDetails: String? { source }

    init(source: String) {
        self.source = source
    }

    func execute() async throws {
        try? removeItemIfExists(at: source)
    }

    func rollBack() async throws { }
    func getReverseCommandXML() -> String? { nil }
}

class CreateSymlinkCommand: HDPIMCommand {
    let source: String  // 链接目标
    let target: String  // 链接路径
    var commandName: String { "CreateSymlink" }
    var commandDetails: String? { "\(source) -> \(target)" }
    private var created = false

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func execute() async throws {
        try ensureParentDirectoryExists(for: target)
        try? removeItemIfExists(at: target)
        try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: source)
        created = true
    }

    func rollBack() async throws {
        if created {
            try? removeItemIfExists(at: target)
        }
    }

    func getReverseCommandXML() -> String? { nil }
}
