//
//  HDPIMInstallPipeline.swift
//  Adobe Downloader
//

import Foundation
import AppKit

class HDPIMInstallPipeline {

    private static let canonicalAllInstallLanguages = [
        "cs_CZ", "da_DK", "de_DE", "el_GR", "en_AE", "en_GB", "en_IL", "en_US",
        "es_ES", "es_MX", "fi_FI", "fil_PH", "fr_CA", "fr_FR", "fr_MA", "hi_IN",
        "hu_HU", "id_ID", "it_IT", "ja_JP", "ko_KR", "ms_MY", "nb_NO", "nl_NL",
        "pl_PL", "pt_BR", "ro_RO", "ru_RU", "sk_SK", "sl_SI", "sv_SE", "th_TH",
        "tr_TR", "uk_UA", "vi_VN", "zh_CN", "zh_TW"
    ]

    private var isCancelled = false
    private var backupManager: HDPIMBackupManager?
    private var allExecutedCommands: [HDPIMCommand] = []
    private var temporaryExtractDirectories: [URL] = []
    private var backedUpPaths: Set<String> = []

    private var logHandler: ((String) -> Void)?

    private struct ValidatedExtractPackage {
        let extractionResult: HDPIMExtractionResult
        let extractDir: URL
        let validation: HDPIMInstallHelper.ExtractedPackageValidationResult
    }

    private enum PackageExecutionMode {
        case full(HDPIMInstalledPackageSnapshot?)
        case databaseOnly(HDPIMInstalledPackageSnapshot)
        case delta(HDPIMInstalledPackageSnapshot, DeltaPackageInfo, URL)
    }

    private struct PackagePersistenceArtifacts {
        let uninstallPIMXPath: String?
        let uninstallPIMXHash: String?
        let uninstallPIMXHash256: String?
        let repairPIMXPath: String?
        let repairPIMXHash: String?
        let repairPIMXHash256: String?
        let targetFolders: [String]
    }

    private struct BackupTargetCandidate {
        let path: String
        let isDirectoryLike: Bool?
    }

    private final class ExtractionProgressState {
        var lastReportedStep = -1
    }

    private final class CommandProgressState {
        var lastReportedStep = -1
        var lastReportedStatus: String?
    }

    private func log(_ message: String) {
        #if DEBUG
        if let logHandler {
            logHandler(message)
        } else {
            print(message)
        }
        #endif
    }

