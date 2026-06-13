//
//  HDPIMDatabase.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2026/03/18.
//

import Foundation
import SQLite3

struct HDPIMInstallRecord {
    let sapCode: String
    let codexVersion: String
    let platform: String
    let packageName: String
    let packageVersion: String
    let installPath: String
    let uninstallPIMXPath: String?
    let uninstallPIMXHash: String?
    let installTimestamp: Date
}

struct HDPIMInstalledPackageSnapshot {
    let sapCode: String
    let productVersion: String
    let processorFamily: HDPIMProcessorFamily
    let packageName: String
    let packageVersion: String
    let installDir: String
    let uninstallPIMXPath: String?
    let uninstallPIMXHash: String?
    let uninstallPIMXHash256: String?
    let repairPIMXPath: String?
    let repairPIMXHash: String?
    let repairPIMXHash256: String?
    let targetFolders: [String]
}

enum HDPIMInstallStatus: String {
    case notInstalled = "0"
    case installed = "1"
}

enum HDPIMProcessorFamily: String, Hashable {
    case bit32 = "32Bit"
    case bit64 = "64Bit"
    case arm64Bit = "Arm64Bit"

	static func from(platform: String) -> HDPIMProcessorFamily {
		let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		switch normalized {
		case "MACARM64", "ARM64BIT", "ARM64", "AARCH64":
			return .arm64Bit
		case "OSX", "32BIT", "I386", "X86":
			return .bit32
		case "OSX10", "64BIT", "X64", "X86_64":
			return .bit64
		default:
			return .bit64
		}
	}
}

enum HDPIMProductMetaKey: String {
    case appLaunch = "AppLaunch"
    case installLang = "InstallLang"
    case latestInstalledVersion = "LatestInstalledVersion"
    case baseVersion = "BaseVersion"
    case platform = "Platform"
    case conflictingProcesses = "ConflictingProcesses"
    case conflictingProcessesXML = "ConflictingProcessesXML"
    case name = "Name"
    case buildVersion = "BuildVersion"
    case amtConfigLEID = "AMTConfig.LEID"
}

enum HDPIMPackageMetaKey: String {
    case type = "Type"
    case sequenceNumber = "SequenceNumber"
    case uninstallPIMX = "UninstallPIMX"
    case uninstallPIMXHash = "UninstallPIMXHash"
    case uninstallPIMXHash256 = "UninstallPIMXHash256"
    case repairPIMX = "RepairPIMX"
    case repairPIMXHash = "RepairPIMXHash"
    case repairPIMXHash256 = "RepairPIMXHash256"
    case installSize = "InstallSize"
    case processorFamily = "ProcessorFamily"
    case targetFolderList = "TargetFolderList"
}

enum HDPIMProductExtraMetaKey {
    static let installDir = "InstallDir"
    static let installDirBookmarkData = "installDirBookmarkData"
    static let launchPathBookmarkData = "launchPathBookmarkData"
    static let buildGuid = "BuildGuid"
    static let amtConfigAppID = "AMTConfig.appID"
    static let amtConfigPath = "AMTConfig.path"
    static let modules = "modules"
    static let isUWPProduct = "isUWPProduct"
    static let isSelfReference = "isSelfReference"
    static let autoInstall = "autoInstall"
    static let autoPatchUpdate = "autoPatchUpdate"
    static let isVisibleProduct = "isVisibleProduct"
    static let isNonCCProduct = "isNonCCProduct"
    static let vulcanConfig = "VulcanConfig"
    static let uxpPluginConfig = "UxpPluginConfig"
    static let ffcEnvironment = "FFCEnvironment"
}

enum HDPIMPackageExtraMetaKey: String {
    case ribsCoexistenceCode = "RIBSCoexistenceCode"
    case uwpInfoXML = "UWPInfoXML"
    case module = "Module"
}

struct HDPIMNativeProductRecord {
    let sapCode: String
    let productVersion: String
    let processorFamily: HDPIMProcessorFamily
    let status: HDPIMInstallStatus
}

struct HDPIMNativePackageRecord {
    let sapCode: String
    let productVersion: String
    let processorFamily: HDPIMProcessorFamily
    let packageName: String
    let packageVersion: String
    let isShared: Bool
}

struct HDPIMNativeProductMetaRecord {
    let sapCode: String
    let productVersion: String
    let processorFamily: HDPIMProcessorFamily
    let key: String
    let value: String
    let appendIfNeeded: Bool
}

struct HDPIMNativePackageMetaRecord {
    let sapCode: String
    let productVersion: String
    let processorFamily: HDPIMProcessorFamily
    let packageName: String
    let packageVersion: String
    let key: String
    let value: String
    let appendIfNeeded: Bool
}

struct HDPIMNativeProductReferenceRecord {
    let dependencySapCode: String
    let dependencyVersion: String
    let dependencyProcessorFamily: HDPIMProcessorFamily
    let referencingSapCode: String
    let referencingVersion: String
    let referencingProcessorFamily: HDPIMProcessorFamily
    let type: String
}

struct HDPIMNativeProductKey: Hashable {
    let sapCode: String
    let version: String
    let platform: String

    var processorFamily: HDPIMProcessorFamily {
        HDPIMProcessorFamily.from(platform: platform)
    }
}

struct HDPIMNativeProductContext {
    let sapCode: String
    let codexVersion: String
    let platform: String
    let buildGuid: String
    let buildVersion: String
    let baseVersion: String
    let installLanguage: String
    let productName: String
    let amtConfigLEID: String?
    let amtConfigAppID: String?
    let amtConfigPath: String?
    let conflictingProcesses: String
    let conflictingProcessesXML: String
    let installDir: String
    let appLaunchPath: String
    let resolvedAppLaunchPath: String
    let modules: [String]
    let autoInstall: Bool
    let isVisibleProduct: Bool
    let isSelfReference: Bool
    let isNonCCProduct: Bool
    let vulcanConfig: String?
    let uxpPluginConfig: String?
    let ffcEnvironment: String?
    let dependencies: [HDPIMNativeProductReferenceRecord]

    var processorFamily: HDPIMProcessorFamily {
        HDPIMProcessorFamily.from(platform: platform)
    }

    var productKey: HDPIMNativeProductKey {
        HDPIMNativeProductKey(
            sapCode: sapCode,
            version: codexVersion,
            platform: platform
        )
    }

    var latestInstalledVersionSlot: String {
        let trimmed = baseVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? codexVersion : trimmed
    }
}

struct HDPIMNativePackageContext {
    let sapCode: String
    let productVersion: String
    let platform: String
    let packageName: String
    let packageVersion: String
    let packageType: String
    let packageProcessorFamily: String
    let sequenceNumber: Int
    let installDir: String
    let uninstallPIMXPath: String?
    let uninstallPIMXHash: String?
    let uninstallPIMXHash256: String?
    let repairPIMXPath: String?
    let repairPIMXHash: String?
    let repairPIMXHash256: String?
    let installSize: String
    let targetFolders: [String]
    let ribsCoexistenceCode: String?
    let module: String?
    let uwpInfoXML: String?
    let isShared: Bool

    var processorFamily: HDPIMProcessorFamily {
        HDPIMProcessorFamily.from(platform: platform)
    }
}

final class HDPIMDatabase {

    static let shared = HDPIMDatabase()

    private enum Schema {
        static let productInstallationInfo = "product_installation_info"
        static let packageInstallationInfo = "package_installation_info"
        static let productInstallationMetaInfo = "product_installation_meta_info"
        static let packageInstallationMetaInfo = "package_installation_meta_info"
        static let productReferenceInfo = "product_reference_info"
        static let packageReferenceInfo = "Package_reference_info"
        static let userActionInfo = "user_action_info"
        static let pimMeta = "pim_meta"
    }

    private var db: OpaquePointer?
    private let dbPath: URL

	var dbHandle: OpaquePointer? { db }

	var isOpen: Bool { db != nil }

    private init() {
        let appSupport = URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
        let capsDir = appSupport
            .appendingPathComponent("Adobe", isDirectory: true)
            .appendingPathComponent("caps", isDirectory: true)
        dbPath = capsDir.appendingPathComponent("hdpim.db")
    }

	func open() throws {
		if db != nil {
			return
		}

		try FileManager.default.createDirectory(
			at: dbPath.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

        if sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            throw HDPIMDatabaseError.openFailed(lastErrorMessage())
        }

        sqlite3_busy_timeout(db, 1000)

        do {
            try ensureSchema()
        } catch {
            close()
            throw error
        }
	}

	func openReadOnly() throws {
		if db != nil {
			return
		}

		if sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
			throw HDPIMDatabaseError.openFailed(lastErrorMessage())
		}
        sqlite3_busy_timeout(db, 1000)
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func recordInstall(products: [HDPIMNativeProductContext], packages: [HDPIMNativePackageContext]) throws {
        guard db != nil else {
            throw HDPIMDatabaseError.queryFailed("数据库未打开")
        }

        try beginTransaction(name: "HDPIMDatabase-recordInstall")
        do {
            for product in products {
                try writeProduct(product)
            }
            for product in products {
                for dependency in product.dependencies {
                    try writeProductReference(dependency)
                }
            }
            for package in packages {
                try writePackage(package)
            }
            try commitTransaction(name: "HDPIMDatabase-recordInstall")
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-recordInstall")
            throw error
        }
    }

