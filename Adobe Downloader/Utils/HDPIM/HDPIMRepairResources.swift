//
//  HDPIMRepairResources.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit
import Darwin

/// 持久资源目录的名称绑定清单摘要；引用此目录的 PIMX 再由数据库摘要保护。
enum HDPIMRepairResources {
    static let defaultStorageRoot = URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers/AdobeDownloaderRepairResources")

    struct MissingStoredProgram: Error, LocalizedError {
        let path: String

        var errorDescription: String? {
            HDPIMMaterialError.invalid("已登记的恢复或卸载程序不存在：\(path)").errorDescription
        }
    }

    fileprivate struct Entry: Codable, Equatable {
        let path: String
        let kind: String
        let mode: UInt16
        let sha256: String?
        let link: String?
    }

    private struct Manifest: Codable {
        let version: Int
        let packageIdentity: String
        let entries: [Entry]
    }

    struct Plan {
        let descriptors: [PIMXCommandDescriptor]
        let changedPaths: [String]
        fileprivate let sourceRoot: URL?
        fileprivate let destination: URL?
        fileprivate let manifestData: Data?
        fileprivate let entries: [Entry]

        var resourceDirectory: URL? { destination }
        var resourceSourceDirectory: URL? { sourceRoot }
        var resourceManifestData: Data? { manifestData }

        func verifyPublished() throws {
            if let destination { try validateFolder(destination) }
        }

