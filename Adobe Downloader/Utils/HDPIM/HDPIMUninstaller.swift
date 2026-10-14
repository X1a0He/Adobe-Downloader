import Foundation
import CryptoKit
import Darwin

struct HDPIMInstalledProductForUninstall: Identifiable, Equatable {
	let sapCode: String
	let version: String
	let processorFamily: HDPIMProcessorFamily
	let installDir: String
	let modules: [String]
	let packages: [HDPIMNativePackageContext]

	var id: String {
		"\(sapCode)|\(version)|\(processorFamily.rawValue)"
	}

	var displayPlatform: String {
		switch processorFamily {
		case .arm64Bit:
			return "MACARM64"
		case .bit32:
			return "OSX"
		case .bit64:
			return "OSX10"
		}
	}

	static func == (lhs: HDPIMInstalledProductForUninstall, rhs: HDPIMInstalledProductForUninstall) -> Bool {
		lhs.id == rhs.id &&
		lhs.installDir == rhs.installDir &&
		lhs.modules == rhs.modules &&
		lhs.packages.map(packageIdentity) == rhs.packages.map(packageIdentity)
	}

	private static func packageIdentity(_ package: HDPIMNativePackageContext) -> String {
		"\(package.packageName)|\(package.packageVersion)|\(package.module ?? "")"
	}
}

struct HDPIMPackageUninstallKey: Hashable, Identifiable {
	let packageName: String
	let packageVersion: String

	var id: String {
		"\(packageName)|\(packageVersion)"
	}
}

enum HDPIMUninstallTarget: Hashable {
	case product
	case modules(Set<String>)
	case packages(Set<HDPIMPackageUninstallKey>)

	var isModuleUninstall: Bool {
		if case .modules = self {
			return true
		}
		return false
	}
}

private final class HDPIMUninstallProgressReporter {
	private static let chunkSize: Int64 = 2 * 1024 * 1024
	private let progressHandler: ((Double, String) -> Void)?
	private let packageWorkSizes: [String: Int64]
	private let totalWorkSize: Int64
	private var completedWorkSize: Int64 = 0
	private var currentPackageWorkSize: Int64 = 0
	private var currentPackageId: String?
	private var lastProgress = 0.0
	private var lastUpdateTime = -Double.infinity
	private var packageStartTime = 0.0
	private var completedCommands = 0

	init(packages: [HDPIMNativePackageContext], progressHandler: ((Double, String) -> Void)?) {
		self.progressHandler = progressHandler
		var sizes: [String: Int64] = [:]
		for package in packages {
			sizes[Self.packageId(package)] = Self.workSize(for: package)
		}
		packageWorkSizes = sizes
		totalWorkSize = sizes.values.reduce(0, +)
	}

	func reportPreparation(_ status: String) {
		emit(0.04, status, force: true)
	}

	func reportPackageSelection(packageCount: Int) {
		let status: String
		if packageCount > 0 {
			status = String(format: String(localized: "正在准备 %d 个 HDPIM 卸载包"), packageCount)
		} else {
			status = String(localized: "未找到需要删除的包，正在更新 HDPIM 模块状态")
		}
		emit(0.055, status, force: true)
	}

	func beginPackage(_ package: HDPIMNativePackageContext, index: Int, total: Int) {
		currentPackageId = Self.packageId(package)
		currentPackageWorkSize = 0
		packageStartTime = ProcessInfo.processInfo.systemUptime
		completedCommands = 0
		emitPackageProgress(status: String(format: String(localized: "正在卸载 %@ (%d/%d)"), package.packageName, index, total), force: true)
	}

	func packageWorkSize(for package: HDPIMNativePackageContext) -> Int64 {
		packageWorkSizes[Self.packageId(package)] ?? Self.workSize(for: package)
	}

	func reportPackageProgress(_ package: HDPIMNativePackageContext, completedCommands: Int, totalCommands: Int) {
		let size = packageWorkSize(for: package)
		guard size > 0 else {
			return
		}
		currentPackageId = Self.packageId(package)
		self.completedCommands = completedCommands
		let processedBytes = Int64(Double(size) * Double(completedCommands) / Double(max(totalCommands, 1)))
		currentPackageWorkSize = min(max(processedBytes, currentPackageWorkSize), size)
		emitPackageProgress(status: String(format: String(localized: "正在卸载 %@... %d/%d 步"),
                                              package.packageName, completedCommands, totalCommands))
	}

	func completePackage(_ package: HDPIMNativePackageContext) {
		let size = packageWorkSize(for: package)
		completedWorkSize += size
		currentPackageId = nil
		currentPackageWorkSize = 0
		let elapsed = ProcessInfo.processInfo.systemUptime - packageStartTime
		emitPackageProgress(status: String(format: String(localized: "已完成 %@ 卸载（%d 步，耗时 %.1f 秒）"),
                                              package.packageName, completedCommands, elapsed), force: true)
	}

