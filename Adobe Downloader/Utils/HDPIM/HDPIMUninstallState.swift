import Foundation
import SQLite3

struct HDPIMUninstallIdentity: Hashable {
    let sapCode: String
    let version: String
    let processorFamily: HDPIMProcessorFamily

    fileprivate var bindings: [String] { [sapCode, version, processorFamily.rawValue] }
}

struct HDPIMUninstallProductState {
    let identity: HDPIMUninstallIdentity
    let metadata: [String: String]
    let packages: [HDPIMNativePackageContext]

    var baseVersion: String {
        let value = metadata[HDPIMProductMetaKey.baseVersion.rawValue] ?? ""
        return value.isEmpty ? identity.version : value
    }

    var platform: String {
        if let value = metadata[HDPIMProductMetaKey.platform.rawValue], !value.isEmpty {
            return value
        }
        switch identity.processorFamily {
        case .bit32: return "osx"
        case .bit64: return "osx10-64"
        case .arm64Bit: return "macarm64"
        }
    }

    var modules: Set<String> {
        if let value = metadata[HDPIMProductExtraMetaKey.modules] {
            return uninstallMetaValues(value)
        }
        return packages.reduce(into: Set<String>()) { result, package in
            result.formUnion(uninstallMetaValues(package.module ?? ""))
        }
    }
}

struct HDPIMUninstallDatabaseState {
    let products: [HDPIMUninstallIdentity: HDPIMUninstallProductState]
    let references: [DependencyReference]
    fileprivate let latestInstalledVersions: [HDPIMUninstallIdentity: String]

    func resolve(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws -> HDPIMUninstallProductState {
        let identity = HDPIMUninstallIdentity(sapCode: sapCode, version: version, processorFamily: processorFamily)
        if let product = products[identity] {
            return product
        }
        if let latestVersion = latestInstalledVersions[identity], !latestVersion.isEmpty {
            let latestIdentity = HDPIMUninstallIdentity(
                sapCode: sapCode, version: latestVersion, processorFamily: processorFamily
            )
            if let product = products[latestIdentity], product.baseVersion == version {
                return product
            }
            throw HDPIMUninstallStateError.invalidState("产品 \(sapCode) \(version) 的安装版本映射无效")
        }
        throw HDPIMUninstallStateError.invalidState("未找到已安装产品 \(sapCode) \(version) \(processorFamily.rawValue)")
    }
}

enum HDPIMUninstallStateError: Error, LocalizedError {
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .invalidState(let message): return message
        }
    }
}