    func recordInstalledPackage(
        _ package: HDPIMNativePackageContext,
        product: HDPIMNativeProductContext?
    ) throws {
        guard db != nil else {
            throw HDPIMDatabaseError.queryFailed("数据库未打开")
        }

        let legacySnapshot = getInstalledPackageSnapshots(
            sapCode: package.sapCode,
            processorFamily: package.processorFamily,
            packageName: package.packageName,
            expectedInstallDir: package.installDir
        ).first

        let packageWithInheritedData = package.withInheritedLegacyData(from: legacySnapshot)

        try beginTransaction(name: "HDPIMDatabase-recordInstalledPackage")
        do {
            try writePackage(packageWithInheritedData)
            if let product {
                try writeProductInstallLocation(
                    sapCode: product.sapCode,
                    productVersion: product.codexVersion,
                    processorFamily: product.processorFamily,
                    installDir: product.installDir,
                    resolvedAppLaunchPath: product.resolvedAppLaunchPath
                )
            }
            try commitTransaction(name: "HDPIMDatabase-recordInstalledPackage")

            if let ribsCode = packageWithInheritedData.ribsCoexistenceCode, !ribsCode.isEmpty,
               let product = product {
                _ = HDPIMRIBSHelper.addRIBSDependency(
                    ribsCode: ribsCode,
                    sapCode: product.sapCode,
                    baseVersion: product.baseVersion,
                    productName: product.productName
                )
            }
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-recordInstalledPackage")
            throw error
        }
    }

    func recordInstalledProducts(_ products: [HDPIMNativeProductContext]) throws {
        guard db != nil else {
            throw HDPIMDatabaseError.queryFailed("数据库未打开")
        }

        try beginTransaction(name: "HDPIMDatabase-recordInstalledProducts")
        do {
            for product in products {
                try writeProduct(product)
            }
            for product in products {
                for dependency in product.dependencies {
                    try writeProductReference(dependency)
                }
            }
            try commitTransaction(name: "HDPIMDatabase-recordInstalledProducts")
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-recordInstalledProducts")
            throw error
        }
    }

    func removeInstallations(productKeys: [HDPIMNativeProductKey]) throws {
        let uniqueKeys = Array(Set(productKeys))
        try beginTransaction(name: "HDPIMDatabase-removeInstallation")
        do {
            for key in uniqueKeys {
                let latestInstalledVersionSlot = try fetchProductBaseVersion(
                    sapCode: key.sapCode,
                    version: key.version,
                    processorFamily: key.processorFamily
                ) ?? key.version

                try deleteProductReference(
                    sapCode: key.sapCode,
                    version: latestInstalledVersionSlot,
                    processorFamily: key.processorFamily,
                    referencingVersion: key.version
                )
                try deletePackageReference(for: key.sapCode, version: key.version, processorFamily: key.processorFamily)
                try deletePackageMeta(for: key.sapCode, version: key.version, processorFamily: key.processorFamily)
                try deletePackageInfo(for: key.sapCode, version: key.version, processorFamily: key.processorFamily)
                try deleteProductRecords(
                    sapCode: key.sapCode,
                    version: key.version,
                    processorFamily: key.processorFamily
                )
                if latestInstalledVersionSlot != key.version {
                    try deleteProductRecords(
                        sapCode: key.sapCode,
                        version: latestInstalledVersionSlot,
                        processorFamily: key.processorFamily
                    )
                }
            }
            try commitTransaction(name: "HDPIMDatabase-removeInstallation")
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-removeInstallation")
            throw error
        }
    }

    func removeProductInstallationRecords(productKeys: [HDPIMNativeProductKey]) throws {
        let uniqueKeys = Array(Set(productKeys))
        try beginTransaction(name: "HDPIMDatabase-removeProductInstallationRecords")
        do {
            for key in uniqueKeys {
                let latestInstalledVersionSlot = try fetchProductBaseVersion(
                    sapCode: key.sapCode,
                    version: key.version,
                    processorFamily: key.processorFamily
                ) ?? key.version

                try deleteProductReference(
                    sapCode: key.sapCode,
                    version: latestInstalledVersionSlot,
                    processorFamily: key.processorFamily,
                    referencingVersion: key.version
                )
                try deleteProductRecords(
                    sapCode: key.sapCode,
                    version: key.version,
                    processorFamily: key.processorFamily
                )
                if latestInstalledVersionSlot != key.version {
                    try deleteProductRecords(
                        sapCode: key.sapCode,
                        version: latestInstalledVersionSlot,
                        processorFamily: key.processorFamily
                    )
                }
            }
            try commitTransaction(name: "HDPIMDatabase-removeProductInstallationRecords")
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-removeProductInstallationRecords")
            throw error
        }
    }