	func reportCompletion(_ status: String) {
		emit(totalWorkSize > 0 ? 0.95 : 0.85, status, force: true)
	}

	func reportFinished() {
		emit(1.0, String(localized: "卸载完成"), force: true)
	}

	private func emitPackageProgress(status: String, force: Bool = false) {
		guard totalWorkSize > 0 else {
			emit(0.6, status, force: force)
			return
		}
		let packageFraction = min(max(Double(completedWorkSize + currentPackageWorkSize) / Double(totalWorkSize), 0), 1)
		emit(0.08 + packageFraction * 0.84, status, force: force)
	}

	private func emit(_ progress: Double, _ status: String, force: Bool = false) {
		guard let progressHandler else {
			return
		}
		let clampedProgress = min(max(progress, lastProgress), 1.0)
		let now = ProcessInfo.processInfo.systemUptime
		let elapsed = now - lastUpdateTime
		let progressedEnough = clampedProgress - lastProgress >= 0.005
		guard force || (elapsed >= 0.25 && (progressedEnough || elapsed >= 1)) else {
			return
		}
		lastProgress = clampedProgress
		lastUpdateTime = now
		progressHandler(clampedProgress, status)
	}

	private static func workSize(for package: HDPIMNativePackageContext) -> Int64 {
		let value = Int64(package.installSize.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
		return value > 0 ? value : chunkSize
	}

	private static func packageId(_ package: HDPIMNativePackageContext) -> String {
		[
			package.sapCode,
			package.productVersion,
			package.platform,
			package.packageName,
			package.packageVersion
		].joined(separator: "|")
	}
}

struct HDPIMUninstallResult: Codable {
    enum Outcome: String, Codable { case completed, warnings, cancelled, failed, partial }
    let outcome: Outcome
    let warnings: [String]
    let details: String?
    let recoveryDirectory: String?
    var diagnostics: [String]? = nil
}

struct HDPIMUninstallFailure: Error, LocalizedError {
    let result: HDPIMUninstallResult
    var errorDescription: String? { result.details }
}

private struct HDPIMPreparedUninstallPackage {
    let package: HDPIMNativePackageContext
    let descriptors: [PIMXCommandDescriptor]
    let commands: [HDPIMCommand]
    let repair: [HDPIMCommand]
}

private struct HDPIMPreparedUninstallProduct {
    let product: HDPIMUninstallProductState
    let target: HDPIMUninstallTarget
    let packages: [HDPIMPreparedUninstallPackage]
}

final class HDPIMUninstaller {
    static func installedProducts(sapCode: String? = nil, version: String? = nil) -> [HDPIMInstalledProductForUninstall] {
        do {
            let database = try HDPIMDatabase.shared.makeReadOnlyConnection()
            defer { database.close() }
            return try database.loadUninstallState().products.values
                .filter { (sapCode == nil || $0.identity.sapCode == sapCode) && (version == nil || $0.identity.version == version) }
                .map { product in
                    HDPIMInstalledProductForUninstall(sapCode: product.identity.sapCode, version: product.identity.version,
                        processorFamily: product.identity.processorFamily,
                        installDir: product.metadata[HDPIMProductExtraMetaKey.installDir] ?? "",
                        modules: product.modules.sorted(), packages: product.packages)
                }.sorted { $0.sapCode == $1.sapCode ? AppStatics.compareVersions($0.version, $1.version) > 0 : $0.sapCode < $1.sapCode }
        } catch {
            print("[HDPIM] 读取卸载状态失败：\(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    static func uninstall(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily,
                          preservingUserPreferences: Bool = true,
                          progressHandler: ((Double, String) -> Void)? = nil) async throws -> HDPIMUninstallResult {
        try await perform(sapCode: sapCode, version: version, processorFamily: processorFamily, target: .product,
                          preservingUserPreferences: preservingUserPreferences, progressHandler: progressHandler)
    }

    @discardableResult
    static func uninstallModules(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily,
                                 moduleIds: Set<String>, preservingUserPreferences: Bool = true,
                                 progressHandler: ((Double, String) -> Void)? = nil) async throws -> HDPIMUninstallResult {
        try await perform(sapCode: sapCode, version: version, processorFamily: processorFamily, target: .modules(moduleIds),
                          preservingUserPreferences: preservingUserPreferences, progressHandler: progressHandler)
    }

    @discardableResult
    static func uninstallPackages(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily,
                                  packageKeys: Set<HDPIMPackageUninstallKey>, preservingUserPreferences: Bool = true,
                                  progressHandler: ((Double, String) -> Void)? = nil) async throws -> HDPIMUninstallResult {
        try await perform(sapCode: sapCode, version: version, processorFamily: processorFamily, target: .packages(packageKeys),
                          preservingUserPreferences: preservingUserPreferences, progressHandler: progressHandler)
    }

    private static func perform(sapCode: String, version: String, processorFamily: HDPIMProcessorFamily,
                                target: HDPIMUninstallTarget, preservingUserPreferences: Bool,
                                progressHandler: ((Double, String) -> Void)?) async throws -> HDPIMUninstallResult {
        let database = HDPIMDatabase.shared
        let shouldClose = !database.isOpen
        if shouldClose { try database.open() }
        defer { if shouldClose { database.close() } }
        try database.beginUninstallTransaction()
        var transactionOpen = true
        let backup = HDPIMBackupManager()
        var wroteFiles = false
        var attemptedHooks: [HDPIMPreparedUninstallPackage] = []
        var plans: [HDPIMPreparedUninstallProduct] = []
        var warnings: [String] = []
        var diagnostics: [String] = []
        var retainedARPTargets: Set<URL> = []
        var pcd: HDPIMPCDCompletion?
        do {
            try HDPIMOperationContext.checkCancellation()
            let preparationStart = ProcessInfo.processInfo.systemUptime
            progressHandler?(0.02, "正在读取卸载状态")
            let state = try database.loadUninstallState()
            let stateElapsed = ProcessInfo.processInfo.systemUptime - preparationStart
            progressHandler?(0.022, String(format: "卸载状态读取完成（%.2f 秒），正在校验产品依赖", stateElapsed))
            let root = try state.resolve(sapCode: sapCode, version: version, processorFamily: processorFamily)
            let products: [HDPIMUninstallProductState]
            if case .product = target {
                products = try productPlan(root: root, state: state, warnings: &warnings)
            } else { products = [root] }
            let dependencyElapsed = ProcessInfo.processInfo.systemUptime - preparationStart - stateElapsed
            progressHandler?(0.025, String(format: "产品依赖校验完成（%.2f 秒），正在准备卸载材料", dependencyElapsed))
            for (productIndex, product) in products.enumerated() {
                try HDPIMOperationContext.checkCancellation()
                let productTarget: HDPIMUninstallTarget = product.identity == root.identity ? target : .product
                let productProgress = 0.025 + 0.025 * Double(productIndex) / Double(max(products.count, 1))
                progressHandler?(productProgress, "正在检查冲突进程：\(product.identity.sapCode)")
                try validateConflicts(product)
                let selected = try selectedPackages(product, target: productTarget)
                var prepared: [HDPIMPreparedUninstallPackage] = []
                prepared.reserveCapacity(selected.count)
                for (packageIndex, package) in selected.enumerated() {
                    try HDPIMOperationContext.checkCancellation()
                    let packageStart = ProcessInfo.processInfo.systemUptime
                    let fraction = Double(packageIndex) / Double(max(selected.count, 1))
                    let packageProgress = productProgress + 0.025 * fraction / Double(max(products.count, 1))
                    progressHandler?(packageProgress, "正在校验卸载材料：\(package.packageName)（\(packageIndex + 1)/\(selected.count)）")
                    prepared.append(try preparePackage(package, product: product, preservingUserPreferences: preservingUserPreferences))
                    let elapsed = ProcessInfo.processInfo.systemUptime - packageStart
                    progressHandler?(packageProgress, String(format: "已校验 %@（%.2f 秒）", package.packageName, elapsed))
                }
                plans.append(.init(product: product, target: productTarget, packages: prepared))
            }
            progressHandler?(0.05, "正在准备卸载登记")
            let removedIdentities = Set(plans.compactMap { plan -> HDPIMUninstallIdentity? in
                if case .product = plan.target { return plan.product.identity }
                return nil
            })
            retainedARPTargets = Set(state.products.values.filter { !removedIdentities.contains($0.identity) }
                .flatMap { arpTargets(for: $0) })
            let needsPCD = plans.contains {
                if case .product = $0.target {
                    return !($0.product.metadata[HDPIMProductExtraMetaKey.amtConfigAppID] ?? "").isEmpty
                        || !($0.product.metadata[HDPIMProductMetaKey.amtConfigLEID.rawValue] ?? "").isEmpty
                }
                return false
            }
            if needsPCD { pcd = try HDPIMPCDCompletion() }
            let packages = plans.flatMap(\.packages)
            let reporter = HDPIMUninstallProgressReporter(packages: packages.map(\.package), progressHandler: progressHandler)
            reporter.reportPackageSelection(packageCount: packages.count)
            progressHandler?(0.056, "正在检查卸载路径")
            let changes = try packages.flatMap { try HDPIMFileChange.from($0.descriptors) }
            let removalPolicy = HDPIMRemovalPolicy.PreflightChecker()
            for package in packages {
                for descriptor in package.descriptors {
                    switch descriptor {
                    case .deleteFile(let path, _), .deleteDirectory(let path, _, _): try validateRemovalPath(path, using: removalPolicy)
                    default: break
                    }
                }
            }
            let preparationElapsed = ProcessInfo.processInfo.systemUptime - preparationStart
            progressHandler?(0.06, String(format: "卸载预检完成（%.2f 秒），正在保存卸载恢复记录", preparationElapsed))
            try await backup.capture(changes)
            for (index, package) in packages.enumerated() {
                try HDPIMOperationContext.checkCancellation()
                reporter.beginPackage(package.package, index: index + 1, total: packages.count)
                var hookRecorded = false
                for (commandIndex, command) in package.commands.enumerated() {
                    try HDPIMOperationContext.checkCancellation()
                    if command is RunProgramCommand, !hookRecorded {
                        attemptedHooks.append(package)
                        hookRecorded = true
                    }
                    wroteFiles = true
                    try await command.execute()
                    try HDPIMOperationContext.checkCancellation()
                    reporter.reportPackageProgress(package.package,
                        completedCommands: commandIndex + 1, totalCommands: package.commands.count)
                }
                reporter.completePackage(package.package)
            }
            reporter.reportCompletion("正在提交卸载记录")
            for plan in plans {
                try HDPIMOperationContext.checkCancellation()
                let modules: Set<String>
                let entire: Bool
                switch plan.target {
                case .product: modules = []; entire = true
                case .modules(let values): modules = values; entire = false
                case .packages: modules = []; entire = false
                }
                try database.commitUninstallProduct(plan.product, removedPackages: plan.packages.map(\.package),
                                                     removingModules: modules, entireProduct: entire)
            }
            // 最后一次取消仍属于可恢复阶段；提交成功后的请求不得把成功改成取消。
            try HDPIMOperationContext.checkCancellation()
            try database.commitUninstallTransaction()
            transactionOpen = false
        } catch {
            let original = error
            var recoveryErrors: [String] = []
            await HDPIMOperationContext.$isRecovering.withValue(true) {
                if wroteFiles {
                    do { try await backup.restoreAll() }
                    catch { recoveryErrors.append("文件恢复失败：\(error.localizedDescription)") }
                }
                if transactionOpen {
                    do { try database.rollbackUninstallTransaction(); transactionOpen = false }
                    catch { recoveryErrors.append("数据库恢复失败：\(error.localizedDescription)") }
                }
                if recoveryErrors.isEmpty {
                    for package in attemptedHooks {
                        guard !package.repair.isEmpty else {
                            recoveryErrors.append("\(package.package.packageName) 已执行外部卸载程序，但没有可用的 repair 命令，不能确认其副作用已恢复")
                            continue
                        }
                        recoveryErrors += await HDPIMRollbackHelper.repairPreviousPackages([package.repair])
                    }
                }
            }
            let cancelled = original is CancellationError || HDPIMOperationContext.cancellation?.isCancelled == true
            let outcome: HDPIMUninstallResult.Outcome = recoveryErrors.isEmpty ? (cancelled ? .cancelled : .failed) : .partial
            let message = ([cancelled && recoveryErrors.isEmpty ? "卸载已取消，已恢复本次文件及数据库变更" : original.localizedDescription]
                           + recoveryErrors).joined(separator: "\n")
            throw HDPIMUninstallFailure(result: .init(outcome: outcome, warnings: warnings, details: message,
                                                       recoveryDirectory: backup.hasBackups ? backup.recoveryDirectory.path : nil))
        }
        // 外部登记不与 PIM 数据库共享事务，提交后逐项收尾并明确报告残留。
        await HDPIMOperationContext.$isRecovering.withValue(true) {
            for plan in plans {
                if case .product = plan.target {
                    completeProduct(plan.product, pcd: pcd, retainedARPTargets: retainedARPTargets,
                                    warnings: &warnings, diagnostics: &diagnostics)
                }
            }
            do {
                if !(try database.hasInstalledNonCCProducts()) {
                    for path in ["/Library/Application Support/Adobe/ADCRefs/AIM.adcref",
                                 "/Library/Application Support/Adobe/AdobeApplicationManager/AAMRefs/AIM.aamref"] {
                        try removeOwnedPath(path)
                    }
                }
            } catch { warnings.append("ADS 引用清理未完成：\(error.localizedDescription)") }
            let paths = Set(plans.flatMap(\.packages).flatMap { [$0.package.uninstallPIMXPath, $0.package.repairPIMXPath].compactMap { $0 } })
            for path in paths where !path.isEmpty {
                do { if !(try database.uninstallMaterialIsReferenced(path: path)) { try removeOwnedPath(path) } }
                catch { warnings.append("保留材料 \(path)：\(error.localizedDescription)") }
            }
            do { try await backup.cleanup() }
            catch { warnings.append("恢复记录清理未完成：\(backup.recoveryDirectory.path)，\(error.localizedDescription)") }
        }
        progressHandler?(1, warnings.isEmpty ? "卸载完成" : "卸载完成，部分收尾需要处理")
        var seenDiagnostics: Set<String> = []
        return .init(outcome: warnings.isEmpty ? .completed : .warnings, warnings: warnings, details: nil, recoveryDirectory: nil,
                     diagnostics: diagnostics.filter { seenDiagnostics.insert($0).inserted })
    }

    private static func productPlan(root: HDPIMUninstallProductState, state: HDPIMUninstallDatabaseState,
                                    warnings: inout [String]) throws -> [HDPIMUninstallProductState] {
        func referrers(_ product: HDPIMUninstallProductState) -> Set<HDPIMUninstallIdentity> {
            Set(state.references.filter {
                $0.dependencySapCode == product.identity.sapCode && $0.dependencyProcessorFamily == product.identity.processorFamily
                    && ($0.dependencyVersion == product.baseVersion || $0.dependencyVersion == product.identity.version)
            }.compactMap {
                let key = HDPIMUninstallIdentity(sapCode: $0.referencingSapCode, version: $0.referencingVersion,
                                                processorFamily: $0.referencingProcessorFamily)
                return state.products[key] == nil ? nil : key
            })
        }
        let blocking = referrers(root).subtracting([root.identity])
        guard blocking.isEmpty else {
            throw UninstallError.dependencyExists("产品仍被引用：" + blocking.map { "\($0.sapCode) \($0.version)" }.sorted().joined(separator: "、"))
        }
        var candidates = [root.identity: root]
        var order = [root.identity]
        var index = 0
        while index < order.count {
            let identity = order[index]; index += 1
            for reference in state.references where reference.referencingSapCode == identity.sapCode
                && reference.referencingVersion == identity.version && reference.referencingProcessorFamily == identity.processorFamily {
                let matching = state.products.values.filter {
                    $0.identity.sapCode == reference.dependencySapCode && $0.identity.processorFamily == reference.dependencyProcessorFamily
                        && ($0.baseVersion == reference.dependencyVersion || $0.identity.version == reference.dependencyVersion)
                }
                guard !matching.isEmpty else { continue }
                let dependency = try state.resolve(sapCode: reference.dependencySapCode, version: reference.dependencyVersion,
                                                    processorFamily: reference.dependencyProcessorFamily)
                if isTruthy(dependency.metadata[HDPIMProductExtraMetaKey.isSelfReference]) { continue }
                if candidates[dependency.identity] == nil { candidates[dependency.identity] = dependency; order.append(dependency.identity) }
            }
        }
        var changed = true
        while changed {
            changed = false
            for identity in order where identity != root.identity {
                guard let product = candidates[identity] else { continue }
                if !referrers(product).subtracting(Set(candidates.keys)).isEmpty {
                    candidates[identity] = nil; changed = true
                    warnings.append("保留仍被其他产品引用的依赖：\(identity.sapCode) \(identity.version)")
                }
            }
        }
        // 被保留父产品的后代也会由引用检查保留；只提交仍从根可达的候选。
        var reachable: Set<HDPIMUninstallIdentity> = [root.identity]
        var pending = [root.identity]
        while let identity = pending.popLast() {
            for reference in state.references where reference.referencingSapCode == identity.sapCode
                && reference.referencingVersion == identity.version && reference.referencingProcessorFamily == identity.processorFamily {
                for product in candidates.values where product.identity.sapCode == reference.dependencySapCode
                    && product.identity.processorFamily == reference.dependencyProcessorFamily
                    && (product.baseVersion == reference.dependencyVersion || product.identity.version == reference.dependencyVersion) {
                    if reachable.insert(product.identity).inserted { pending.append(product.identity) }
                }
            }
        }
        return order.filter { reachable.contains($0) }.compactMap { candidates[$0] }
    }

    private static func selectedPackages(_ product: HDPIMUninstallProductState, target: HDPIMUninstallTarget) throws -> [HDPIMNativePackageContext] {
        let selected: [HDPIMNativePackageContext]
        switch target {
        case .product: selected = product.packages
        case .modules(let modules):
            guard !modules.isEmpty, modules.isSubset(of: product.modules) else { throw UninstallError.moduleNotInstalled }
            let keeping = product.modules.subtracting(modules)
            selected = product.packages.filter {
                let associations = Set(splitMetaValues($0.module ?? "")).intersection(product.modules)
                return !associations.isDisjoint(with: modules) && associations.isDisjoint(with: keeping)
            }
        case .packages(let keys):
            selected = product.packages.filter { keys.contains(.init(packageName: $0.packageName, packageVersion: $0.packageVersion)) }
            guard !keys.isEmpty, selected.count == keys.count else { throw UninstallError.noPackagesSelected }
        }
        return selected.sorted { $0.sequenceNumber == $1.sequenceNumber ? $0.packageName < $1.packageName : $0.sequenceNumber > $1.sequenceNumber }
    }

    private static func preparePackage(_ package: HDPIMNativePackageContext, product: HDPIMUninstallProductState,
                                       preservingUserPreferences: Bool) throws -> HDPIMPreparedUninstallPackage {
        guard let path = package.uninstallPIMXPath, !path.isEmpty else { throw UninstallError.missingUninstallPIMX(package.packageName) }
        let url = URL(fileURLWithPath: path)
        let xml = try verifiedXML(url, sha1: package.uninstallPIMXHash, sha256: package.uninstallPIMXHash256)
        let context = propertyTable(product, package: package, preservingUserPreferences: preservingUserPreferences)
        let parser = PIMXParser(propertyTable: context)
        let descriptors = try parser.parseUninstallCommands(pimxURL: url, xmlData: xml, preservingUserPreferences: preservingUserPreferences)
        let engine = HDPIMCommandEngine(propertyTable: context)
        var repair: [HDPIMCommand] = []
        if let path = package.repairPIMXPath, !path.isEmpty {
            let repairURL = URL(fileURLWithPath: path)
            let data = try verifiedXML(repairURL, sha1: package.repairPIMXHash, sha256: package.repairPIMXHash256)
            // 旧 repair 材料重放安装 Hook，与旧包恢复使用相同的工作流。
            let repairContext = context.cloned(); repairContext.setProperty("workflowType", "install")
            let repairDescriptors = try PIMXParser(propertyTable: repairContext).parseRepairCommands(pimxURL: repairURL, xmlData: data)
                .filter { if case .runProgram = $0 { return true }; return false }
            try HDPIMRepairResources.validateStoredCommands(repairDescriptors)
            repair = HDPIMCommandEngine(propertyTable: repairContext).generateCommands(from: repairDescriptors)
        }
        try HDPIMRepairResources.validateStoredCommands(descriptors)
        return .init(package: package, descriptors: descriptors, commands: engine.generateCommands(from: descriptors), repair: repair)
    }

    static func verifiedXML(_ url: URL, sha1: String?, sha256: String?) throws -> Data {
        try HDPIMMaterialIntegrity.verifiedXML(url, sha1: sha1, sha256: sha256)
    }

    private static func propertyTable(_ product: HDPIMUninstallProductState, package: HDPIMNativePackageContext,
                                      preservingUserPreferences: Bool) -> HDPIMPropertyTable {
        let table = HDPIMPropertyTable()
        table.setupSystemDirectories()
        for (key, value) in product.metadata { table.setProperty(key, value) }
        table.setInstallDir(package.installDir); table.setProductInstallDir(package.installDir); table.setTargetDir(package.installDir)
        for (key, value) in ["workflowType": "uninstall", "DeleteUserPreferences": preservingUserPreferences ? "false" : "true",
                            "sapCode": package.sapCode, "SAPCode": package.sapCode, "CodexVersion": package.productVersion,
                            "ProductVersion": package.productVersion, "BaseVersion": product.baseVersion, "Platform": product.platform,
                            "ProcessorFamily": package.processorFamily.rawValue, "SetPermission": "true", "PackageName": package.packageName,
                            "PackageVersion": package.packageVersion, "PackageProcessorFamily": package.packageProcessorFamily,
                            "PackageType": package.packageType, "Type": package.packageType, "ExtractSize": package.installSize,
                            "Module": package.module ?? "", "RIBSCoexistenceCode": package.ribsCoexistenceCode ?? ""] { table.setProperty(key, value) }
        let language = product.metadata[HDPIMProductMetaKey.installLang.rawValue] ?? StorageData.shared.defaultLanguage
        table.setProperty("installLanguage", language)
        table.setProperty("uiDisplayLanguage", language.split(separator: ",").first.map(String.init) ?? language)
        return table
    }

    private static func validateConflicts(_ product: HDPIMUninstallProductState) throws {
        let xml = product.metadata[HDPIMProductMetaKey.conflictingProcessesXML.rawValue] ?? ""
        if !xml.isEmpty { _ = try XMLDocument(xmlString: xml, options: []) }
        var conflicts = parseConflictingProcessesXML(xml)
        if conflicts.isEmpty {
            conflicts = splitMetaValues(product.metadata[HDPIMProductMetaKey.conflictingProcesses.rawValue] ?? "").map {
                var value = ConflictingProcessInfo(); value.regularExpression = $0; value.processDisplayName = $0; return value
            }
        }
        let running = HDPIMConflictingProcessDetector.detectConflictingProcesses(conflictingProcesses: conflicts)
        guard running.isEmpty else { throw UninstallError.conflictingProcesses(running.map { $0.processInfo.processDisplayName }) }
    }

    private static func completeProduct(_ product: HDPIMUninstallProductState, pcd: HDPIMPCDCompletion?,
                                        retainedARPTargets: Set<URL>, warnings: inout [String], diagnostics: inout [String]) {
        let meta = product.metadata
        let appID = meta[HDPIMProductExtraMetaKey.amtConfigAppID] ?? ""
        let leid = meta[HDPIMProductMetaKey.amtConfigLEID.rawValue] ?? ""
        do {
            if !appID.isEmpty || !leid.isEmpty { try pcd?.removeProduct(appID: appID, leid: leid) }
            if !appID.isEmpty && !leid.isEmpty {
                guard HDPIMPackageMaterial.isLeafName(appID), HDPIMPackageMaterial.isLeafName(leid) else {
                    throw HDPIMMaterialError.invalid("产品 PCF 身份无效")
                }
                let path = "/Library/Application Support/Adobe/PCF/\(appID).\(leid).xml"
                try removeOwnedPath(path)
                try removeEmptyDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            }
        } catch { warnings.append("保留产品配置，AMT/PCD 收尾未完成：\(error.localizedDescription)") }
        do { try removeARP(product, retainedARPTargets: retainedARPTargets, warnings: &warnings, diagnostics: &diagnostics) }
        catch { warnings.append("卸载入口收尾未完成：\(error.localizedDescription)") }
        do {
            let installDir = meta[HDPIMProductExtraMetaKey.installDir] ?? ""
            if !installDir.isEmpty {
                var existing = URL(fileURLWithPath: installDir)
                while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
                let values = try existing.resourceValues(forKeys: [.volumeURLKey])
                if let volume = values.volume { try removeEmptyDirectory(volume.appendingPathComponent(".adobeTemp").path) }
            }
        } catch { warnings.append("保留临时目录：\(error.localizedDescription)") }
    }

    private static func arpTargets(for product: HDPIMUninstallProductState) -> Set<URL> {
        let root = URL(fileURLWithPath: "/Library/Application Support/Adobe/Uninstall")
        return Set([product.platform, "osx"].map { platform in
            let guid = HDPIMARPNaming.appGuid(sapCode: product.identity.sapCode, version: product.identity.version, platform: platform)
            return root.appendingPathComponent(guid + ".app").standardizedFileURL
        })
    }

    private static func removeARP(_ product: HDPIMUninstallProductState, retainedARPTargets: Set<URL>,
                                  warnings: inout [String], diagnostics: inout [String]) throws {
        let root = URL(fileURLWithPath: "/Library/Application Support/Adobe/Uninstall")
        let guid = HDPIMARPNaming.appGuid(sapCode: product.identity.sapCode, version: product.identity.version, platform: product.platform)
        let legacy = HDPIMARPNaming.appGuid(sapCode: product.identity.sapCode, version: product.identity.version, platform: "osx")
        var directories = ["/Applications/Utilities/Adobe Installers"]
        let installDir = product.metadata[HDPIMProductExtraMetaKey.installDir] ?? ""
        var candidate = installDir
        if let launch = product.metadata[HDPIMProductMetaKey.appLaunch.rawValue], !launch.isEmpty {
            let table = HDPIMPropertyTable(); table.setupSystemDirectories(); table.setInstallDir(installDir); table.setProductInstallDir(installDir)
            var url = URL(fileURLWithPath: try table.expandPathForInstallation(launch))
            for _ in 0..<4 { url.deleteLastPathComponent() }
            if url.path != "/" { candidate = url.path }
        }
        if !candidate.isEmpty, !HDPIMRemovalPolicy.isProtected(candidate) { directories.append(candidate) }
        else { candidate = "" }
        for name in Set([guid, legacy]) {
            let app = root.appendingPathComponent(name + ".app")
            let arguments = root.appendingPathComponent(name + ".adbarg")
            guard FileManager.default.fileExists(atPath: app.path) || FileManager.default.fileExists(atPath: arguments.path) else { continue }
            let lines = try String(contentsOf: arguments, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            guard lines.contains("--sapCode=\(product.identity.sapCode)"), lines.contains("--productVersion=\(product.identity.version)"),
                  lines.contains(where: { $0.hasPrefix("--productPlatform=") && HDPIMProcessorFamily.from(platform: String($0.dropFirst(18))) == product.identity.processorFamily }) else {
                throw HDPIMMaterialError.invalid("卸载入口身份不匹配，已保留：\(arguments.path)")
            }
            for directory in directories where FileManager.default.fileExists(atPath: directory) {
                do {
                    try removeAliases(to: app, in: URL(fileURLWithPath: directory), retainedARPTargets: retainedARPTargets,
                                      warnings: &warnings, diagnostics: &diagnostics)
                }
                catch { warnings.append("别名目录读取未完成，已保留未知条目：\(directory)，\(error.localizedDescription)") }
            }
            try removeOwnedPath(app.path); try removeOwnedPath(arguments.path)
        }
        if !candidate.isEmpty {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: candidate)
            if let entries, entries.count <= 3, Set(entries).isSubset(of: [".DS_Store", "Thumbs.db", "desktop.ini"]) {
                for entry in entries { try removeOwnedPath(URL(fileURLWithPath: candidate).appendingPathComponent(entry).path) }
            }
            try removeEmptyDirectory(candidate)
        }
        try removeEmptyDirectory(root.path)
    }

    private static func removeAliases(to target: URL, in directory: URL, retainedARPTargets: Set<URL>,
                                      warnings: inout [String], diagnostics: inout [String]) throws {
        let targetPath = target.standardizedFileURL.path
        let retainedPaths = Set(retainedARPTargets.map { $0.standardizedFileURL.path })
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isAliasFileKey])
        for item in items {
            do {
                guard try item.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true else { continue }
                let resolved: URL
                do {
                    resolved = try URL(resolvingAliasFileAt: item, options: [.withoutUI, .withoutMounting])
                } catch {
                    // 解析失败时只用书签的历史路径分类，不能据此删除别名或其目标。
                    let bookmark = try? URL.bookmarkData(withContentsOf: item)
                    let lastPath = bookmark.flatMap { URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path }
                    if let lastPath, lastPath.hasPrefix("/"),
                       retainedPaths.contains(URL(fileURLWithPath: lastPath).standardizedFileURL.path),
                       URL(fileURLWithPath: lastPath).standardizedFileURL.path != targetPath {
                        diagnostics.append("其他已登记产品的卸载别名目标无法解析，已保留：\(item.path) → \(lastPath)，\(error.localizedDescription)")
                    } else {
                        warnings.append("卸载别名目标无法解析，已保留：\(item.path)，\(error.localizedDescription)")
                    }
                    continue
                }
                if resolved.standardizedFileURL.path == targetPath { try removeOwnedPath(item.path) }
            } catch {
                warnings.append("卸载别名文件读取或清理未完成，已保留：\(item.path)，\(error.localizedDescription)")
            }
        }
    }