extension HDPIMDatabase {
    func loadUninstallState() throws -> HDPIMUninstallDatabaseState {
        var metadataByProduct: [HDPIMUninstallIdentity: [String: String]] = [:]
        for row in try uninstallRows("""
            SELECT SAPCode, ProductVersion, ProcessorFamily, Key, Value
            FROM product_installation_meta_info
            """) {
            let identity = try uninstallIdentity(row)
            let key = try uninstallRequired(row[3], label: "产品元数据键")
            guard metadataByProduct[identity]?[key] == nil else {
                throw HDPIMUninstallStateError.invalidState("产品元数据重复：\(identity.sapCode) \(key)")
            }
            metadataByProduct[identity, default: [:]][key] = row[4] ?? ""
        }

        var installedIdentities = Set<HDPIMUninstallIdentity>()
        for row in try uninstallRows("""
            SELECT SAPCode, ProductVersion, ProcessorFamily
            FROM product_installation_info WHERE Status = ?
            """, parameters: [HDPIMInstallStatus.installed.rawValue]) {
            guard installedIdentities.insert(try uninstallIdentity(row)).inserted else {
                throw HDPIMUninstallStateError.invalidState("数据库包含重复的已安装产品")
            }
        }

        var packageMetadata: [UninstallPackageIdentity: [String: String]] = [:]
        for row in try uninstallRows("""
            SELECT m.SAPCode, m.ProductVersion, m.ProcessorFamily, m.PackageName, m.PackageVersion, m.Key, m.Value
            FROM package_installation_meta_info m
            INNER JOIN product_installation_info p
              ON p.SAPCode = m.SAPCode AND p.ProductVersion = m.ProductVersion
             AND p.ProcessorFamily = m.ProcessorFamily AND p.Status = ?
            """, parameters: [HDPIMInstallStatus.installed.rawValue]) {
            let identity = try uninstallPackageIdentity(row)
            let key = try uninstallRequired(row[5], label: "包元数据键")
            guard packageMetadata[identity]?[key] == nil else {
                throw HDPIMUninstallStateError.invalidState("包元数据重复：\(identity.packageName) \(key)")
            }
            packageMetadata[identity, default: [:]][key] = row[6] ?? ""
        }

        var sharedPackages = Set<UninstallPackageIdentity>()
        for row in try uninstallRows("""
            SELECT r.SAPCode, r.ProductVersion, r.ProcessorFamily, r.PackageName, r.PackageVersion
            FROM Package_reference_info r
            INNER JOIN product_installation_info p
              ON p.SAPCode = r.SAPCode AND p.ProductVersion = r.ProductVersion
             AND p.ProcessorFamily = r.ProcessorFamily AND p.Status = ?
            """, parameters: [HDPIMInstallStatus.installed.rawValue]) {
            sharedPackages.insert(try uninstallPackageIdentity(row))
        }

        var packagesByProduct: [HDPIMUninstallIdentity: [HDPIMNativePackageContext]] = [:]
        var packageIdentities = Set<UninstallPackageIdentity>()
        for row in try uninstallRows("""
            SELECT k.SAPCode, k.ProductVersion, k.ProcessorFamily, k.PackageName, k.PackageVersion
            FROM package_installation_info k
            INNER JOIN product_installation_info p
              ON p.SAPCode = k.SAPCode AND p.ProductVersion = k.ProductVersion
             AND p.ProcessorFamily = k.ProcessorFamily AND p.Status = ?
            """, parameters: [HDPIMInstallStatus.installed.rawValue]) {
            let key = try uninstallPackageIdentity(row)
            guard packageIdentities.insert(key).inserted else {
                throw HDPIMUninstallStateError.invalidState("数据库包含重复的已安装包：\(key.packageName)")
            }
            let meta = packageMetadata[key] ?? [:]
            let sequenceValue = meta[HDPIMPackageMetaKey.sequenceNumber.rawValue] ?? "0"
            guard let sequence = Int(sequenceValue) else {
                throw HDPIMUninstallStateError.invalidState("包安装顺序无效：\(key.packageName)")
            }
            packagesByProduct[key.product, default: []].append(HDPIMNativePackageContext(
                sapCode: key.product.sapCode,
                productVersion: key.product.version,
                platform: key.product.processorFamily.rawValue,
                packageName: key.packageName,
                packageVersion: key.packageVersion,
                packageType: meta[HDPIMPackageMetaKey.type.rawValue] ?? "",
                packageProcessorFamily: meta[HDPIMPackageMetaKey.processorFamily.rawValue] ?? "",
                sequenceNumber: sequence,
                installDir: metadataByProduct[key.product]?[HDPIMProductExtraMetaKey.installDir] ?? "",
                uninstallPIMXPath: meta[HDPIMPackageMetaKey.uninstallPIMX.rawValue],
                uninstallPIMXHash: meta[HDPIMPackageMetaKey.uninstallPIMXHash.rawValue],
                uninstallPIMXHash256: meta[HDPIMPackageMetaKey.uninstallPIMXHash256.rawValue],
                repairPIMXPath: meta[HDPIMPackageMetaKey.repairPIMX.rawValue],
                repairPIMXHash: meta[HDPIMPackageMetaKey.repairPIMXHash.rawValue],
                repairPIMXHash256: meta[HDPIMPackageMetaKey.repairPIMXHash256.rawValue],
                installSize: meta[HDPIMPackageMetaKey.installSize.rawValue] ?? "0",
                targetFolders: uninstallMetaValues(meta[HDPIMPackageMetaKey.targetFolderList.rawValue] ?? "").sorted(),
                ribsCoexistenceCode: meta[HDPIMPackageExtraMetaKey.ribsCoexistenceCode.rawValue],
                module: meta[HDPIMPackageExtraMetaKey.module.rawValue],
                uwpInfoXML: meta[HDPIMPackageExtraMetaKey.uwpInfoXML.rawValue],
                isShared: sharedPackages.contains(key)
            ))
        }

        var products: [HDPIMUninstallIdentity: HDPIMUninstallProductState] = [:]
        for identity in installedIdentities {
            let packages = (packagesByProduct[identity] ?? []).sorted {
                if $0.sequenceNumber != $1.sequenceNumber { return $0.sequenceNumber < $1.sequenceNumber }
                if $0.packageName != $1.packageName { return $0.packageName < $1.packageName }
                return AppStatics.compareVersions($0.packageVersion, $1.packageVersion) < 0
            }
            products[identity] = HDPIMUninstallProductState(
                identity: identity, metadata: metadataByProduct[identity] ?? [:], packages: packages
            )
        }

        let references = try uninstallRows("""
            SELECT SAPCode, ProductVersion, ProcessorFamily,
                   ReferencingSAPCode, ReferencingProductVersion, ReferencingProcessorFamily, Type
            FROM product_reference_info
            """).map { row in
                let dependency = try uninstallIdentity(row)
                let referencing = try uninstallIdentity(Array(row[3...5]))
                return DependencyReference(
                    dependencySapCode: dependency.sapCode,
                    dependencyVersion: dependency.version,
                    dependencyProcessorFamily: dependency.processorFamily,
                    referencingSapCode: referencing.sapCode,
                    referencingVersion: referencing.version,
                    referencingProcessorFamily: referencing.processorFamily,
                    referenceType: row[6] ?? ""
                )
            }
        let latestVersions = metadataByProduct.compactMapValues {
            $0[HDPIMProductMetaKey.latestInstalledVersion.rawValue]
        }
        return HDPIMUninstallDatabaseState(
            products: products, references: references, latestInstalledVersions: latestVersions
        )
    }

