import Foundation
import CryptoKit
import Darwin

enum HDPIMMaterialIntegrity {
    static func verifiedXML(_ url: URL, sha1: String?, sha256: String?) throws -> Data {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw HDPIMMaterialError.invalid("安装材料不可读，请先修复材料：\(url.path)：\(error.localizedDescription)") }
        let expected: String
        let actual: String
        if let hash = sha256, !hash.isEmpty {
            expected = hash
            actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else if let hash = sha1, !hash.isEmpty {
            expected = hash
            actual = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            throw HDPIMMaterialError.invalid("安装材料缺少摘要，请先修复材料：\(url.path)")
        }
        guard actual == expected.lowercased() else {
            throw HDPIMMaterialError.invalid("安装材料摘要不匹配，请先修复材料：\(url.path)")
        }
        return try PIMXParser.decodeXMLData(data, sourceURL: url)
    }

    static func recoveryContext(from context: HDPIMPropertyTable) -> HDPIMPropertyTable {
        let result = context.cloned()
        let temporaryKeys = Set(["stagingfolder", "sourcefolder", "mediafolder"])
        let temporaryRoots = temporaryKeys.compactMap { context.getProperty($0) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for (key, value) in context.allProperties {
            let expanded = context.expandString(value)
            if temporaryKeys.contains(key.lowercased()) || temporaryRoots.contains(where: {
                expanded == $0 || expanded.hasPrefix($0 + "/")
            }) {
                result.removeProperty(key)
            }
        }
        return result
    }

    static func validateFiles(for package: HDPIMNativePackageContext, context: HDPIMPropertyTable) throws {
        let table = recoveryContext(from: context)
        table.setProductInstallDir(package.installDir)
        for (path, sha1, sha256, workflow) in [
            (package.uninstallPIMXPath, package.uninstallPIMXHash, package.uninstallPIMXHash256, "uninstall"),
            (package.repairPIMXPath, package.repairPIMXHash, package.repairPIMXHash256, "install")
        ] {
            guard let path, !path.isEmpty else {
                guard (sha1 ?? "").isEmpty && (sha256 ?? "").isEmpty else {
                    throw HDPIMMaterialError.invalid("材料路径与摘要不成组：\(package.packageName)")
                }
                continue
            }
            let url = URL(fileURLWithPath: path)
            let xml = try verifiedXML(url, sha1: sha1, sha256: sha256)
            table.setProperty("workflowType", workflow)
            let parser = PIMXParser(propertyTable: table)
            let commands = try workflow == "uninstall"
                ? parser.parseUninstallCommands(pimxURL: url, xmlData: xml, preservingUserPreferences: true)
                : parser.parseRepairCommands(pimxURL: url, xmlData: xml)
            if workflow == "uninstall" {
                try validateInstalledPayload(parser.parseInstalledPayload(pimxURL: url, xmlData: xml))
            }
            try HDPIMRepairResources.validateStoredCommands(commands)
        }
    }

    /// DB-only 复用计划已选定的材料；在产品写入前同时确认两个文件与恢复依赖。
    static func validateReuse(_ snapshot: HDPIMInstalledPackageSnapshot,
                              context: HDPIMPropertyTable) throws {
        guard let uninstall = snapshot.uninstallPIMXPath, !uninstall.isEmpty,
              let repair = snapshot.repairPIMXPath, !repair.isEmpty else {
            throw HDPIMMaterialError.invalid("旧包材料不完整，请先修复材料：\(snapshot.packageName)")
        }
        let table = recoveryContext(from: context)
        table.setProductInstallDir(snapshot.installDir)
        table.setProperty("CodexVersion", snapshot.productVersion)
        table.setProperty("PackageVersion", snapshot.packageVersion)
        table.setProperty("workflowType", "uninstall")
        let uninstallURL = URL(fileURLWithPath: uninstall)
        let uninstallXML = try verifiedXML(uninstallURL, sha1: snapshot.uninstallPIMXHash,
                                           sha256: snapshot.uninstallPIMXHash256)
        let uninstallCommands = try PIMXParser(propertyTable: table).parseUninstallCommands(
            pimxURL: uninstallURL, xmlData: uninstallXML, preservingUserPreferences: true
        )
        try validateInstalledPayload(PIMXParser(propertyTable: table).parseInstalledPayload(
            pimxURL: uninstallURL, xmlData: uninstallXML
        ))
        try HDPIMRepairResources.validateStoredCommands(uninstallCommands)
        table.setProperty("workflowType", "install")
        let repairURL = URL(fileURLWithPath: repair)
        let repairXML = try verifiedXML(repairURL, sha1: snapshot.repairPIMXHash,
                                        sha256: snapshot.repairPIMXHash256)
        let repairCommands = try PIMXParser(propertyTable: table).parseRepairCommands(
            pimxURL: repairURL, xmlData: repairXML
        )
        try HDPIMRepairResources.validateStoredCommands(repairCommands)
    }

    /// 用包自身的已校验清单判断能否复用，避免只凭安装目录存在就跳过损坏的包。
    static func validateInstalledPayload(_ snapshot: HDPIMInstalledPackageSnapshot) throws {
        guard let path = snapshot.uninstallPIMXPath, !path.isEmpty else {
            throw HDPIMMaterialError.invalid("旧包缺少载荷清单：\(snapshot.packageName)")
        }
        let table = HDPIMPropertyTable()
        table.setupSystemDirectories()
        table.setProductInstallDir(snapshot.installDir)
        table.setInstallDir(snapshot.installDir)
        table.setProperty("CodexVersion", snapshot.productVersion)
        table.setProperty("PackageVersion", snapshot.packageVersion)
        table.setProperty("workflowType", "uninstall")
        let url = URL(fileURLWithPath: path)
        let xml = try verifiedXML(url, sha1: snapshot.uninstallPIMXHash, sha256: snapshot.uninstallPIMXHash256)
        let commands = try PIMXParser(propertyTable: table).parseInstalledPayload(
            pimxURL: url, xmlData: xml
        )
        try validateInstalledPayload(commands)
    }

    /// 卸载条目也可能包含缓存或共享可变数据；这里只核对应用和框架载荷，排除用户偏好。
    static func validateInstalledPayload(_ commands: [PIMXCommandDescriptor]) throws {
        for command in commands {
            try HDPIMOperationContext.checkCancellation()
            let path: String
            let isDirectory: Bool
            switch command {
            case .deleteFile(let target, false):
                path = target
                isDirectory = false
            case .deleteDirectory(let target, _, false):
                path = target
                isDirectory = true
            default: continue
            }
            guard (path as NSString).pathComponents.contains(where: {
                let component = $0.lowercased()
                return component.hasSuffix(".app") || component.hasSuffix(".framework")
            }) else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw HDPIMMaterialError.invalid("已安装应用载荷缺失或不可读，需要全量修复：\(path)")
            }
            let type = info.st_mode & S_IFMT
            guard isDirectory ? type == S_IFDIR : (type == S_IFREG || type == S_IFLNK) else {
                throw HDPIMMaterialError.invalid("已安装应用载荷类型不匹配，需要全量修复：\(path)")
            }
        }
    }
}
