import Foundation

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

private struct HDPIMUninstallCompletionSnapshot {
	let sapCode: String
	let version: String
	let processorFamily: HDPIMProcessorFamily
	let installDir: String
	let appLaunchPath: String
	let modulesToRemove: Set<String>
	let buildGuid: String
	let amtConfigAppID: String
	let amtConfigLEID: String
	let uninstallPIMXPaths: Set<String>
	let repairPIMXPaths: Set<String>

	var appGuid: String {
		HDPIMARPNaming.appGuid(sapCode: sapCode, version: version)
	}

	var uninstallAppPath: String {
		"/Library/Application Support/Adobe/Uninstall/\(appGuid).app"
	}

	var uninstallAdbargPath: String {
		"/Library/Application Support/Adobe/Uninstall/\(appGuid).adbarg"
	}

	var amtConfigPath: String? {
		let appID = amtConfigAppID.trimmingCharacters(in: .whitespacesAndNewlines)
		let leid = amtConfigLEID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !appID.isEmpty, !leid.isEmpty else {
			return nil
		}
		return "/Library/Application Support/Adobe/PCF/\(appID).\(leid).xml"
	}
}

private struct HDPIMPackageUninstallPlan {
	let package: HDPIMNativePackageContext
	let pimxPlan: HDPIMRollbackHelper.UninstallPIMXPlan?
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
	private var lastStatus = ""

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
		emit(0.04, status)
	}

	func reportPackageSelection(packageCount: Int) {
		let status: String
		if packageCount > 0 {
			status = String(format: String(localized: "正在准备 %d 个 HDPIM 卸载包"), packageCount)
		} else {
			status = String(localized: "未找到需要删除的包，正在更新 HDPIM 模块状态")
		}
		emit(0.08, status)
	}

	func beginPackage(_ package: HDPIMNativePackageContext, index: Int, total: Int) {
		currentPackageId = Self.packageId(package)
		currentPackageWorkSize = 0
		emitPackageProgress(status: String(format: String(localized: "正在卸载 %@ (%d/%d)"), package.packageName, index, total))
	}

	func packageWorkSize(for package: HDPIMNativePackageContext) -> Int64 {
		packageWorkSizes[Self.packageId(package)] ?? Self.workSize(for: package)
	}

	func reportPackageProgress(_ package: HDPIMNativePackageContext, processedBytes: Int64, detail: String) {
		let size = packageWorkSize(for: package)
		guard size > 0 else {
			return
		}
		currentPackageId = Self.packageId(package)
		currentPackageWorkSize = min(max(processedBytes, currentPackageWorkSize), size)
		emitPackageProgress(status: String(format: String(localized: "正在卸载 %@: %@"), package.packageName, detail))
	}

	func completePackage(_ package: HDPIMNativePackageContext) {
		let size = packageWorkSize(for: package)
		completedWorkSize += size
		currentPackageId = nil
		currentPackageWorkSize = 0
		emitPackageProgress(status: String(format: String(localized: "已完成 %@ 卸载"), package.packageName))
	}

	func reportCompletion(_ status: String) {
		emit(totalWorkSize > 0 ? 0.95 : 0.85, status)
	}

	func reportFinished() {
		emit(1.0, String(localized: "卸载完成"), force: true)
	}

	private func emitPackageProgress(status: String) {
		guard totalWorkSize > 0 else {
			emit(0.6, status)
			return
		}
		let packageFraction = min(max(Double(completedWorkSize + currentPackageWorkSize) / Double(totalWorkSize), 0), 1)
		emit(0.08 + packageFraction * 0.84, status)
	}

	private func emit(_ progress: Double, _ status: String, force: Bool = false) {
		guard let progressHandler else {
			return
		}
		let clampedProgress = min(max(progress, lastProgress), 1.0)
		let statusChanged = status != lastStatus
		let progressedEnough = clampedProgress - lastProgress >= 0.005
		guard force || statusChanged || progressedEnough else {
			return
		}
		lastProgress = clampedProgress
		lastStatus = status
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

final class HDPIMUninstaller {

	static func installedProducts(
		sapCode: String? = nil,
		version: String? = nil
	) -> [HDPIMInstalledProductForUninstall] {
		let database = HDPIMDatabase.shared
		let shouldClose = !database.isOpen
		do {
			if shouldClose {
				try database.openReadOnly()
			}
			defer {
				if shouldClose {
					database.close()
				}
			}

			return database.getAllInstalledProducts()
				.filter { product in
					if let sapCode, product.sapCode != sapCode {
						return false
					}
					if let version, product.version != version {
						return false
					}
					return true
				}
				.map { product in
					let processorFamily = HDPIMProcessorFamily.from(platform: product.platform)
					let packages = database.getInstalledPackageContexts(
						sapCode: product.sapCode,
						version: product.version,
						processorFamily: processorFamily
					)
					let modules = installedModuleIds(
						database: database,
						sapCode: product.sapCode,
						version: product.version,
						processorFamily: processorFamily,
						packages: packages
					)
					return HDPIMInstalledProductForUninstall(
						sapCode: product.sapCode,
						version: product.version,
						processorFamily: processorFamily,
						installDir: database.getProductMeta(
							sapCode: product.sapCode,
							version: product.version,
							processorFamily: processorFamily,
							key: HDPIMProductExtraMetaKey.installDir
						) ?? "",
						modules: modules,
						packages: packages
					)
				}
				.sorted { lhs, rhs in
					if lhs.sapCode != rhs.sapCode {
						return lhs.sapCode < rhs.sapCode
					}
					return AppStatics.compareVersions(lhs.version, rhs.version) > 0
				}
		} catch {
			return []
		}
	}

	static func uninstall(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		progressHandler: ((Double, String) -> Void)? = nil
	) async throws {
		try await uninstall(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: .product,
			progressHandler: progressHandler
		)
	}

	static func uninstallModules(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		moduleIds: Set<String>,
		progressHandler: ((Double, String) -> Void)? = nil
	) async throws {
		try await uninstall(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: .modules(moduleIds),
			progressHandler: progressHandler
		)
	}

	static func uninstallPackages(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		packageKeys: Set<HDPIMPackageUninstallKey>,
		progressHandler: ((Double, String) -> Void)? = nil
	) async throws {
		try await uninstall(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: .packages(packageKeys),
			progressHandler: progressHandler
		)
	}

	private static func uninstall(
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		target: HDPIMUninstallTarget,
		progressHandler: ((Double, String) -> Void)? = nil
	) async throws {
		let database = HDPIMDatabase.shared
		let shouldClose = !database.isOpen
		if shouldClose {
			try database.open()
		}
		defer {
			if shouldClose {
				database.close()
			}
		}
		func reopenDatabaseIfNeeded() throws {
			if shouldClose && !database.isOpen {
				try database.open()
			}
		}

		progressHandler?(0.04, String(localized: "正在分析 HDPIM 卸载状态"))

		if case .product = target {
			let canUninstall = HDPIMDependencyManager.shared.canUninstall(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			)
			print("[HDPIM-DEP] 依赖检查 \(sapCode) \(version): canUninstall=\(canUninstall.canUninstall), reason=\(canUninstall.reason ?? "无")")

			guard canUninstall.canUninstall else {
				throw UninstallError.dependencyExists(canUninstall.reason ?? "")
			}

			validateDependentProductsForProductUninstall(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			)
		}

		let selectedPackages = try selectedPackages(
			database: database,
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: target
		)
		let validPackages = validInstalledPackages(
			selectedPackages
		)

		guard !validPackages.isEmpty || target.isModuleUninstall else {
			throw UninstallError.noPackagesSelected
		}

		let progressReporter = HDPIMUninstallProgressReporter(
			packages: validPackages,
			progressHandler: progressHandler
		)
		progressReporter.reportPackageSelection(packageCount: validPackages.count)

		if case .product = target {
			try validateUWPProductUninstall(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				packages: validPackages
			)
			try validateConflictingProcesses(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			)
		}

		let completionSnapshot = makeCompletionSnapshot(
			database: database,
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: target,
			packages: selectedPackages
		)
		let uninstallPlans = try validPackages.map { package in
			try makePackageUninstallPlan(package, database: database)
		}

		for (index, plan) in uninstallPlans.enumerated() {
			let package = plan.package
			progressReporter.beginPackage(package, index: index + 1, total: validPackages.count)
			try await uninstallPackage(plan, progressReporter: progressReporter)
			try database.removeInstalledPackages([package])
			progressReporter.completePackage(package)
		}

		progressReporter.reportCompletion(String(localized: "正在完成 HDPIM 卸载状态更新"))
		try await performCompletion(
			database: database,
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			target: target,
			snapshot: completionSnapshot
		)
		progressReporter.reportFinished()
	}

	private static func makeCompletionSnapshot(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		target: HDPIMUninstallTarget,
		packages: [HDPIMNativePackageContext]
	) -> HDPIMUninstallCompletionSnapshot {
		HDPIMUninstallCompletionSnapshot(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			installDir: database.getProductMeta(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.installDir
			) ?? "",
			appLaunchPath: database.getResolvedProductLaunchPath(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			),
			modulesToRemove: modulesToRemove(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				target: target,
				selectedPackages: packages
			),
			buildGuid: database.getProductMeta(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.buildGuid
			) ?? "",
			amtConfigAppID: database.getProductMeta(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.amtConfigAppID
			) ?? "",
			amtConfigLEID: database.getProductMeta(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				key: HDPIMProductMetaKey.amtConfigLEID.rawValue
			) ?? "",
			uninstallPIMXPaths: Set(packages.compactMap(\.uninstallPIMXPath).filter { !$0.isEmpty }),
			repairPIMXPaths: Set(packages.compactMap(\.repairPIMXPath).filter { !$0.isEmpty })
		)
	}

	private static func selectedPackages(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		target: HDPIMUninstallTarget
	) throws -> [HDPIMNativePackageContext] {
		switch target {
		case .product:
			return database.getInstalledPackageContexts(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			)

		case .modules(let moduleIds):
			let installedPackages = database.getInstalledPackageContexts(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily
			)
			let installedModules = Set(installedModuleIds(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				packages: installedPackages
			))
			let modulesToRemove = installedModules.intersection(moduleIds)
			guard !modulesToRemove.isEmpty else {
				throw UninstallError.moduleNotInstalled
			}
			let modulesToKeep = installedModules.subtracting(modulesToRemove)
			return installedPackages.filter { package in
				let packageModules = Set(splitMetaValues(package.module ?? ""))
				return !packageModules.isDisjoint(with: modulesToRemove)
					&& packageModules.isDisjoint(with: modulesToKeep)
			}

		case .packages(let packageKeys):
			let packageNames = Set(packageKeys.map(\.packageName))
			return database.getInstalledPackageContexts(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				packageNames: packageNames
			).filter { package in
				packageKeys.contains(HDPIMPackageUninstallKey(
					packageName: package.packageName,
					packageVersion: package.packageVersion
				))
			}
		}
	}

	private static func validInstalledPackages(
		_ packages: [HDPIMNativePackageContext]
	) -> [HDPIMNativePackageContext] {
		packages
	}

	private static func validateDependentProductsForProductUninstall(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
	) {
		let dependentReferences = HDPIMDependencyManager.shared.dependentReferences(
			forSapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)

		for reference in dependentReferences {
			if isTruthy(database.getProductMeta(
				sapCode: reference.dependencySapCode,
				version: reference.dependencyVersion,
				processorFamily: reference.dependencyProcessorFamily,
				key: HDPIMProductExtraMetaKey.isSelfReference
			)) {
				print("[HDPIM] Dependent product with sapCode \(reference.dependencySapCode) and version \(reference.dependencyVersion) is a self referenced product, it will not be uninstalled with this parent product, it should be uninstalled seperately.")
				continue
			}

			let canUninstall = HDPIMDependencyManager.shared.canUninstallDependentProduct(
				reference,
				excludingReferencingProduct: (
					sapCode: sapCode,
					version: version,
					processorFamily: processorFamily
				)
			)
			if !canUninstall.canUninstall {
				print("[HDPIM] Dependent product with sapCode \(reference.dependencySapCode) and version \(reference.dependencyVersion) will not be uninstalled as it is referred by \(canUninstall.referenceCount) products")
			}
		}
	}

	private static func modulesToRemove(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		target: HDPIMUninstallTarget,
		selectedPackages: [HDPIMNativePackageContext]
	) -> Set<String> {
		guard case .modules(let moduleIds) = target else {
			return []
		}

		let installedModules = Set(installedModuleIds(
			database: database,
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			packages: selectedPackages
		))
		return installedModules.intersection(moduleIds)
	}

	private static func validateUWPProductUninstall(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		packages: [HDPIMNativePackageContext]
	) throws {
		let isUWPProduct = isTruthy(
			database.getProductMeta(
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.isUWPProduct
			)
		) || packages.contains { package in
			!(package.uwpInfoXML ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		}

		guard isUWPProduct else {
			return
		}

		let canUninstall = HDPIMDependencyManager.shared.canUninstall(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)
		guard canUninstall.canUninstall else {
			throw UninstallError.uwpReferenceExists(canUninstall.reason ?? "")
		}
	}

	private static func validateConflictingProcesses(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
	) throws {
		let conflictingProcesses = productConflictingProcesses(
			database: database,
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)

		guard !conflictingProcesses.isEmpty else {
			return
		}

		let runningProcesses = HDPIMConflictingProcessDetector.detectConflictingProcesses(
			conflictingProcesses: conflictingProcesses
		)
		guard !runningProcesses.isEmpty else {
			return
		}

		let names = runningProcesses.map { process in
			firstNonEmptyString([
				process.processInfo.processDisplayName,
				process.executablePath,
				process.processInfo.regularExpression
			])
		}
		throw UninstallError.conflictingProcesses(Array(Set(names)).sorted())
	}

	private static func productConflictingProcesses(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily
	) -> [ConflictingProcessInfo] {
		let xml = database.getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductMetaKey.conflictingProcessesXML.rawValue
		) ?? ""
		let xmlProcesses = parseConflictingProcessesXML(xml)
		if !xmlProcesses.isEmpty {
			return xmlProcesses
		}

		let rawList = database.getProductMeta(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily,
			key: HDPIMProductMetaKey.conflictingProcesses.rawValue
		) ?? ""
		return rawList
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.map { value in
				var process = ConflictingProcessInfo()
				process.regularExpression = value
				process.processDisplayName = value
				return process
			}
	}

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

	private static func uninstallPackage(
		_ plan: HDPIMPackageUninstallPlan,
		progressReporter: HDPIMUninstallProgressReporter?
	) async throws {
		let package = plan.package
		guard let pimxPlan = plan.pimxPlan else {
			progressReporter?.reportPackageProgress(package, processedBytes: progressReporter?.packageWorkSize(for: package) ?? 0, detail: String(localized: "卸载 PIMX 已缺失，安装目标已不存在，跳过命令执行"))
			return
		}

		try await HDPIMRollbackHelper.executeUninstallPIMXPlan(
			pimxPlan,
			estimatedWorkSize: progressReporter?.packageWorkSize(for: package) ?? 0,
			progressHandler: { processedBytes, detail in
				progressReporter?.reportPackageProgress(
					package,
					processedBytes: processedBytes,
					detail: detail
				)
			}
		)
	}

	private static func makePackageUninstallPlan(
		_ package: HDPIMNativePackageContext,
		database: HDPIMDatabase
	) throws -> HDPIMPackageUninstallPlan {
		guard let pimxPath = package.uninstallPIMXPath,
		      !pimxPath.isEmpty else {
			throw UninstallError.missingUninstallPIMX(package.packageName)
		}

		let propertyTable = makePropertyTable(for: package, database: database)
		guard FileManager.default.fileExists(atPath: pimxPath) else {
			if installedTargetsAreGone(package: package, propertyTable: propertyTable) {
				return HDPIMPackageUninstallPlan(
					package: package,
					pimxPlan: nil
				)
			}
			throw UninstallError.missingUninstallPIMX(pimxPath)
		}

		let pimxPlan = try HDPIMRollbackHelper.makeUninstallPIMXPlan(
			at: URL(fileURLWithPath: pimxPath),
			propertyTable: propertyTable
		)
		return HDPIMPackageUninstallPlan(
			package: package,
			pimxPlan: pimxPlan
		)
	}

	private static func installedTargetsAreGone(
		package: HDPIMNativePackageContext,
		propertyTable: HDPIMPropertyTable
	) -> Bool {
		let targets = package.targetFolders
			.map { propertyTable.expandPath($0).trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty && !$0.contains("[") }
		guard !targets.isEmpty else {
			return false
		}
		return targets.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
	}

	private static func makePropertyTable(
		for package: HDPIMNativePackageContext,
		database: HDPIMDatabase
	) -> HDPIMPropertyTable {
		let propertyTable = HDPIMPropertyTable()
		propertyTable.setupSystemDirectories()
		propertyTable.setInstallDir(package.installDir)
		propertyTable.setProductInstallDir(package.installDir)
		propertyTable.setTargetDir(package.installDir)
		propertyTable.setProperty("ProductInstallDir", package.installDir)
		propertyTable.setProperty("TargetDir", package.installDir)
		propertyTable.setProperty("workflowType", "uninstall")
		propertyTable.setProperty("sapCode", package.sapCode)
		propertyTable.setProperty("SAPCode", package.sapCode)
		propertyTable.setProperty("CodexVersion", package.productVersion)
		propertyTable.setProperty("ProductVersion", package.productVersion)
		if let baseVersion = database.getProductMeta(
			sapCode: package.sapCode,
			version: package.productVersion,
			processorFamily: package.processorFamily,
			key: HDPIMProductMetaKey.baseVersion.rawValue
		), !baseVersion.isEmpty {
			propertyTable.setProperty("BaseVersion", baseVersion)
		}
		if let buildVersion = database.getProductMeta(
			sapCode: package.sapCode,
			version: package.productVersion,
			processorFamily: package.processorFamily,
			key: HDPIMProductMetaKey.buildVersion.rawValue
		), !buildVersion.isEmpty {
			propertyTable.setProperty("BuildVersion", buildVersion)
		}
		if let buildGuid = database.getProductMeta(
			sapCode: package.sapCode,
			version: package.productVersion,
			processorFamily: package.processorFamily,
			key: HDPIMProductExtraMetaKey.buildGuid
		), !buildGuid.isEmpty {
			propertyTable.setProperty("BuildGuid", buildGuid)
		}
		propertyTable.setProperty("Platform", platform(for: package.processorFamily))
		propertyTable.setProperty("ProcessorFamily", package.processorFamily.rawValue)
		propertyTable.setProperty("SetPermission", "true")
		propertyTable.setProperty("PackageName", package.packageName)
		propertyTable.setProperty("PackageVersion", package.packageVersion)
		propertyTable.setProperty("PackageProcessorFamily", package.packageProcessorFamily)
		propertyTable.setProperty("PackageType", package.packageType)
		propertyTable.setProperty("Type", package.packageType)
		propertyTable.setProperty("ExtractSize", package.installSize)
		if let ribsCode = package.ribsCoexistenceCode, !ribsCode.isEmpty {
			propertyTable.setProperty("RIBSCoexistenceCode", ribsCode)
		}
		let installLanguage = firstNonEmptyString([
			database.getProductMeta(
				sapCode: package.sapCode,
				version: package.productVersion,
				processorFamily: package.processorFamily,
				key: HDPIMProductMetaKey.installLang.rawValue
			),
			StorageData.shared.defaultLanguage
		])
		propertyTable.setProperty("InstallLang", installLanguage)
		propertyTable.setProperty("installLanguage", installLanguage)
		propertyTable.setProperty("uiDisplayLanguage", firstInstallLanguageToken(installLanguage))
		if let module = package.module, !module.isEmpty {
			propertyTable.setProperty("Module", module)
		}
		return propertyTable
	}

	private static func performCompletion(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		target: HDPIMUninstallTarget,
		snapshot: HDPIMUninstallCompletionSnapshot
	) async throws {
		await cleanupSelectedPIMXFiles(
			database: database,
			uninstallPIMXPaths: snapshot.uninstallPIMXPaths,
			repairPIMXPaths: snapshot.repairPIMXPaths
		)

		switch target {
		case .product:
			try await removeProductIfNoPackagesRemain(
				database: database,
				sapCode: sapCode,
				version: version,
				processorFamily: processorFamily,
				snapshot: snapshot
			)

		case .modules(let moduleIds):
			let modulesToRemove = snapshot.modulesToRemove.intersection(moduleIds)
			if !modulesToRemove.isEmpty {
				_ = try database.updateInstalledModules(
					sapCode: sapCode,
					version: version,
					processorFamily: processorFamily,
					removing: modulesToRemove
				)
			}

		case .packages:
			break
		}

		await removePathIfExists("/.adobeTemp")
	}

	private static func removeProductIfNoPackagesRemain(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		snapshot: HDPIMUninstallCompletionSnapshot
	) async throws {
		let remainingPackages = database.getInstalledPackageContexts(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)
		print("[HDPIM-COMPLETION] \(sapCode) \(version) 剩余包数量: \(remainingPackages.count)")
		guard remainingPackages.isEmpty else {
			print("[HDPIM-COMPLETION] \(sapCode) 还有 \(remainingPackages.count) 个包未删除，保留产品记录")
			return
		}

		print("[HDPIM-COMPLETION] \(sapCode) 所有包已删除，开始删除产品记录")
		try database.removeProductInstallationRecords(productKeys: [
			HDPIMNativeProductKey(
				sapCode: sapCode,
				version: version,
				platform: platform(for: processorFamily)
			)
		])
		await performProductSystemCompletion(
			database: database,
			snapshot: snapshot
		)
	}

	private static func performProductSystemCompletion(
		database: HDPIMDatabase,
		snapshot: HDPIMUninstallCompletionSnapshot
	) async {
		await removeAMTConfig(snapshot: snapshot)
		await removeARPEntry(snapshot: snapshot)
		await removeReferenceToADS(database: database)
		await cleanupOrphanedPIMXFiles(
			database: database,
			uninstallPIMXPaths: snapshot.uninstallPIMXPaths,
			repairPIMXPaths: snapshot.repairPIMXPaths
		)
	}

	private static func removeAMTConfig(snapshot: HDPIMUninstallCompletionSnapshot) async {
		if let amtConfigPath = snapshot.amtConfigPath {
			await removePathIfExists(amtConfigPath)
			await removeEmptyDirectoryIfExists(URL(fileURLWithPath: amtConfigPath).deletingLastPathComponent().path)
		}
	}

	private static func removeARPEntry(snapshot: HDPIMUninstallCompletionSnapshot) async {
		await removePathIfExists(snapshot.uninstallAppPath)
		await removePathIfExists(snapshot.uninstallAdbargPath)

		let installDir = snapshot.installDir.trimmingCharacters(in: .whitespacesAndNewlines)
		if shouldRemoveProductDirectory(installDir) {
			await removePathIfExists(installDir)
		}

		let appLaunchPath = snapshot.appLaunchPath.trimmingCharacters(in: .whitespacesAndNewlines)
		if !appLaunchPath.isEmpty {
			let appURL = URL(fileURLWithPath: appLaunchPath)
			let appBundleURL = nearestAppBundleURL(from: appURL) ?? appURL
			await removePathIfExists(appBundleURL.path)
		}

		await removeEmptyDirectoryIfExists("/Library/Application Support/Adobe/Uninstall")
	}

	private static func removeReferenceToADS(database: HDPIMDatabase) async {
		let hasNonCCProduct = database.getAllInstalledProducts().contains { product in
			let processorFamily = HDPIMProcessorFamily.from(platform: product.platform)
			return isTruthy(database.getProductMeta(
				sapCode: product.sapCode,
				version: product.version,
				processorFamily: processorFamily,
				key: HDPIMProductExtraMetaKey.isNonCCProduct
			))
		}

		guard !hasNonCCProduct else {
			return
		}

		await removePathIfExists("/Library/Application Support/Adobe/ADCRefs/AIM.adcref")
		await removePathIfExists("/Library/Application Support/Adobe/AdobeApplicationManager/AAMRefs/AIM.aamref")
	}

	private static func cleanupOrphanedPIMXFiles(
		database: HDPIMDatabase,
		uninstallPIMXPaths: Set<String>,
		repairPIMXPaths: Set<String>
	) async {
		await cleanupSelectedPIMXFiles(
			database: database,
			uninstallPIMXPaths: uninstallPIMXPaths,
			repairPIMXPaths: repairPIMXPaths
		)
		await cleanupOrphanedPIMXFiles(
			database: database,
			directory: "/Library/Application Support/Adobe/Installers/uninstallXml",
			metaKey: HDPIMPackageMetaKey.uninstallPIMX.rawValue
		)
		await cleanupOrphanedPIMXFiles(
			database: database,
			directory: "/Library/Application Support/Adobe/Installers/repairXml",
			metaKey: HDPIMPackageMetaKey.repairPIMX.rawValue
		)
	}

	private static func cleanupSelectedPIMXFiles(
		database: HDPIMDatabase,
		uninstallPIMXPaths: Set<String>,
		repairPIMXPaths: Set<String>
	) async {
		for path in uninstallPIMXPaths where !database.packageMetaValueExists(key: HDPIMPackageMetaKey.uninstallPIMX.rawValue, value: path) {
			await removePathIfExists(path)
		}
		for path in repairPIMXPaths where !database.packageMetaValueExists(key: HDPIMPackageMetaKey.repairPIMX.rawValue, value: path) {
			await removePathIfExists(path)
		}
	}

	private static func cleanupOrphanedPIMXFiles(
		database: HDPIMDatabase,
		directory: String,
		metaKey: String
	) async {
		guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
			return
		}

		let entries = enumerator
			.compactMap { $0 as? String }
			.filter { $0.lowercased().hasSuffix(".pimx") }
		for entry in entries {
			let path = URL(fileURLWithPath: directory).appendingPathComponent(entry).path
			if database.packageMetaValueExists(key: metaKey, value: path) {
				continue
			}
			await removePathIfExists(path)
		}
	}

	private static func nearestAppBundleURL(from url: URL) -> URL? {
		var current = url
		while current.path != "/" {
			if current.pathExtension == "app" {
				return current
			}
			current.deleteLastPathComponent()
		}
		return nil
	}

	private static func shouldRemoveProductDirectory(_ path: String) -> Bool {
		let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty else {
			return false
		}

		let blocked = [
			"/Applications",
			"/Library/Application Support/Adobe",
			"/Library/Application Support",
			"/Library",
			"/"
		]
		return !blocked.contains(normalized)
	}

	private static var usesLocalPrivilegedExecution: Bool {
		ProcessInfo.processInfo.environment[HDPIMHeadlessInstallRunner.localExecutionEnvironmentKey] == "1"
	}

	private static func removePathIfExists(_ path: String) async {
		let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedPath.isEmpty,
		      FileManager.default.fileExists(atPath: normalizedPath) else {
			return
		}

		do {
			if usesLocalPrivilegedExecution {
				try removeLocalPath(normalizedPath)
			} else {
				try await HelperManager.shared.uninstallPath(normalizedPath)
			}
		} catch {
			print("[HDPIM] 卸载完成清理失败: \(normalizedPath), error: \(error.localizedDescription)")
		}
	}

	private static func removeLocalPath(_ path: String) throws {
		guard !isProtectedRemovalRoot(path) else {
			throw NSError(
				domain: "HDPIMUninstaller",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "禁止删除共享根目录: %@"), path)]
			)
		}

		try FileManager.default.removeItem(atPath: path)
	}

	private static func isProtectedRemovalRoot(_ path: String) -> Bool {
		[
			"/Applications",
			"/Library/Application Support/Adobe",
			"/Library/Application Support",
			"/Library",
			"/tmp",
			"/"
		].contains(path)
	}

	private static func removeEmptyDirectoryIfExists(_ path: String) async {
		let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedPath.isEmpty,
		      FileManager.default.fileExists(atPath: normalizedPath) else {
			return
		}

		if let contents = try? FileManager.default.contentsOfDirectory(atPath: normalizedPath),
		   !contents.isEmpty {
			return
		}

		await removePathIfExists(normalizedPath)
	}

	private static func platform(for processorFamily: HDPIMProcessorFamily) -> String {
		switch processorFamily {
		case .arm64Bit:
			return "MACARM64"
		case .bit32:
			return "OSX"
		case .bit64:
			return "OSX10"
		}
	}

	private static func installedModuleIds(
		database: HDPIMDatabase,
		sapCode: String,
		version: String,
		processorFamily: HDPIMProcessorFamily,
		packages: [HDPIMNativePackageContext]
	) -> [String] {
		var modules = database.getInstalledModuleIds(
			sapCode: sapCode,
			version: version,
			processorFamily: processorFamily
		)

		for package in packages {
			for module in splitMetaValues(package.module ?? "") where !modules.contains(module) {
				modules.append(module)
			}
		}

		return modules.sorted()
	}

	private static func splitMetaValues(_ value: String) -> [String] {
		value
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}

	private static func firstNonEmptyString(_ values: [String?]) -> String {
		for value in values {
			let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			if !trimmedValue.isEmpty {
				return trimmedValue
			}
		}
		return ""
	}

	private static func firstInstallLanguageToken(_ value: String) -> String {
		value
			.split(separator: ",")
			.first
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? value
	}

	private static func isTruthy(_ value: String?) -> Bool {
		switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "1", "true", "yes":
			return true
		default:
			return false
		}
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