    func beginUninstallTransaction() throws {
        guard let handle = dbHandle, sqlite3_get_autocommit(handle) != 0 else {
            throw HDPIMUninstallStateError.invalidState("卸载事务无法开始：数据库未打开或已有事务")
        }
        try uninstallExecute("BEGIN IMMEDIATE")
    }

    func commitUninstallTransaction() throws {
        try requireUninstallTransaction()
        try uninstallExecute("COMMIT")
    }

    func rollbackUninstallTransaction() throws {
        try requireUninstallTransaction()
        try uninstallExecute("ROLLBACK")
    }

    /// 文件动作与本方法必须处于调用方持有的同一卸载事务内；发生错误由调用方恢复文件并回滚。
    func commitUninstallProduct(
        _ product: HDPIMUninstallProductState,
        removedPackages: [HDPIMNativePackageContext],
        removingModules: Set<String>,
        entireProduct: Bool
    ) throws {
        try requireUninstallTransaction()
        let identity = product.identity
        guard !(try uninstallRows("""
            SELECT 1 FROM product_installation_info
            WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Status = ? LIMIT 1
            """, parameters: identity.bindings + [HDPIMInstallStatus.installed.rawValue])).isEmpty else {
            throw HDPIMUninstallStateError.invalidState("待卸载产品的安装记录已改变：\(identity.sapCode) \(identity.version)")
        }

        let plannedPackages = Set(product.packages.map(UninstallPackageIdentity.init))
        for key in Set(removedPackages.map(UninstallPackageIdentity.init)) {
            guard key.product == identity, plannedPackages.contains(key) else {
                throw HDPIMUninstallStateError.invalidState("卸载包不属于当前产品计划：\(key.packageName)")
            }
            for table in ["Package_reference_info", "package_installation_meta_info", "package_installation_info"] {
                try uninstallExecute("""
                    DELETE FROM \(table)
                    WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?
                      AND PackageName = ? AND PackageVersion = ?
                    """, parameters: key.bindings)
            }
        }

        if !entireProduct {
            guard !removingModules.isEmpty else { return }
            let remainingModules = product.modules.subtracting(removingModules)
            try uninstallExecute("""
                INSERT OR REPLACE INTO product_installation_meta_info
                (SAPCode, ProductVersion, ProcessorFamily, Key, Value) VALUES (?, ?, ?, ?, ?)
                """, parameters: identity.bindings + [
                    HDPIMProductExtraMetaKey.modules, remainingModules.sorted().joined(separator: ",")
                ])
            for row in try uninstallRows("""
                SELECT p.PackageName, p.PackageVersion, m.Value
                FROM package_installation_info p
                INNER JOIN package_installation_meta_info m
                  ON m.SAPCode = p.SAPCode AND m.ProductVersion = p.ProductVersion
                 AND m.ProcessorFamily = p.ProcessorFamily AND m.PackageName = p.PackageName
                 AND m.PackageVersion = p.PackageVersion AND m.Key = ?
                WHERE p.SAPCode = ? AND p.ProductVersion = ? AND p.ProcessorFamily = ?
                """, parameters: [HDPIMPackageExtraMetaKey.module.rawValue] + identity.bindings) {
                let packageName = try uninstallRequired(row[0], label: "包名")
                let packageVersion = try uninstallRequired(row[1], label: "包版本")
                let modules = uninstallMetaValues(row[2] ?? "").intersection(remainingModules)
                try uninstallExecute("""
                    UPDATE package_installation_meta_info SET Value = ?
                    WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?
                      AND PackageName = ? AND PackageVersion = ? AND Key = ?
                    """, parameters: [modules.sorted().joined(separator: ",")] + identity.bindings + [
                        packageName, packageVersion, HDPIMPackageExtraMetaKey.module.rawValue
                    ])
            }
            return
        }

        try requireNoUninstallPackages(identity)
        try removeUninstallProductRecords(identity)

        if product.baseVersion != identity.version {
            let baseIdentity = HDPIMUninstallIdentity(
                sapCode: identity.sapCode, version: product.baseVersion, processorFamily: identity.processorFamily
            )
            let rows = try uninstallRows("""
                SELECT Value FROM product_installation_meta_info
                WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Key = ?
                """, parameters: baseIdentity.bindings + [HDPIMProductMetaKey.latestInstalledVersion.rawValue])
            if rows.first?.first == identity.version {
                try requireNoUninstallPackages(baseIdentity)
                try removeUninstallProductRecords(baseIdentity, removedVersion: identity.version)
            }
        }
    }

