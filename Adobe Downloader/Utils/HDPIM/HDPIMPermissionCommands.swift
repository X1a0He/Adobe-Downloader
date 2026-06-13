//
//  HDPIMPermissionCommands.swift
//  Adobe Downloader
//

import Foundation
import Darwin

private func shellQuotedPermission(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

class ChmodCommand: HDPIMCommand {
    let path: String
    let mode: String
    var commandName: String { "Chmod" }
    private var oldMode: String?

    init(path: String, mode: String) {
        self.path = path
        self.mode = mode
    }

    func execute() async throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw HDPIMCommandError.getPermissionFailed
        }

        oldMode = String(info.st_mode & 0o777)

        guard let octalMode = modeParser(mode) else {
            throw HDPIMCommandError.setPermissionFailed
        }

        if chmod(path, octalMode) != 0 {
            try await HDPIMCommandExecutor.executeShellChecked("/bin/chmod \(shellQuotedPermission(mode)) \(shellQuotedPermission(path))", onError: .setPermissionFailed)
        }
    }

    func rollBack() async throws {
        if let oldMode, let octalMode = modeParser(oldMode) {
            if chmod(path, octalMode) != 0 {
                try? await HDPIMCommandExecutor.executeShellChecked("/bin/chmod \(shellQuotedPermission(oldMode)) \(shellQuotedPermission(path))", onError: .setPermissionFailed)
            }
        }
    }
}

class ChownerCommand: HDPIMCommand {
    let path: String
    let uid: String
    let gid: String
    var commandName: String { "Chowner" }
    private var oldOwner: String?

    init(path: String, uid: String, gid: String) {
        self.path = path
        self.uid = uid
        self.gid = gid
    }

    func execute() async throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw HDPIMCommandError.getOwnerFailed
        }

        oldOwner = "\(info.st_uid):\(info.st_gid)"

        guard let resolvedUID = parseUID(uid) else {
            throw HDPIMCommandError.setOwnerFailed
        }
        guard let resolvedGID = parseGID(gid) else {
            throw HDPIMCommandError.setOwnerFailed
        }

        if chown(path, resolvedUID, resolvedGID) != 0 {
            let ownerSpec = "\(resolvedUID):\(resolvedGID)"
            try await HDPIMCommandExecutor.executeShellChecked("/usr/sbin/chown \(shellQuotedPermission(ownerSpec)) \(shellQuotedPermission(path))", onError: .setOwnerFailed)
        }
    }

    func rollBack() async throws {
        if let oldOwner = oldOwner {
            let parts = oldOwner.split(separator: ":").map(String.init)
            if parts.count == 2,
               let restoredUID = parseUID(parts[0]),
               let restoredGID = parseGID(parts[1]) {
                if chown(path, restoredUID, restoredGID) != 0 {
                    try? await HDPIMCommandExecutor.executeShellChecked("/usr/sbin/chown \(shellQuotedPermission(oldOwner)) \(shellQuotedPermission(path))", onError: .setOwnerFailed)
                }
            }
        }
    }
}

private func modeParser(_ value: String) -> mode_t? {
    guard let numeric = UInt16(value, radix: 8) else { return nil }
    return mode_t(numeric)
}

private func parseUID(_ value: String) -> uid_t? {
    if let numeric = UInt32(value) {
        return numeric
    }

    return value.withCString { pointer in
        guard let pwd = getpwnam(pointer) else { return nil }
        return pwd.pointee.pw_uid
    }
}

private func parseGID(_ value: String) -> gid_t? {
    if let numeric = UInt32(value) {
        return numeric
    }

    return value.withCString { pointer in
        guard let group = getgrnam(pointer) else { return nil }
        return group.pointee.gr_gid
    }
}