    func removeInstallations(
        products: [HDPIMNativeProductContext],
        removeRepairPIMX: Bool = false,
        removeUninstallPIMX: Bool = false
    ) throws {
        let uniqueProducts = Array(
            Dictionary(
                uniqueKeysWithValues: products.map {
                    (productIdentity(sapCode: $0.sapCode, version: $0.codexVersion, processorFamily: $0.processorFamily.rawValue), $0)
                }
            ).values
        )

        let pimsToDelete = try uniqueProducts.flatMap { product in
            try collectPIMXPaths(
                sapCode: product.sapCode,
                version: product.codexVersion,
                processorFamily: product.processorFamily,
                includeRepair: removeRepairPIMX,
                includeUninstall: removeUninstallPIMX
            )
        }

        try beginTransaction(name: "HDPIMDatabase-removeInstallation")
        do {
            for product in uniqueProducts {
                try deleteProductLifecycle(product)
            }
            try commitTransaction(name: "HDPIMDatabase-removeInstallation")
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-removeInstallation")
            throw error
        }

        for path in Set(pimsToDelete) where !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func removeInstalledPackages(
        _ packages: [HDPIMNativePackageContext],
        removeRepairPIMX: Bool = false,
        removeUninstallPIMX: Bool = false
    ) throws {
        let uniquePackages = Array(
            Dictionary(
                uniqueKeysWithValues: packages.map {
                    (
                        packageIdentity(
                            sapCode: $0.sapCode,
                            version: $0.productVersion,
                            processorFamily: $0.processorFamily.rawValue,
                            packageName: $0.packageName,
                            packageVersion: $0.packageVersion
                        ),
                        $0
                    )
                }
            ).values
        )

        let pimxPaths = uniquePackages.flatMap { package in
            [
                removeRepairPIMX ? package.repairPIMXPath : nil,
                removeUninstallPIMX ? package.uninstallPIMXPath : nil
            ].compactMap { $0 }.filter { !$0.isEmpty }
        }

        try beginTransaction(name: "HDPIMDatabase-removeInstalledPackages")
        do {
            for package in uniquePackages {
                try deletePackageReference(
                    packageName: package.packageName,
                    packageVersion: package.packageVersion,
                    sapCode: package.sapCode,
                    version: package.productVersion,
                    processorFamily: package.processorFamily
                )
                try deletePackageMeta(
                    sapCode: package.sapCode,
                    version: package.productVersion,
                    processorFamily: package.processorFamily,
                    packageName: package.packageName,
                    packageVersion: package.packageVersion
                )
                try deletePackageInfo(
                    sapCode: package.sapCode,
                    version: package.productVersion,
                    processorFamily: package.processorFamily,
                    packageName: package.packageName,
                    packageVersion: package.packageVersion
                )
            }
            try commitTransaction(name: "HDPIMDatabase-removeInstalledPackages")

            for package in uniquePackages {
                if let ribsCode = package.ribsCoexistenceCode, !ribsCode.isEmpty {
                    _ = HDPIMRIBSHelper.removeRIBSDependency(
                        ribsCode: ribsCode,
                        sapCode: package.sapCode,
                        baseVersion: package.productVersion
                    )
                }
            }
        } catch {
            try? rollbackTransaction(name: "HDPIMDatabase-removeInstalledPackages")
            throw error
        }

        for path in Set(pimxPaths) where !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func isInstalled(sapCode: String, version: String) -> Bool {
        let sql = """
        SELECT COUNT(*)
        FROM \(Schema.productInstallationInfo)
        WHERE SAPCode = ? AND ProductVersion = ? AND Status = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        bindText(sapCode, index: 1, to: stmt)
        bindText(version, index: 2, to: stmt)
        bindText(HDPIMInstallStatus.installed.rawValue, index: 3, to: stmt)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    func isProductReallyInstalled(sapCode: String, version: String, platform: String, validateFiles: Bool = false) -> Bool {
        if db == nil {
            try? openReadOnly()
        }
        return isInstalled(sapCode: sapCode, version: version)
    }

    func getInstalledPackages(sapCode: String, version: String) -> [HDPIMInstallRecord] {
        let sql = """
        SELECT p.SAPCode,
               p.ProductVersion,
               p.ProcessorFamily,
               p.PackageName,
               p.PackageVersion,
               COALESCE(pm_install.Value, ''),
               pm_uninstall.Value,
               pm_uninstall_sha1.Value
        FROM \(Schema.packageInstallationInfo) p
        LEFT JOIN \(Schema.productInstallationMetaInfo) pm_install
          ON pm_install.SAPCode = p.SAPCode
         AND pm_install.ProductVersion = p.ProductVersion
         AND pm_install.ProcessorFamily = p.ProcessorFamily
         AND pm_install.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_uninstall
          ON pm_uninstall.SAPCode = p.SAPCode
         AND pm_uninstall.ProductVersion = p.ProductVersion
         AND pm_uninstall.ProcessorFamily = p.ProcessorFamily
         AND pm_uninstall.PackageName = p.PackageName
         AND pm_uninstall.PackageVersion = p.PackageVersion
         AND pm_uninstall.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_uninstall_sha1
          ON pm_uninstall_sha1.SAPCode = p.SAPCode
         AND pm_uninstall_sha1.ProductVersion = p.ProductVersion
         AND pm_uninstall_sha1.ProcessorFamily = p.ProcessorFamily
         AND pm_uninstall_sha1.PackageName = p.PackageName
         AND pm_uninstall_sha1.PackageVersion = p.PackageVersion
         AND pm_uninstall_sha1.Key = ?
        WHERE p.SAPCode = ? AND p.ProductVersion = ?
        ORDER BY p.PackageName, p.PackageVersion;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        bindText(HDPIMProductExtraMetaKey.installDir, index: 1, to: stmt)
        bindText(HDPIMPackageMetaKey.uninstallPIMX.rawValue, index: 2, to: stmt)
        bindText(HDPIMPackageMetaKey.uninstallPIMXHash.rawValue, index: 3, to: stmt)
        bindText(sapCode, index: 4, to: stmt)
        bindText(version, index: 5, to: stmt)

        var records: [HDPIMInstallRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(
                HDPIMInstallRecord(
                    sapCode: columnText(stmt, index: 0),
                    codexVersion: columnText(stmt, index: 1),
                    platform: columnText(stmt, index: 2),
                    packageName: columnText(stmt, index: 3),
                    packageVersion: columnText(stmt, index: 4),
                    installPath: columnText(stmt, index: 5),
                    uninstallPIMXPath: columnOptionalText(stmt, index: 6),
                    uninstallPIMXHash: columnOptionalText(stmt, index: 7),
                    installTimestamp: Date()
                )
            )
        }
		return records
	}

	func getInstalledPackageContexts(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleIds: Set<String> = [],
		packageNames: Set<String> = []
	) -> [HDPIMNativePackageContext] {
		let sql = """
		SELECT p.SAPCode,
		       p.ProductVersion,
		       p.ProcessorFamily,
		       p.PackageName,
		       p.PackageVersion,
		       COALESCE(pm_install.Value, '')
		FROM \(Schema.packageInstallationInfo) p
		INNER JOIN \(Schema.productInstallationInfo) prod
		  ON prod.SAPCode = p.SAPCode
		 AND prod.ProductVersion = p.ProductVersion
		 AND prod.ProcessorFamily = p.ProcessorFamily
		 AND prod.Status = ?
		LEFT JOIN \(Schema.productInstallationMetaInfo) pm_install
		  ON pm_install.SAPCode = p.SAPCode
		 AND pm_install.ProductVersion = p.ProductVersion
		 AND pm_install.ProcessorFamily = p.ProcessorFamily
		 AND pm_install.Key = ?
		WHERE p.SAPCode = ? AND p.ProductVersion = ? AND p.ProcessorFamily = ?
		ORDER BY p.PackageName, p.PackageVersion;
		"""

		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
			return []
		}
		defer { sqlite3_finalize(stmt) }

		bindText(HDPIMInstallStatus.installed.rawValue, index: 1, to: stmt)
		bindText(HDPIMProductExtraMetaKey.installDir, index: 2, to: stmt)
		bindText(sapCode, index: 3, to: stmt)
		bindText(version, index: 4, to: stmt)
		bindText(processorFamily.rawValue, index: 5, to: stmt)

		var packages: [HDPIMNativePackageContext] = []
		while sqlite3_step(stmt) == SQLITE_ROW {
			let packageName = columnText(stmt, index: 3)
			let packageVersion = columnText(stmt, index: 4)
			if !packageNames.isEmpty, !packageNames.contains(packageName) {
				continue
			}

			let context = makeInstalledPackageContext(
				sapCode: columnText(stmt, index: 0),
				productVersion: columnText(stmt, index: 1),
				processorFamily: HDPIMProcessorFamily.from(platform: columnText(stmt, index: 2)),
				packageName: packageName,
				packageVersion: packageVersion,
				installDir: columnText(stmt, index: 5)
			)

			if !moduleIds.isEmpty {
				let packageModules = Set(splitMetaValues(context.module ?? ""))
				if packageModules.isDisjoint(with: moduleIds) {
					continue
				}
			}

			packages.append(context)
		}

		return packages.sorted { lhs, rhs in
			if lhs.sequenceNumber != rhs.sequenceNumber {
				return lhs.sequenceNumber < rhs.sequenceNumber
			}
			if lhs.packageName != rhs.packageName {
				return lhs.packageName < rhs.packageName
			}
			return AppStatics.compareVersions(lhs.packageVersion, rhs.packageVersion) < 0
		}
	}

	func getInstalledModuleIds(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
	) -> [String] {
		guard let raw = getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductExtraMetaKey.modules
		) else {
			return []
		}
		return splitMetaValues(raw)
	}

	func updateInstalledModules(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		removing moduleIds: Set<String>
	) throws -> [String] {
		let remainingModules = getInstalledModuleIds(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)
		.filter { !moduleIds.contains($0) }

		try insertProductMeta(
			.init(
				sapCode: sapCode,
				productVersion: version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.modules,
				value: remainingModules.joined(separator: ","),
				appendIfNeeded: false
			)
		)

		return remainingModules
	}