    func uninstallMaterialIsReferenced(path: String) throws -> Bool {
        !(try uninstallRows("""
            SELECT 1 FROM package_installation_meta_info
            WHERE Key IN (?, ?) AND Value = ? LIMIT 1
            """, parameters: [
                HDPIMPackageMetaKey.uninstallPIMX.rawValue, HDPIMPackageMetaKey.repairPIMX.rawValue, path
            ])).isEmpty
    }

    func hasInstalledNonCCProducts() throws -> Bool {
        !(try uninstallRows("""
            SELECT 1 FROM product_installation_info p
            INNER JOIN product_installation_meta_info m
              ON m.SAPCode = p.SAPCode AND m.ProductVersion = p.ProductVersion
             AND m.ProcessorFamily = p.ProcessorFamily
            WHERE p.Status = ? AND m.Key = ? AND LOWER(TRIM(m.Value)) IN ('true', '1', 'yes')
            LIMIT 1
            """, parameters: [
                HDPIMInstallStatus.installed.rawValue, HDPIMProductExtraMetaKey.isNonCCProduct
            ])).isEmpty
    }

    private func requireUninstallTransaction() throws {
        guard let handle = dbHandle, sqlite3_get_autocommit(handle) == 0 else {
            throw HDPIMUninstallStateError.invalidState("卸载数据库写入需要调用方持有事务")
        }
    }