    func install(
        productDir: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws {
        isCancelled = false
        self.logHandler = logHandler
        temporaryExtractDirectories.removeAll()
        backedUpPaths.removeAll()
        defer { cleanupTemporaryExtractDirectories() }

        progressHandler(0.0, "正在解析 driver.xml...")
        let (productInfo, requestInfo): (ProductInfoFromDriver, [String: String])
        do {
            (productInfo, requestInfo) = try parseDriverXML(at: productDir)
            log("[HDPIM Pipeline] driver.xml 解析成功: sapCode=\(productInfo.sapCode), deps=\(productInfo.dependencies.count)")
        } catch {
            log("[HDPIM Pipeline] driver.xml 解析失败: \(error)")
            throw error
        }

        let propertyTable = HDPIMPropertyTable()

        propertyTable.setupSystemDirectories()

        let installDir = requestInfo["InstallDir"] ?? "/Applications"
        propertyTable.setInstallDir(installDir)
        propertyTable.mergeFromRequestInfo(requestInfo)
        propertyTable.setProperty("workflowType", "install")

        progressHandler(0.05, "正在收集包信息...")
        try HDPIMDatabase.shared.open()
        let databaseAvailable = true
        defer { HDPIMDatabase.shared.close() }

        let collectedPackages = try collectPackages(
            productDir: productDir,
            productInfo: productInfo,
            propertyTable: propertyTable
        )

        guard !collectedPackages.isEmpty else {
            progressHandler(1.0, "没有需要安装的包")
            return
        }

        log("[HDPIM Pipeline] 收集到 \(collectedPackages.count) 个候选包: \(collectedPackages.map { $0.packageName })")

        let installedProductIdentities = HDPIMDatabase.shared.getInstalledProductIdentitySet()
        let installedProducts = HDPIMParityDecisionEngine.shared.makeInstalledProductSnapshots(databaseAlreadyOpen: true)

        let allProductContexts = makeProductDatabaseContexts(
            productInfo: productInfo,
            requestInfo: requestInfo,
            propertyTable: propertyTable,
            packages: collectedPackages
        )
        let productContextByIdentity = Dictionary(
            uniqueKeysWithValues: allProductContexts.map { (productIdentity(for: $0), $0) }
        )
        let newProductIdentities = Set(
            allProductContexts
                .map(productIdentity(for:))
                .filter { !installedProductIdentities.contains($0) }
        )

        let packagesToInstall = try filterPackagesForInstall(
            collectedPackages,
            productInfo: productInfo,
            requestInfo: requestInfo,
            propertyTable: propertyTable,
            databaseAvailable: databaseAvailable
        )

        guard !packagesToInstall.isEmpty else {
            progressHandler(1.0, "当前状态已满足安装要求")
            return
        }

        log("[HDPIM Pipeline] 本次实际需要安装 \(packagesToInstall.count) 个包: \(packagesToInstall.map { $0.packageName })")

        progressHandler(0.075, "正在校验安装包完整性...")
        try validatePackageArchives(packagesToInstall)

        progressHandler(0.08, "正在检查冲突进程...")
        try checkConflictingProcesses(packages: packagesToInstall)

        progressHandler(0.1, "正在分析安装状态...")
        let backup = HDPIMBackupManager()
        self.backupManager = backup

        var executionModeByPackage: [String: PackageExecutionMode] = [:]
        for pkg in packagesToInstall {
            executionModeByPackage[packageIdentity(for: pkg)] = await resolvePackageExecutionMode(for: pkg)
        }

        let totalPackages = packagesToInstall.count
        var installedCount = 0
        var persistedPackageContexts: [HDPIMNativePackageContext] = []
        var obsoletePackageContexts: [HDPIMNativePackageContext] = []
        var obsoleteProductKeys: [HDPIMNativeProductKey] = []
        let productContexts = makeProductContextsForPersistence(
            allProductContexts,
            packagesToInstall: packagesToInstall
        )
        let newProductContexts = productContexts.filter {
            newProductIdentities.contains(productIdentity(for: $0))
        }

        do {
            for (index, pkg) in packagesToInstall.enumerated() {
                if isCancelled || (cancellationCheck?() ?? false) {
                    throw HDPIMInstallError.cancelled
                }

                let packageProgress = Double(index) / Double(totalPackages)
                let baseProgress = 0.15 + packageProgress * 0.8  // 15%~95%
                let executionMode: PackageExecutionMode
                if let cachedExecutionMode = executionModeByPackage[packageIdentity(for: pkg)] {
                    executionMode = cachedExecutionMode
                } else {
                    executionMode = await resolvePackageExecutionMode(for: pkg)
                }
                let amtConfigAppID = firstNonEmptyString([
                    pkg.applicationInfo.amtConfig["AMTConfig.appID"],
                    pkg.applicationInfo.amtConfig["appID"]
                ])
                let targetPackageVersion = firstNonEmptyString([
                    pkg.parsed.packageVersion,
                    pkg.version
                ]) ?? pkg.version
                let persistenceArtifacts: PackagePersistenceArtifacts

                switch executionMode {
                case .databaseOnly(let installedPackage):
                    log("[HDPIM Pipeline] 包 \(pkg.packageName) 已存在相同版本 \(installedPackage.packageVersion)，按官方链路仅补数据库记录")
                    progressHandler(baseProgress + 0.08, "正在复用 \(pkg.packageName) 的已安装包信息...")
                    persistenceArtifacts = makePersistenceArtifacts(from: installedPackage)

                case .full(_), .delta(_, _, _):
                    log("[HDPIM Pipeline] 开始解压 (\(index+1)/\(totalPackages)): \(pkg.packageName) (\(pkg.zipPath.lastPathComponent))")
                    let zipSize = (try? FileManager.default.attributesOfItem(atPath: pkg.zipPath.path)[.size] as? Int64) ?? 0
                    log("[HDPIM Pipeline] ZIP 大小: \(ByteCountFormatter.string(fromByteCount: zipSize, countStyle: .file))")
                    if pkg.compressionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zip-lzma2" {
                        log("[HDPIM Pipeline] 解压后端: minizip-ng + 7-Zip LZMA2 + 3 worker")
                    } else {
                        log("[HDPIM Pipeline] 解压后端: minizip-ng + 3 worker")
                    }
                    progressHandler(baseProgress, "正在解压 \(pkg.packageName) (\(index+1)/\(totalPackages))...")

                    let extractedPackage: ValidatedExtractPackage
                    do {
                        let extractionState = ExtractionProgressState()
                        extractedPackage = try await extractPackage(
                            pkg: pkg,
                            propertyTable: propertyTable,
                            cancellationCheck: cancellationCheck,
                            progressHandler: { extractProgress in
                                let clampedProgress = min(max(extractProgress, 0), 1)
                                let mappedProgress = baseProgress + clampedProgress * 0.02
                                let percent = Int(clampedProgress * 100)
                                let coarseStep = percent / 2
                                guard coarseStep != extractionState.lastReportedStep || percent == 100 else {
                                    return
                                }
                                extractionState.lastReportedStep = coarseStep
                                progressHandler(
                                    mappedProgress,
                                    "正在解压 \(pkg.packageName) (\(index+1)/\(totalPackages))... \(percent)%"
                                )
                            }
                        )
                        let extractDir = extractedPackage.extractDir
                        log("[HDPIM Pipeline] 解压完成: \(pkg.packageName) → \(extractDir.path)")
                        log("[HDPIM Pipeline] PIMX 校验通过: \(extractedPackage.validation.pimxURL.path)")
                        log("[HDPIM Pipeline] 解压恢复统计: symlink=\(extractedPackage.extractionResult.restoredSymlinkCount), permissions=\(extractedPackage.extractionResult.restoredPermissionCount), metadata=\(extractedPackage.extractionResult.restoredMetadataCount), retries=\(extractedPackage.extractionResult.usedRetryCount)")
                        if !extractedPackage.extractionResult.diffJSONURLs.isEmpty {
                            log("[HDPIM Pipeline] 发现 diff.json: \(extractedPackage.extractionResult.diffJSONURLs.map(\.lastPathComponent))")
                        }
                        if let contents = try? FileManager.default.contentsOfDirectory(atPath: extractDir.path) {
                            log("[HDPIM Pipeline] 解压内容 (\(contents.count) 项): \(contents.prefix(20))")
                        }
                    } catch {
                        log("[HDPIM Pipeline] 解压失败 \(pkg.packageName): \(error)")
                        throw HDPIMInstallError.extractionFailed("\(pkg.packageName): \(error.localizedDescription)")
                    }

                    let helper = HDPIMInstallHelper(propertyTable: propertyTable)
                    helper.logHandler = logHandler

                    try await backupPackageTargetsIfNeeded(
                        package: pkg,
                        executionMode: executionMode,
                        extractedPackage: extractedPackage,
                        backup: backup,
                        progress: baseProgress + 0.02,
                        progressHandler: progressHandler
                    )

                    switch executionMode {
                    case .full(_):
                        progressHandler(baseProgress + 0.02, "正在安装 \(pkg.packageName)...")
                        let commandState = CommandProgressState()

                        let result = try await helper.installPackage(
                            parsedPackage: pkg.parsed,
                            extractDir: extractedPackage.extractDir,
                            sapCode: pkg.sapCode,
                            version: pkg.version,
                            platform: pkg.platform,
                            amtConfigAppID: amtConfigAppID,
                            installDir: installDir,
                            aliasPackageName: pkg.aliasPackageName,
                            productInstallDir: pkg.productInstallDir,
                            validatedExtract: extractedPackage.validation,
                            progressHandler: { cmdIndex, cmdTotal, cmdName in
                                let normalizedTotal = max(cmdTotal, 1)
                                let ratio = Double(cmdIndex + 1) / Double(normalizedTotal)
                                let cmdProgress = baseProgress + 0.02 + ratio * 0.06
                                let percent = Int(ratio * 100)
                                let coarseStep = percent / 2

                                let status: String
                                if cmdName.contains("正在处理:") {
                                    status = "[\(pkg.packageName)] \(cmdName)"
                                } else {
                                    status = "正在安装 \(pkg.packageName)... \(percent)%"
                                }

                                guard commandState.lastReportedStatus != status
                                        || commandState.lastReportedStep != coarseStep
                                        || cmdName.contains("正在处理:")
                                        || percent == 100 else {
                                    return
                                }

                                commandState.lastReportedStatus = status
                                commandState.lastReportedStep = coarseStep
                                progressHandler(cmdProgress, status)
                            }
                        )

                        allExecutedCommands.append(contentsOf: result.executedCommands)
                        persistenceArtifacts = makePersistenceArtifacts(
                            from: result,
                            validatedPackage: extractedPackage
                        )

                    case .delta(let installedPackage, let deltaInfo, let diffJsonURL):
                        log("[HDPIM Pipeline] 包 \(pkg.packageName) 命中 delta 更新，基线版本: \(installedPackage.packageVersion)")
                        let deltaProgressState = CommandProgressState()
                        let deltaHelper = HDPIMDeltaHelper()
                        do {
                            try await deltaHelper.execute(
                                sapCode: pkg.sapCode,
                                codexVersion: pkg.version,
                                platform: pkg.platform,
                                installDir: pkg.productInstallDir,
                                extractDir: extractedPackage.extractDir.path,
                                deltaInfo: deltaInfo,
                                diffJsonURL: diffJsonURL,
                                packageName: pkg.packageName,
                                packageVersion: installedPackage.packageVersion,
                                progressHandler: { fraction, message in
                                    let clampedFraction = min(max(fraction, 0), 1)
                                    let mappedProgress = baseProgress + 0.02 + clampedFraction * 0.06
                                    let percent = Int(clampedFraction * 100)
                                    let coarseStep = percent / 2
                                    let status = message.contains(pkg.packageName)
                                        ? message
                                        : "正在增量更新 \(pkg.packageName)... \(percent)%"

                                    guard deltaProgressState.lastReportedStatus != status
                                            || deltaProgressState.lastReportedStep != coarseStep
                                            || percent == 100 else {
                                        return
                                    }

                                    deltaProgressState.lastReportedStatus = status
                                    deltaProgressState.lastReportedStep = coarseStep
                                    progressHandler(mappedProgress, status)
                                },
                                databaseAlreadyOpen: true
                            )

                            let artifacts = try helper.preparePackageArtifacts(
                                parsedPackage: pkg.parsed,
                                validatedExtract: extractedPackage.validation,
                                sapCode: pkg.sapCode,
                                version: pkg.version,
                                platform: pkg.platform,
                                amtConfigAppID: amtConfigAppID
                            )
                            persistenceArtifacts = makePersistenceArtifacts(
                                from: artifacts,
                                validatedPackage: extractedPackage
                            )
                        } catch {
                            log("[HDPIM Pipeline] Delta 更新失败，回退 full install: \(error.localizedDescription)")
                            progressHandler(baseProgress + 0.02, "正在回退为完整安装 \(pkg.packageName)...")
                            let commandState = CommandProgressState()
                            let result = try await helper.installPackage(
                                parsedPackage: pkg.parsed,
                                extractDir: extractedPackage.extractDir,
                                sapCode: pkg.sapCode,
                                version: pkg.version,
                                platform: pkg.platform,
                                amtConfigAppID: amtConfigAppID,
                                installDir: installDir,
                                aliasPackageName: pkg.aliasPackageName,
                                productInstallDir: pkg.productInstallDir,
                                validatedExtract: extractedPackage.validation,
                                progressHandler: { cmdIndex, cmdTotal, cmdName in
                                    let normalizedTotal = max(cmdTotal, 1)
                                    let ratio = Double(cmdIndex + 1) / Double(normalizedTotal)
                                    let cmdProgress = baseProgress + 0.02 + ratio * 0.06
                                    let percent = Int(ratio * 100)
                                    let coarseStep = percent / 2

                                    let status: String
                                    if cmdName.contains("正在处理:") {
                                        status = "[\(pkg.packageName)] \(cmdName)"
                                    } else {
                                        status = "正在安装 \(pkg.packageName)... \(percent)%"
                                    }

                                    guard commandState.lastReportedStatus != status
                                            || commandState.lastReportedStep != coarseStep
                                            || cmdName.contains("正在处理:")
                                            || percent == 100 else {
                                        return
                                    }

                                    commandState.lastReportedStatus = status
                                    commandState.lastReportedStep = coarseStep
                                    progressHandler(cmdProgress, status)
                                }
                            )

                            allExecutedCommands.append(contentsOf: result.executedCommands)
                            persistenceArtifacts = makePersistenceArtifacts(
                                from: result,
                                validatedPackage: extractedPackage
                            )
                        }

                    case .databaseOnly:
                        fatalError("unexpected package execution mode")
                    }
                }

                let installedPackageContext = makePackageDatabaseContext(
                    package: pkg,
                    persistenceArtifacts: persistenceArtifacts,
                    installSequenceNumber: index + 1
                )
                try HDPIMDatabase.shared.recordInstalledPackage(
                    installedPackageContext,
                    product: newProductIdentities.contains(productIdentity(for: pkg))
                        ? productContextByIdentity[productIdentity(for: pkg)]
                        : nil
                )
                persistedPackageContexts.append(installedPackageContext)
                if let obsoletePackageContext = obsoletePackageContext(
                    for: executionMode,
                    targetPackageVersion: targetPackageVersion
                ) {
                    obsoletePackageContexts.append(obsoletePackageContext)
                }
                if let obsoleteProductKey = obsoleteProductKey(
                    for: executionMode,
                    targetProductVersion: pkg.version,
                    targetPlatform: pkg.platform
                ) {
                    obsoleteProductKeys.append(obsoleteProductKey)
                }

                installedCount += 1
            }

            try HDPIMDatabase.shared.recordInstalledProducts(productContexts)
            if !obsoletePackageContexts.isEmpty {
                try HDPIMDatabase.shared.removeInstalledPackages(obsoletePackageContexts)
            }
            let uniqueObsoleteProductKeys = Array(Set(obsoleteProductKeys))
            if !uniqueObsoleteProductKeys.isEmpty {
                try HDPIMDatabase.shared.removeInstallations(productKeys: uniqueObsoleteProductKeys)
                try HDPIMDatabase.shared.recordInstalledProducts(productContexts)
            }

            progressHandler(0.95, "正在清理临时文件...")
            do {
                try await backup.cleanup()
            } catch {
                log("[HDPIM Pipeline] 清理备份目录失败: \(error.localizedDescription)")
            }

            progressHandler(1.0, "安装完成")

        } catch {
            let errorDetail = "[\(packagesToInstall[min(installedCount, packagesToInstall.count - 1)].packageName)] \(error.localizedDescription)"
            progressHandler(0.0, "安装失败: \(errorDetail)，正在回滚...")

            await HDPIMRollbackHelper.rollback(
                executedCommands: allExecutedCommands,
                backupManager: backup
            )

            if !persistedPackageContexts.isEmpty {
                try? HDPIMDatabase.shared.removeInstalledPackages(
                    persistedPackageContexts,
                    removeRepairPIMX: true,
                    removeUninstallPIMX: true
                )
            }

            if !newProductContexts.isEmpty {
                try? HDPIMDatabase.shared.removeInstallations(
                    products: newProductContexts,
                    removeRepairPIMX: true,
                    removeUninstallPIMX: true
                )
            }

            throw error
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func parseDriverXML(at productDir: URL) throws -> (ProductInfoFromDriver, [String: String]) {
        let driverPath = productDir.appendingPathComponent("driver.xml")

        guard FileManager.default.fileExists(atPath: driverPath.path) else {
            throw HDPIMInstallError.pimxNotFound("driver.xml 不存在: \(driverPath.path)")
        }

        let xmlData = try Data(contentsOf: driverPath)
        let xmlDoc = try XMLDocument(data: xmlData, options: [])

        let sapCode = try xmlDoc.nodes(forXPath: "//ProductInfo/SapCode").first?.stringValue
            ?? xmlDoc.nodes(forXPath: "//ProductInfo/SAPCode").first?.stringValue ?? ""
        let codexVersion = try xmlDoc.nodes(forXPath: "//ProductInfo/CodexVersion").first?.stringValue
            ?? xmlDoc.nodes(forXPath: "//ProductInfo/ProductVersion").first?.stringValue
            ?? ""
        let platform = try xmlDoc.nodes(forXPath: "//ProductInfo/Platform").first?.stringValue ?? ""
        let buildGuid = try xmlDoc.nodes(forXPath: "//ProductInfo/BuildGuid").first?.stringValue ?? ""
        let buildVersion = try xmlDoc.nodes(forXPath: "//ProductInfo/BuildVersion").first?.stringValue ?? ""
        let moduleNodes = try xmlDoc.nodes(forXPath: "//ProductInfo/Modules/Module")

        var dependencies: [(sapCode: String, version: String, platform: String, buildGuid: String, buildVersion: String)] = []
        let depNodes = try xmlDoc.nodes(forXPath: "//ProductInfo/Dependencies/Dependency")
        for node in depNodes {
            guard let element = node as? XMLElement else { continue }
            let depSapCode = try element.nodes(forXPath: "SapCode").first?.stringValue
                ?? element.nodes(forXPath: "SAPCode").first?.stringValue ?? ""
            let depVersion = try element.nodes(forXPath: "CodexVersion").first?.stringValue
                ?? element.nodes(forXPath: "ProductVersion").first?.stringValue ?? ""
            let depPlatform = try element.nodes(forXPath: "Platform").first?.stringValue ?? ""
            let depBuildGuid = try element.nodes(forXPath: "BuildGuid").first?.stringValue ?? ""
            let depBuildVersion = try element.nodes(forXPath: "BuildVersion").first?.stringValue ?? ""
            if !depSapCode.isEmpty {
                dependencies.append((sapCode: depSapCode, version: depVersion, platform: depPlatform, buildGuid: depBuildGuid, buildVersion: depBuildVersion))
            }
        }

        let moduleIds = moduleNodes.compactMap { node -> String? in
            guard let element = node as? XMLElement else { return nil }
            return try? element.nodes(forXPath: "Id").first?.stringValue
        }.compactMap { $0 }.filter { !$0.isEmpty }

        var requestInfo: [String: String] = [:]
        let requestNodes = try xmlDoc.nodes(forXPath: "//RequestInfo/*")
        for node in requestNodes {
            if let name = node.name, let value = node.stringValue {
                requestInfo[name] = value
            }
        }

        let productInfo = ProductInfoFromDriver(
            sapCode: sapCode,
            codexVersion: codexVersion,
            platform: platform,
            buildGuid: buildGuid,
            buildVersion: buildVersion,
            dependencies: dependencies,
            moduleIds: moduleIds
        )

        if requestInfo["TargetArchitecture"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            requestInfo["TargetArchitecture"] = HDPIMParityDecisionEngine.shared.requestedTargetArchitecture(
                requestInfo: requestInfo,
                productInfo: productInfo
            ).rawValue
        }

        return (productInfo, requestInfo)
    }

    private func collectPackages(
        productDir: URL,
        productInfo: ProductInfoFromDriver,
        propertyTable: HDPIMPropertyTable
    ) throws -> [PackageToInstall] {
        var packages: [PackageToInstall] = []

        var sapCodes = [(sapCode: productInfo.sapCode, version: productInfo.codexVersion, platform: productInfo.platform)]
        for dep in productInfo.dependencies {
            sapCodes.append((sapCode: dep.sapCode, version: dep.version, platform: dep.platform))
        }

        for (sapCode, version, platform) in sapCodes {
            let sapDir = productDir.appendingPathComponent(sapCode)
            let appJsonPath = sapDir.appendingPathComponent("application.json")

            guard FileManager.default.fileExists(atPath: appJsonPath.path),
                  let jsonString = try? String(contentsOf: appJsonPath, encoding: .utf8),
                  let appInfo = try? ApplicationJSONParser.parse(jsonString: jsonString) else {
                continue
            }

            let productInstallDir: String
            if !appInfo.installDir.isEmpty {
                productInstallDir = propertyTable.expandPath(appInfo.installDir)
                log("[HDPIM Pipeline] 产品 \(sapCode) InstallDir: \(appInfo.installDir) → \(productInstallDir)")
            } else {
                productInstallDir = propertyTable.getProperty("INSTALLDIR") ?? "/Applications"
                log("[HDPIM Pipeline] 产品 \(sapCode) 无 InstallDir，使用默认: \(productInstallDir)")
            }

            for parsedPkg in appInfo.packages where !parsedPkg.path.isEmpty {
                let zipPath = sapDir.appendingPathComponent(parsedPkg.fullPackageName)
                guard FileManager.default.fileExists(atPath: zipPath.path) else { continue }

                let aliasName = parsedPkg.aliasPackageName.isEmpty
                    ? parsedPkg.packageName
                    : parsedPkg.aliasPackageName

                packages.append(PackageToInstall(
                    sapCode: sapCode,
                    version: version.isEmpty ? appInfo.codexVersion : version,
                    platform: platform,
                    packageName: parsedPkg.packageName,
                    parsed: parsedPkg,
                    applicationInfo: appInfo,
                    zipPath: zipPath,
                    sapDir: sapDir,
                    compressionType: appInfo.compressionType,
                    aliasPackageName: aliasName,
                    productInstallDir: productInstallDir
                ))
            }
        }

        return packages.sorted {
            let leftSequence = $0.parsed.installSequenceNumber > 0 ? $0.parsed.installSequenceNumber : .max
            let rightSequence = $1.parsed.installSequenceNumber > 0 ? $1.parsed.installSequenceNumber : .max
            if leftSequence != rightSequence {
                return leftSequence < rightSequence
            }
            return $0.packageName < $1.packageName
        }
    }

    private func filterPackagesForInstall(
        _ packages: [PackageToInstall],
        productInfo: ProductInfoFromDriver,
        requestInfo: [String: String],
        propertyTable: HDPIMPropertyTable,
        databaseAvailable: Bool
    ) throws -> [PackageToInstall] {
        let installedProducts = databaseAvailable
            ? HDPIMParityDecisionEngine.shared.makeInstalledProductSnapshots(databaseAlreadyOpen: true)
            : []

        return HDPIMParityDecisionEngine.shared.filterInstallPackages(
            productInfo: productInfo,
            requestInfo: requestInfo,
            packages: packages,
            propertyTable: propertyTable,
            installedProducts: installedProducts,
            databaseAvailable: databaseAvailable
        )
    }

    private func validatePackageArchives(_ packages: [PackageToInstall]) throws {
        for package in packages {
            try validatePackageArchive(package)
        }
    }

    private func validatePackageArchive(_ package: PackageToInstall) throws {
        if package.parsed.downloadSize > 0 {
            let actualSize = try zipFileSize(package.zipPath)
            guard actualSize == package.parsed.downloadSize else {
                throw HDPIMInstallError.extractionFailed(
                    "安装包校验失败: \(package.packageName) 大小不一致，期望 \(formatByteCount(package.parsed.downloadSize))，实际 \(formatByteCount(actualSize))。请重新下载该包后再安装"
                )
            }
        }

        log("[HDPIM Pipeline] 安装包大小校验通过: \(package.packageName)")
    }

    private func zipFileSize(_ zipURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func formatByteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func resolvePackageExecutionMode(for package: PackageToInstall) async -> PackageExecutionMode {
        let processorFamily = HDPIMProcessorFamily.from(platform: package.platform)
        let installedPackages = HDPIMDatabase.shared.getInstalledPackageSnapshots(
            sapCode: package.sapCode,
            processorFamily: processorFamily,
            packageName: package.packageName,
            expectedInstallDir: package.productInstallDir
        )

        guard let installedPackage = installedPackages.first else {
            return .full(nil)
        }

        let targetPackageVersion = firstNonEmptyString([
            package.parsed.packageVersion,
            package.version
        ]) ?? package.version

        if installedPackage.packageVersion == targetPackageVersion {
            return .databaseOnly(installedPackage)
        }

        let deltaSelection = await HDPIMDeltaSelector.shared.selectDeltaPackage(
            parsedPackage: package.parsed,
            installedPackageVersion: installedPackage.packageVersion,
            sapCode: package.sapCode,
            codexVersion: package.version,
            processorFamily: processorFamily
        )

        switch deltaSelection {
        case .delta(let deltaInfo, let diffJsonURL):
            return .delta(installedPackage, deltaInfo, diffJsonURL)
        case .fullPackage, .skip:
            return .full(installedPackage)
        }
    }

    private func obsoletePackageContext(
        for executionMode: PackageExecutionMode,
        targetPackageVersion: String
    ) -> HDPIMNativePackageContext? {
        let installedPackage: HDPIMInstalledPackageSnapshot?
        switch executionMode {
        case .full(let snapshot):
            installedPackage = snapshot
        case .databaseOnly(let snapshot):
            installedPackage = snapshot
        case .delta(let snapshot, _, _):
            installedPackage = snapshot
        }

        guard let installedPackage,
              installedPackage.packageVersion != targetPackageVersion else {
            return nil
        }

        return makeInstalledPackageContext(from: installedPackage)
    }

    private func obsoleteProductKey(
        for executionMode: PackageExecutionMode,
        targetProductVersion: String,
        targetPlatform: String
    ) -> HDPIMNativeProductKey? {
        let installedPackage: HDPIMInstalledPackageSnapshot?
        switch executionMode {
        case .full(let snapshot):
            installedPackage = snapshot
        case .databaseOnly(let snapshot):
            installedPackage = snapshot
        case .delta(let snapshot, _, _):
            installedPackage = snapshot
        }

        guard let installedPackage,
              installedPackage.productVersion != targetProductVersion else {
            return nil
        }

        return HDPIMNativeProductKey(
            sapCode: installedPackage.sapCode,
            version: installedPackage.productVersion,
            platform: targetPlatform
        )
    }

    private func makeProductContextsForPersistence(
        _ products: [HDPIMNativeProductContext],
        packagesToInstall: [PackageToInstall]
    ) -> [HDPIMNativeProductContext] {
        let packageProductIdentities = Set(packagesToInstall.map(productIdentity(for:)))
        return products.filter { packageProductIdentities.contains(productIdentity(for: $0)) }
    }

    private func extractPackage(
        pkg: PackageToInstall,
        propertyTable: HDPIMPropertyTable,
        cancellationCheck: (() -> Bool)? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ValidatedExtractPackage {
        let extractDir = try makeExtractLocation(installDir: pkg.productInstallDir)
        temporaryExtractDirectories.append(extractDir)

        let extractionResult = try await extractPackageAssets(
            pkg: pkg,
            to: extractDir,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        guard !extractionResult.pimxURLs.isEmpty else {
            throw HDPIMInstallError.pimxNotFound("包 \(pkg.packageName) 解压后未找到 .pimx")
        }
        let validation = try HDPIMInstallHelper.validateExtractedPackage(
            parsedPackage: pkg.parsed,
            extractDir: extractDir,
            aliasPackageName: pkg.aliasPackageName,
            productInstallDir: pkg.productInstallDir,
            propertyTable: propertyTable
        )

        return ValidatedExtractPackage(
            extractionResult: extractionResult,
            extractDir: extractDir,
            validation: validation
        )
    }

    private func extractPackageAssets(
        pkg: PackageToInstall,
        to destination: URL,
        progressHandler: ((Double) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws -> HDPIMExtractionResult {
        let coordinator = HDPIMExtractionCoordinator()
        let result = try await coordinator.extract(
            request: HDPIMExtractionRequest(
                sourceURL: pkg.zipPath,
                destinationURL: destination,
                compressionType: pkg.compressionType,
                packageName: pkg.packageName,
                validationURL: pkg.parsed.validationURLType2 ?? pkg.parsed.validationURLType1,
                isDMG: pkg.parsed.type.lowercased() == "dmg",
                allowOverlap: false
            ),
            progressHandler: progressHandler,
            retryHandler: { [weak self] attempt, maxRetryCount, error in
                self?.log("[HDPIM Pipeline] 解压重试 \(attempt)/\(maxRetryCount): \(pkg.packageName), reason=\(error.localizedDescription)")
            },
            cancellationCheck: { [weak self] in
                (self?.isCancelled ?? false) || (cancellationCheck?() ?? false)
            }
        )

        if result.usedRetryCount > 0 {
            log("[HDPIM Pipeline] 解压重试完成: \(pkg.packageName), retries=\(result.usedRetryCount)")
        }

        return result
    }

    private func makeExtractLocation(installDir: String) throws -> URL {
        let fileManager = FileManager.default
        let installURL = URL(fileURLWithPath: installDir, isDirectory: true)

        for baseURL in try extractLocationCandidates(for: installURL) {
            let primaryURL = baseURL
                .appendingPathComponent(".adobeTemp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fileManager.createDirectory(at: primaryURL, withIntermediateDirectories: true)
                return primaryURL
            } catch {
                continue
            }
        }

        let fallbackURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        log("[HDPIM Pipeline] 无法在目标卷创建 .adobeTemp，回退到系统临时目录: \(fallbackURL.path)")
        try fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
    }

    private func extractLocationCandidates(for installURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let volumeRootURL = try resolveVolumeRoot(for: installURL)
        var candidates: [URL] = []

        let dataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if volumeRootURL.path == "/" && fileManager.fileExists(atPath: dataVolumeURL.path) {
            candidates.append(dataVolumeURL)
        }

        candidates.append(volumeRootURL)

        var seen: Set<String> = []
        return candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func resolveVolumeRoot(for url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let existingURL = nearestExistingAncestor(for: standardizedURL)

        if let volumeURL = try existingURL.resourceValues(forKeys: [.volumeURLKey]).volume {
            return volumeURL.standardizedFileURL
        }

        let path = existingURL.path
        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                return URL(fileURLWithPath: "/Volumes/\(components[1])", isDirectory: true)
            }
        }

        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    private func nearestExistingAncestor(for url: URL) -> URL {
        let fileManager = FileManager.default
        var cursor = url

        while !fileManager.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path.isEmpty {
                return URL(fileURLWithPath: "/", isDirectory: true)
            }
            cursor = parent
        }

        return cursor
    }

    private func cleanupTemporaryExtractDirectories() {
        let fileManager = FileManager.default
        for directory in temporaryExtractDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryExtractDirectories.removeAll()
    }

    private func checkConflictingProcesses(packages: [PackageToInstall]) throws {
        var regexPatterns: [(regex: String, displayName: String)] = []
        var seen: Set<String> = []

        for pkg in packages {
            for process in pkg.applicationInfo.conflictingProcesses {
                let regex = process.regularExpression.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !regex.isEmpty, seen.insert(regex).inserted else { continue }
                let name = process.processDisplayName.isEmpty ? regex : process.processDisplayName
                regexPatterns.append((regex: regex, displayName: name))
            }
        }

        guard !regexPatterns.isEmpty else { return }

        let runningApps = NSWorkspace.shared.runningApplications
        let processNames = runningApps.compactMap { app -> String? in
            app.localizedName ?? app.bundleIdentifier
        }

        var conflicting: [String] = []
        for pattern in regexPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: .caseInsensitive) else {
                continue
            }
            for name in processNames {
                let range = NSRange(name.startIndex..., in: name)
                if regex.firstMatch(in: name, range: range) != nil {
                    if !conflicting.contains(pattern.displayName) {
                        conflicting.append(pattern.displayName)
                    }
                    break
                }
            }
        }

        guard !conflicting.isEmpty else { return }

        log("[HDPIM Pipeline] 检测到冲突进程: \(conflicting.joined(separator: ", "))")
        throw HDPIMInstallError.conflictingProcessDetected(conflicting)
    }

    private func backupPackageTargetsIfNeeded(
        package: PackageToInstall,
        executionMode: PackageExecutionMode,
        extractedPackage: ValidatedExtractPackage,
        backup: HDPIMBackupManager,
        progress: Double,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        guard packageRequiresFileBackup(executionMode) else {
            return
        }

        let backupDirs = collectInstallDirectories(
            package: package,
            extractedPackage: extractedPackage
        )
        guard !backupDirs.isEmpty else {
            return
        }

        log("[HDPIM Pipeline] 包 \(package.packageName) 需要备份 \(backupDirs.count) 个目录: \(backupDirs.map(\.path))")
        try await backup.backupDirectories(
            backupDirs,
            progressHandler: { index, total, dir in
                progressHandler(progress, "正在备份 \(package.packageName) 的现有文件 (\(index + 1)/\(total)): \(dir.lastPathComponent)")
            },
            logHandler: log
        )
    }

    private func packageRequiresFileBackup(_ executionMode: PackageExecutionMode) -> Bool {
        switch executionMode {
        case .databaseOnly:
            return false
        case .full, .delta:
            return true
        }
    }

    private func collectInstallDirectories(
        package: PackageToInstall,
        extractedPackage: ValidatedExtractPackage
    ) -> [URL] {
        let fileManager = FileManager.default
        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        propertyTable.setInstallDir(package.productInstallDir)
        propertyTable.setProductInstallDir(package.productInstallDir)
        propertyTable.setMediaFolder(extractedPackage.extractDir.path)
        propertyTable.setSourceFolder(extractedPackage.extractDir.path)
        propertyTable.setStagingFolder(extractedPackage.validation.stagingFolder)
        propertyTable.setProperty("workflowType", "install")

        let candidates = backupCandidates(
            from: extractedPackage.validation.packageInfo,
            fallbackInstallDir: package.productInstallDir
        )
        let expandedPaths = candidates.compactMap { candidate -> String? in
            let expandedPath = propertyTable.expandPath(candidate.path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expandedPath.isEmpty, !expandedPath.contains("[") else {
                return nil
            }

            let backupPath = backupDirectoryPath(
                expandedPath,
                isDirectoryLike: candidate.isDirectoryLike
            )
            guard !backupPath.isEmpty,
                  !shouldSkipExpandedBackupPath(backupPath),
                  fileManager.fileExists(atPath: backupPath) else {
                return nil
            }

            return normalizedBackupPath(backupPath)
        }

        var mergedPaths = mergeNestedBackupPaths(expandedPaths)
        mergedPaths.removeAll { path in
            !backedUpPaths.insert(path).inserted
        }

        return mergedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func backupCandidates(
        from packageInfo: PIMXPackageInfo,
        fallbackInstallDir: String
    ) -> [BackupTargetCandidate] {
        let assetCandidates = packageInfo.assetReferences.map {
            BackupTargetCandidate(path: $0.targetTemplate, isDirectoryLike: $0.isDirectoryLike)
        }

        if !assetCandidates.isEmpty {
            return assetCandidates
        }

        let commandCandidates = packageInfo.commands.compactMap { command -> BackupTargetCandidate? in
            switch command {
            case .moveFile(_, let target, _),
                    .copyFile(_, let target, _),
                    .blindCopy(_, let target, _),
                    .createSymlink(_, let target, _):
                return BackupTargetCandidate(path: target, isDirectoryLike: false)
            case .mergeDirectory(_, let target, _),
                    .createDirectory(let target, _):
                return BackupTargetCandidate(path: target, isDirectoryLike: true)
            case .deleteFile(let target),
                    .registerApplication(let target),
                    .setDisplayAttributes(let target, _),
                    .touch(let target):
                return BackupTargetCandidate(path: target, isDirectoryLike: false)
            case .deleteDirectory(let target),
                    .permission(let target, _),
                    .owner(let target, _, _),
                    .folderIcon(let target, _):
                return BackupTargetCandidate(path: target, isDirectoryLike: true)
            case .runProgram:
                return nil
            }
        }

        if !commandCandidates.isEmpty {
            return commandCandidates
        }

        return [BackupTargetCandidate(path: fallbackInstallDir, isDirectoryLike: true)]
    }

    private func backupDirectoryPath(_ path: String, isDirectoryLike: Bool?) -> String {
        if isDirectoryLike == true {
            return path
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return path
        }

        return (path as NSString).deletingLastPathComponent
    }

    private func normalizedBackupPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
        guard standardized.count > 1 else {
            return standardized
        }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private func shouldSkipExpandedBackupPath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "/"
            || normalized.localizedCaseInsensitiveContains("/CustomHook/")
    }

    private func mergeNestedBackupPaths(_ paths: [String]) -> [String] {
        let uniquePaths = Array(Set(paths))
            .filter { !$0.isEmpty }
            .sorted {
                let leftDepth = $0.split(separator: "/").count
                let rightDepth = $1.split(separator: "/").count
                if leftDepth != rightDepth {
                    return leftDepth < rightDepth
                }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }

        var merged: [String] = []
        for path in uniquePaths {
            if merged.contains(where: { isBackupPath(path, nestedIn: $0) }) {
                continue
            }
            merged.removeAll { isBackupPath($0, nestedIn: path) }
            merged.append(path)
        }

        return merged.sorted(by: targetFolderComesFirst)
    }

    private func isBackupPath(_ path: String, nestedIn parent: String) -> Bool {
        if path == parent {
            return true
        }
        let normalizedParent = parent.hasSuffix("/") ? parent : "\(parent)/"
        return path.hasPrefix(normalizedParent)
    }

    private func makeProductDatabaseContexts(
        productInfo: ProductInfoFromDriver,
        requestInfo: [String: String],
        propertyTable: HDPIMPropertyTable,
        packages: [PackageToInstall]
    ) -> [HDPIMNativeProductContext] {
        let groups = makeProductPackageGroups(
            productInfo: productInfo,
            packages: packages
        )
        let installLanguage = requestInfo["InstallLanguage"] ?? ""
        let fallbackInstallDir = requestInfo["InstallDir"]
            ?? propertyTable.getProperty("INSTALLDIR")
            ?? "/Applications"

        let groupLookup = Dictionary(uniqueKeysWithValues: groups.map {
            ("\($0.sapCode)|\($0.version)|\($0.platform)", $0)
        })

        return groups.map { group in
            let actualInstallDir = firstNonEmptyString([
                group.productInstallDir,
                fallbackInstallDir
            ]) ?? fallbackInstallDir
            let productPropertyTable = propertyTable.cloned()
            productPropertyTable.setInstallDir(actualInstallDir)
            productPropertyTable.setProductInstallDir(actualInstallDir)

            let appLaunchValue = firstNonEmptyString([
                propertyString(group.applicationInfo.properties["AppLaunchUsingProcessorFamily"]),
                propertyString(group.applicationInfo.properties["AppLaunch"]),
                propertyString(group.applicationInfo.properties["LaunchPath"]),
                propertyString(group.applicationInfo.properties["AppLaunchPath"])
            ]) ?? ""
            let resolvedAppLaunchPath = appLaunchValue.isEmpty ? "" : productPropertyTable.expandPath(appLaunchValue)

            let productName = firstNonEmptyString([
                group.applicationInfo.displayName,
                propertyString(group.applicationInfo.properties["ProductName"]),
                propertyString(group.applicationInfo.properties["Name"]),
                group.sapCode
            ]) ?? group.sapCode
            let conflictingProcesses = makeConflictingProcessList(from: group.applicationInfo)
            let conflictingProcessesXML = makeConflictingProcessesXML(from: group.applicationInfo)

            let modules: [String]
            if group.sapCode == productInfo.sapCode && !productInfo.moduleIds.isEmpty {
                modules = Array(Set(productInfo.moduleIds)).sorted()
            } else {
                modules = Array(Set(group.applicationInfo.modules.map(\.id).filter { !$0.isEmpty })).sorted()
            }

            let dependencies: [HDPIMNativeProductReferenceRecord]
            if group.sapCode == productInfo.sapCode {
                dependencies = productInfo.dependencies.compactMap { dependency in
                    let matchedGroup = groupLookup["\(dependency.sapCode)|\(dependency.version)|\(dependency.platform)"]
                        ?? groups.first(where: { $0.sapCode == dependency.sapCode })
                    let dependencyVersion = firstNonEmptyString([
                        matchedGroup?.applicationInfo.baseVersion,
                        matchedGroup?.version,
                        dependency.version
                    ]) ?? productInfo.codexVersion
                    let dependencyPlatform = matchedGroup?.platform ?? dependency.platform

                    return HDPIMNativeProductReferenceRecord(
                        dependencySapCode: dependency.sapCode,
                        dependencyVersion: dependencyVersion,
                        dependencyProcessorFamily: HDPIMProcessorFamily.from(platform: dependencyPlatform),
                        referencingSapCode: productInfo.sapCode,
                        referencingVersion: productInfo.codexVersion,
                        referencingProcessorFamily: HDPIMProcessorFamily.from(platform: productInfo.platform),
                        type: ""
                    )
                }
            } else {
                dependencies = []
            }

            return HDPIMNativeProductContext(
                sapCode: group.sapCode,
                codexVersion: group.version,
                platform: group.platform,
                buildGuid: group.buildGuid,
                buildVersion: firstNonEmptyString([
                    group.buildVersion,
                    group.applicationInfo.productVersion,
                    group.version
                ]) ?? group.version,
                baseVersion: group.applicationInfo.baseVersion,
                installLanguage: makeInstallLanguage(
                    from: group.applicationInfo,
                    requestedLanguage: installLanguage
                ),
                productName: productName,
                amtConfigLEID: firstNonEmptyString([
                    group.applicationInfo.amtConfig["AMTConfig.LEID"],
                    group.applicationInfo.amtConfig["LEID"]
                ]),
                amtConfigAppID: firstNonEmptyString([
                    group.applicationInfo.amtConfig["AMTConfig.appID"],
                    group.applicationInfo.amtConfig["appID"]
                ]),
                amtConfigPath: firstNonEmptyString([
                    group.applicationInfo.amtConfig["AMTConfig.path"],
                    group.applicationInfo.amtConfig["path"]
                ]),
                conflictingProcesses: conflictingProcesses,
                conflictingProcessesXML: conflictingProcessesXML,
                installDir: actualInstallDir,
                appLaunchPath: appLaunchValue,
                resolvedAppLaunchPath: resolvedAppLaunchPath,
                modules: modules,
                autoInstall: group.applicationInfo.autoInstall,
                isVisibleProduct: group.applicationInfo.isVisibleProduct,
                isSelfReference: group.applicationInfo.isSelfReference,
                isNonCCProduct: group.applicationInfo.isNonCCProduct,
                vulcanConfig: propertyString(group.applicationInfo.properties["VulcanConfig"]),
                uxpPluginConfig: propertyString(group.applicationInfo.properties["UxpPluginConfig"]),
                ffcEnvironment: propertyTable.getProperty("FFCEnvironment"),
                dependencies: dependencies
            )
        }
    }

    private func makeProductPackageGroups(
        productInfo: ProductInfoFromDriver,
        packages: [PackageToInstall]
    ) -> [ProductPackageGroup] {
        var buildGuidByKey: [String: String] = [
            "\(productInfo.sapCode)|\(productInfo.codexVersion)|\(productInfo.platform)": productInfo.buildGuid
        ]
        var buildVersionByKey: [String: String] = [
            "\(productInfo.sapCode)|\(productInfo.codexVersion)|\(productInfo.platform)": productInfo.buildVersion
        ]

        for dependency in productInfo.dependencies {
            buildGuidByKey["\(dependency.sapCode)|\(dependency.version)|\(dependency.platform)"] = dependency.buildGuid
            buildVersionByKey["\(dependency.sapCode)|\(dependency.version)|\(dependency.platform)"] = dependency.buildVersion
        }

        var groups: [ProductPackageGroup] = []
        var indexByKey: [String: Int] = [:]

        for package in packages {
            let key = "\(package.sapCode)|\(package.version)|\(package.platform)"
            if let index = indexByKey[key] {
                let existing = groups[index]
                groups[index] = ProductPackageGroup(
                    sapCode: existing.sapCode,
                    version: existing.version,
                    platform: existing.platform,
                    buildGuid: existing.buildGuid,
                    buildVersion: existing.buildVersion,
                    applicationInfo: existing.applicationInfo,
                    productInstallDir: existing.productInstallDir,
                    packages: existing.packages + [package]
                )
                continue
            }

            indexByKey[key] = groups.count
            groups.append(
                ProductPackageGroup(
                    sapCode: package.sapCode,
                    version: package.version,
                    platform: package.platform,
                    buildGuid: buildGuidByKey["\(package.sapCode)|\(package.version)|\(package.platform)"] ?? "",
                    buildVersion: buildVersionByKey["\(package.sapCode)|\(package.version)|\(package.platform)"] ?? "",
                    applicationInfo: package.applicationInfo,
                    productInstallDir: package.productInstallDir,
                    packages: [package]
                )
            )
        }

        return groups
    }

    private func makePackageDatabaseContext(
        package: PackageToInstall,
        persistenceArtifacts: PackagePersistenceArtifacts,
        installSequenceNumber: Int
    ) -> HDPIMNativePackageContext {
        let moduleValue = makeModuleValue(for: package)
        let packageProcessorFamily = officialPackageProcessorFamily(for: package)
        let extractSizeValue: String = {
            if package.parsed.extractSize > 0 {
                return "\(package.parsed.extractSize)"
            }
            if package.parsed.downloadSize > 0 {
                return "\(package.parsed.downloadSize)"
            }
            let zipSize = (try? FileManager.default.attributesOfItem(atPath: package.zipPath.path)[.size] as? Int64) ?? 0
            return zipSize > 0 ? "\(zipSize)" : "0"
        }()

        return HDPIMNativePackageContext(
            sapCode: package.sapCode,
            productVersion: package.version,
            platform: package.platform,
            packageName: package.packageName,
            packageVersion: package.parsed.packageVersion.isEmpty ? package.version : package.parsed.packageVersion,
            packageType: package.parsed.type,
            packageProcessorFamily: packageProcessorFamily,
            sequenceNumber: package.parsed.installSequenceNumber > 0 ? package.parsed.installSequenceNumber : installSequenceNumber,
            installDir: package.productInstallDir,
            uninstallPIMXPath: persistenceArtifacts.uninstallPIMXPath,
            uninstallPIMXHash: persistenceArtifacts.uninstallPIMXHash,
            uninstallPIMXHash256: persistenceArtifacts.uninstallPIMXHash256,
            repairPIMXPath: persistenceArtifacts.repairPIMXPath,
            repairPIMXHash: persistenceArtifacts.repairPIMXHash,
            repairPIMXHash256: persistenceArtifacts.repairPIMXHash256,
            installSize: extractSizeValue,
            targetFolders: persistenceArtifacts.targetFolders,
            ribsCoexistenceCode: propertyString(package.applicationInfo.properties["RIBSCoexistenceCode"]),
            module: moduleValue,
            uwpInfoXML: nil,
            isShared: package.parsed.isShared
        )
    }

    private func makePersistenceArtifacts(
        from installResult: HDPIMInstallHelper.InstallResult,
        validatedPackage: ValidatedExtractPackage
    ) -> PackagePersistenceArtifacts {
        PackagePersistenceArtifacts(
            uninstallPIMXPath: installResult.uninstallPIMXPath?.path,
            uninstallPIMXHash: installResult.uninstallPIMXHash,
            uninstallPIMXHash256: installResult.uninstallPIMXHash256,
            repairPIMXPath: installResult.repairPIMXPath?.path,
            repairPIMXHash: installResult.repairPIMXHash,
            repairPIMXHash256: installResult.repairPIMXHash256,
            targetFolders: makeTargetFolders(from: validatedPackage.validation.packageInfo.assetReferences)
        )
    }

    private func makePersistenceArtifacts(
        from installedPackage: HDPIMInstalledPackageSnapshot
    ) -> PackagePersistenceArtifacts {
        PackagePersistenceArtifacts(
            uninstallPIMXPath: installedPackage.uninstallPIMXPath,
            uninstallPIMXHash: installedPackage.uninstallPIMXHash,
            uninstallPIMXHash256: installedPackage.uninstallPIMXHash256,
            repairPIMXPath: installedPackage.repairPIMXPath,
            repairPIMXHash: installedPackage.repairPIMXHash,
            repairPIMXHash256: installedPackage.repairPIMXHash256,
            targetFolders: installedPackage.targetFolders.sorted(by: targetFolderComesFirst)
        )
    }

    private func makeInstalledPackageContext(
        from installedPackage: HDPIMInstalledPackageSnapshot
    ) -> HDPIMNativePackageContext {
        HDPIMNativePackageContext(
            sapCode: installedPackage.sapCode,
            productVersion: installedPackage.productVersion,
            platform: platform(for: installedPackage.processorFamily),
            packageName: installedPackage.packageName,
            packageVersion: installedPackage.packageVersion,
            packageType: "",
            packageProcessorFamily: "",
            sequenceNumber: 0,
            installDir: installedPackage.installDir,
            uninstallPIMXPath: installedPackage.uninstallPIMXPath,
            uninstallPIMXHash: installedPackage.uninstallPIMXHash,
            uninstallPIMXHash256: installedPackage.uninstallPIMXHash256,
            repairPIMXPath: installedPackage.repairPIMXPath,
            repairPIMXHash: installedPackage.repairPIMXHash,
            repairPIMXHash256: installedPackage.repairPIMXHash256,
            installSize: "0",
            targetFolders: installedPackage.targetFolders,
            ribsCoexistenceCode: nil,
            module: nil,
            uwpInfoXML: nil,
            isShared: false
        )
    }

    private func makeTargetFolders(from assets: [PIMXAssetReference]) -> [String] {
        var seen: Set<String> = []
        var folders: [String] = []

        for asset in assets {
            let targetPath = asset.targetTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetPath.isEmpty,
                  !shouldSkipTargetFolder(targetPath),
                  seen.insert(targetPath).inserted else {
                continue
            }
            folders.append(targetPath)
        }

        return folders.sorted(by: targetFolderComesFirst)
    }

    private func productIdentity(for product: HDPIMNativeProductContext) -> String {
        "\(product.sapCode)|\(product.codexVersion)|\(product.processorFamily.rawValue)"
    }

    private func productIdentity(for package: PackageToInstall) -> String {
        "\(package.sapCode)|\(package.version)|\(HDPIMProcessorFamily.from(platform: package.platform).rawValue)"
    }

    private func packageIdentity(for package: PackageToInstall) -> String {
        let processorFamily = HDPIMProcessorFamily.from(platform: package.platform).rawValue
        let packageVersion = package.parsed.packageVersion.isEmpty ? package.version : package.parsed.packageVersion
        return "\(package.sapCode)|\(package.version)|\(processorFamily)|\(package.packageName)|\(packageVersion)"
    }

    private func makeModuleValue(for package: PackageToInstall) -> String? {
        let matchedModules = package.applicationInfo.modules
            .filter { module in
                module.referencePackages.contains(package.packageName)
                    || module.referencePackages.contains(package.aliasPackageName)
                    || module.referencePackages.contains(package.parsed.fullPackageName)
            }
            .map(\.id)
            .filter { !$0.isEmpty }

        guard !matchedModules.isEmpty else {
            return nil
        }
        return matchedModules.joined(separator: ",")
    }

    private func makeConflictingProcessList(from appInfo: ApplicationInfo) -> String {
        appInfo.conflictingProcesses.compactMap { process in
            firstNonEmptyString([
                process.processDisplayName,
                process.regularExpression,
                process.relativePath
            ])
        }.joined(separator: ",")
    }

    private func makeConflictingProcessesXML(from appInfo: ApplicationInfo) -> String {
        guard !appInfo.conflictingProcesses.isEmpty else {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ConflictingProcesses></ConflictingProcesses>"
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ConflictingProcesses>\n"

        for process in appInfo.conflictingProcesses {
            xml += "    <ConflictingProcess headless=\"\(xmlEscaped(process.headless))\" forceKillAllowed=\"\(xmlEscaped(process.forceKillAllowed))\" adobeOwned=\"\(xmlEscaped(process.adobeOwned))\">"
            xml += "<RegularExpression>\(xmlEscaped(process.regularExpression))</RegularExpression>\n"
            xml += "        <ProcessDisplayName>\(xmlEscaped(process.processDisplayName))</ProcessDisplayName>\n"
            xml += "        <RelativePath>\(xmlEscaped(process.relativePath))</RelativePath>\n"
            let parentRegex = process.parentRegularExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            if !parentRegex.isEmpty {
                xml += "        <ParentRegularExpression>\(xmlEscaped(process.parentRegularExpression))</ParentRegularExpression>\n"
            }
            let parentDisplayName = process.parentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !parentDisplayName.isEmpty {
                xml += "        <ParentDisplayName>\(xmlEscaped(process.parentDisplayName))</ParentDisplayName>\n"
            }
            xml += "    </ConflictingProcess>\n"
        }

        xml += "</ConflictingProcesses>"
        return xml
    }

    private func officialPackageProcessorFamily(for package: PackageToInstall) -> String {
        let explicitValue = package.parsed.processorFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitValue.isEmpty {
            return explicitValue
        }

        let productPlatform = firstNonEmptyString([
            propertyString(package.applicationInfo.properties["Platform"]),
            package.platform
        ]) ?? ""

        return productPlatform.localizedCaseInsensitiveContains("64") ? "64-bit" : "32-bit"
    }

    private func makeInstallLanguage(from appInfo: ApplicationInfo, requestedLanguage: String) -> String {
        let rawLanguages = appInfo.supportedLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let supportedLanguages = rawLanguages.filter { $0.caseInsensitiveCompare("mul") != .orderedSame }
        let hasMulLanguage = rawLanguages.contains { $0.caseInsensitiveCompare("mul") == .orderedSame }
        let trimmedRequested = requestedLanguage.trimmingCharacters(in: .whitespacesAndNewlines)

        if appInfo.autoInstall && !appInfo.isVisibleProduct {
            if hasMulLanguage {
                return Self.canonicalAllInstallLanguages.joined(separator: ",")
            }
            if !supportedLanguages.isEmpty {
                return supportedLanguages.joined(separator: ",")
            }
        }

        if !supportedLanguages.isEmpty,
            supportedLanguages.count <= 2,
            !trimmedRequested.isEmpty,
           supportedLanguages.contains(trimmedRequested),
           supportedLanguages.contains("en_US") {
            return supportedLanguages.joined(separator: ",")
        }

        if !trimmedRequested.isEmpty {
            if supportedLanguages.contains(trimmedRequested) {
                return trimmedRequested
            }
            if hasMulLanguage {
                return Self.canonicalAllInstallLanguages.joined(separator: ",")
            }
            if supportedLanguages.contains("en_US"), trimmedRequested != "en_US" {
                return ["en_US", trimmedRequested].joined(separator: ",")
            }
            return trimmedRequested
        }

        if !supportedLanguages.isEmpty {
            return supportedLanguages.joined(separator: ",")
        }

        if hasMulLanguage {
            return Self.canonicalAllInstallLanguages.joined(separator: ",")
        }

        return ""
    }

    private func shouldSkipTargetFolder(_ path: String) -> Bool {
        path.localizedCaseInsensitiveContains("/CustomHook/")
    }

    private func targetFolderComesFirst(_ lhs: String, _ rhs: String) -> Bool {
        let leftCategory = targetFolderCategoryRank(lhs)
        let rightCategory = targetFolderCategoryRank(rhs)
        if leftCategory != rightCategory {
            return leftCategory < rightCategory
        }

        let leftSpecial = targetFolderSpecialRank(lhs, category: leftCategory)
        let rightSpecial = targetFolderSpecialRank(rhs, category: rightCategory)
        if leftSpecial != rightSpecial {
            return leftSpecial < rightSpecial
        }

        return lhs.localizedStandardCompare(rhs) == .orderedDescending
    }

    private func targetFolderCategoryRank(_ path: String) -> Int {
        let normalized = path.lowercased()
        if normalized.hasPrefix("[userpreferences]") {
            return 0
        }
        if normalized.hasPrefix("[usercommon]") {
            return 1
        }
        if normalized.hasPrefix("[shareddocuments]") {
            return 2
        }
        if normalized.hasPrefix("[installdir]") {
            return 3
        }
        if normalized.hasPrefix("[adobecommon]") {
            return 4
        }
        return 5
    }

    private func targetFolderSpecialRank(_ path: String, category: Int) -> Int {
        let normalized = path.lowercased()
        switch category {
        case 0:
            return normalized == "[userpreferences]" ? 1 : 0
        case 1:
            return normalized.contains("/uxp/pluginsstorage/") ? 0 : 1
        case 3:
            return normalized == "[installdir]" ? 1 : 0
        case 4:
            if normalized == "[adobecommon]" {
                return 2
            }
            if normalized.contains("/amt") {
                return 0
            }
            return 1
        default:
            return 0
        }
    }

    private func propertyString(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private func platform(for processorFamily: HDPIMProcessorFamily) -> String {
        switch processorFamily {
        case .bit32:
            return "OSX10"
        case .bit64:
            return "osx10-64"
        case .arm64Bit:
            return "macarm64"
        }
    }

    private func firstNonEmptyString(_ values: [String?]) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct ProductPackageGroup {
    let sapCode: String
    let version: String
    let platform: String
    let buildGuid: String
    let buildVersion: String
    let applicationInfo: ApplicationInfo
    let productInstallDir: String
    let packages: [PackageToInstall]
}

struct ProductInfoFromDriver {
    let sapCode: String
    let codexVersion: String
    let platform: String
    let buildGuid: String
    let buildVersion: String
    let dependencies: [(sapCode: String, version: String, platform: String, buildGuid: String, buildVersion: String)]
    let moduleIds: [String]
}

struct PackageToInstall {
    let sapCode: String
    let version: String
    let platform: String
    let packageName: String
    let parsed: ParsedPackage
    let applicationInfo: ApplicationInfo
    let zipPath: URL
    let sapDir: URL
    let compressionType: String
    let aliasPackageName: String
    let productInstallDir: String
}