	func getInstalledPackageNames(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
    ) -> [String] {
        let sql = """
        SELECT p.PackageName
        FROM \(Schema.packageInstallationInfo) p
        INNER JOIN \(Schema.productInstallationInfo) prod
          ON prod.SAPCode = p.SAPCode
         AND prod.ProductVersion = p.ProductVersion
         AND prod.ProcessorFamily = p.ProcessorFamily
         AND prod.Status = ?
        WHERE p.SAPCode = ? AND p.ProductVersion = ? AND p.ProcessorFamily = ?
        ORDER BY p.PackageName;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        bindText(HDPIMInstallStatus.installed.rawValue, index: 1, to: stmt)
        bindText(sapCode, index: 2, to: stmt)
        bindText(version, index: 3, to: stmt)
        bindText(processorFamily.rawValue, index: 4, to: stmt)

        var packageNames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let packageName = columnText(stmt, index: 0)
            if !packageName.isEmpty {
                packageNames.append(packageName)
            }
        }
        return packageNames
    }

    func getInstalledPackageSnapshots(
        sapCode: String,
        processorFamily: HDPIMProcessorFamily,
        packageName: String,
        expectedInstallDir: String
    ) -> [HDPIMInstalledPackageSnapshot] {
        let sql = """
        SELECT p.SAPCode,
               p.ProductVersion,
               p.PackageName,
               p.PackageVersion,
               COALESCE(pm_install_dir.Value, ''),
               pm_uninstall.Value,
               pm_uninstall_sha1.Value,
               pm_uninstall_sha256.Value,
               pm_repair.Value,
               pm_repair_sha1.Value,
               pm_repair_sha256.Value
        FROM \(Schema.packageInstallationInfo) p
        INNER JOIN \(Schema.productInstallationInfo) prod
          ON prod.SAPCode = p.SAPCode
         AND prod.ProductVersion = p.ProductVersion
         AND prod.ProcessorFamily = p.ProcessorFamily
         AND prod.Status = ?
        LEFT JOIN \(Schema.productInstallationMetaInfo) pm_install_dir
          ON pm_install_dir.SAPCode = p.SAPCode
         AND pm_install_dir.ProductVersion = p.ProductVersion
         AND pm_install_dir.ProcessorFamily = p.ProcessorFamily
         AND pm_install_dir.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_uninstall
          ON pm_uninstall.SAPCode = p.SAPCode
         AND pm_uninstall.ProductVersion = p.ProductVersion
         AND pm_uninstall.ProcessorFamily = p.ProcessorFamily
         AND pm_uninstall.PackageName = p.PackageName
         AND pm_uninstall.PackageVersion = p.PackageVersion
         AND pm_uninstall.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_uninstall_sha1
          ON pm_uninstall_sha1.SAPCode = p.SAPCode
         AND pm_uninstall_sha1.ProductVersion = p.ProductVersion
         AND pm_uninstall_sha1.ProcessorFamily = p.ProcessorFamily
         AND pm_uninstall_sha1.PackageName = p.PackageName
         AND pm_uninstall_sha1.PackageVersion = p.PackageVersion
         AND pm_uninstall_sha1.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_uninstall_sha256
          ON pm_uninstall_sha256.SAPCode = p.SAPCode
         AND pm_uninstall_sha256.ProductVersion = p.ProductVersion
         AND pm_uninstall_sha256.ProcessorFamily = p.ProcessorFamily
         AND pm_uninstall_sha256.PackageName = p.PackageName
         AND pm_uninstall_sha256.PackageVersion = p.PackageVersion
         AND pm_uninstall_sha256.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_repair
          ON pm_repair.SAPCode = p.SAPCode
         AND pm_repair.ProductVersion = p.ProductVersion
         AND pm_repair.ProcessorFamily = p.ProcessorFamily
         AND pm_repair.PackageName = p.PackageName
         AND pm_repair.PackageVersion = p.PackageVersion
         AND pm_repair.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_repair_sha1
          ON pm_repair_sha1.SAPCode = p.SAPCode
         AND pm_repair_sha1.ProductVersion = p.ProductVersion
         AND pm_repair_sha1.ProcessorFamily = p.ProcessorFamily
         AND pm_repair_sha1.PackageName = p.PackageName
         AND pm_repair_sha1.PackageVersion = p.PackageVersion
         AND pm_repair_sha1.Key = ?
        LEFT JOIN \(Schema.packageInstallationMetaInfo) pm_repair_sha256
          ON pm_repair_sha256.SAPCode = p.SAPCode
         AND pm_repair_sha256.ProductVersion = p.ProductVersion
         AND pm_repair_sha256.ProcessorFamily = p.ProcessorFamily
         AND pm_repair_sha256.PackageName = p.PackageName
         AND pm_repair_sha256.PackageVersion = p.PackageVersion
         AND pm_repair_sha256.Key = ?
        WHERE p.SAPCode = ? AND p.ProcessorFamily = ? AND p.PackageName = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        bindText(HDPIMInstallStatus.installed.rawValue, index: 1, to: stmt)
        bindText(HDPIMProductExtraMetaKey.installDir, index: 2, to: stmt)
        bindText(HDPIMPackageMetaKey.uninstallPIMX.rawValue, index: 3, to: stmt)
        bindText(HDPIMPackageMetaKey.uninstallPIMXHash.rawValue, index: 4, to: stmt)
        bindText(HDPIMPackageMetaKey.uninstallPIMXHash256.rawValue, index: 5, to: stmt)
        bindText(HDPIMPackageMetaKey.repairPIMX.rawValue, index: 6, to: stmt)
        bindText(HDPIMPackageMetaKey.repairPIMXHash.rawValue, index: 7, to: stmt)
        bindText(HDPIMPackageMetaKey.repairPIMXHash256.rawValue, index: 8, to: stmt)
        bindText(sapCode, index: 9, to: stmt)
        bindText(processorFamily.rawValue, index: 10, to: stmt)
        bindText(packageName, index: 11, to: stmt)

        let normalizedExpectedInstallDir = normalizedComparablePath(expectedInstallDir)
        var snapshots: [HDPIMInstalledPackageSnapshot] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let productVersion = columnText(stmt, index: 1)
            let resolvedPackageName = columnText(stmt, index: 2)
            let packageVersion = columnText(stmt, index: 3)
            let installDir = columnText(stmt, index: 4)

            if !normalizedExpectedInstallDir.isEmpty,
               normalizedComparablePath(installDir) != normalizedExpectedInstallDir {
                continue
            }

            let isValid = (try? hasValidInstalledPackage(
                sapCode: sapCode,
                productVersion: productVersion,
                processorFamily: processorFamily,
                packageName: resolvedPackageName,
                packageVersion: packageVersion,
                expectedInstallDir: expectedInstallDir
            )) ?? false
            if !isValid {
                continue
            }

            let targetFoldersRaw = (try? fetchPackageMetaValue(
                sapCode: sapCode,
                version: productVersion,
                processorFamily: processorFamily,
                packageName: resolvedPackageName,
                packageVersion: packageVersion,
                key: HDPIMPackageMetaKey.targetFolderList.rawValue
            )) ?? nil

            snapshots.append(
                HDPIMInstalledPackageSnapshot(
                    sapCode: columnText(stmt, index: 0),
                    productVersion: productVersion,
                    processorFamily: processorFamily,
                    packageName: resolvedPackageName,
                    packageVersion: packageVersion,
                    installDir: installDir,
                    uninstallPIMXPath: columnOptionalText(stmt, index: 5),
                    uninstallPIMXHash: columnOptionalText(stmt, index: 6),
                    uninstallPIMXHash256: columnOptionalText(stmt, index: 7),
                    repairPIMXPath: columnOptionalText(stmt, index: 8),
                    repairPIMXHash: columnOptionalText(stmt, index: 9),
                    repairPIMXHash256: columnOptionalText(stmt, index: 10),
                    targetFolders: splitMetaValues(targetFoldersRaw ?? "")
                )
            )
        }