    private static func validateRemovalPath(_ path: String, using policy: HDPIMRemovalPolicy.PreflightChecker? = nil) throws {
        try HDPIMFileChange.validate(path)
        let isProtected = policy?.isProtected(path) ?? HDPIMRemovalPolicy.isProtected(path)
        guard !isProtected else {
            throw HDPIMMaterialError.invalid("禁止删除共享根目录：\(path)")
        }
    }

    private static func removeOwnedPath(_ path: String) throws {
        try validateRemovalPath(path)
        var info = stat()
        if lstat(path, &info) == 0 { try FileManager.default.removeItem(atPath: path) }
        else if errno != ENOENT && errno != ENOTDIR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func removeEmptyDirectory(_ path: String) throws {
        try validateRemovalPath(path)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else { return }
        if rmdir(path) != 0, errno != ENOENT && errno != ENOTEMPTY { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func splitMetaValues(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private static func isTruthy(_ value: String?) -> Bool { ["true", "1", "yes"].contains(value?.lowercased() ?? "") }
	private static func parseConflictingProcessesXML(_ xml: String) -> [ConflictingProcessInfo] {
		let trimmedXML = xml.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedXML.isEmpty,
		      let data = trimmedXML.data(using: .utf8),
		      let document = try? XMLDocument(data: data, options: []),
		      let nodes = try? document.nodes(forXPath: "//ConflictingProcess") else {
			return []
		}

		return nodes.compactMap { node -> ConflictingProcessInfo? in
			guard let element = node as? XMLElement else {
				return nil
			}

			var process = ConflictingProcessInfo()
			process.regularExpression = childText("RegularExpression", in: element)
			process.processDisplayName = childText("ProcessDisplayName", in: element)
			process.relativePath = childText("RelativePath", in: element)
			process.parentRegularExpression = childText("ParentRegularExpression", in: element)
			process.parentDisplayName = childText("ParentDisplayName", in: element)
			process.headless = element.attribute(forName: "headless")?.stringValue ?? ""
			process.forceKillAllowed = element.attribute(forName: "forceKillAllowed")?.stringValue ?? ""
			process.adobeOwned = element.attribute(forName: "adobeOwned")?.stringValue ?? ""

			return process.regularExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : process
		}
	}

	private static func childText(_ name: String, in element: XMLElement) -> String {
		let nodes = (try? element.nodes(forXPath: name)) ?? []
		return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
	}

}

enum UninstallError: Error, LocalizedError {
	case dependencyExists(String)
	case uwpReferenceExists(String)
	case noPackagesSelected
	case moduleNotInstalled
	case missingUninstallPIMX(String)
	case conflictingProcesses([String])

	var errorDescription: String? {
		switch self {
		case .dependencyExists(let reason):
			return reason.isEmpty ? String(localized: "该产品仍被其他产品引用，不能卸载") : reason
		case .uwpReferenceExists(let reason):
			return reason.isEmpty ? String(localized: "该 UWP 产品仍被其他产品引用，不能卸载") : reason
		case .noPackagesSelected:
			return String(localized: "没有找到可卸载的包")
		case .moduleNotInstalled:
			return String(localized: "所选模块未安装或已被移除")
		case .missingUninstallPIMX(let value):
			return String(format: String(localized: "找不到卸载 PIMX: %@"), value)
		case .conflictingProcesses(let processes):
			return String(format: String(localized: "检测到冲突进程，请先退出: %@"), processes.joined(separator: ", "))
		}
	}
}