        /// 必须在事务备份完成后、任何安装命令移动源文件前发布。
        func publish() throws {
            guard let sourceRoot, let destination, let manifestData else { return }
            if exists(destination.path) {
                try validateFolder(destination)
                return
            }
            try ensureProtectedDirectory(destination)
            let payload = destination.appendingPathComponent("payload")
            try ensureProtectedDirectory(payload)
            for entry in entries {
                try Task.checkCancellation()
                let target = payload.appendingPathComponent(entry.path)
                switch entry.kind {
                case "directory":
                    try ensureProtectedDirectory(target)
                case "file":
                    let source = sourceRoot.appendingPathComponent(entry.path)
                    let info = try fileInfo(source.path)
                    guard info.st_mode & S_IFMT == S_IFREG else {
                        throw invalid("资源类型在发布前发生变化：\(source.path)")
                    }
                    try FileManager.default.copyItem(at: source, to: target)
                    try clearACL(target)
                    guard chown(target.path, 0, 0) == 0, chmod(target.path, mode_t(entry.mode)) == 0 else {
                        throw invalid("无法保护恢复资源：\(target.path)")
                    }
                case "symlink":
                    guard let link = entry.link else { throw invalid("恢复资源链接记录无效") }
                    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                    guard lchown(target.path, 0, 0) == 0 else {
                        throw invalid("无法保护恢复资源链接：\(target.path)")
                    }
                default:
                    throw invalid("恢复资源类型无效：\(entry.kind)")
                }
            }
            let manifestURL = destination.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL, options: .withoutOverwriting)
            guard chown(manifestURL.path, 0, 0) == 0, chmod(manifestURL.path, 0o644) == 0 else {
                throw invalid("无法保护恢复资源清单：\(manifestURL.path)")
            }
            try validateFolder(destination)
        }
    }

    static func prepare(
        stagingFolder: String,
        packageIdentity: String,
        descriptors: [PIMXCommandDescriptor]
    ) throws -> Plan {
        let staging = URL(fileURLWithPath: stagingFolder).standardizedFileURL
        let sourceRoot = staging.resolvingSymlinksInPath()
        let prefixes = Array(Set([staging.path, sourceRoot.path])).sorted { $0.count > $1.count }
        var selectedRoots = Set<String>()
        var executablePaths = Set<String>()
        for descriptor in descriptors {
            guard case .runProgram(_, let repair, let uninstall) = descriptor else { continue }
            for invocation in [repair, uninstall].compactMap({ $0 }) {
                for value in [invocation.path] + invocation.arguments {
                    for prefix in prefixes {
                        try collectRoots(in: value, stagingPrefix: prefix, into: &selectedRoots)
                    }
                }
                for prefix in prefixes where invocation.path.hasPrefix(prefix + "/") {
                    let relative = String(invocation.path.dropFirst(prefix.count + 1))
                    executablePaths.insert(relative)
                    let resolved = sourceRoot.appendingPathComponent(relative).resolvingSymlinksInPath().path
                    if resolved.hasPrefix(sourceRoot.path + "/") {
                        executablePaths.insert(String(resolved.dropFirst(sourceRoot.path.count + 1)))
                    }
                }
            }
        }
        guard !selectedRoots.isEmpty else {
            return Plan(descriptors: descriptors, changedPaths: [], sourceRoot: nil,
                        destination: nil, manifestData: nil, entries: [])
        }
        var entries: [Entry] = []
        for root in selectedRoots.sorted() {
            let source = sourceRoot.appendingPathComponent(root)
            let info = try fileInfo(source.path)
            // 单独位于 staging 根部的程序无法证明相邻依赖范围，不能猜测为独立文件。
            if executablePaths.contains(root), info.st_mode & S_IFMT != S_IFDIR {
                throw invalid("恢复程序位于解压根目录，无法确定资源范围：\(source.path)")
            }
            try snapshot(source, relative: root, allowedRoot: source, executablePaths: executablePaths,
                         protected: false, into: &entries)
        }
        entries.sort { $0.path < $1.path }
        let manifest = Manifest(version: 1, packageIdentity: packageIdentity, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let identity = digest(Data(packageIdentity.utf8))
        let destination = defaultStorageRoot.appendingPathComponent(identity).appendingPathComponent(digest(data))
        let payload = destination.appendingPathComponent("payload").path
        let rewritten = descriptors.map { descriptor -> PIMXCommandDescriptor in
            guard case .runProgram(let execution, let repair, let uninstall) = descriptor else { return descriptor }
            return .runProgram(
                execution: execution,
                repair: repair.map { rewrittenInvocation($0, prefixes: prefixes, payload: payload) },
                uninstall: uninstall.map { rewrittenInvocation($0, prefixes: prefixes, payload: payload) }
            )
        }
        let alreadyPublished = exists(destination.path)
        if alreadyPublished { try validateFolder(destination) }
        return Plan(descriptors: rewritten, changedPaths: alreadyPublished ? [] : [destination.path],
                    sourceRoot: sourceRoot, destination: destination, manifestData: data, entries: entries)
    }

    /// 仅用于已经登记的材料；安装前的新 Hook 可能依赖尚未复制到目标的产品文件。
    static func validateStoredCommands(_ descriptors: [PIMXCommandDescriptor]) throws {
        var checked = Set<String>()
        var missingProgram: MissingStoredProgram?
        for descriptor in descriptors {
            guard case .runProgram(let execution, let repair, let uninstall) = descriptor else { continue }
            for invocation in [execution, repair, uninstall].compactMap({ $0 }) {
                try validatePersistentReferences(in: invocation)
                if checked.insert(invocation.path).inserted {
                    guard invocation.path.hasPrefix("/"), !invocation.path.contains("\0") else {
                        throw invalid("恢复或卸载程序路径无效：\(invocation.path)")
                    }
                    var info = stat()
                    guard stat(invocation.path, &info) == 0 else {
                        let code = errno
                        guard code == ENOENT || code == ENOTDIR else {
                            throw invalid("无法检查恢复或卸载程序：\(invocation.path)，errno=\(code)")
                        }
                        missingProgram = missingProgram ?? MissingStoredProgram(path: invocation.path)
                        continue
                    }
                    guard info.st_mode & S_IFMT == S_IFREG else {
                        throw invalid("恢复或卸载程序不是普通文件：\(invocation.path)")
                    }
                }
            }
        }
        // 检查完其他命令后才报告缺失，避免全量容错掩盖损坏资源或非法路径。
        if let missingProgram { throw missingProgram }
    }

    static func validatePersistentReferences(in invocation: PIMXProgramInvocation) throws {
        var folders = Set<String>()
        let prefix = defaultStorageRoot.path + "/"
        for value in [invocation.path] + invocation.arguments {
            var remaining = value[...]
            while let range = remaining.range(of: prefix) {
                let tail = remaining[range.upperBound...]
                let components = tail.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count >= 3, isDigest(String(components[0])),
                      isDigest(String(components[1])), components[2] == "payload",
                      !components.contains(".."), !components.contains("."),
                      !tail.contains("\0") else {
                    throw invalid("恢复资源引用格式无效：\(value)")
                }
                let folder = defaultStorageRoot.appendingPathComponent(String(components[0]))
                    .appendingPathComponent(String(components[1]))
                folders.insert(folder.path)
                remaining = tail
            }
        }
        for folder in folders.sorted() { try validateFolder(URL(fileURLWithPath: folder)) }
    }

    private static func collectRoots(in value: String, stagingPrefix: String, into roots: inout Set<String>) throws {
        if value == stagingPrefix || value.hasSuffix("=" + stagingPrefix) || value.contains("[StagingFolder]") {
            throw invalid("恢复参数引用整个解压目录，无法确定资源范围：\(value)")
        }
        var remaining = value[...]
        while let range = remaining.range(of: stagingPrefix + "/") {
            let tail = remaining[range.upperBound...]
            let components = tail.split(separator: "/", omittingEmptySubsequences: false)
            guard let component = components.first,
                  !component.isEmpty, !components.contains("."), !components.contains(".."),
                  !tail.contains("\0") else {
                throw invalid("恢复资源引用无效：\(value)")
            }
            roots.insert(String(component))
            remaining = tail
        }
    }

    private static func rewrittenInvocation(_ invocation: PIMXProgramInvocation, prefixes: [String], payload: String) -> PIMXProgramInvocation {
        func rewrite(_ value: String) -> String {
            var result = value.replacingOccurrences(of: "[StagingFolder]", with: payload)
            for prefix in prefixes { result = result.replacingOccurrences(of: prefix + "/", with: payload + "/") }
            return result
        }
        func persistedValue(template: String, resolved: String) -> String {
            let persistent = rewrite(resolved)
            // 按解析后的路径绑定临时依赖，兼容大小写变量与间接属性；其他模板保持原有语义。
            return persistent == resolved ? template : persistent
        }
        return PIMXProgramInvocation(
            path: rewrite(invocation.path), arguments: invocation.arguments.map(rewrite),
            successExitCodes: invocation.successExitCodes, hasExplicitSuccessExitCodes: invocation.hasExplicitSuccessExitCodes,
            pimxPath: persistedValue(template: invocation.pimxPath, resolved: invocation.path),
            pimxArguments: zip(invocation.pimxArguments, invocation.arguments).map {
                persistedValue(template: $0.0, resolved: $0.1)
            },
            runInUserMode: invocation.runInUserMode
        )
    }

    private static func snapshot(
        _ url: URL, relative: String, allowedRoot: URL, executablePaths: Set<String>,
        protected: Bool, into entries: inout [Entry]
    ) throws {
        if !protected { try Task.checkCancellation() }
        let info = try fileInfo(url.path)
        if protected { try validateProtection(url, info: info) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            entries.append(Entry(path: relative, kind: "directory", mode: protected ? UInt16(info.st_mode & 0o777) : 0o755, sha256: nil, link: nil))
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                try snapshot(child, relative: relative + "/" + child.lastPathComponent, allowedRoot: allowedRoot,
                             executablePaths: executablePaths, protected: protected, into: &entries)
            }
        case S_IFREG:
            let executable = executablePaths.contains(relative) || info.st_mode & 0o111 != 0
            let mode: UInt16 = protected ? UInt16(info.st_mode & 0o777) : (executable ? 0o755 : 0o644)
            entries.append(Entry(path: relative, kind: "file", mode: mode, sha256: try fileDigest(url), link: nil))
        case S_IFLNK:
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let resolved = url.resolvingSymlinksInPath().path
            guard !link.hasPrefix("/"), resolved.hasPrefix(allowedRoot.path + "/"),
                  FileManager.default.fileExists(atPath: resolved) else {
                throw invalid("恢复资源链接越过所选资源目录或目标缺失：\(url.path)")
            }
            entries.append(Entry(path: relative, kind: "symlink", mode: 0, sha256: nil, link: link))
        default:
            throw invalid("不支持的恢复资源文件类型：\(url.path)")
        }
    }

    private static func validateFolder(_ folder: URL) throws {
        try validateProtectedAncestors(folder)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let info = try fileInfo(manifestURL.path)
        guard info.st_mode & S_IFMT == S_IFREG else { throw invalid("恢复资源清单不是普通文件") }
        try validateProtection(manifestURL, info: info)
        let data = try Data(contentsOf: manifestURL)
        guard digest(data) == folder.lastPathComponent else { throw invalid("恢复资源清单摘要不匹配：\(manifestURL.path)") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, digest(Data(manifest.packageIdentity.utf8)) == folder.deletingLastPathComponent().lastPathComponent else {
            throw invalid("恢复资源清单身份不匹配：\(manifestURL.path)")
        }
        let payload = folder.appendingPathComponent("payload")
        try validateProtectedAncestors(payload)
        var actual: [Entry] = []
        for child in try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil) {
            try snapshot(child, relative: child.lastPathComponent, allowedRoot: child,
                         executablePaths: [], protected: true, into: &actual)
        }
        actual.sort { $0.path < $1.path }
        guard actual == manifest.entries else { throw invalid("恢复资源内容或权限不匹配：\(folder.path)") }
    }

    private static func ensureProtectedDirectory(_ url: URL) throws {
        if exists(url.path) {
            try validateProtectedAncestors(url)
            return
        }
        try ensureProtectedDirectory(url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        guard chown(url.path, 0, 0) == 0, chmod(url.path, 0o755) == 0 else {
            throw invalid("无法保护恢复资源目录：\(url.path)")
        }
        try validateProtectedAncestors(url)
    }

    private static func validateProtectedAncestors(_ url: URL) throws {
        var current = url
        while true {
            let info = try fileInfo(current.path)
            guard info.st_mode & S_IFMT == S_IFDIR else { throw invalid("恢复资源父目录不是普通目录：\(current.path)") }
            try validateProtection(current, info: info)
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }

    private static func validateProtection(_ url: URL, info: stat) throws {
        guard info.st_uid == 0,
              (info.st_mode & S_IFMT == S_IFLNK || info.st_mode & 0o6022 == 0) else {
            throw invalid("恢复资源允许非 root 用户写入或包含特殊权限：\(url.path)")
        }
        guard info.st_mode & S_IFMT != S_IFLNK else { return }
        guard let security = filesec_init() else { throw invalid("无法初始化恢复资源权限检查") }
        defer { filesec_free(security) }
        var currentInfo = stat()
        guard lstatx_np(url.path, &currentInfo, security) == 0,
              currentInfo.st_dev == info.st_dev, currentInfo.st_ino == info.st_ino,
              currentInfo.st_uid == info.st_uid, currentInfo.st_mode == info.st_mode else {
            throw invalid("恢复资源权限读取失败或检查期间发生变化：\(url.path)")
        }
        // acl_get_file 的 ENOENT 同时表示路径缺失和无扩展 ACL，需分别确认文件与属性状态。
        var hasACL: Int32 = 0
        guard filesec_query_property(security, FILESEC_ACL, &hasACL) == 0 else {
            throw invalid("无法检查恢复资源 ACL 状态：\(url.path)")
        }
        guard hasACL != 0 else { return }
        var storedACL: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &storedACL) == 0, let acl = storedACL else {
            throw invalid("无法检查恢复资源 ACL：\(url.path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writablePermissions: [acl_perm_t] = [
            ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
            ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER
        ]
        let writableMask = writablePermissions.reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        var entry: acl_entry_t?
        var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, entryID, &entry) == 0 {
            entryID = Int32(ACL_NEXT_ENTRY.rawValue)
            guard let entry else { throw invalid("恢复资源 ACL 条目无效：\(url.path)") }
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else {
                throw invalid("无法检查恢复资源 ACL 权限：\(url.path)")
            }
            if tag == ACL_EXTENDED_ALLOW && mask & writableMask != 0 {
                throw invalid("恢复资源 ACL 允许额外写入：\(url.path)")
            }
        }
    }

    private static func clearACL(_ url: URL) throws {
        guard let acl = acl_init(0) else { throw invalid("无法初始化恢复资源 ACL") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else {
            throw invalid("无法清理恢复资源副本 ACL：\(url.path)")
        }
    }

    private static func fileInfo(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw invalid("无法读取恢复资源：\(path)") }
        return info
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid("无法读取恢复资源内容：\(url.path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw invalid("恢复资源不是普通文件：\(url.path)")
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func invalid(_ detail: String) -> HDPIMMaterialError {
        .invalid(detail)
    }
}