        return snapshots.sorted { lhs, rhs in
            let productCompare = AppStatics.compareVersions(lhs.productVersion, rhs.productVersion)
            if productCompare != 0 {
                return productCompare > 0
            }
            return AppStatics.compareVersions(lhs.packageVersion, rhs.packageVersion) > 0
        }
    }

    func getAllInstalledProducts() -> [(sapCode: String, version: String, platform: String)] {
        let sql = """
        SELECT SAPCode, ProductVersion, ProcessorFamily
        FROM \(Schema.productInstallationInfo)
        WHERE Status = ?
        ORDER BY SAPCode;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        bindText(HDPIMInstallStatus.installed.rawValue, index: 1, to: stmt)

        var products: [(String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            products.append((
                columnText(stmt, index: 0),
                columnText(stmt, index: 1),
                columnText(stmt, index: 2)
            ))
        }
        return products
    }

    func getProductMeta(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        key: String
    ) -> String? {
        try? fetchProductMetaValue(sapCode: sapCode, version: version, processorFamily: processorFamily, key: key)
    }

	func getResolvedProductLaunchPath(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
	) -> String {
		if let bookmarkValue = getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductExtraMetaKey.launchPathBookmarkData
		), let bookmarkPath = resolvedBookmarkPath(from: bookmarkValue), !bookmarkPath.isEmpty {
			return bookmarkPath
		}

		let rawLaunchPath = getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductMetaKey.appLaunch.rawValue
		)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !rawLaunchPath.isEmpty else {
			return ""
		}

		let propertyTable = HDPIMPropertyTable()
		propertyTable.setupSystemDirectories()
		let installDir = getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductExtraMetaKey.installDir
		)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if !installDir.isEmpty {
			propertyTable.setInstallDir(installDir)
			propertyTable.setProductInstallDir(installDir)
		}

		let expandedPath = propertyTable
			.expandPath(rawLaunchPath)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return expandedPath.isEmpty ? rawLaunchPath : expandedPath
	}

	func packageMetaValueExists(key: String, value: String) -> Bool {
		let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedValue.isEmpty else {
			return false
		}

		let sql = """
		SELECT COUNT(*)
		FROM \(Schema.packageInstallationMetaInfo)
		WHERE Key = ? AND Value = ?;
		"""

		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
			return false
		}
		defer { sqlite3_finalize(stmt) }

		bindText(key, index: 1, to: stmt)
		bindText(trimmedValue, index: 2, to: stmt)

		if sqlite3_step(stmt) == SQLITE_ROW {
			return sqlite3_column_int(stmt, 0) > 0
		}
		return false
	}

    func setProductMeta(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        key: String,
        value: String
    ) {
        let record = HDPIMNativeProductMetaRecord(
            sapCode: sapCode,
            productVersion: version,
            processorFamily: processorFamily,
            key: key,
            value: value,
            appendIfNeeded: false
        )
        try? insertProductMeta(record)
    }

    func getDeltaFailVersions(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) -> Set<String> {
        guard let raw = getProductMeta(sapCode: sapCode, version: version, processorFamily: processorFamily, key: "DeltaFailVersions") else {
            return []
        }
        return Set(raw.split(separator: ",").map { String($0) })
    }

    func addDeltaFailVersion(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily, failedVersion: String) {
        var existing = getDeltaFailVersions(sapCode: sapCode, version: version, processorFamily: processorFamily)
        existing.insert(failedVersion)
        setProductMeta(sapCode: sapCode, version: version, processorFamily: processorFamily, key: "DeltaFailVersions", value: existing.joined(separator: ","))
    }

    func getInstalledProductIdentitySet() -> Set<String> {
        let sql = """
        SELECT SAPCode, ProductVersion, ProcessorFamily
        FROM \(Schema.productInstallationInfo)
        WHERE Status = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        bindText(HDPIMInstallStatus.installed.rawValue, index: 1, to: stmt)

        var identities: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            identities.insert(
                productIdentity(
                    sapCode: columnText(stmt, index: 0),
                    version: columnText(stmt, index: 1),
                    processorFamily: columnText(stmt, index: 2)
                )
            )
        }
        return identities
    }

    func getInstalledPackageIdentitySet() -> Set<String> {
        let sql = """
        SELECT SAPCode, ProductVersion, ProcessorFamily, PackageName, PackageVersion
        FROM \(Schema.packageInstallationInfo);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var identities: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            identities.insert(
                packageIdentity(
                    sapCode: columnText(stmt, index: 0),
                    version: columnText(stmt, index: 1),
                    processorFamily: columnText(stmt, index: 2),
                    packageName: columnText(stmt, index: 3),
                    packageVersion: columnText(stmt, index: 4)
                )
            )
        }
        return identities
    }

    func hasValidInstalledPackage(
        sapCode: String,
        productVersion: String,
        processorFamily: HDPIMProcessorFamily,
        packageName: String,
        packageVersion: String,
        expectedInstallDir: String
    ) throws -> Bool {
        guard try hasPackageRecord(
            sapCode: sapCode,
            productVersion: productVersion,
            processorFamily: processorFamily,
            packageName: packageName,
            packageVersion: packageVersion
        ) else {
            return false
        }

        let uninstallPIMXPath = try fetchPackageMetaValue(
            sapCode: sapCode,
            version: productVersion,
            processorFamily: processorFamily,
            packageName: packageName,
            packageVersion: packageVersion,
            key: HDPIMPackageMetaKey.uninstallPIMX.rawValue
        ) ?? ""
        if uninstallPIMXPath.isEmpty || !FileManager.default.fileExists(atPath: uninstallPIMXPath) {
            return false
        }

        let storedInstallDir = try fetchProductMetaValue(
            sapCode: sapCode,
            version: productVersion,
            processorFamily: processorFamily,
            key: HDPIMProductExtraMetaKey.installDir
        ) ?? ""
        if !storedInstallDir.isEmpty,
           !expectedInstallDir.isEmpty,
           normalizedComparablePath(storedInstallDir) != normalizedComparablePath(expectedInstallDir) {
            return false
        }

        let targetFolderValue = try fetchPackageMetaValue(
            sapCode: sapCode,
            version: productVersion,
            processorFamily: processorFamily,
            packageName: packageName,
            packageVersion: packageVersion,
            key: HDPIMPackageMetaKey.targetFolderList.rawValue
        ) ?? ""
        let targetFolders = splitMetaValues(targetFolderValue)
        if targetFolders.isEmpty {
            return true
        }

        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        let installDir = storedInstallDir.isEmpty ? expectedInstallDir : storedInstallDir
        if !installDir.isEmpty {
            propertyTable.setInstallDir(installDir)
            propertyTable.setProductInstallDir(installDir)
        }

        for targetFolder in targetFolders {
            let expandedTarget = propertyTable.expandPath(targetFolder)
            if expandedTarget.isEmpty || expandedTarget.contains("[") {
                continue
            }

            let comparablePath = normalizedComparablePath(expandedTarget)
            if comparablePath.isEmpty || !FileManager.default.fileExists(atPath: comparablePath) {
                return false
            }
        }

        return true
    }

    private func ensureSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.productInstallationInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            Status INT,
            constraint pk PRIMARY KEY (SAPCode, ProductVersion, ProcessorFamily)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.packageInstallationInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            PackageName varchar(36),
            PackageVersion varchar(36),
            constraint pk PRIMARY KEY (SAPCode, ProductVersion, ProcessorFamily, PackageName, PackageVersion)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.productInstallationMetaInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            Key TEXT,
            Value TEXT,
            constraint pk PRIMARY KEY (SAPCode, ProductVersion, ProcessorFamily, Key)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.packageInstallationMetaInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            PackageName varchar(36),
            PackageVersion varchar(36),
            Key TEXT,
            Value TEXT,
            constraint pk PRIMARY KEY (SAPCode, ProductVersion, ProcessorFamily, PackageName, PackageVersion, Key)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.productReferenceInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            ReferencingSAPCode varchar(36),
            ReferencingProductVersion varchar(36),
            ReferencingProcessorFamily varchar(36),
            Type varchar,
            constraint pk PRIMARY KEY (
                SAPCode,
                ProductVersion,
                ProcessorFamily,
                ReferencingSAPCode,
                ReferencingProductVersion,
                ReferencingProcessorFamily
            )
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.packageReferenceInfo) (
            PackageName varchar(36),
            PackageVersion varchar(36),
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            Type TEXT,
            constraint pk PRIMARY KEY (PackageName, PackageVersion, SAPCode, ProductVersion, ProcessorFamily)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.userActionInfo) (
            SAPCode varchar(36),
            ProductVersion varchar(36),
            ProcessorFamily varchar(36),
            Action TEXT,
            TimeOfAction TEXT,
            constraint pk PRIMARY KEY (SAPCode, ProductVersion, ProcessorFamily, Action, TimeOfAction)
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS \(Schema.pimMeta) (
            Key TEXT,
            Value TEXT,
            constraint pk PRIMARY KEY (Key)
        )
        """)

        try setPimMeta(key: "schema_version", value: "2")
        try setPimMeta(key: "schema_compatibility_version", value: "1")
    }

    private func writeProduct(_ product: HDPIMNativeProductContext) throws {
        let record = HDPIMNativeProductRecord(
            sapCode: product.sapCode,
            productVersion: product.codexVersion,
            processorFamily: product.processorFamily,
            status: .installed
        )
        try insertProduct(record)

        try writeProductInstallLocation(
            sapCode: product.sapCode,
            productVersion: product.codexVersion,
            processorFamily: product.processorFamily,
            installDir: product.installDir,
            resolvedAppLaunchPath: product.resolvedAppLaunchPath
        )

        let modulesValue = Array(Set(product.modules)).sorted().joined(separator: ",")

        let metaRecords: [HDPIMNativeProductMetaRecord] = [
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.appLaunch.rawValue, value: product.appLaunchPath, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.installLang.rawValue, value: product.installLanguage, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.baseVersion.rawValue, value: product.baseVersion, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.platform.rawValue, value: product.platform, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.conflictingProcessesXML.rawValue, value: product.conflictingProcessesXML, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.name.rawValue, value: product.productName, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.buildVersion.rawValue, value: product.buildVersion, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductMetaKey.amtConfigLEID.rawValue, value: product.amtConfigLEID ?? "", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.amtConfigAppID, value: product.amtConfigAppID ?? "", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.amtConfigPath, value: product.amtConfigPath ?? "", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.isUWPProduct, value: "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.modules, value: modulesValue, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.isSelfReference, value: product.isSelfReference ? "true" : "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.autoInstall, value: product.autoInstall ? "true" : "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.autoPatchUpdate, value: "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.isVisibleProduct, value: product.isVisibleProduct ? "true" : "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.isNonCCProduct, value: product.isNonCCProduct ? "true" : "false", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.buildGuid, value: product.buildGuid, appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.vulcanConfig, value: product.vulcanConfig ?? "", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.uxpPluginConfig, value: product.uxpPluginConfig ?? "", appendIfNeeded: false),
            .init(sapCode: product.sapCode, productVersion: product.codexVersion, processorFamily: product.processorFamily, key: HDPIMProductExtraMetaKey.ffcEnvironment, value: product.ffcEnvironment ?? "", appendIfNeeded: false)
        ]

        for metaRecord in metaRecords where shouldWriteProductMeta(metaRecord) {
            try insertProductMeta(metaRecord)
        }

        try insertProductMeta(
            .init(
                sapCode: product.sapCode,
                productVersion: product.latestInstalledVersionSlot,
                processorFamily: product.processorFamily,
                key: HDPIMProductMetaKey.latestInstalledVersion.rawValue,
                value: product.codexVersion,
                appendIfNeeded: false
            )
        )
    }

    private func writeProductInstallLocation(
        sapCode: String,
        productVersion: String,
        processorFamily: HDPIMProcessorFamily,
        installDir: String,
        resolvedAppLaunchPath: String
    ) throws {
        let installBookmark = makeBookmarkValue(for: installDir)
        let launchBookmark = makeBookmarkValue(for: resolvedAppLaunchPath)

        let installLocationMeta: [HDPIMNativeProductMetaRecord] = [
            .init(
                sapCode: sapCode,
                productVersion: productVersion,
                processorFamily: processorFamily,
                key: HDPIMProductExtraMetaKey.installDir,
                value: installDir,
                appendIfNeeded: false
            ),
            .init(
                sapCode: sapCode,
                productVersion: productVersion,
                processorFamily: processorFamily,
                key: HDPIMProductExtraMetaKey.installDirBookmarkData,
                value: installBookmark,
                appendIfNeeded: false
            ),
            .init(
                sapCode: sapCode,
                productVersion: productVersion,
                processorFamily: processorFamily,
                key: HDPIMProductExtraMetaKey.launchPathBookmarkData,
                value: launchBookmark,
                appendIfNeeded: false
            )
        ]

        for metaRecord in installLocationMeta where shouldWriteProductMeta(metaRecord) {
            try insertProductMeta(metaRecord)
        }
    }

    private func writePackage(_ package: HDPIMNativePackageContext) throws {
        let record = HDPIMNativePackageRecord(
            sapCode: package.sapCode,
            productVersion: package.productVersion,
            processorFamily: package.processorFamily,
            packageName: package.packageName,
            packageVersion: package.packageVersion,
            isShared: package.isShared
        )

        try insertPackage(record)

        let packageMetaRecords: [HDPIMNativePackageMetaRecord] = [
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.type.rawValue, value: package.packageType, appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.sequenceNumber.rawValue, value: "\(package.sequenceNumber)", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.uninstallPIMX.rawValue, value: package.uninstallPIMXPath ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.uninstallPIMXHash.rawValue, value: package.uninstallPIMXHash ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.uninstallPIMXHash256.rawValue, value: package.uninstallPIMXHash256 ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.repairPIMX.rawValue, value: package.repairPIMXPath ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.repairPIMXHash.rawValue, value: package.repairPIMXHash ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.repairPIMXHash256.rawValue, value: package.repairPIMXHash256 ?? "", appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.installSize.rawValue, value: package.installSize, appendIfNeeded: false),
            .init(sapCode: package.sapCode, productVersion: package.productVersion, processorFamily: package.processorFamily, packageName: package.packageName, packageVersion: package.packageVersion, key: HDPIMPackageMetaKey.processorFamily.rawValue, value: package.packageProcessorFamily.isEmpty ? defaultPackageProcessorFamilyValue(for: package.processorFamily) : package.packageProcessorFamily, appendIfNeeded: false)
        ]

        for metaRecord in packageMetaRecords {
            try insertPackageMeta(metaRecord)
        }

        for targetFolder in package.targetFolders {
            try insertPackageMeta(
                .init(
                    sapCode: package.sapCode,
                    productVersion: package.productVersion,
                    processorFamily: package.processorFamily,
                    packageName: package.packageName,
                    packageVersion: package.packageVersion,
                    key: HDPIMPackageMetaKey.targetFolderList.rawValue,
                    value: targetFolder,
                    appendIfNeeded: true
                )
            )
        }

        try insertPackageMeta(
            .init(
                sapCode: package.sapCode,
                productVersion: package.productVersion,
                processorFamily: package.processorFamily,
                packageName: package.packageName,
                packageVersion: package.packageVersion,
                key: HDPIMPackageExtraMetaKey.ribsCoexistenceCode.rawValue,
                value: package.ribsCoexistenceCode ?? "",
                appendIfNeeded: false
            )
        )

        if let module = package.module, !module.isEmpty {
            try insertPackageMeta(
                .init(
                    sapCode: package.sapCode,
                    productVersion: package.productVersion,
                    processorFamily: package.processorFamily,
                    packageName: package.packageName,
                    packageVersion: package.packageVersion,
                    key: HDPIMPackageExtraMetaKey.module.rawValue,
                    value: module,
                    appendIfNeeded: false
                )
            )
        }

        if let uwpInfoXML = package.uwpInfoXML, !uwpInfoXML.isEmpty {
            try insertPackageMeta(
                .init(
                    sapCode: package.sapCode,
                    productVersion: package.productVersion,
                    processorFamily: package.processorFamily,
                    packageName: package.packageName,
                    packageVersion: package.packageVersion,
                    key: HDPIMPackageExtraMetaKey.uwpInfoXML.rawValue,
                    value: uwpInfoXML,
                    appendIfNeeded: false
                )
            )
        }

        if package.isShared {
            try insertPackageReference(package)
        }
    }

    private func writeProductReference(_ record: HDPIMNativeProductReferenceRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO \(Schema.productReferenceInfo)
        (SAPCode, ProductVersion, ProcessorFamily,
         ReferencingSAPCode, ReferencingProductVersion, ReferencingProcessorFamily, Type)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(record.dependencySapCode, index: 1, to: stmt)
        bindText(record.dependencyVersion, index: 2, to: stmt)
        bindText(record.dependencyProcessorFamily.rawValue, index: 3, to: stmt)
        bindText(record.referencingSapCode, index: 4, to: stmt)
        bindText(record.referencingVersion, index: 5, to: stmt)
        bindText(record.referencingProcessorFamily.rawValue, index: 6, to: stmt)
        bindText(record.type, index: 7, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func insertProduct(_ record: HDPIMNativeProductRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO \(Schema.productInstallationInfo)
        (SAPCode, ProductVersion, ProcessorFamily, Status)
        VALUES (?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(record.sapCode, index: 1, to: stmt)
        bindText(record.productVersion, index: 2, to: stmt)
        bindText(record.processorFamily.rawValue, index: 3, to: stmt)
        bindText(record.status.rawValue, index: 4, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func insertPackage(_ record: HDPIMNativePackageRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO \(Schema.packageInstallationInfo)
        (SAPCode, ProductVersion, ProcessorFamily, PackageName, PackageVersion)
        VALUES (?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(record.sapCode, index: 1, to: stmt)
        bindText(record.productVersion, index: 2, to: stmt)
        bindText(record.processorFamily.rawValue, index: 3, to: stmt)
        bindText(record.packageName, index: 4, to: stmt)
        bindText(record.packageVersion, index: 5, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func insertProductMeta(_ record: HDPIMNativeProductMetaRecord) throws {
        let value = try mergedProductMetaValue(for: record)
        let sql = """
        INSERT OR REPLACE INTO \(Schema.productInstallationMetaInfo)
        (SAPCode, ProductVersion, ProcessorFamily, Key, Value)
        VALUES (?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(record.sapCode, index: 1, to: stmt)
        bindText(record.productVersion, index: 2, to: stmt)
        bindText(record.processorFamily.rawValue, index: 3, to: stmt)
        bindText(record.key, index: 4, to: stmt)
        bindText(value, index: 5, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func insertPackageMeta(_ record: HDPIMNativePackageMetaRecord) throws {
        let value = try mergedPackageMetaValue(for: record)
        let sql = """
        INSERT OR REPLACE INTO \(Schema.packageInstallationMetaInfo)
        (SAPCode, ProductVersion, ProcessorFamily, PackageName, PackageVersion, Key, Value)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(record.sapCode, index: 1, to: stmt)
        bindText(record.productVersion, index: 2, to: stmt)
        bindText(record.processorFamily.rawValue, index: 3, to: stmt)
        bindText(record.packageName, index: 4, to: stmt)
        bindText(record.packageVersion, index: 5, to: stmt)
        bindText(record.key, index: 6, to: stmt)
        bindText(value, index: 7, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func insertPackageReference(_ package: HDPIMNativePackageContext) throws {
        let sql = """
        INSERT OR REPLACE INTO \(Schema.packageReferenceInfo)
        (PackageName, PackageVersion, SAPCode, ProductVersion, ProcessorFamily, Type)
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(package.packageName, index: 1, to: stmt)
        bindText(package.packageVersion, index: 2, to: stmt)
        bindText(package.sapCode, index: 3, to: stmt)
        bindText(package.productVersion, index: 4, to: stmt)
        bindText(package.processorFamily.rawValue, index: 5, to: stmt)
        bindText("", index: 6, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func mergedProductMetaValue(for record: HDPIMNativeProductMetaRecord) throws -> String {
        guard record.appendIfNeeded else {
            return record.value
        }
        let existing = try fetchProductMetaValue(
            sapCode: record.sapCode,
            version: record.productVersion,
            processorFamily: record.processorFamily,
            key: record.key
        )
        return mergeMetaValues(existing: existing, newValue: record.value)
    }

    private func mergedPackageMetaValue(for record: HDPIMNativePackageMetaRecord) throws -> String {
        guard record.appendIfNeeded else {
            return record.value
        }
        let existing = try fetchPackageMetaValue(
            sapCode: record.sapCode,
            version: record.productVersion,
            processorFamily: record.processorFamily,
            packageName: record.packageName,
            packageVersion: record.packageVersion,
            key: record.key
        )
        return mergeMetaValues(existing: existing, newValue: record.value)
    }

    private func fetchProductMetaValue(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        key: String
    ) throws -> String? {
        let sql = """
        SELECT Value
        FROM \(Schema.productInstallationMetaInfo)
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Key = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(sapCode, index: 1, to: stmt)
        bindText(version, index: 2, to: stmt)
        bindText(processorFamily.rawValue, index: 3, to: stmt)
        bindText(key, index: 4, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        return columnOptionalText(stmt, index: 0)
    }

    private func fetchProductBaseVersion(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws -> String? {
        try fetchProductMetaValue(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily,
            key: HDPIMProductMetaKey.baseVersion.rawValue
        )
    }

    private func fetchPackageMetaValue(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        packageName: String,
        packageVersion: String,
        key: String
    ) throws -> String? {
        let sql = """
        SELECT Value
        FROM \(Schema.packageInstallationMetaInfo)
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND PackageName = ? AND PackageVersion = ? AND Key = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(sapCode, index: 1, to: stmt)
        bindText(version, index: 2, to: stmt)
        bindText(processorFamily.rawValue, index: 3, to: stmt)
        bindText(packageName, index: 4, to: stmt)
        bindText(packageVersion, index: 5, to: stmt)
        bindText(key, index: 6, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        return columnOptionalText(stmt, index: 0)
    }

	private func hasPackageRecord(
		sapCode: String,
		productVersion: String,
		processorFamily: HDPIMProcessorFamily,
        packageName: String,
        packageVersion: String
    ) throws -> Bool {
        let sql = """
        SELECT COUNT(*)
        FROM \(Schema.packageInstallationInfo)
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND PackageName = ? AND PackageVersion = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(sapCode, index: 1, to: stmt)
        bindText(productVersion, index: 2, to: stmt)
        bindText(processorFamily.rawValue, index: 3, to: stmt)
        bindText(packageName, index: 4, to: stmt)
        bindText(packageVersion, index: 5, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return false
        }

		return sqlite3_column_int(stmt, 0) > 0
	}

	private func hasPackageReference(_ package: HDPIMNativePackageContext) -> Bool {
		let sql = """
		SELECT COUNT(*)
		FROM \(Schema.packageReferenceInfo)
		WHERE PackageName = ? AND PackageVersion = ? AND SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?;
		"""

		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
			return false
		}
		defer { sqlite3_finalize(stmt) }

		bindText(package.packageName, index: 1, to: stmt)
		bindText(package.packageVersion, index: 2, to: stmt)
		bindText(package.sapCode, index: 3, to: stmt)
		bindText(package.productVersion, index: 4, to: stmt)
		bindText(package.processorFamily.rawValue, index: 5, to: stmt)

		guard sqlite3_step(stmt) == SQLITE_ROW else {
			return false
		}
		return sqlite3_column_int(stmt, 0) > 0
	}

	private func makeInstalledPackageContext(
		sapCode: String,
		productVersion: String,
		processorFamily: HDPIMProcessorFamily,
		packageName: String,
		packageVersion: String,
		installDir: String
	) -> HDPIMNativePackageContext {
		let packageType = (try? fetchPackageMetaValue(
			sapCode: sapCode,
			version: productVersion,
			processorFamily: processorFamily,
			packageName: packageName,
			packageVersion: packageVersion,
			key: HDPIMPackageMetaKey.type.rawValue
		)) ?? ""
		let packageProcessorFamily = (try? fetchPackageMetaValue(
			sapCode: sapCode,
			version: productVersion,
			processorFamily: processorFamily,
			packageName: packageName,
			packageVersion: packageVersion,
			key: HDPIMPackageMetaKey.processorFamily.rawValue
		)) ?? ""
		let sequenceValue = (try? fetchPackageMetaValue(
			sapCode: sapCode,
			version: productVersion,
			processorFamily: processorFamily,
			packageName: packageName,
			packageVersion: packageVersion,
			key: HDPIMPackageMetaKey.sequenceNumber.rawValue
		)) ?? "0"
		let targetFolderValue = (try? fetchPackageMetaValue(
			sapCode: sapCode,
			version: productVersion,
			processorFamily: processorFamily,
			packageName: packageName,
			packageVersion: packageVersion,
			key: HDPIMPackageMetaKey.targetFolderList.rawValue
		)) ?? ""
		let package = HDPIMNativePackageContext(
			sapCode: sapCode,
			productVersion: productVersion,
			platform: processorFamily.rawValue,
			packageName: packageName,
			packageVersion: packageVersion,
			packageType: packageType,
			packageProcessorFamily: packageProcessorFamily,
			sequenceNumber: Int(sequenceValue) ?? 0,
			installDir: installDir,
			uninstallPIMXPath: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.uninstallPIMX.rawValue)) ?? nil,
			uninstallPIMXHash: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.uninstallPIMXHash.rawValue)) ?? nil,
			uninstallPIMXHash256: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.uninstallPIMXHash256.rawValue)) ?? nil,
			repairPIMXPath: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.repairPIMX.rawValue)) ?? nil,
			repairPIMXHash: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.repairPIMXHash.rawValue)) ?? nil,
			repairPIMXHash256: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.repairPIMXHash256.rawValue)) ?? nil,
			installSize: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageMetaKey.installSize.rawValue)) ?? "0",
			targetFolders: splitMetaValues(targetFolderValue),
			ribsCoexistenceCode: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageExtraMetaKey.ribsCoexistenceCode.rawValue)) ?? nil,
			module: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageExtraMetaKey.module.rawValue)) ?? nil,
			uwpInfoXML: (try? fetchPackageMetaValue(sapCode: sapCode, version: productVersion, processorFamily: processorFamily, packageName: packageName, packageVersion: packageVersion, key: HDPIMPackageExtraMetaKey.uwpInfoXML.rawValue)) ?? nil,
			isShared: false
		)

		return HDPIMNativePackageContext(
			sapCode: package.sapCode,
			productVersion: package.productVersion,
			platform: package.platform,
			packageName: package.packageName,
			packageVersion: package.packageVersion,
			packageType: package.packageType,
			packageProcessorFamily: package.packageProcessorFamily,
			sequenceNumber: package.sequenceNumber,
			installDir: package.installDir,
			uninstallPIMXPath: package.uninstallPIMXPath,
			uninstallPIMXHash: package.uninstallPIMXHash,
			uninstallPIMXHash256: package.uninstallPIMXHash256,
			repairPIMXPath: package.repairPIMXPath,
			repairPIMXHash: package.repairPIMXHash,
			repairPIMXHash256: package.repairPIMXHash256,
			installSize: package.installSize,
			targetFolders: package.targetFolders,
			ribsCoexistenceCode: package.ribsCoexistenceCode,
			module: package.module,
			uwpInfoXML: package.uwpInfoXML,
			isShared: hasPackageReference(package)
		)
	}

	private func mergeMetaValues(existing: String?, newValue: String) -> String {
		guard let existing, !existing.isEmpty else {
            return newValue
        }
        let existingSet = Set(existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if existingSet.contains(newValue) {
            return existing
        }
        return existing + "," + newValue
    }

    private func setPimMeta(key: String, value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO \(Schema.pimMeta)
        (Key, Value)
        VALUES (?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(key, index: 1, to: stmt)
        bindText(value, index: 2, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func deleteProductLifecycle(_ product: HDPIMNativeProductContext) throws {
        try deleteProductReference(for: product)
        try deletePackageReference(for: product.sapCode, version: product.codexVersion, processorFamily: product.processorFamily)
        try deletePackageMeta(for: product.sapCode, version: product.codexVersion, processorFamily: product.processorFamily)
        try deletePackageInfo(for: product.sapCode, version: product.codexVersion, processorFamily: product.processorFamily)
        try deleteLatestInstalledVersionMeta(for: product)
        try deleteProductMeta(for: product.sapCode, version: product.codexVersion, processorFamily: product.processorFamily)
        try deleteProductInfo(for: product.sapCode, version: product.codexVersion, processorFamily: product.processorFamily)
    }

    private func deleteProductRecords(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws {
        try deleteProductMeta(for: sapCode, version: version, processorFamily: processorFamily)
        try deleteProductInfo(for: sapCode, version: version, processorFamily: processorFamily)
    }

    private func deleteLatestInstalledVersionMeta(for product: HDPIMNativeProductContext) throws {
        try delete(
            table: Schema.productInstallationMetaInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Key = ?",
            bindings: [
                product.sapCode,
                product.latestInstalledVersionSlot,
                product.processorFamily.rawValue,
                HDPIMProductMetaKey.latestInstalledVersion.rawValue
            ]
        )
    }

    private func collectPIMXPaths(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        includeRepair: Bool,
        includeUninstall: Bool
    ) throws -> [String] {
        guard includeRepair || includeUninstall else {
            return []
        }

        let keys = [
            includeRepair ? HDPIMPackageMetaKey.repairPIMX.rawValue : nil,
            includeUninstall ? HDPIMPackageMetaKey.uninstallPIMX.rawValue : nil
        ].compactMap { $0 }

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sql = """
        SELECT Value
        FROM \(Schema.packageInstallationMetaInfo)
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Key IN (\(placeholders));
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(sapCode, index: 1, to: stmt)
        bindText(version, index: 2, to: stmt)
        bindText(processorFamily.rawValue, index: 3, to: stmt)
        for (index, key) in keys.enumerated() {
            bindText(key, index: Int32(index + 4), to: stmt)
        }

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let value = columnText(stmt, index: 0)
            if !value.isEmpty {
                paths.append(value)
            }
        }
        return paths
    }

    private func deleteProductInfo(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        print("[HDPIM-DELETE-PRODUCT] 即将删除产品记录: \(sapCode) \(version) \(processorFamily.rawValue)")
        try delete(
            table: Schema.productInstallationInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [sapCode, version, processorFamily.rawValue]
        )
        print("[HDPIM-DELETE-PRODUCT] 已删除产品记录: \(sapCode)")
    }

    private func deleteProductMeta(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        try delete(
            table: Schema.productInstallationMetaInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [sapCode, version, processorFamily.rawValue]
        )
    }

    private func deleteProductMeta(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        key: String
    ) throws {
        try delete(
            table: Schema.productInstallationMetaInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Key = ?",
            bindings: [sapCode, version, processorFamily.rawValue, key]
        )
    }

    private func deletePackageInfo(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        try delete(
            table: Schema.packageInstallationInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [sapCode, version, processorFamily.rawValue]
        )
    }

    private func deletePackageInfo(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        packageName: String,
        packageVersion: String
    ) throws {
        print("[HDPIM-DELETE-PKG] 即将删除包记录: \(sapCode) \(version) \(packageName) \(packageVersion)")
        try delete(
            table: Schema.packageInstallationInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND PackageName = ? AND PackageVersion = ?",
            bindings: [sapCode, version, processorFamily.rawValue, packageName, packageVersion]
        )
        print("[HDPIM-DELETE-PKG] 已删除包记录: \(packageName)")
    }

    private func deletePackageMeta(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        try delete(
            table: Schema.packageInstallationMetaInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [sapCode, version, processorFamily.rawValue]
        )
    }

    private func deletePackageMeta(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        packageName: String,
        packageVersion: String
    ) throws {
        try delete(
            table: Schema.packageInstallationMetaInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND PackageName = ? AND PackageVersion = ?",
            bindings: [sapCode, version, processorFamily.rawValue, packageName, packageVersion]
        )
    }

    private func deleteProductReference(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        try deleteProductReference(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily,
            referencingVersion: version
        )
    }

    private func deleteProductReference(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily,
        referencingVersion: String
    ) throws {
        try delete(
            table: Schema.productReferenceInfo,
            whereClause: """
            (SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?)
            OR
            (ReferencingSAPCode = ? AND ReferencingProductVersion = ? AND ReferencingProcessorFamily = ?)
            """,
            bindings: [sapCode, version, processorFamily.rawValue, sapCode, referencingVersion, processorFamily.rawValue]
        )
    }

    private func deleteProductReference(for product: HDPIMNativeProductContext) throws {
        try delete(
            table: Schema.productReferenceInfo,
            whereClause: """
            (SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?)
            OR
            (ReferencingSAPCode = ? AND ReferencingProductVersion = ? AND ReferencingProcessorFamily = ?)
            """,
            bindings: [
                product.sapCode,
                product.latestInstalledVersionSlot,
                product.processorFamily.rawValue,
                product.sapCode,
                product.codexVersion,
                product.processorFamily.rawValue
            ]
        )
    }

    private func deletePackageReference(for sapCode: String, version: String, processorFamily: HDPIMProcessorFamily) throws {
        try delete(
            table: Schema.packageReferenceInfo,
            whereClause: "SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [sapCode, version, processorFamily.rawValue]
        )
    }

    private func deletePackageReference(
        packageName: String,
        packageVersion: String,
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws {
        try delete(
            table: Schema.packageReferenceInfo,
            whereClause: "PackageName = ? AND PackageVersion = ? AND SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?",
            bindings: [packageName, packageVersion, sapCode, version, processorFamily.rawValue]
        )
    }

    private func delete(table: String, whereClause: String, bindings: [String]) throws {
        let sql = "DELETE FROM \(table) WHERE \(whereClause);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        for (offset, value) in bindings.enumerated() {
            bindText(value, index: Int32(offset + 1), to: stmt)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func beginTransaction(name: String) throws {
        try execute("BEGIN TRANSACTION \"\(name)\"")
    }

    private func commitTransaction(name: String) throws {
        try execute("END TRANSACTION \"\(name)\"")
    }

    private func rollbackTransaction(name: String) throws {
        try execute("ROLLBACK TRANSACTION \"\(name)\"")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(lastErrorMessage())
        }
    }

    private func bindText(_ value: String, index: Int32, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    private func columnOptionalText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func lastErrorMessage() -> String {
        guard let db else {
            return "unknown sqlite error"
        }
        return String(cString: sqlite3_errmsg(db))
    }

    private func shouldKeepEmptyProductMeta(_ key: String) -> Bool {
        key == HDPIMProductMetaKey.conflictingProcessesXML.rawValue
            || key == HDPIMProductExtraMetaKey.installDirBookmarkData
            || key == HDPIMProductExtraMetaKey.launchPathBookmarkData
    }

    private func shouldWriteProductMeta(_ record: HDPIMNativeProductMetaRecord) -> Bool {
        if !record.value.isEmpty {
            return true
        }

        if shouldKeepEmptyProductMeta(record.key) {
            return true
        }

        switch record.key {
        case HDPIMProductMetaKey.appLaunch.rawValue,
             HDPIMProductMetaKey.installLang.rawValue,
             HDPIMProductMetaKey.baseVersion.rawValue,
             HDPIMProductMetaKey.platform.rawValue,
             HDPIMProductMetaKey.name.rawValue,
             HDPIMProductMetaKey.buildVersion.rawValue,
             HDPIMProductExtraMetaKey.amtConfigAppID,
             HDPIMProductExtraMetaKey.installDir,
             HDPIMProductExtraMetaKey.isUWPProduct,
             HDPIMProductExtraMetaKey.isSelfReference,
             HDPIMProductExtraMetaKey.autoInstall,
             HDPIMProductExtraMetaKey.autoPatchUpdate,
             HDPIMProductExtraMetaKey.isVisibleProduct,
             HDPIMProductExtraMetaKey.isNonCCProduct:
            return true
        default:
            return false
        }
    }

    private func makeBookmarkValue(for path: String) -> String {
        guard !path.isEmpty else {
            return ""
        }
        let url = URL(fileURLWithPath: path)
        guard let bookmarkData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return ""
        }
        return bookmarkData.base64EncodedString()
    }

	private func resolvedBookmarkPath(from value: String) -> String? {
		let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedValue.isEmpty,
		      let data = Data(base64Encoded: trimmedValue) else {
			return nil
		}

		var isStale = false
		guard let url = try? URL(
			resolvingBookmarkData: data,
			options: [],
			relativeTo: nil,
			bookmarkDataIsStale: &isStale
		) else {
			return nil
		}
		return url.path
	}

    private func splitMetaValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedComparablePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard standardized.count > 1 else {
            return standardized
        }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private func defaultPackageProcessorFamilyValue(for processorFamily: HDPIMProcessorFamily) -> String {
        switch processorFamily {
        case .bit32:
            return "32-bit"
        case .bit64, .arm64Bit:
            return "64-bit"
        }
    }

    private func productIdentity(sapCode: String, version: String, processorFamily: String) -> String {
        "\(sapCode)|\(version)|\(processorFamily)"
    }

    private func packageIdentity(
        sapCode: String,
        version: String,
        processorFamily: String,
        packageName: String,
        packageVersion: String
    ) -> String {
        "\(sapCode)|\(version)|\(processorFamily)|\(packageName)|\(packageVersion)"
    }
}

enum HDPIMDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "数据库打开失败: \(msg)"
        case .queryFailed(let msg):
            return "数据库查询失败: \(msg)"
        }
    }
}

extension HDPIMNativePackageContext {
    func withInheritedLegacyData(from legacy: HDPIMInstalledPackageSnapshot?) -> HDPIMNativePackageContext {
        guard let legacy = legacy else { return self }

        let newUninstallPath = legacy.uninstallPIMXPath?.isEmpty == false ? legacy.uninstallPIMXPath : uninstallPIMXPath
        let newUninstallHash = legacy.uninstallPIMXHash256?.isEmpty == false ? nil : (legacy.uninstallPIMXHash?.isEmpty == false ? legacy.uninstallPIMXHash : uninstallPIMXHash)
        let newUninstallHash256 = legacy.uninstallPIMXHash256?.isEmpty == false ? legacy.uninstallPIMXHash256 : uninstallPIMXHash256
        let newRepairPath = legacy.repairPIMXPath?.isEmpty == false ? legacy.repairPIMXPath : repairPIMXPath
        let newRepairHash = legacy.repairPIMXHash256?.isEmpty == false ? nil : (legacy.repairPIMXHash?.isEmpty == false ? legacy.repairPIMXHash : repairPIMXHash)
        let newRepairHash256 = legacy.repairPIMXHash256?.isEmpty == false ? legacy.repairPIMXHash256 : repairPIMXHash256
        let mergedFolders = Array(Set(targetFolders + legacy.targetFolders))

        return HDPIMNativePackageContext(
            sapCode: sapCode, productVersion: productVersion, platform: platform,
            packageName: packageName, packageVersion: packageVersion, packageType: packageType,
            packageProcessorFamily: packageProcessorFamily, sequenceNumber: sequenceNumber,
            installDir: installDir, uninstallPIMXPath: newUninstallPath,
            uninstallPIMXHash: newUninstallHash, uninstallPIMXHash256: newUninstallHash256,
            repairPIMXPath: newRepairPath, repairPIMXHash: newRepairHash,
            repairPIMXHash256: newRepairHash256, installSize: installSize,
            targetFolders: mergedFolders, ribsCoexistenceCode: ribsCoexistenceCode,
            module: module, uwpInfoXML: uwpInfoXML, isShared: isShared
        )
    }
}