    private func requireNoUninstallPackages(_ identity: HDPIMUninstallIdentity) throws {
        guard try uninstallRows("""
            SELECT 1 FROM package_installation_info
            WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? LIMIT 1
            """, parameters: identity.bindings).isEmpty else {
            throw HDPIMUninstallStateError.invalidState("产品仍有安装包，不能删除产品记录：\(identity.sapCode) \(identity.version)")
        }
    }

    private func removeUninstallProductRecords(
        _ identity: HDPIMUninstallIdentity,
        removedVersion: String? = nil
    ) throws {
        try uninstallExecute("""
            DELETE FROM product_reference_info
            WHERE ReferencingSAPCode = ? AND ReferencingProductVersion = ? AND ReferencingProcessorFamily = ?
            """, parameters: identity.bindings)
        // 旧 CodexVersion 可能同时是新版本的 BaseVersion 槽，保留指向其他版本的映射。
        try uninstallExecute("""
            DELETE FROM product_installation_meta_info
            WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?
              AND (Key <> ? OR Value IS NULL OR Value = ?)
            """, parameters: identity.bindings + [
                HDPIMProductMetaKey.latestInstalledVersion.rawValue, removedVersion ?? identity.version
            ])
        try uninstallExecute("""
            DELETE FROM product_installation_info
            WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?
            """, parameters: identity.bindings)
    }

    private func uninstallExecute(_ sql: String, parameters: [String] = []) throws {
        _ = try uninstallRows(sql, parameters: parameters)
    }

    private func uninstallRows(_ sql: String, parameters: [String] = []) throws -> [[String?]] {
        guard let handle = dbHandle else {
            throw HDPIMUninstallStateError.invalidState("卸载数据库未打开")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(parameters.count) else {
            throw HDPIMUninstallStateError.invalidState("卸载数据库语句参数数量不匹配")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in parameters.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient)
            }
            guard result == SQLITE_OK else {
                throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            let row: [String?] = (0..<sqlite3_column_count(statement)).map { index in
                guard let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            }
            rows.append(row)
        }
    }
}

private struct UninstallPackageIdentity: Hashable {
    let product: HDPIMUninstallIdentity
    let packageName: String
    let packageVersion: String

    init(product: HDPIMUninstallIdentity, packageName: String, packageVersion: String) {
        self.product = product
        self.packageName = packageName
        self.packageVersion = packageVersion
    }

    init(_ package: HDPIMNativePackageContext) {
        product = HDPIMUninstallIdentity(
            sapCode: package.sapCode, version: package.productVersion, processorFamily: package.processorFamily
        )
        packageName = package.packageName
        packageVersion = package.packageVersion
    }

    var bindings: [String] { product.bindings + [packageName, packageVersion] }
}

private func uninstallIdentity(_ row: [String?]) throws -> HDPIMUninstallIdentity {
    let rawFamily = try uninstallRequired(row[2], label: "产品架构")
    guard let family = HDPIMProcessorFamily(rawValue: rawFamily) else {
        throw HDPIMUninstallStateError.invalidState("数据库中的产品架构无效：\(rawFamily)")
    }
    return HDPIMUninstallIdentity(
        sapCode: try uninstallRequired(row[0], label: "SAPCode"),
        version: try uninstallRequired(row[1], label: "产品版本"),
        processorFamily: family
    )
}

private func uninstallPackageIdentity(_ row: [String?]) throws -> UninstallPackageIdentity {
    UninstallPackageIdentity(
        product: try uninstallIdentity(row),
        packageName: try uninstallRequired(row[3], label: "包名"),
        packageVersion: try uninstallRequired(row[4], label: "包版本")
    )
}

private func uninstallRequired(_ value: String?, label: String) throws -> String {
    guard let value, !value.isEmpty else {
        throw HDPIMUninstallStateError.invalidState("数据库中的\(label)为空")
    }
    return value
}

private func uninstallMetaValues(_ value: String) -> Set<String> {
    Set(value.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })
}
