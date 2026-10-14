//
//  HDPIMInstallPipeline.swift
//  Adobe Downloader
//

import Foundation
import AppKit
import CryptoKit
import Darwin

class HDPIMInstallPipeline {

    private static let canonicalAllInstallLanguages = [
        "cs_CZ", "da_DK", "de_DE", "el_GR", "en_AE", "en_GB", "en_IL", "en_US",
        "es_ES", "es_MX", "fi_FI", "fil_PH", "fr_CA", "fr_FR", "fr_MA", "hi_IN",
        "hu_HU", "id_ID", "it_IT", "ja_JP", "ko_KR", "ms_MY", "nb_NO", "nl_NL",
        "pl_PL", "pt_BR", "ro_RO", "ru_RU", "sk_SK", "sl_SI", "sv_SE", "th_TH",
        "tr_TR", "uk_UA", "vi_VN", "zh_CN", "zh_TW"
    ]

    private let operationLock = NSLock()
    private var operationCancellation: HDPIMOperationCancellation?
    private var isCancelled: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operationCancellation?.isCancelled == true
    }
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

    private struct PreparedInstallPackage {
        let plan: HDPIMPlannedPackage
        let extracted: ValidatedExtractPackage?
        let context: HDPIMPropertyTable
        let delta: HDPIMDeltaHelper.Prepared?
        var repairResources: HDPIMRepairResources.Plan? = nil
    }

    private struct PreviousPackageActions {
        let uninstall: [PIMXCommandDescriptor]
        let repair: [HDPIMCommand]
    }

    private typealias PackageExecutionMode = HDPIMPackageExecutionMode

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
        let cancellation = HDPIMOperationCancellation(externalCheck: cancellationCheck)
        try beginOperation(cancellation)
        defer { endOperation(cancellation) }
        try await withTaskCancellationHandler {
            try await HDPIMOperationContext.$cancellation.withValue(cancellation) {
                try HDPIMOperationContext.checkCancellation()
                try await runInstall(productDir: productDir, progressHandler: progressHandler,
                                     logHandler: logHandler, cancellationCheck: { cancellation.isCancelled })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func beginOperation(_ cancellation: HDPIMOperationCancellation) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard operationCancellation == nil else {
            throw HDPIMMaterialError.unavailable("安装操作尚未结束")
        }
        operationCancellation = cancellation
    }

    private func endOperation(_ cancellation: HDPIMOperationCancellation) {
        cancellation.stopMonitoring()
        operationLock.lock()
        operationCancellation = nil
        operationLock.unlock()
    }

    private func runInstall(
        productDir: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?,
        cancellationCheck: (() -> Bool)?
    ) async throws {
        self.logHandler = logHandler
        let metrics = InstallMetrics(log: log)
        allExecutedCommands.removeAll()
        temporaryExtractDirectories.removeAll()
        backedUpPaths.removeAll()
        defer { cleanupTemporaryExtractDirectories() }

        progressHandler(0.0, AppLocalized("正在解析 driver.xml..."))
        let (productInfo, requestInfo): (ProductInfoFromDriver, [String: String])
        do {
            (productInfo, requestInfo) = try parseDriverXML(at: productDir)
            log(String(format: AppLocalized("[HDPIM Pipeline] driver.xml 解析成功: sapCode=%@, deps=%d"), productInfo.sapCode, productInfo.dependencies.count))
        } catch {
            log(String(format: AppLocalized("[HDPIM Pipeline] driver.xml 解析失败: %@"), String(describing: error)))
            throw error
        }

        let propertyTable = HDPIMPropertyTable()

        propertyTable.setupSystemDirectories()

        let installDir = requestInfo["InstallDir"] ?? "/Applications"
        propertyTable.setInstallDir(installDir)
        propertyTable.mergeFromRequestInfo(requestInfo)
        propertyTable.setProperty("workflowType", "install")

        progressHandler(0.05, AppLocalized("正在收集包信息..."))
        try HDPIMDatabase.shared.open()
        let databaseAvailable = true
        defer { HDPIMDatabase.shared.close() }
        let databaseVersion = try HDPIMDatabase.shared.dataVersion()

        let reusedDependencies = try resolveReusedDependencies(
            productDir: productDir, productInfo: productInfo, propertyTable: propertyTable
        )
        let collectedPackages = try collectPackages(
            productDir: productDir,
            productInfo: productInfo,
            propertyTable: propertyTable,
            reusedDependencies: Set(reusedDependencies.keys)
        )

        guard !collectedPackages.isEmpty else {
            progressHandler(1.0, AppLocalized("没有需要安装的包"))
            return
        }

        log(String(format: AppLocalized("[HDPIM Pipeline] 收集到 %d 个候选包: %@"), collectedPackages.count, String(describing: collectedPackages.map { $0.packageName })))

        let installedProductIdentities = HDPIMDatabase.shared.getInstalledProductIdentitySet()

        let allProductContexts = makeProductDatabaseContexts(
            productInfo: productInfo,
            requestInfo: requestInfo,
            propertyTable: propertyTable,
            packages: collectedPackages,
            reusedDependencies: reusedDependencies
        )
        let productContextByIdentity = Dictionary(
            uniqueKeysWithValues: allProductContexts.map { (productIdentity(for: $0), $0) }
        )
        let newProductIdentities = Set(
            allProductContexts
                .map(productIdentity(for:))
                .filter { !installedProductIdentities.contains($0) }
        )

        let selectedPackages = try filterPackagesForInstall(
            collectedPackages,
            productInfo: productInfo,
            requestInfo: requestInfo,
            propertyTable: propertyTable,
            databaseAvailable: databaseAvailable
        )

        guard !selectedPackages.isEmpty else {
            progressHandler(1.0, AppLocalized("当前状态已满足安装要求"))
            return
        }

        try X1a0HeCCComponents.requireComplete()
        let plans = try selectedPackages.map { try makeInstallPlan(for: $0, requestInfo: requestInfo) }
        for plan in plans {
            if case .databaseOnly(let snapshot) = plan.mode {
                let context = try makePackageContext(plan.package, parent: propertyTable, requestInfo: requestInfo)
                try HDPIMMaterialIntegrity.validateReuse(snapshot, context: context)
            }
        }
        let packagesToInstall = plans.map(\.package)
        let packageProgress = HDPIMPackageProgressReporter(packages: packagesToInstall.enumerated().map { index, package in
            HDPIMPackageProgress(id: index, name: package.packageName, productCode: package.sapCode,
                                 version: package.parsed.packageVersion)
        }, handler: logHandler)
        metrics.finishStage("解析与计划", inputBytes: packagesToInstall.reduce(0) { $0 + $1.parsed.downloadSize })
        let allowNetwork = !["1", "true", "yes"].contains((requestInfo["Offline"] ?? "").lowercased())
        for plan in plans {
            try HDPIMOperationContext.checkCancellation()
            if let reason = plan.fullFallbackReason {
                log("[HDPIM Pipeline] \(plan.package.packageName) 准备回退全量：\(reason)")
                try await HDPIMInstallMaterialPreparer.prepareFullFallback(plan, allowNetwork: allowNetwork) { fraction, status in
                    progressHandler(0.06 + min(max(fraction, 0), 1) * 0.01, status)
                }
            }
        }
        log(String(format: AppLocalized("[HDPIM Pipeline] 本次实际需要安装 %d 个包: %@"), packagesToInstall.count, String(describing: packagesToInstall.map { $0.packageName })))

        progressHandler(0.075, AppLocalized("正在校验安装包完整性..."))
        try validatePackageArchives(plans.filter { $0.mode.requiresExtraction }.map(\.package), cancellationCheck: cancellationCheck)
        metrics.finishStage("材料补齐与完整性校验")

        let fullPreviousActions: [PreviousPackageActions?] = try plans.map { plan in
            guard case .full = plan.mode else { return nil }
            let context = try makePackageContext(plan.package, parent: propertyTable, requestInfo: requestInfo)
            return try preparePreviousCommands(for: plan, context: context)
        }

        progressHandler(0.08, AppLocalized("正在检查冲突进程..."))
        try checkConflictingProcesses(packages: packagesToInstall)

        progressHandler(0.1, AppLocalized("正在分析安装状态..."))
        let preparedPackages = try await preparePackages(
            plans, propertyTable: propertyTable, requestInfo: requestInfo,
            allowNetwork: allowNetwork, packageProgress: packageProgress, progressHandler: progressHandler
        )
        metrics.finishStage("并行解压与预检", inputBytes: preparedPackages.reduce(0) { $0 + $1.plan.package.parsed.extractSize })
        let userDirectoryOwnership = try prepareUserDirectoryOwnership(preparedPackages)
        let backup = HDPIMBackupManager()
        self.backupManager = backup

        let totalPackages = packagesToInstall.count
        var installedCount = 0
        var persistedPackageContexts: [HDPIMNativePackageContext] = []
        var obsoletePackageContexts: [HDPIMNativePackageContext] = []
        var obsoleteProductKeys: [HDPIMNativeProductKey] = []
        let productContexts = makeProductContextsForPersistence(
            allProductContexts,
            packagesToInstall: packagesToInstall
        )

        let previousActions = try preparedPackages.enumerated().map { index, prepared in
            if let actions = fullPreviousActions[index] { return actions }
            return try preparePreviousCommands(for: prepared.plan, context: prepared.context)
        }
        var previousRepairsNeeded = Set<Int>()
        var changes: [HDPIMFileChange] = userDirectoryOwnership?.changes ?? []
        for (index, prepared) in preparedPackages.enumerated() where prepared.plan.mode.requiresExtraction {
            changes += try HDPIMFileChange.from(previousActions[index].uninstall)
            guard let extracted = prepared.extracted else { continue }
            if let delta = prepared.delta {
                changes += try HDPIMFileChange.from(delta.commands)
                changes += try HDPIMFileChange.from(extracted.validation.packageInfo.commands.filter(isModifier))
            } else {
                changes += try HDPIMFileChange.from(extracted.validation.packageInfo.commands)
            }
            changes += (prepared.repairResources?.changedPaths ?? [])
                .map { HDPIMFileChange(path: $0, kind: .contents) }
            let package = prepared.plan.package
            let appID = package.applicationInfo.amtConfig["AMTConfig.appID"] ?? package.applicationInfo.amtConfig["appID"]
            changes += HDPIMInstallHelper(propertyTable: prepared.context).artifactURLs(for: package, amtConfigAppID: appID)
                .map { HDPIMFileChange(path: $0.path, kind: .contents) }
        }
        changes += HDPIMARPCompletion.targetPaths(for: productContexts).map { HDPIMFileChange(path: $0, kind: .contents) }
        changes.append(HDPIMFileChange(path: HDPIMRIBSHelper.storageDirectory.path, kind: .contents))
        var lastBackupUpdate = -Double.infinity
        try await backup.capture(changes) { index, total, _ in
            let now = ProcessInfo.processInfo.systemUptime
            guard index + 1 == total || now - lastBackupUpdate >= 0.15 else { return }
            lastBackupUpdate = now
            let fraction = Double(index + 1) / Double(max(total, 1))
            progressHandler(0.54 + fraction * 0.01, "正在准备安装恢复记录... \(Int(fraction * 100))%")
        }
        metrics.finishStage("恢复记录")
        try HDPIMOperationContext.checkCancellation()
        try HDPIMDatabase.shared.beginInstallTransaction()
        var transactionOpen = true
        var startedSystemWrites = false

        do {
            guard try HDPIMDatabase.shared.dataVersion() == databaseVersion else {
                throw HDPIMMaterialError.unavailable("准备期间安装数据库发生变化，请重新开始安装")
            }
            let verifiedDependencies = try resolveReusedDependencies(
                productDir: productDir, productInfo: productInfo, propertyTable: propertyTable
            )
            guard verifiedDependencies.count == reusedDependencies.count,
                  reusedDependencies.allSatisfy({ sapCode, selected in
                      guard let verified = verifiedDependencies[sapCode] else { return false }
                      return verified.version == selected.version
                          && verified.baseVersion == selected.baseVersion
                          && verified.processorFamily == selected.processorFamily
                  }) else {
                throw HDPIMMaterialError.unavailable("准备期间复用依赖发生变化，请补齐材料后重新安装")
            }
            for prepared in preparedPackages {
                switch prepared.plan.mode {
                case .databaseOnly(let installed), .delta(let installed, _):
                    try HDPIMMaterialIntegrity.validateReuse(installed, context: prepared.context)
                case .full: break
                }
            }
            if let userDirectoryOwnership {
                startedSystemWrites = true
                try userDirectoryOwnership.repairExistingDirectories()
            }
            for (index, prepared) in preparedPackages.enumerated() {
                let plan = prepared.plan
                let pkg = plan.package
                if isCancelled || (cancellationCheck?() ?? false) {
                    throw HDPIMInstallError.cancelled
                }

                let completedFraction = Double(index) / Double(totalPackages)
                let baseProgress = 0.55 + completedFraction * 0.36
                packageProgress.update(index: index, stage: .installing, fraction: 0)
                let packageSpan = 0.36 / Double(totalPackages)
                let executionMode = plan.mode
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
                    log(String(format: AppLocalized("[HDPIM Pipeline] 包 %@ 已存在相同版本 %@，按官方链路仅补数据库记录"), pkg.packageName, installedPackage.packageVersion))
                    progressHandler(baseProgress + packageSpan, String(format: AppLocalized("正在复用 %@ 的已安装包信息..."), pkg.packageName))
                    persistenceArtifacts = makePersistenceArtifacts(from: installedPackage)

                case .full(_), .delta(_, _):
                    startedSystemWrites = true
                    guard let extractedPackage = prepared.extracted else {
                        throw HDPIMMaterialError.unavailable("包尚未完成解压预检：\(pkg.packageName)")
                    }
                    log("[HDPIM Pipeline] 使用已预检材料：\(pkg.packageName)，类型=\(plan.material.kind.rawValue)")
                    try prepared.repairResources?.publish()
                    let helper = HDPIMInstallHelper(propertyTable: prepared.context)
                    helper.logHandler = logHandler

                    if !previousActions[index].uninstall.isEmpty {
                        progressHandler(baseProgress, "正在处理 \(pkg.packageName) 的旧安装状态...")
                        let engine = HDPIMCommandEngine(propertyTable: prepared.context)
                        _ = try await engine.executeAll(commands: engine.generateCommands(from: previousActions[index].uninstall),
                                                       commandWillExecute: { command in
                            if command is RunProgramCommand || command is RegisterApplicationCommand {
                                previousRepairsNeeded.insert(index)
                            }
                        })
                    }

                    switch executionMode {
                    case .full(_):
                        progressHandler(baseProgress, String(format: AppLocalized("正在全量安装 %@..."), pkg.packageName))
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
                            commandWillExecute: { command in
                                if command is RunProgramCommand {
                                    try userDirectoryOwnership?.repairExistingDirectories()
                                    self.allExecutedCommands.append(command)
                                }
                            },
                            commandDidExecute: { if !($0 is RunProgramCommand) { self.allExecutedCommands.append($0) } },
                            progressHandler: { cmdIndex, cmdTotal, cmdName in
                                packageProgress.update(index: index, stage: .installing,
                                                       fraction: Double(cmdIndex) / Double(max(cmdTotal, 1)))
                                let normalizedTotal = max(cmdTotal, 1)
                                let ratio = Double(cmdIndex + 1) / Double(normalizedTotal)
                                let cmdProgress = baseProgress + ratio * packageSpan
                                let percent = Int(ratio * 100)
                                let coarseStep = percent / 2

                                let isProcessingCommand = cmdName.contains("正在处理:") ||
                                    cmdName.localizedCaseInsensitiveContains("processing:")
                                let status: String
                                if isProcessingCommand {
                                    status = "[\(pkg.packageName)] \(cmdName)"
                                } else {
                                    status = String(format: AppLocalized("正在安装 %@... %d%%"), pkg.packageName, percent)
                                }

                                guard commandState.lastReportedStatus != status
                                        || commandState.lastReportedStep != coarseStep
                                        || isProcessingCommand
                                        || percent == 100 else {
                                    return
                                }

                                commandState.lastReportedStatus = status
                                commandState.lastReportedStep = coarseStep
                                progressHandler(cmdProgress, status)
                            }
                        )

                        persistenceArtifacts = makePersistenceArtifacts(
                            from: result,
                            validatedPackage: extractedPackage
                        )

                    case .delta:
                        guard let preparedDelta = prepared.delta else {
                            throw HDPIMMaterialError.invalid("差分计划尚未完成预检：\(pkg.packageName)")
                        }
                        let deltaProgressState = CommandProgressState()
                        let deltaHelper = HDPIMDeltaHelper()
                        packageProgress.update(index: index, stage: .updatingFiles, fraction: 0)
                        try await deltaHelper.execute(
                            preparedDelta,
                            progressHandler: { fraction, message in
                                let clampedFraction = min(max(fraction, 0), 1)
                                packageProgress.update(index: index, stage: .updatingFiles, fraction: clampedFraction)
                                let mappedProgress = baseProgress + clampedFraction * packageSpan
                                let percent = Int(clampedFraction * 100)
                                let coarseStep = percent / 2
                                let status = message.contains(pkg.packageName)
                                    ? message
                                    : String(format: AppLocalized("正在增量更新 %@... %d%%"), pkg.packageName, percent)

                                guard deltaProgressState.lastReportedStatus != status
                                        || deltaProgressState.lastReportedStep != coarseStep
                                        || percent == 100 else {
                                    return
                                }

                                deltaProgressState.lastReportedStatus = status
                                deltaProgressState.lastReportedStep = coarseStep
                                progressHandler(mappedProgress, status)
                            }
                        )

                        let modifiers = extractedPackage.validation.packageInfo.commands.filter(isModifier)
                        let engine = HDPIMCommandEngine(propertyTable: prepared.context)
                        packageProgress.update(index: index, stage: .installing, fraction: 0)
                        let modifierResult = try await engine.executeAll(
                            commands: engine.generateCommands(from: modifiers),
                            commandWillExecute: { command in
                                if command is RunProgramCommand {
                                    try userDirectoryOwnership?.repairExistingDirectories()
                                    self.allExecutedCommands.append(command)
                                }
                            },
                            commandDidExecute: { if !($0 is RunProgramCommand) { self.allExecutedCommands.append($0) } },
                            progressHandler: { commandIndex, commandCount, _ in
                                packageProgress.update(index: index, stage: .installing,
                                                       fraction: Double(commandIndex) / Double(max(commandCount, 1)))
                            }
                        )

                        packageProgress.update(index: index, stage: .registering, fraction: 0)
                        let artifacts = try helper.preparePackageArtifacts(
                            parsedPackage: pkg.parsed,
                            validatedExtract: extractedPackage.validation,
                            executedCommands: modifierResult.executedCommands,
                            sapCode: pkg.sapCode,
                            version: pkg.version,
                            platform: pkg.platform,
                            amtConfigAppID: amtConfigAppID,
                            uninstallManifestOverride: preparedDelta.uninstallManifest,
                            literalPathsOverride: preparedDelta.literalPaths
                        )
                        persistenceArtifacts = makePersistenceArtifacts(
                            from: artifacts,
                            validatedPackage: extractedPackage
                        )

                    case .databaseOnly:
                        fatalError("unexpected package execution mode")
                    }
                }

                packageProgress.update(index: index, stage: .registering, fraction: 0)
                let installedPackageContext = makePackageDatabaseContext(
                    package: pkg,
                    persistenceArtifacts: persistenceArtifacts,
                    installSequenceNumber: index + 1
                )
                startedSystemWrites = true
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

                packageProgress.update(index: index, stage: .awaitingCompletion, fraction: 1)
                installedCount += 1
                metrics.finishStage("安装 \(pkg.packageName) [\(plan.material.kind.rawValue)]")
            }

            try HDPIMDatabase.shared.recordInstalledProducts(productContexts)
            if !obsoletePackageContexts.isEmpty {
                try HDPIMDatabase.shared.removeInstalledPackages(obsoletePackageContexts)
            }
            let uniqueObsoleteProductKeys = Array(Set(obsoleteProductKeys))
            if !uniqueObsoleteProductKeys.isEmpty {
                try HDPIMDatabase.shared.removeObsoleteProducts(uniqueObsoleteProductKeys)
                try HDPIMDatabase.shared.recordInstalledProducts(productContexts)
            }

            progressHandler(0.93, AppLocalized("正在注册卸载条目..."))
            HDPIMARPCompletion.createARPEntries(
                for: productContexts,
                progressHandler: progressHandler,
                logHandler: logHandler
            )

            for (index, package) in persistedPackageContexts.enumerated() {
                try HDPIMOperationContext.checkCancellation()
                try HDPIMDatabase.shared.validateMaterialRegistration(package)
                try HDPIMMaterialIntegrity.validateFiles(for: package, context: preparedPackages[index].context)
                try preparedPackages[index].repairResources?.verifyPublished()
            }
            try userDirectoryOwnership?.repairExistingDirectories()
            try await userDirectoryOwnership?.verifyUserAccess()
            try HDPIMOperationContext.checkCancellation()
            try HDPIMDatabase.shared.commitInstallTransaction()
            transactionOpen = false
            metrics.finishStage("数据库提交与注册")

            progressHandler(0.95, AppLocalized("正在清理临时文件..."))
            do {
                try await backup.cleanup()
            } catch {
                log(String(format: AppLocalized("[HDPIM Pipeline] 清理备份目录失败: %@"), error.localizedDescription))
            }

            metrics.finishStage("清理恢复备份")

            progressHandler(1.0, AppLocalized("安装完成"))

        } catch {
            let errorDetail = "[\(packagesToInstall[min(installedCount, packagesToInstall.count - 1)].packageName)] \(error.localizedDescription)"
            progressHandler(0.0, String(format: AppLocalized("安装失败: %@，正在回滚..."), errorDetail))

            var recoveryErrors: [String] = []
            var filesRestored = !startedSystemWrites
            if startedSystemWrites {
                let recovery = await HDPIMOperationContext.$isRecovering.withValue(true) {
                    await HDPIMRollbackHelper.rollback(executedCommands: allExecutedCommands, backupManager: backup,
                                                       fileChangesCaptured: true)
                }
                recoveryErrors += recovery.failures
                filesRestored = recovery.filesRestored
            }
            var databaseRestored = true
            if transactionOpen {
                do { try HDPIMDatabase.shared.rollbackInstallTransaction() }
                catch {
                    databaseRestored = false
                    recoveryErrors.append("数据库恢复失败：\(error.localizedDescription)")
                }
            }
            if filesRestored && databaseRestored {
                recoveryErrors += await HDPIMOperationContext.$isRecovering.withValue(true) {
                    await HDPIMRollbackHelper.repairPreviousPackages(
                        previousRepairsNeeded.sorted().map { previousActions[$0].repair }
                    )
                }
            } else if !previousRepairsNeeded.isEmpty {
                recoveryErrors.append("文件或数据库未完整恢复，未执行旧版本 repair")
            }
            if !recoveryErrors.isEmpty {
                throw HDPIMInstallError.rollbackFailed("原始错误：\(error.localizedDescription)\n\(recoveryErrors.joined(separator: "\n"))\n恢复记录：\(backup.recoveryDirectory.path)")
            }
            throw error
        }
    }

    func cancel() {
        operationLock.lock()
        let cancellation = operationCancellation
        operationLock.unlock()
        cancellation?.cancel()
    }

    private func parseDriverXML(at productDir: URL) throws -> (ProductInfoFromDriver, [String: String]) {
        let driverPath = productDir.appendingPathComponent("driver.xml")

        guard FileManager.default.fileExists(atPath: driverPath.path) else {
            throw HDPIMInstallError.pimxNotFound(String(format: AppLocalized("driver.xml 不存在: %@"), driverPath.path))
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
        var dependencyBaseVersions: [String: String] = [:]
        var reuseOnlyDependencies = Set<String>()
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
                dependencyBaseVersions[depSapCode] = try element.nodes(forXPath: "BaseVersion").first?.stringValue ?? ""
                if try element.nodes(forXPath: "ReuseInstalled").first?.stringValue == "true" {
                    reuseOnlyDependencies.insert(depSapCode)
                }
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
            moduleIds: moduleIds,
            dependencyBaseVersions: dependencyBaseVersions,
            reuseOnlyDependencies: reuseOnlyDependencies
        )

        if requestInfo["TargetArchitecture"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            requestInfo["TargetArchitecture"] = HDPIMParityDecisionEngine.shared.requestedTargetArchitecture(
                requestInfo: requestInfo,
                productInfo: productInfo
            ).rawValue
        }

        return (productInfo, requestInfo)
    }

    private func resolveReusedDependencies(
        productDir: URL, productInfo: ProductInfoFromDriver, propertyTable: HDPIMPropertyTable
    ) throws -> [String: HDPIMInstalledProductSnapshot] {
        let engine = HDPIMParityDecisionEngine.shared
        let installed = engine.makeInstalledProductSnapshots(databaseAlreadyOpen: true)
        var result: [String: HDPIMInstalledProductSnapshot] = [:]
        for dependency in productInfo.dependencies {
            try HDPIMOperationContext.checkCancellation()
            guard HDPIMPackageMaterial.isLeafName(dependency.sapCode) else {
                throw HDPIMMaterialError.invalid("非法依赖标识：\(dependency.sapCode)")
            }
            let applicationURL = productDir.appendingPathComponent(dependency.sapCode)
                .appendingPathComponent("application.json")
            let baseVersion: String
            if let declared = productInfo.dependencyBaseVersions[dependency.sapCode], !declared.isEmpty {
                baseVersion = declared
            } else if FileManager.default.fileExists(atPath: applicationURL.path) {
                baseVersion = try ApplicationJSONParser.parse(
                    jsonString: String(contentsOf: applicationURL, encoding: .utf8)
                ).baseVersion
            } else {
                baseVersion = ""
            }
            guard let reused = engine.reusableInstalledProduct(
                sapCode: dependency.sapCode, targetVersion: dependency.version,
                targetPlatform: dependency.platform, targetBaseVersion: baseVersion,
                installedProducts: installed
            ) else {
                if productInfo.reuseOnlyDependencies.contains(dependency.sapCode)
                    || !FileManager.default.fileExists(atPath: applicationURL.path) {
                    throw HDPIMMaterialError.unavailable(
                        "依赖 \(dependency.sapCode) 已无法复用，请补齐安装材料后重试"
                    )
                }
                continue
            }
            let contexts = HDPIMDatabase.shared.getInstalledPackageContexts(
                sapCode: reused.sapCode, version: reused.version, processorFamily: reused.processorFamily
            )
            for package in contexts {
                guard let snapshot = HDPIMDatabase.shared.getInstalledPackageSnapshots(
                    sapCode: reused.sapCode, processorFamily: reused.processorFamily,
                    packageName: package.packageName, expectedInstallDir: package.installDir
                ).first(where: { $0.productVersion == reused.version && $0.packageVersion == package.packageVersion }) else {
                    throw HDPIMMaterialError.unavailable("依赖 \(reused.sapCode) 状态已变化，请补齐材料后重试")
                }
                try HDPIMMaterialIntegrity.validateReuse(snapshot, context: propertyTable)
            }
            result[dependency.sapCode] = reused
        }
        return result
    }

    private func collectPackages(
        productDir: URL,
        productInfo: ProductInfoFromDriver,
        propertyTable: HDPIMPropertyTable,
        reusedDependencies: Set<String>
    ) throws -> [PackageToInstall] {
        var packages: [PackageToInstall] = []

        var sapCodes = [(sapCode: productInfo.sapCode, version: productInfo.codexVersion, platform: productInfo.platform)]
        for dep in productInfo.dependencies where !reusedDependencies.contains(dep.sapCode) {
            sapCodes.append((sapCode: dep.sapCode, version: dep.version, platform: dep.platform))
        }

        for (sapCode, version, platform) in sapCodes {
            let sapDir = productDir.appendingPathComponent(sapCode)
            let appJsonPath = sapDir.appendingPathComponent("application.json")

            let jsonString = try String(contentsOf: appJsonPath, encoding: .utf8)
            let appInfo = try ApplicationJSONParser.parse(jsonString: jsonString)

            let productInstallDir: String
            if !appInfo.installDir.isEmpty {
                productInstallDir = try propertyTable.expandPathForInstallation(appInfo.installDir)
                log(String(format: AppLocalized("[HDPIM Pipeline] 产品 %@ InstallDir: %@ → %@"), sapCode, appInfo.installDir, productInstallDir))
            } else {
                productInstallDir = propertyTable.getProperty("INSTALLDIR") ?? "/Applications"
                log(String(format: AppLocalized("[HDPIM Pipeline] 产品 %@ 无 InstallDir，使用默认: %@"), sapCode, productInstallDir))
            }

            guard productInstallDir.hasPrefix("/"), !productInstallDir.contains("\0"),
                  productInstallDir != "/" else {
                throw HDPIMMaterialError.invalid("产品安装路径未正确展开：\(productInstallDir)")
            }

            for parsedPkg in appInfo.packages where !parsedPkg.path.isEmpty {
                let zipPath = sapDir.appendingPathComponent(parsedPkg.fullPackageName)
                guard HDPIMPackageMaterial.isLeafName(parsedPkg.fullPackageName) else {
                    throw HDPIMMaterialError.invalid("非法包文件名：\(parsedPkg.fullPackageName)")
                }

                let aliasName = parsedPkg.aliasPackageName.isEmpty
                    ? parsedPkg.packageName
                    : parsedPkg.aliasPackageName
                guard HDPIMPackageMaterial.isLeafName(aliasName) else {
                    throw HDPIMMaterialError.invalid("非法 AliasPackageName：\(aliasName)")
                }

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

    private func validatePackageArchives(
        _ packages: [PackageToInstall],
        cancellationCheck: (() -> Bool)?
    ) throws {
        for package in packages {
            guard !isCancelled, !Task.isCancelled, !(cancellationCheck?() ?? false) else {
                throw HDPIMInstallError.cancelled
            }
            try validatePackageArchive(package, cancellationCheck: cancellationCheck)
        }
    }

    private func validatePackageArchive(
        _ package: PackageToInstall,
        cancellationCheck: (() -> Bool)?
    ) throws {
        do {
            _ = try DownloadArtifactStore.verify(
                fileURL: package.zipPath,
                identity: DownloadArtifactStore.Identity(
                    name: package.parsed.fullPackageName,
                    version: package.parsed.packageVersion,
                    hashKey: package.parsed.packageHashKey
                ),
                expectedSize: package.parsed.downloadSize,
                cancellationCheck: { [weak self] in
                    (self?.isCancelled ?? true) || Task.isCancelled || (cancellationCheck?() ?? false)
                }
            )
            guard !isCancelled, !Task.isCancelled, !(cancellationCheck?() ?? false) else {
                throw CancellationError()
            }
        } catch is CancellationError {
            throw HDPIMInstallError.cancelled
        } catch {
            guard !isCancelled, !Task.isCancelled, !(cancellationCheck?() ?? false) else {
                throw HDPIMInstallError.cancelled
            }
            throw HDPIMInstallError.extractionFailed(
                String(format: AppLocalized("安装包完整性校验失败: %@。%@。请返回下载管理继续下载或重新校验后再安装"), package.packageName, error.localizedDescription)
            )
        }

        log(String(format: AppLocalized("[HDPIM Pipeline] 安装包完整性校验通过: %@"), package.packageName))
    }

    private func makeInstallPlan(for package: PackageToInstall, requestInfo: [String: String]) throws -> HDPIMPlannedPackage {
        let processorFamily = HDPIMProcessorFamily.from(platform: package.platform)
        let installedPackages = HDPIMDatabase.shared.getInstalledPackageSnapshots(
            sapCode: package.sapCode,
            processorFamily: processorFamily,
            packageName: package.packageName,
            expectedInstallDir: package.productInstallDir,
            includingInvalidMaterials: true
        )

        let failedVersions = HDPIMDatabase.shared.getDeltaFailVersions(
            sapCode: package.sapCode,
            version: package.version,
            processorFamily: processorFamily
        )
        var forceFullInstall = ["1", "true", "yes"].contains((requestInfo["ForceInstall"] ?? "").lowercased())
        if let installed = installedPackages.first,
           let platform = HDPIMDatabase.shared.getProductMeta(
                sapCode: installed.sapCode, version: installed.productVersion,
                processorFamily: installed.processorFamily, key: HDPIMProductMetaKey.platform.rawValue
           ), !platform.isEmpty, platform.caseInsensitiveCompare(package.platform) != .orderedSame {
            forceFullInstall = true
        }
        return try HDPIMInstallPlanner.plan(package: package, installedPackages: installedPackages,
                                            failedDeltaVersions: Set(failedVersions), forceFullInstall: forceFullInstall)
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
        case .delta(let snapshot, _):
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
        case .delta(let snapshot, _):
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

    private func isModifier(_ descriptor: PIMXCommandDescriptor) -> Bool {
        switch descriptor {
        case .runProgram, .registerApplication, .permission, .owner, .setDisplayAttributes, .touch, .folderIcon:
            return true
        default:
            return false
        }
    }

    private func preparePreviousCommands(for plan: HDPIMPlannedPackage,
                                         context parentContext: HDPIMPropertyTable) throws -> PreviousPackageActions {
        try HDPIMOperationContext.checkCancellation()
        let snapshot: HDPIMInstalledPackageSnapshot
        let modifiersOnly: Bool
        switch plan.mode {
        case .full(let previous):
            guard let previous else { return PreviousPackageActions(uninstall: [], repair: []) }
            snapshot = previous
            modifiersOnly = false
        case .delta(let previous, _):
            snapshot = previous
            modifiersOnly = true
        case .databaseOnly:
            return PreviousPackageActions(uninstall: [], repair: [])
        }
        let context = HDPIMMaterialIntegrity.recoveryContext(from: parentContext)
        context.setProductInstallDir(snapshot.installDir)
        context.setProperty("CodexVersion", snapshot.productVersion)
        context.setProperty("PackageVersion", snapshot.packageVersion)
        context.setProperty("workflowType", "uninstall")
        let url: URL
        let xmlData: Data
        do {
            guard let path = snapshot.uninstallPIMXPath, !path.isEmpty else {
                throw HDPIMMaterialError.invalid("旧包缺少卸载 PIMX：\(snapshot.packageName)")
            }
            url = URL(fileURLWithPath: path)
            xmlData = try HDPIMMaterialIntegrity.verifiedXML(url, sha1: snapshot.uninstallPIMXHash,
                                                         sha256: snapshot.uninstallPIMXHash256)
        } catch {
            try HDPIMOperationContext.checkCancellation()
            guard !modifiersOnly else { throw error }
            let warning = String(format: AppLocalized("[HDPIM Pipeline] Warning: 旧卸载材料不可用，跳过旧清理并继续全量安装，可能保留旧文件。产品=%@ %@，包=%@，旧材料=%@，安装源=%@"),
                                 snapshot.sapCode, snapshot.productVersion, snapshot.packageName,
                                 snapshot.uninstallPIMXPath ?? "", plan.package.zipPath.path)
            if let logHandler { logHandler(warning) } else { print(warning) }
            log("[HDPIM Pipeline] 旧卸载材料校验详情：\(error.localizedDescription)")
            return PreviousPackageActions(uninstall: [], repair: [])
        }
        let parsed = try PIMXParser(propertyTable: context).parseUninstallCommands(
            pimxURL: url, xmlData: xmlData, preservingUserPreferences: true
        )
        let commands = modifiersOnly ? parsed.filter(isModifier) : parsed
        do {
            try HDPIMRepairResources.validateStoredCommands(commands)
            let needsRepair = commands.contains {
                switch $0 { case .runProgram, .registerApplication: return true; default: return false }
            }
            guard needsRepair else { return PreviousPackageActions(uninstall: commands, repair: []) }
            guard let repairPath = snapshot.repairPIMXPath, !repairPath.isEmpty else {
                throw HDPIMMaterialError.invalid("旧包缺少 Hook 恢复材料：\(snapshot.packageName)")
            }
            let repairURL = URL(fileURLWithPath: repairPath)
            let repairXML = try HDPIMMaterialIntegrity.verifiedXML(repairURL, sha1: snapshot.repairPIMXHash, sha256: snapshot.repairPIMXHash256)
            context.setProperty("workflowType", "install")
            let repair = try PIMXParser(propertyTable: context).parseRepairCommands(pimxURL: repairURL, xmlData: repairXML)
            guard !repair.isEmpty else {
                throw HDPIMMaterialError.invalid("旧包 Hook 恢复材料为空：\(snapshot.packageName)")
            }
            try HDPIMRepairResources.validateStoredCommands(repair)
            _ = try HDPIMFileChange.from(repair)
            return PreviousPackageActions(uninstall: commands, repair: HDPIMCommandEngine(propertyTable: context).generateCommands(from: repair))
        } catch let error as HDPIMRepairResources.MissingStoredProgram {
            try HDPIMOperationContext.checkCancellation()
            guard !modifiersOnly else { throw error }
            let warning = String(format: AppLocalized("[HDPIM Pipeline] Warning: 旧卸载或恢复程序不存在，跳过该包旧动作并继续全量安装，可能保留旧文件或注册信息。产品=%@ %@，包=%@，缺失程序=%@，安装源=%@"),
                                 snapshot.sapCode, snapshot.productVersion, snapshot.packageName,
                                 error.path, plan.package.zipPath.path)
            if let logHandler { logHandler(warning) } else { print(warning) }
            return PreviousPackageActions(uninstall: [], repair: [])
        }
    }

    private func prepareUserDirectoryOwnership(_ packages: [PreparedInstallPackage]) throws -> HDPIMUserDirectoryOwnership? {
        let home = URL(fileURLWithPath: HDPIMRuntimeEnvironment.userHomeDirectory()).standardizedFileURL.path
        var directories: [String] = []
        for prepared in packages {
            try HDPIMOperationContext.checkCancellation()
            if case .databaseOnly(let snapshot) = prepared.plan.mode {
                guard let path = snapshot.uninstallPIMXPath, !path.isEmpty else {
                    throw HDPIMMaterialError.invalid("旧包缺少卸载 PIMX：\(snapshot.packageName)")
                }
                let url = URL(fileURLWithPath: path)
                let xml = try HDPIMMaterialIntegrity.verifiedXML(url, sha1: snapshot.uninstallPIMXHash,
                                                               sha256: snapshot.uninstallPIMXHash256)
                let context = HDPIMMaterialIntegrity.recoveryContext(from: prepared.context)
                context.setProductInstallDir(snapshot.installDir)
                context.setProperty("CodexVersion", snapshot.productVersion)
                context.setProperty("PackageVersion", snapshot.packageVersion)
                context.setProperty("workflowType", "uninstall")
                directories += try PIMXParser(propertyTable: context).parseInstalledDirectories(pimxURL: url, xmlData: xml)
            } else {
                let manifest = prepared.delta?.uninstallManifest
                    ?? prepared.extracted?.validation.packageInfo.uninstallManifest ?? []
                directories += try manifest.map { entry in
                    let path = try entry.actualTargetPath ?? prepared.context.expandPathForInstallation(entry.targetPath)
                    return entry.isDirectory ? path : (path as NSString).deletingLastPathComponent
                }
                if let delta = prepared.delta {
                    directories += HDPIMUserDirectoryOwnership.installationDirectories(from: delta.commands)
                } else if let extracted = prepared.extracted {
                    directories += try HDPIMUserDirectoryOwnership.installationDirectories(
                        from: extracted.validation.packageInfo.commands, userHome: home
                    )
                }
            }
        }
        guard directories.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(home + "/") }) else {
            return nil
        }
        let ownership = try HDPIMUserDirectoryOwnership(directories: directories, user: .resolve(userHome: home))
        return ownership.directories.isEmpty ? nil : ownership
    }

    private func preparePackages(
        _ plans: [HDPIMPlannedPackage],
        propertyTable: HDPIMPropertyTable,
        requestInfo: [String: String],
        allowNetwork: Bool,
        packageProgress: HDPIMPackageProgressReporter,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> [PreparedInstallPackage] {
        var roots: [URL?] = []
        var contexts: [HDPIMPropertyTable] = []
        for plan in plans {
            let root = try plan.mode.requiresExtraction ? makeExtractLocation(installDir: plan.package.productInstallDir) : nil
            roots.append(root)
            if let root { temporaryExtractDirectories.append(root) }
            contexts.append(try makePackageContext(plan.package, parent: propertyTable, requestInfo: requestInfo))
        }
        try validatePreparationCapacity(plans, roots: roots)
        var result = [PreparedInstallPackage?](repeating: nil, count: plans.count)
        let progress = HDPIMPreparationProgress(count: plans.count, handler: progressHandler)
        try await withThrowingTaskGroup(of: (Int, PreparedInstallPackage).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let plan = plans[index]
                let root = roots[index]
                let context = contexts[index]
                group.addTask {
                    packageProgress.update(index: index, stage: .preparing, fraction: 0)
                    let prepared = try await self.preparePackage(plan, root: root, context: context,
                                                                 allowNetwork: allowNetwork) { fraction, status in
                        packageProgress.update(index: index, stage: .preparing, fraction: fraction)
                        progress.update(index: index, fraction: fraction, name: plan.package.packageName, status: status)
                    }
                    packageProgress.update(index: index, stage: .prepared, fraction: 1)
                    return (index, prepared)
                }
            }
            while next < min(2, plans.count) {
                enqueue(next)
                next += 1
            }
            do {
                while let (index, prepared) = try await group.next() {
                    result[index] = prepared
                    if next < plans.count {
                        try HDPIMOperationContext.checkCancellation()
                        enqueue(next)
                        next += 1
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
        return try result.enumerated().map { index, item in
            guard let item else {
                throw HDPIMMaterialError.unavailable("未完成包预检：\(plans[index].package.packageName)")
            }
            guard let extracted = item.extracted else { return item }
            let package = item.plan.package
            let identity = [package.sapCode, package.version, package.platform,
                            package.packageName, package.parsed.packageVersion, package.productInstallDir]
                .joined(separator: "\n")
            let resources = try HDPIMRepairResources.prepare(
                stagingFolder: extracted.validation.stagingFolder, packageIdentity: identity,
                descriptors: extracted.validation.packageInfo.commands
            )
            let sourceInfo = extracted.validation.packageInfo
            let info = PIMXPackageInfo(
                packageName: sourceInfo.packageName, commands: resources.descriptors,
                assetReferences: sourceInfo.assetReferences, literalPaths: sourceInfo.literalPaths,
                uninstallManifest: sourceInfo.uninstallManifest
            )
            let validation = HDPIMInstallHelper.ExtractedPackageValidationResult(
                pimxURL: extracted.validation.pimxURL, pimxData: extracted.validation.pimxData,
                packageInfo: info, stagingFolder: extracted.validation.stagingFolder
            )
            return PreparedInstallPackage(
                plan: item.plan,
                extracted: ValidatedExtractPackage(extractionResult: extracted.extractionResult,
                                                  extractDir: extracted.extractDir, validation: validation),
                context: item.context, delta: item.delta, repairResources: resources
            )
        }
    }

    private func makePackageContext(_ package: PackageToInstall, parent: HDPIMPropertyTable,
                                    requestInfo: [String: String]) throws -> HDPIMPropertyTable {
        let context = parent.cloned()
        for (key, value) in package.applicationInfo.properties {
            if let value = value as? String { context.setProperty(key, value) }
        }
        context.mergeFromRequestInfo(requestInfo)
        if let requestedLanguage = context.getProperty("installLanguage"), !requestedLanguage.isEmpty {
            context.setProperty("installLanguage", try HDPIMParityDecisionEngine.shared.languageWithEnglishFallback(
                requestedLanguage, applicationInfo: package.applicationInfo))
        }
        context.setProductInstallDir(package.productInstallDir)
        context.setProperty("SAPCode", package.sapCode)
        context.setProperty("CodexVersion", package.version)
        context.setProperty("PackageName", package.packageName)
        context.setProperty("PackageVersion", package.parsed.packageVersion)
        context.setProperty("workflowType", "install")
        return context
    }

    private func validatePreparationCapacity(_ plans: [HDPIMPlannedPackage], roots: [URL?]) throws {
        var volumes: [String: (available: Int64, required: Int64)] = [:]
        for (index, plan) in plans.enumerated() {
            guard let root = roots[index] else { continue }
            let values = try root.resourceValues(forKeys: [.volumeIdentifierKey, .volumeAvailableCapacityForImportantUsageKey])
            guard let available = values.volumeAvailableCapacityForImportantUsage else { continue }
            let key = String(describing: values.volumeIdentifier)
            let selectedSize = max(0, plan.material.selected.extractSize)
            let fullSize = plan.material.kind == .delta ? max(0, plan.material.full?.extractSize ?? 0) : 0
            let required = selectedSize.addingReportingOverflow(fullSize)
            let total = (volumes[key]?.required ?? 0).addingReportingOverflow(required.partialValue)
            guard !required.overflow, !total.overflow else { throw HDPIMMaterialError.invalid("材料解压大小溢出") }
            volumes[key] = (min(available, volumes[key]?.available ?? available), total.partialValue)
        }
        for volume in volumes.values where volume.required > volume.available {
            throw HDPIMMaterialError.unavailable("准备目录空间不足：预计需要 \(volume.required) 字节，可用 \(volume.available) 字节")
        }
    }

    private final class InstallMetrics {
        private let started = ProcessInfo.processInfo.systemUptime
        private var previous = ProcessInfo.processInfo.systemUptime
        private let log: (String) -> Void
        init(log: @escaping (String) -> Void) { self.log = log }
        func finishStage(_ stage: String, inputBytes: Int64? = nil) {
            let now = ProcessInfo.processInfo.systemUptime
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let bytes = inputBytes.map { "，材料字节=\($0)" } ?? ""
            log(String(format: "[HDPIM 耗时] %@：%.3f s，累计 %.3f s，进程峰值内存=%lld 字节%@",
                       stage, now - previous, now - started, Int64(usage.ru_maxrss), bytes))
            previous = now
        }
    }

    private func preparePackage(
        _ initialPlan: HDPIMPlannedPackage, root: URL?, context: HDPIMPropertyTable,
        allowNetwork: Bool, progress: @escaping (Double, String?) -> Void
    ) async throws -> PreparedInstallPackage {
        try HDPIMOperationContext.checkCancellation()
        guard let root else {
            progress(1, nil)
            return PreparedInstallPackage(plan: initialPlan, extracted: nil, context: context, delta: nil)
        }
        let localCancellation = PDMTransferCancellation()
        return try await withTaskCancellationHandler {
            let isCancelled = { self.isCancelled || localCancellation.isCancelled }
            let extracted = try await extractPackage(pkg: initialPlan.package, to: root,
                                                      propertyTable: context, cancellationCheck: isCancelled,
                                                      progressHandler: { progress($0 * 0.85, nil) })
            let package = initialPlan.package
            context.setMediaFolder(root.path)
            context.setSourceFolder(root.path)
            context.setStagingFolder(extracted.validation.stagingFolder)
            if case .delta(let installed, _) = initialPlan.mode {
                let diffURL = try await HDPIMInstallMaterialPreparer.diffJSON(for: initialPlan,
                                                                            extracted: extracted.extractionResult,
                                                                            allowNetwork: allowNetwork)
                do {
                    progress(0.85, "正在校验并预计算差分补丁：\(package.packageName)")
                    let delta = try await HDPIMDeltaHelper().prepare(diffJsonURL: diffURL, package: package,
                                                               propertyTable: context, extractDir: root)
                    progress(1, nil)
                    return PreparedInstallPackage(plan: initialPlan, extracted: extracted, context: context, delta: delta)
                } catch let error as DeltaPreflightError {
                    let full = try initialPlan.material.selectingFull()
                    let plan = HDPIMPlannedPackage(package: package.selecting(full), material: full,
                                                   mode: .full(installed), fullFallbackReason: error.localizedDescription)
                    log("[HDPIM Pipeline] \(package.packageName) 差分预检不适用，回退全量：\(error.localizedDescription)")
                    try await HDPIMInstallMaterialPreparer.prepareFullFallback(plan, allowNetwork: allowNetwork) { fraction, status in
                        progress(0.85 + fraction * 0.06, status)
                    }
                    try HDPIMOperationContext.checkCancellation()
                    let fullRoot = root.appendingPathComponent("full-fallback", isDirectory: true)
                    progress(0.91, "正在解压回退全量包：\(package.packageName) 0%")
                    let fullExtract = try await extractPackage(pkg: plan.package, to: fullRoot,
                                                              propertyTable: context, cancellationCheck: isCancelled,
                                                              progressHandler: { fraction in
                        progress(0.91 + fraction * 0.09, "正在解压回退全量包：\(package.packageName) \(Int(fraction * 100))%")
                    })
                    context.setMediaFolder(fullRoot.path)
                    context.setSourceFolder(fullRoot.path)
                    context.setStagingFolder(fullExtract.validation.stagingFolder)
                    progress(1, nil)
                    return PreparedInstallPackage(plan: plan, extracted: fullExtract, context: context, delta: nil)
                }
            }
            progress(1, nil)
            return PreparedInstallPackage(plan: initialPlan, extracted: extracted, context: context, delta: nil)
        } onCancel: {
            localCancellation.cancel()
        }
    }

    private func extractPackage(
        pkg: PackageToInstall,
        to extractDir: URL,
        propertyTable: HDPIMPropertyTable,
        cancellationCheck: (() -> Bool)? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ValidatedExtractPackage {
        let extractionResult = try await extractPackageAssets(
            pkg: pkg,
            to: extractDir,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )
        guard !extractionResult.pimxURLs.isEmpty else {
            throw HDPIMInstallError.pimxNotFound(String(format: AppLocalized("包 %@ 解压后未找到 .pimx"), pkg.packageName))
        }
        let validation = try HDPIMInstallHelper.validateExtractedPackage(
            parsedPackage: pkg.parsed,
            extractDir: extractDir,
            aliasPackageName: pkg.aliasPackageName,
            productInstallDir: pkg.productInstallDir,
            propertyTable: propertyTable,
            skipAssetSourceValidation: pkg.parsed.material?.kind == .delta
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
                self?.log(String(format: AppLocalized("[HDPIM Pipeline] 解压重试 %d/%d: %@, reason=%@"), attempt, maxRetryCount, pkg.packageName, error.localizedDescription))
            },
            cancellationCheck: { [weak self] in
                (self?.isCancelled ?? false) || (cancellationCheck?() ?? false)
            }
        )

        if result.usedRetryCount > 0 {
            log(String(format: AppLocalized("[HDPIM Pipeline] 解压重试完成: %@, retries=%d"), pkg.packageName, result.usedRetryCount))
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
        log(String(format: AppLocalized("[HDPIM Pipeline] 无法在目标卷创建 .adobeTemp，回退到系统临时目录: %@"), fallbackURL.path))
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

        log(String(format: AppLocalized("[HDPIM Pipeline] 检测到冲突进程: %@"), conflicting.joined(separator: ", ")))
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

        log(String(format: AppLocalized("[HDPIM Pipeline] 包 %@ 需要备份 %d 个目录"), package.packageName, backupDirs.count))
        var lastBackupPercent = -1
        try await backup.backupDirectories(
            backupDirs,
            progressHandler: { index, total, _ in
                let percent = total > 0 ? (index + 1) * 100 / total : 100
                guard percent != lastBackupPercent else { return }
                lastBackupPercent = percent
                progressHandler(progress, String(format: AppLocalized("正在备份 %@ 的现有文件... %d%%"), package.packageName, percent))
            }
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
        if package.parsed.fullPackageName.contains("_delta_") {
            return collectDeltaBackupTargets(package: package, extractedPackage: extractedPackage)
        }

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
            if self.isDeterminedSystemFolder(candidate.path) {
                return nil
            }
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

    private func collectDeltaBackupTargets(
        package: PackageToInstall,
        extractedPackage: ValidatedExtractPackage
    ) -> [URL] {
        guard let diffJsonURL = extractedPackage.extractionResult.diffJSONURLs.first,
              let data = try? Data(contentsOf: diffJsonURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        propertyTable.setInstallDir(package.productInstallDir)
        propertyTable.setProductInstallDir(package.productInstallDir)
        propertyTable.setSourceFolder(extractedPackage.extractDir.path)
        propertyTable.setMediaFolder(extractedPackage.extractDir.path)

        let fileManager = FileManager.default
        var targets: [String] = []

        for entry in entries {
            let action = ((entry["deltaAction"] as? String) ?? (entry["action"] as? String) ?? "").uppercased()
            guard action == "PATCH" || action == "PATCH_FILE"
                    || action == "DELETE" || action == "DELETE_FILE" else {
                continue
            }

            let rawDestination = (entry["destination"] as? String) ?? (entry["target"] as? String) ?? ""
            guard !rawDestination.isEmpty else { continue }
            guard !isDeterminedSystemFolder(rawDestination) else { continue }

            let expanded = propertyTable.expandPath(rawDestination)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expanded.isEmpty, !expanded.contains("["),
                  !shouldSkipExpandedBackupPath(expanded),
                  fileManager.fileExists(atPath: expanded) else {
                continue
            }

            targets.append(normalizedBackupPath(expanded))
        }

        let uniqueTargets = Array(Set(targets)).filter { backedUpPaths.insert($0).inserted }
        return uniqueTargets.map { URL(fileURLWithPath: $0) }
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
            case .deleteFile(let target, _),
                    .registerApplication(let target),
                    .setDisplayAttributes(let target, _),
                    .touch(let target):
                return BackupTargetCandidate(path: target, isDirectoryLike: false)
            case .deleteDirectory(let target, _, _),
                    .permission(let target, _),
                    .owner(let target, _, _),
                    .folderIcon(let target, _):
                return BackupTargetCandidate(path: target, isDirectoryLike: true)
            case .unlockPath(let path, _):
                return BackupTargetCandidate(path: path, isDirectoryLike: false)
            case .localizeFile(_, let target), .macAlias(_, let target, _):
                return BackupTargetCandidate(path: target, isDirectoryLike: false)
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

    private func isDeterminedSystemFolder(_ rawPath: String) -> Bool {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        let determinedFolders: Set<String> = [
            "[adobecommon]", "[adobeprogramfiles]", "[programfiles]",
            "[sharedapplicationdata]", "[shareddocuments]", "[shareddesktop]",
            "[utilities]", "[fontsfolder]", "[library]", "[librarypreferences]",
            "[scriptingadditions]", "[system32folder]", "[startmenu]", "[startmenusubfolder]",
            "[userpreferences]", "[usercommon]", "[userhome]", "[userdocuments]",
            "[userdesktop]", "[userpictures]", "[usertemplates]", "[userfavorites]",
            "[userroamingappdata]", "[userlocalappdata]"
        ]
        return determinedFolders.contains(normalized)
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
        packages: [PackageToInstall],
        reusedDependencies: [String: HDPIMInstalledProductSnapshot]
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
                    let reused = reusedDependencies[dependency.sapCode]
                    let dependencyVersion = reused?.version ?? firstNonEmptyString([
                        matchedGroup?.applicationInfo.baseVersion,
                        matchedGroup?.version,
                        dependency.version
                    ]) ?? productInfo.codexVersion
                    let dependencyPlatform = matchedGroup?.platform ?? dependency.platform

                    return HDPIMNativeProductReferenceRecord(
                        dependencySapCode: dependency.sapCode,
                        dependencyVersion: dependencyVersion,
                        dependencyProcessorFamily: reused?.processorFamily ?? HDPIMProcessorFamily.from(platform: dependencyPlatform),
                        referencingSapCode: productInfo.sapCode,
                        referencingVersion: productInfo.codexVersion,
                        referencingProcessorFamily: HDPIMProcessorFamily.from(platform: productInfo.platform),
                        type: ""
                    )
                }
            } else {
                dependencies = []
            }

            let installLanguageValue = makeInstallLanguage(
                from: group.applicationInfo,
                requestedLanguage: installLanguage
            )
            let uninstallDisplayName = group.applicationInfo.localizedUninstallDisplayName(
                installLanguage: installLanguageValue
            ) ?? productName

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
                installLanguage: installLanguageValue,
                productName: productName,
                uninstallDisplayName: uninstallDisplayName,
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
    var dependencyBaseVersions: [String: String] = [:]
    var reuseOnlyDependencies: Set<String> = []
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
