import Foundation
import Darwin

/// 用户身份从账户记录解析，不能用 root 进程的 HOME 推断执行权限。
struct HDPIMUserExecutionContext {
    let name: String
    let uid: uid_t
    let home: String

    static func resolve(userHome: String = HDPIMRuntimeEnvironment.userHomeDirectory()) throws -> Self {
        let requested = URL(fileURLWithPath: userHome).standardizedFileURL.resolvingSymlinksInPath()
        let name = requested.lastPathComponent
        let size = max(16384, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        var buffer = [CChar](repeating: 0, count: size)
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let status = getpwnam_r(name, &account, &buffer, size, &result)
        guard status == 0, result != nil, account.pw_uid != 0,
              let homePointer = account.pw_dir, let namePointer = account.pw_name else {
            throw HDPIMMaterialError.unavailable("无法确认安装用户，拒绝以 root 身份执行用户程序")
        }
        let home = String(cString: homePointer)
        guard userHome.hasPrefix("/"),
              URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath() == requested,
              geteuid() == 0 || geteuid() == account.pw_uid else {
            throw HDPIMMaterialError.unavailable("安装用户与账户目录不匹配")
        }
        return Self(name: String(cString: namePointer), uid: account.pw_uid, home: home)
    }
}

/// 只修正包清单声明的用户目录及有限父目录链，不枚举已有用户数据。
struct HDPIMUserDirectoryOwnership {
    let user: HDPIMUserExecutionContext
    let directories: [String]

    init(directories: [String], user: HDPIMUserExecutionContext) throws {
        self.user = user
        let home = URL(fileURLWithPath: user.home).standardizedFileURL.path
        let roots = Self.directoryRoots(userHome: home)
        var selected = Set<String>()
        for directory in directories {
            try HDPIMFileChange.validate(directory)
            var path = URL(fileURLWithPath: directory).standardizedFileURL.path
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            while path != root {
                selected.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        self.directories = selected.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        // 在备份前拒绝符号链接祖先，避免备份与修改落到不同目录。
        for path in self.directories { _ = try withDirectory(path) { _ in } }
    }

    var changes: [HDPIMFileChange] {
        directories.map { HDPIMFileChange(path: $0, kind: .metadata) }
    }

    /// 安装命令保留永久资产；文件写入也可能隐式创建父目录。
    static func installationDirectories(from commands: [PIMXCommandDescriptor], userHome: String) throws -> [String] {
        let roots = directoryRoots(userHome: userHome)
        var directories: [String] = []
        for command in commands {
            switch command {
            case .createDirectory(let path, _):
                directories.append(path)
            case .moveFile(let source, let target, _), .copyFile(let source, let target, _),
                 .blindCopy(let source, let target, _), .mergeDirectory(let source, let target, _):
                let destination = URL(fileURLWithPath: target).standardizedFileURL.path
                guard roots.contains(where: { destination == $0 || destination.hasPrefix($0 + "/") }) else { continue }
                directories.append((destination as NSString).deletingLastPathComponent)
                // 包装目录可能整体移动或合并；只映射安装源的真实目录，不遍历用户目标。
                var pending = [(source, destination)]
                while let (sourcePath, targetPath) = pending.popLast() {
                    try HDPIMOperationContext.checkCancellation()
                    var info = stat()
                    guard lstat(sourcePath, &info) == 0 else {
                        if errno == ENOENT { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: sourcePath])
                    }
                    guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                    directories.append(targetPath)
                    for name in try FileManager.default.contentsOfDirectory(atPath: sourcePath) {
                        pending.append(((sourcePath as NSString).appendingPathComponent(name),
                                        (targetPath as NSString).appendingPathComponent(name)))
                    }
                }
            case .createSymlink(_, let path, _), .localizeFile(_, let path), .macAlias(_, let path, _):
                directories.append((path as NSString).deletingLastPathComponent)
            default: break
            }
        }
        return directories
    }

    static func installationDirectories(from commands: [DeltaCommand]) -> [String] {
        commands.compactMap { command in
            switch command.type {
            case .createDirectory(let path):
                return path
            case .patchFile(_, let path), .copyFile(_, let path), .moveFile(_, let path),
                 .createSymlink(_, let path), .renameLocalized(let path, _):
                return (path as NSString).deletingLastPathComponent
            default: return nil
            }
        }
    }

    private static func directoryRoots(userHome: String) -> [String] {
        let home = URL(fileURLWithPath: userHome).standardizedFileURL.path
        return ["Library/Preferences", "Library/Caches", "Library/Application Support", "Documents", "Desktop"]
            .map { home + "/" + $0 }
    }

    /// fd 相对打开每一级目录；不跟随链接，也不扩大到其他账户或文件。
    func repairExistingDirectories() throws {
        for path in directories {
            try HDPIMOperationContext.checkCancellation()
            _ = try withDirectory(path) { fd in
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw posixError(path) }
                guard info.st_uid == 0 || info.st_uid == user.uid else {
                    throw HDPIMMaterialError.invalid("用户目录属于其他账户，拒绝更改：\(path)")
                }
                if info.st_uid == 0 {
                    guard fchown(fd, user.uid, gid_t.max) == 0 else { throw posixError(path) }
                }
                guard fstat(fd, &info) == 0 else { throw posixError(path) }
                guard info.st_uid == user.uid, info.st_mode & 0o700 == 0o700 else {
                    throw HDPIMMaterialError.invalid("用户目录未具备读写和访问权限：\(path)")
                }
            }
        }
    }

    func verifyUserAccess() async throws {
        var existing: [String] = []
        for path in directories {
            if try withDirectory(path, body: { _ in }) { existing.append(path) }
        }
        guard !existing.isEmpty else { return }
        // 使用真实账户检查 ACL 和父目录访问权限；root 的 access() 不能代表登录用户。
        let script = "for directory do if ! [ -d \"$directory\" ] || ! [ -r \"$directory\" ] || ! [ -w \"$directory\" ] || ! [ -x \"$directory\" ]; then printf '%s\\n' \"$directory\"; exit 1; fi; done"
        let arguments = ["-c", script, "adobe-user-directory-check"] + existing
        let result: HDPIMShellExecutionResult
        if geteuid() == user.uid {
            result = try await HDPIMProcessRunner.run(executable: "/bin/sh", arguments: arguments)
        } else {
            guard geteuid() == 0 else { throw HDPIMMaterialError.invalid("无法检查安装用户的目录权限") }
            result = try await HDPIMProcessRunner.run(executable: "/usr/bin/sudo",
                arguments: ["-n", "-H", "-u", user.name, "--", "/bin/sh"] + arguments)
        }
        guard result.exitCode == 0 else {
            throw HDPIMMaterialError.invalid("安装用户无法读写配置目录：\(result.output)")
        }
    }

    @discardableResult
    private func withDirectory(_ path: String, body: (Int32) throws -> Void) throws -> Bool {
        let home = URL(fileURLWithPath: user.home).standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { throw HDPIMMaterialError.invalid("用户目录越界：\(path)") }
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(home) }
        defer { close(fd) }
        var homeInfo = stat()
        guard fstat(fd, &homeInfo) == 0, homeInfo.st_uid == user.uid else {
            throw HDPIMMaterialError.invalid("用户主目录身份不匹配：\(home)")
        }
        for component in path.dropFirst(home.count + 1).split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return false }
                throw posixError(path)
            }
            close(fd)
            fd = next
        }
        try body(fd)
        return true
    }

    private func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
