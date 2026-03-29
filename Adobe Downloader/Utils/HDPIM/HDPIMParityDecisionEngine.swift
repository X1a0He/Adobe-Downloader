import Foundation
import JavaScriptCore
import AppKit
import Darwin
import OpenGL

enum HDPIMParityWorkflow {
    case download
    case install
}

enum HDPIMParityTargetArchitecture: String {
    case appleSilicon
    case intel

    static var currentSelection: HDPIMParityTargetArchitecture {
        StorageData.shared.downloadAppleSilicon ? .appleSilicon : .intel
    }

    var requestedPlatformIds: [String] {
        switch self {
        case .appleSilicon:
            return ["macuniversal", "macarm64"]
        case .intel:
            return ["macuniversal", "osx10", "osx10-64"]
        }
    }

    var platformPreference: [String] {
        requestedPlatformIds
    }

    var visiblePlatformIds: [String] {
        requestedPlatformIds
    }

    var catalogPlatformIds: [String] {
        switch self {
        case .appleSilicon:
            return ["macuniversal", "macarm64", "osx10-64", "osx10"]
        case .intel:
            return ["macuniversal", "osx10", "osx10-64"]
        }
    }

    var defaultRequestedPlatform: String {
        switch self {
        case .appleSilicon:
            return "macarm64"
        case .intel:
            return "osx10-64"
        }
    }

    var conditionArchitecture: String {
        switch self {
        case .appleSilicon:
            return "arm64"
        case .intel:
            return "x64"
        }
    }

    var conditionProcessorFamily: String {
        "64-bit"
    }
}

struct HDPIMResolvedPackageDecision {
    let parsedPackage: ParsedPackage
    let packageVersion: String
    let isRequired: Bool
    let isSelectedByDefault: Bool
    let isOfficiallyEligible: Bool
    let officialFilterReasons: [String]
    let moduleIds: [String]
    let installedPackageVersion: String?
    let skipReason: String?
    let hostValidation: HDPIMHostValidationSnapshot?
}

struct HDPIMResolvedDependencyDecision {
    let sapCode: String
    let version: String
    let baseVersion: String
    let buildGuid: String
    let buildVersion: String
    let platform: String
    let targetPlatform: String
    let isSoftDependency: Bool
    let isPlatformMatched: Bool
    let selectedReason: String
    let isProductAlreadySatisfied: Bool
    let skipReason: String?
    let hostValidation: HDPIMHostValidationSnapshot
    let applicationInfo: ApplicationInfo
    let packages: [HDPIMResolvedPackageDecision]
}

struct HDPIMResolvedProductDecision {
    let productId: String
    let displayName: String
    let version: String
    let baseVersion: String
    let buildGuid: String
    let buildVersion: String
    let platform: String
    let dependencies: [HDPIMResolvedDependencyDecision]

    var mainDependency: HDPIMResolvedDependencyDecision? {
        dependencies.first { $0.sapCode == productId }
    }
}

struct HDPIMInstalledProductSnapshot {
    let sapCode: String
    let version: String
    let processorFamily: HDPIMProcessorFamily
    let baseVersion: String
    let buildVersion: String
    let modules: Set<String>
}

private struct HDPIMResolvedPlatformMatch {
    let product: Product
    let platform: Product.Platform
    let languageSet: Product.Platform.LanguageSet
}

private struct HDPIMDependencySeed {
    let sapCode: String
    let version: String
    let baseVersion: String
    let buildGuid: String
    let platform: String
    let targetPlatform: String
    let isPlatformMatched: Bool
    let selectedReason: String
    let isSoftDependency: Bool
}

private struct HDPIMParityConditionContext {
    let installLanguage: String
    let osVersion: String
    let osArchitecture: String
    let osProcessorFamily: String
    let isEnterpriseDeployment: Bool
    let installDirectory: String
}

private struct HDPIMPlatformSelectionDiagnostics {
    let isMatch: Bool
    let reason: String
}

private struct HDPIMCompatibilityScriptEvaluation {
    let isCompatible: Bool
    let checkResult: String
    let failingDescription: String
    let messageString: String
    let isOverrideMessageEnabled: Bool
    let failureXML: String?
}

private enum HDPIMConditionEvaluationMode {
    case target(HDPIMParityTargetArchitecture)
    case host
}

private struct HDPIMDecisionCacheKey: Hashable {
    let productId: String
    let version: String
    let requestedLanguage: String
    let targetArchitecture: HDPIMParityTargetArchitecture
}

private actor HDPIMDecisionCacheStore {
    private var resolvedDecisions: [HDPIMDecisionCacheKey: HDPIMResolvedProductDecision] = [:]
    private var inflightTasks: [HDPIMDecisionCacheKey: Task<HDPIMResolvedProductDecision, Error>] = [:]

    func resolvedDecision(for key: HDPIMDecisionCacheKey) -> HDPIMResolvedProductDecision? {
        resolvedDecisions[key]
    }

    func inflightTask(for key: HDPIMDecisionCacheKey) -> Task<HDPIMResolvedProductDecision, Error>? {
        inflightTasks[key]
    }

    func setInflightTask(
        _ task: Task<HDPIMResolvedProductDecision, Error>,
        for key: HDPIMDecisionCacheKey
    ) {
        inflightTasks[key] = task
    }

    func storeResolvedDecision(
        _ decision: HDPIMResolvedProductDecision,
        for key: HDPIMDecisionCacheKey
    ) {
        resolvedDecisions[key] = decision
        inflightTasks.removeValue(forKey: key)
    }

    func removeInflightTask(for key: HDPIMDecisionCacheKey) {
        inflightTasks.removeValue(forKey: key)
    }

    func clear() {
        resolvedDecisions.removeAll()
        inflightTasks.removeAll()
    }
}

final class HDPIMParityDecisionEngine {

    static let shared = HDPIMParityDecisionEngine()
    private let decisionCacheStore = HDPIMDecisionCacheStore()

    private init() {}

    private func log(_ message: String) {
        print("[HDPIM Decision] \(message)")
    }

    func visiblePlatformText(
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
    ) -> String {
        targetArchitecture.visiblePlatformIds.joined(separator: ", ")
    }

    func preferredPlatform(
        for product: Product,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
    ) -> Product.Platform? {
        selectPreferredPlatform(
            for: product,
            targetArchitecture: targetArchitecture,
            allowFallback: false
        )?.platform
    }

    func preferredPlatformId(
        productId: String,
        version: String,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
    ) -> String? {
        guard let product = findProduct(id: productId, version: version) else {
            return nil
        }
        return preferredPlatform(for: product, targetArchitecture: targetArchitecture)?.id
    }

    func matchingPlatform(
        for product: Product,
        targetPlatform: String,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection,
        allowFallback: Bool = false
    ) -> Product.Platform? {
        selectPlatform(
            for: product,
            preferredPlatformIds: platformPreference(
                for: targetPlatform,
                targetArchitecture: targetArchitecture
            ),
            allowFallback: allowFallback
        )?.platform
    }

    func hasVisibleVersion(
        product: Product,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
    ) -> Bool {
        preferredPlatform(for: product, targetArchitecture: targetArchitecture) != nil
    }

    func visibleVersions(
        productId: String,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
    ) -> [(key: String, value: Product.Platform)] {
        let products = globalCcmResult.products.filter { $0.id == productId }
        guard !products.isEmpty else {
            return findProducts(id: productId)
                .compactMap { product in
                    guard let platform = preferredPlatform(for: product, targetArchitecture: targetArchitecture) else {
                        return nil
                    }
                    return (key: product.version, value: platform)
                }
                .sorted { pair1, pair2 in
                    AppStatics.compareVersions(pair1.key, pair2.key) > 0
                }
        }

        var versionPlatformMap: [String: Product.Platform] = [:]
        for product in products {
            guard let platform = preferredPlatform(for: product, targetArchitecture: targetArchitecture) else {
                continue
            }
            versionPlatformMap[product.version] = platform
        }

        return versionPlatformMap.map { (key: $0.key, value: $0.value) }
            .sorted { pair1, pair2 in
                AppStatics.compareVersions(pair1.key, pair2.key) > 0
            }
    }

    func makeDependencyPreview(from decision: HDPIMResolvedProductDecision) -> [Product.Platform.LanguageSet.Dependency] {
        decision.dependencies.compactMap { dependency in
            guard dependency.sapCode != decision.productId else {
                return nil
            }

            let selectedReason: String = {
                guard let skipReason = dependency.skipReason, !skipReason.isEmpty else {
                    return dependency.selectedReason
                }
                guard !dependency.selectedReason.isEmpty else {
                    return skipReason
                }
                return "\(dependency.selectedReason)；\(skipReason)"
            }()

            return Product.Platform.LanguageSet.Dependency(
                sapCode: dependency.sapCode,
                baseVersion: dependency.baseVersion,
                productVersion: dependency.version,
                buildGuid: dependency.buildGuid,
                isMatchPlatform: dependency.isPlatformMatched,
                targetPlatform: dependency.targetPlatform,
                selectedPlatform: dependency.platform,
                selectedReason: selectedReason,
                isSoftDependency: dependency.isSoftDependency,
                hostValidation: nil
            )
        }
    }

    func resolveDependencyPreview(
        rawDependency: Product.Platform.LanguageSet.Dependency,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection,
        softDependencySet: Set<String> = []
    ) -> Product.Platform.LanguageSet.Dependency {
        guard let seed = resolveDependencySeed(
            rawDependency: rawDependency,
            targetArchitecture: targetArchitecture,
            softDependencySet: softDependencySet
        ) else {
            return Product.Platform.LanguageSet.Dependency(
                sapCode: rawDependency.sapCode,
                baseVersion: rawDependency.baseVersion,
                productVersion: rawDependency.productVersion,
                buildGuid: rawDependency.buildGuid,
                isMatchPlatform: false,
                targetPlatform: firstNonEmptyString([
                    rawDependency.selectedPlatform,
                    targetArchitecture.defaultRequestedPlatform
                ]),
                selectedPlatform: "",
                selectedReason: "未找到可用依赖平台",
                isSoftDependency: softDependencySet.contains(rawDependency.sapCode),
                hostValidation: nil
            )
        }

        return Product.Platform.LanguageSet.Dependency(
            sapCode: seed.sapCode,
            baseVersion: seed.baseVersion,
            productVersion: seed.version,
            buildGuid: seed.buildGuid,
            isMatchPlatform: seed.isPlatformMatched,
            targetPlatform: seed.targetPlatform,
            selectedPlatform: seed.platform,
            selectedReason: seed.selectedReason,
            isSoftDependency: seed.isSoftDependency,
            hostValidation: nil
        )
    }

    func resolveTargetDownloadDecision(
        productId: String,
        version: String,
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> HDPIMResolvedProductDecision {
        guard let product = findProduct(id: productId, version: version) else {
            throw NetworkError.invalidData("找不到产品信息: \(productId) \(version)")
        }

        let installedProducts = makeInstalledProductSnapshots()
        let databaseAvailable = openDatabaseIfNeeded()
        defer {
            if databaseAvailable {
                HDPIMDatabase.shared.close()
            }
        }

        guard let mainMatch = selectPreferredPlatform(
            for: product,
            targetArchitecture: targetArchitecture,
            allowFallback: false
        ) else {
            throw NetworkError.unsupportedPlatform("产品 \(productId) 没有可用平台")
        }

        log(
            "主产品 \(productId) \(version) 命中平台 \(mainMatch.platform.id)，targetArchitecture=\(targetArchitecture.rawValue)，原始依赖数=\(mainMatch.languageSet.dependencies.count)，依赖=\(mainMatch.languageSet.dependencies.map(\.sapCode))"
        )

        progressHandler?("正在获取 \(productId) 的 Application.json...")
        let mainJsonString = try await globalNetworkService.getApplicationInfo(
            buildGuid: mainMatch.languageSet.buildGuid,
            sapCode: product.id,
            version: product.version,
            platform: mainMatch.platform.id
        )
        let mainAppInfo = try ApplicationJSONParser.parse(jsonString: mainJsonString)

        let softDependencySet = Set(mainAppInfo.softDependencies)
        var dependencySeeds: [HDPIMDependencySeed] = [
            HDPIMDependencySeed(
                sapCode: product.id,
                version: product.version,
                baseVersion: mainAppInfo.baseVersion,
                buildGuid: mainMatch.languageSet.buildGuid,
                platform: mainMatch.platform.id,
                targetPlatform: mainMatch.platform.id,
                isPlatformMatched: true,
                selectedReason: "成功匹配目标平台",
                isSoftDependency: false
            )
        ]

        for dependency in mainMatch.languageSet.dependencies {
            log(
                "开始解析依赖 \(dependency.sapCode)，baseVersion=\(dependency.baseVersion)，productVersion=\(dependency.productVersion)，selectedPlatform=\(dependency.selectedPlatform)"
            )
            guard let resolved = resolveDependencySeed(
                rawDependency: dependency,
                targetArchitecture: targetArchitecture,
                softDependencySet: softDependencySet
            ) else {
                log("依赖 \(dependency.sapCode) 解析失败：未找到可用依赖产品")
                continue
            }
            log(
                "依赖 \(dependency.sapCode) 解析成功：targetPlatform=\(resolved.targetPlatform)，selectedPlatform=\(resolved.platform)，reason=\(resolved.selectedReason)"
            )
            dependencySeeds.append(resolved)
        }

        var resolvedDependencies: [HDPIMResolvedDependencyDecision] = []
        for dependencySeed in dependencySeeds {
            progressHandler?("正在处理 \(dependencySeed.sapCode) 的决策信息...")

            let jsonString: String
            if dependencySeed.sapCode == product.id {
                jsonString = mainJsonString
            } else {
                jsonString = try await globalNetworkService.getApplicationInfo(
                    buildGuid: dependencySeed.buildGuid,
                    sapCode: dependencySeed.sapCode,
                    version: dependencySeed.version,
                    platform: dependencySeed.platform
                )
            }

            let applicationInfo = try ApplicationJSONParser.parse(jsonString: jsonString)
            log(
                "依赖 \(dependencySeed.sapCode) 获取 Application.json 完成：platform=\(dependencySeed.platform)，rawPackages=\(applicationInfo.packages.count)"
            )
            let resolvedVersion = firstNonEmptyString([
                applicationInfo.codexVersion,
                applicationInfo.productVersion,
                dependencySeed.version
            ])
            let resolvedBaseVersion = firstNonEmptyString([
                applicationInfo.baseVersion,
                dependencySeed.baseVersion,
                resolvedVersion
            ])
            let resolvedBuildVersion = firstNonEmptyString([
                applicationInfo.productVersion,
                applicationInfo.codexVersion,
                resolvedVersion
            ])
            let shouldSkipProduct = dependencySeed.sapCode != product.id && shouldSkipInstalledProduct(
                sapCode: dependencySeed.sapCode,
                targetVersion: resolvedVersion,
                targetPlatform: dependencySeed.platform,
                installedProducts: installedProducts
            )
            let skipReason = shouldSkipProduct ? "已安装同版本或更高版本依赖" : nil
            let packageDecisions = shouldSkipProduct ? [] : buildPackageDecisions(
                workflow: .download,
                sapCode: dependencySeed.sapCode,
                productVersion: resolvedVersion,
                platform: dependencySeed.platform,
                applicationInfo: applicationInfo,
                requestedLanguage: requestedLanguage,
                targetArchitecture: targetArchitecture,
                selectedModuleIds: Set(),
                expectedInstallDir: expandedInstallDirectory(for: applicationInfo),
                databaseAvailable: databaseAvailable
            )

            log(
                "依赖 \(dependencySeed.sapCode) 决策完成：resolvedVersion=\(resolvedVersion)，skip=\(shouldSkipProduct)，finalPackages=\(packageDecisions.count)"
            )

            resolvedDependencies.append(
                HDPIMResolvedDependencyDecision(
                    sapCode: dependencySeed.sapCode,
                    version: resolvedVersion,
                    baseVersion: resolvedBaseVersion,
                    buildGuid: dependencySeed.buildGuid,
                    buildVersion: resolvedBuildVersion,
                    platform: dependencySeed.platform,
                    targetPlatform: dependencySeed.targetPlatform,
                    isSoftDependency: dependencySeed.isSoftDependency,
                    isPlatformMatched: dependencySeed.isPlatformMatched,
                    selectedReason: dependencySeed.selectedReason,
                    isProductAlreadySatisfied: shouldSkipProduct,
                    skipReason: skipReason,
                    hostValidation: HDPIMHostValidationSnapshot(
                        isInstallable: true,
                        reason: skipReason ?? ""
                    ),
                    applicationInfo: applicationInfo,
                    packages: packageDecisions
                )
            )
        }

        let mainResolved = resolvedDependencies.first(where: { $0.sapCode == productId })
        guard let mainResolved else {
            throw NetworkError.invalidData("主产品决策结果为空: \(productId)")
        }

        return HDPIMResolvedProductDecision(
            productId: product.id,
            displayName: product.displayName,
            version: mainResolved.version,
            baseVersion: mainResolved.baseVersion,
            buildGuid: mainResolved.buildGuid,
            buildVersion: mainResolved.buildVersion,
            platform: mainResolved.platform,
            dependencies: resolvedDependencies
        )
    }

    func resolveDownloadDecision(
        productId: String,
        version: String,
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> HDPIMResolvedProductDecision {
        let cacheKey = HDPIMDecisionCacheKey(
            productId: productId,
            version: version,
            requestedLanguage: requestedLanguage,
            targetArchitecture: targetArchitecture
        )

        if let cachedDecision = await decisionCacheStore.resolvedDecision(for: cacheKey) {
            progressHandler?("正在复用已缓存的决策信息...")
            return cachedDecision
        }

        if let inflightTask = await decisionCacheStore.inflightTask(for: cacheKey) {
            progressHandler?("正在复用进行中的决策请求...")
            return try await inflightTask.value
        }

        let task = Task { [self] in
            try await resolveTargetDownloadDecision(
                productId: productId,
                version: version,
                requestedLanguage: requestedLanguage,
                targetArchitecture: targetArchitecture,
                progressHandler: progressHandler
            )
        }

        await decisionCacheStore.setInflightTask(task, for: cacheKey)

        do {
            let decision = try await task.value
            await decisionCacheStore.storeResolvedDecision(decision, for: cacheKey)
            return decision
        } catch {
            await decisionCacheStore.removeInflightTask(for: cacheKey)
            throw error
        }
    }

    func clearDownloadDecisionCache() async {
        await decisionCacheStore.clear()
    }

    func makeDownloadPresentation(from decision: HDPIMResolvedProductDecision) -> ([Package], [DependenciesToDownload]) {
        var allPackages: [Package] = []
        var dependencies: [DependenciesToDownload] = []

        for dependency in decision.dependencies {
            guard !dependency.packages.isEmpty else {
                continue
            }

            let dependencyModel = DependenciesToDownload(
                sapCode: dependency.sapCode,
                version: dependency.version,
                buildGuid: dependency.buildGuid,
                applicationJson: dependency.applicationInfo.rawJSON,
                isSoftDependency: dependency.isSoftDependency,
                platform: dependency.platform,
                baseVersion: dependency.baseVersion,
                buildVersion: dependency.buildVersion,
                selectedReason: dependency.selectedReason,
                hostValidation: nil
            )

            dependencyModel.packages = dependency.packages.compactMap { packageDecision in
                guard !packageDecision.parsedPackage.path.isEmpty,
                      !packageDecision.parsedPackage.fullPackageName.isEmpty else {
                    return nil
                }

                let package = Package(
                    type: packageDecision.parsedPackage.type,
                    fullPackageName: packageDecision.parsedPackage.fullPackageName,
                    downloadSize: packageDecision.parsedPackage.downloadSize,
                    downloadURL: packageDecision.parsedPackage.path,
                    packageVersion: packageDecision.packageVersion,
                    condition: packageDecision.parsedPackage.condition,
                    isRequired: packageDecision.isRequired,
                    isDefaultSelected: packageDecision.isSelectedByDefault,
                    isOfficiallyEligible: packageDecision.isOfficiallyEligible,
                    officialFilterReasons: packageDecision.officialFilterReasons,
                    validationURL: packageDecision.parsedPackage.validationURLType2
                )
                package.hostValidation = nil
                return package
            }

            if dependencyModel.packages.isEmpty {
                continue
            }

            allPackages.append(contentsOf: dependencyModel.packages)
            dependencies.append(dependencyModel)
        }

        return (allPackages, dependencies)
    }

    private func applyHostValidation(
        to decision: HDPIMResolvedProductDecision,
        requestedLanguage: String
    ) -> HDPIMResolvedProductDecision {
        let hostArchitecture = currentMachineTargetArchitecture()

        let dependencies = decision.dependencies.map { dependency -> HDPIMResolvedDependencyDecision in
            if dependency.isProductAlreadySatisfied {
                return HDPIMResolvedDependencyDecision(
                    sapCode: dependency.sapCode,
                    version: dependency.version,
                    baseVersion: dependency.baseVersion,
                    buildGuid: dependency.buildGuid,
                    buildVersion: dependency.buildVersion,
                    platform: dependency.platform,
                    targetPlatform: dependency.targetPlatform,
                    isSoftDependency: dependency.isSoftDependency,
                    isPlatformMatched: dependency.isPlatformMatched,
                    selectedReason: dependency.selectedReason,
                    isProductAlreadySatisfied: dependency.isProductAlreadySatisfied,
                    skipReason: dependency.skipReason,
                    hostValidation: HDPIMHostValidationSnapshot(
                        isInstallable: true,
                        reason: dependency.skipReason ?? "已满足本机依赖"
                    ),
                    applicationInfo: dependency.applicationInfo,
                    packages: dependency.packages
                )
            }

            let expectedInstallDir = expandedInstallDirectory(for: dependency.applicationInfo)
            let sanitizeValidation = sanitizeProductForInstall(
                sapCode: dependency.sapCode,
                codexVersion: dependency.version,
                platform: dependency.platform,
                baseVersion: dependency.baseVersion,
                parsedPackages: dependency.applicationInfo.packages,
                expectedInstallDir: expectedInstallDir
            )
            let systemValidation = sanitizeValidation.isInstallable
                ? makeHostSystemRequirementValidation(
                    applicationInfo: dependency.applicationInfo,
                    requestedLanguage: requestedLanguage,
                    expectedInstallDir: expectedInstallDir,
                    hostArchitecture: hostArchitecture
                )
                : sanitizeValidation

            let validatedPackages = dependency.packages.map { packageDecision in
                let hostValidation = makeHostPackageValidation(
                    packageDecision: packageDecision,
                    applicationInfo: dependency.applicationInfo,
                    requestedLanguage: requestedLanguage,
                    expectedInstallDir: expectedInstallDir,
                    hostArchitecture: hostArchitecture,
                    dependencyValidation: systemValidation
                )

                return HDPIMResolvedPackageDecision(
                    parsedPackage: packageDecision.parsedPackage,
                    packageVersion: packageDecision.packageVersion,
                    isRequired: packageDecision.isRequired,
                    isSelectedByDefault: packageDecision.isSelectedByDefault,
                    isOfficiallyEligible: packageDecision.isOfficiallyEligible,
                    officialFilterReasons: packageDecision.officialFilterReasons,
                    moduleIds: packageDecision.moduleIds,
                    installedPackageVersion: packageDecision.installedPackageVersion,
                    skipReason: packageDecision.skipReason,
                    hostValidation: hostValidation
                )
            }

            let dependencyValidation = mergeHostDependencyValidation(
                dependency: dependency,
                baseValidation: systemValidation,
                packages: validatedPackages
            )

            return HDPIMResolvedDependencyDecision(
                sapCode: dependency.sapCode,
                version: dependency.version,
                baseVersion: dependency.baseVersion,
                buildGuid: dependency.buildGuid,
                buildVersion: dependency.buildVersion,
                platform: dependency.platform,
                targetPlatform: dependency.targetPlatform,
                isSoftDependency: dependency.isSoftDependency,
                isPlatformMatched: dependency.isPlatformMatched,
                selectedReason: dependency.selectedReason,
                isProductAlreadySatisfied: dependency.isProductAlreadySatisfied,
                skipReason: dependency.skipReason,
                hostValidation: dependencyValidation,
                applicationInfo: dependency.applicationInfo,
                packages: validatedPackages
            )
        }

        return HDPIMResolvedProductDecision(
            productId: decision.productId,
            displayName: decision.displayName,
            version: decision.version,
            baseVersion: decision.baseVersion,
            buildGuid: decision.buildGuid,
            buildVersion: decision.buildVersion,
            platform: decision.platform,
            dependencies: dependencies
        )
    }

    private func makeHostPlatformValidation(platform: String) -> HDPIMHostValidationSnapshot {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Platform can't be empty"
            )
        }

        if !isCurrentOSCompatible(with: normalized) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Current OS(\(currentOSNameString())) Platform(\(platform)) do not match"
            )
        }

        switch normalized {
        case "macarm64", "winarm64":
            if currentMachineOSArchitectureString() != "arm64" {
                return HDPIMHostValidationSnapshot(
                    isInstallable: false,
                    reason: "Current Platform(\(platform)) and Architecture (x86) do not match"
                )
            }
        default:
            break
        }

        return HDPIMHostValidationSnapshot()
    }

    private func sanitizeProductForInstall(
        sapCode: String,
        codexVersion: String,
        platform: String,
        baseVersion: String,
        parsedPackages: [ParsedPackage],
        expectedInstallDir: String
    ) -> HDPIMHostValidationSnapshot {
        if sapCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || codexVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "SapCode or Version can't be empty"
            )
        }

        let platformValidation = makeHostPlatformValidation(platform: platform)
        if !platformValidation.isInstallable {
            return platformValidation
        }

        if parsedPackages.isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "There is no package to install"
            )
        }

        if expectedInstallDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Install directory can't be empty"
            )
        }

        if baseVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Base Version can't be empty"
            )
        }

        if let invalidPackage = parsedPackages.first(where: { !sanitizePackageForInstall($0) }) {
            let packageDescription = firstNonEmptyString([
                invalidPackage.fullPackageName,
                invalidPackage.packageName,
                invalidPackage.aliasPackageName
            ])
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Sanity check failed for package '\(packageDescription)'"
            )
        }

        return HDPIMHostValidationSnapshot()
    }

    private func sanitizePackageForInstall(_ package: ParsedPackage) -> Bool {
        let packageName = firstNonEmptyString([
            package.fullPackageName,
            package.packageName,
            package.aliasPackageName
        ])
        if packageName.isEmpty {
            return false
        }
        return !package.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isCurrentOSCompatible(with platform: String) -> Bool {
        if currentOSNameString().lowercased().contains("mac") {
            return platform.hasPrefix("mac") || platform.hasPrefix("osx")
        }
        return platform.hasPrefix("win")
    }

    private func makeTargetPlatformValidation(
        platform: String,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> HDPIMHostValidationSnapshot {
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Platform can't be empty"
            )
        }

        if !isCurrentOSCompatible(with: normalized) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Current OS(\(currentOSNameString())) Platform(\(platform)) do not match"
            )
        }

        let allowedPlatforms = Set(targetArchitecture.requestedPlatformIds)
        guard allowedPlatforms.contains(normalized) else {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "目标架构与平台 \(platform) 不匹配"
            )
        }

        return HDPIMHostValidationSnapshot()
    }

    private func sanitizeTargetProductForInstall(
        sapCode: String,
        codexVersion: String,
        platform: String,
        baseVersion: String,
        parsedPackages: [ParsedPackage],
        expectedInstallDir: String,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> HDPIMHostValidationSnapshot {
        if sapCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || codexVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "SapCode or Version can't be empty"
            )
        }

        let platformValidation = makeTargetPlatformValidation(
            platform: platform,
            targetArchitecture: targetArchitecture
        )
        if !platformValidation.isInstallable {
            return platformValidation
        }

        if parsedPackages.isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "There is no package to install"
            )
        }

        if expectedInstallDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Install directory can't be empty"
            )
        }

        if baseVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Base Version can't be empty"
            )
        }

        if let invalidPackage = parsedPackages.first(where: { !sanitizePackageForInstall($0) }) {
            let packageDescription = firstNonEmptyString([
                invalidPackage.fullPackageName,
                invalidPackage.packageName,
                invalidPackage.aliasPackageName
            ])
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Sanity check failed for package '\(packageDescription)'"
            )
        }

        return HDPIMHostValidationSnapshot()
    }

    private func makeHostSystemRequirementValidation(
        applicationInfo: ApplicationInfo,
        requestedLanguage: String,
        expectedInstallDir: String,
        hostArchitecture: HDPIMParityTargetArchitecture
    ) -> HDPIMHostValidationSnapshot {
        let propertyTable = makeScriptPropertyTable(
            installLanguage: requestedLanguage,
            installDirectory: expectedInstallDir
        )

        let isCompatible = evaluateSystemRequirements(
            applicationInfo: applicationInfo,
            propertyTable: propertyTable,
            targetArchitecture: hostArchitecture
        )
        guard !isCompatible else {
            return HDPIMHostValidationSnapshot()
        }

        let reason = firstNonEmptyString([
            propertyTable.getProperty("systemRequirement.messageString"),
            propertyTable.getProperty("systemRequirement.failingDescription"),
            "系统要求检查失败"
        ])

        return HDPIMHostValidationSnapshot(
            isInstallable: false,
            reason: reason,
            checkResult: propertyTable.getProperty("systemRequirement.checkResult") ?? "",
            failureXML: propertyTable.getProperty("systemRequirement.failureXML") ?? "",
            failingDescription: propertyTable.getProperty("systemRequirement.failingDescription") ?? "",
            messageString: propertyTable.getProperty("systemRequirement.messageString") ?? ""
        )
    }

    private func makeHostPackageValidation(
        packageDecision: HDPIMResolvedPackageDecision,
        applicationInfo: ApplicationInfo,
        requestedLanguage: String,
        expectedInstallDir: String,
        hostArchitecture: HDPIMParityTargetArchitecture,
        dependencyValidation: HDPIMHostValidationSnapshot
    ) -> HDPIMHostValidationSnapshot {
        guard dependencyValidation.isInstallable else {
            return dependencyValidation
        }

        let propertyTable = makeScriptPropertyTable(
            installLanguage: requestedLanguage,
            installDirectory: expectedInstallDir
        )
        let hostContext = makeConditionContext(
            requestedLanguage: requestedLanguage,
            targetArchitecture: hostArchitecture,
            installDirectory: expectedInstallDir,
            mode: .host
        )

        if !evaluatePackageCompatibility(
            package: packageDecision.parsedPackage,
            propertyTable: propertyTable,
            targetArchitecture: hostArchitecture
        ) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "checkPackageCompatibility 返回 fail"
            )
        }

        if !evaluateCondition(packageDecision.parsedPackage.condition, context: hostContext) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Condition 不满足当前机器"
            )
        }

        let _ = applicationInfo
        return HDPIMHostValidationSnapshot()
    }

    private func mergeHostDependencyValidation(
        dependency: HDPIMResolvedDependencyDecision,
        baseValidation: HDPIMHostValidationSnapshot,
        packages: [HDPIMResolvedPackageDecision]
    ) -> HDPIMHostValidationSnapshot {
        guard baseValidation.isInstallable else {
            return baseValidation
        }

        if let failedRequiredPackage = packages.first(where: {
            $0.isRequired && !($0.hostValidation?.isInstallable ?? true)
        })?.hostValidation {
            return failedRequiredPackage
        }

        if let failedSelectedPackage = packages.first(where: {
            $0.isSelectedByDefault && !($0.hostValidation?.isInstallable ?? true)
        })?.hostValidation {
            return failedSelectedPackage
        }

        if dependency.isProductAlreadySatisfied {
            return HDPIMHostValidationSnapshot(
                isInstallable: true,
                reason: dependency.skipReason ?? "已满足本机依赖"
            )
        }

        return HDPIMHostValidationSnapshot()
    }

    func filterInstallPackages(
        productInfo: ProductInfoFromDriver,
        requestInfo: [String: String],
        packages: [PackageToInstall],
        propertyTable: HDPIMPropertyTable,
        installedProducts: [HDPIMInstalledProductSnapshot],
        databaseAvailable: Bool
    ) -> [PackageToInstall] {
        let requestedLanguage = requestInfo["InstallLanguage"] ?? StorageData.shared.defaultLanguage
        let targetArchitecture = requestedTargetArchitecture(
            requestInfo: requestInfo,
            productInfo: productInfo,
            packages: packages
        )
        let selectedModuleIds = Set(productInfo.moduleIds)
        let _ = propertyTable
        let _ = databaseAvailable

        return packages.filter { package in
            if package.sapCode != productInfo.sapCode,
               shouldSkipInstalledProduct(
                    sapCode: package.sapCode,
                    targetVersion: package.version,
                    targetPlatform: package.platform,
                    installedProducts: installedProducts
               ) {
                return false
            }

            let shouldInclude = validatePackageForInstall(
                package: package,
                requestedLanguage: requestedLanguage,
                targetArchitecture: targetArchitecture,
                selectedModuleIds: package.sapCode == productInfo.sapCode ? selectedModuleIds : Set(),
                expectedInstallDir: package.productInstallDir
            ).isInstallable

            guard shouldInclude else {
                return false
            }

            return true
        }
    }

    func firstInstallValidationFailure(
        productInfo: ProductInfoFromDriver,
        requestInfo: [String: String],
        packages: [PackageToInstall],
        installedProducts: [HDPIMInstalledProductSnapshot]
    ) -> HDPIMHostValidationSnapshot? {
        let requestedLanguage = requestInfo["InstallLanguage"] ?? StorageData.shared.defaultLanguage
        let targetArchitecture = requestedTargetArchitecture(
            requestInfo: requestInfo,
            productInfo: productInfo,
            packages: packages
        )
        let selectedModuleIds = Set(productInfo.moduleIds)

        for package in packages {
            if package.sapCode != productInfo.sapCode,
               shouldSkipInstalledProduct(
                    sapCode: package.sapCode,
                    targetVersion: package.version,
                    targetPlatform: package.platform,
                    installedProducts: installedProducts
               ) {
                continue
            }

            let validation = validatePackageForInstall(
                package: package,
                requestedLanguage: requestedLanguage,
                targetArchitecture: targetArchitecture,
                selectedModuleIds: package.sapCode == productInfo.sapCode ? selectedModuleIds : Set(),
                expectedInstallDir: package.productInstallDir
            )
            if !validation.isInstallable {
                return validation
            }
        }

        return nil
    }

    func shouldIncludePackageForInstall(
        package: PackageToInstall,
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture,
        selectedModuleIds: Set<String>,
        expectedInstallDir: String
    ) -> Bool {
        validatePackageForInstall(
            package: package,
            requestedLanguage: requestedLanguage,
            targetArchitecture: targetArchitecture,
            selectedModuleIds: selectedModuleIds,
            expectedInstallDir: expectedInstallDir
        ).isInstallable
    }

    func validatePackageForInstall(
        package: PackageToInstall,
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture,
        selectedModuleIds: Set<String>,
        expectedInstallDir: String
    ) -> HDPIMHostValidationSnapshot {
        let productValidation = sanitizeTargetProductForInstall(
            sapCode: package.sapCode,
            codexVersion: package.version,
            platform: package.platform,
            baseVersion: package.applicationInfo.baseVersion,
            parsedPackages: package.applicationInfo.packages,
            expectedInstallDir: expectedInstallDir,
            targetArchitecture: targetArchitecture
        )
        if !productValidation.isInstallable {
            return productValidation
        }

        if !passesModuleConfiguration(
            package: package.parsed,
            applicationInfo: package.applicationInfo,
            selectedModuleIds: selectedModuleIds,
            workflow: .install
        ) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "模块配置不适用"
            )
        }

        let context = makeConditionContext(
            requestedLanguage: requestedLanguage,
            targetArchitecture: targetArchitecture,
            installDirectory: expectedInstallDir,
            mode: .target(targetArchitecture)
        )
        if !evaluateCondition(package.parsed.condition, context: context) {
            return HDPIMHostValidationSnapshot(
                isInstallable: false,
                reason: "Condition 不满足目标架构"
            )
        }

        return HDPIMHostValidationSnapshot()
    }

    private func resolveDependencySeed(
        rawDependency: Product.Platform.LanguageSet.Dependency,
        targetArchitecture: HDPIMParityTargetArchitecture,
        softDependencySet: Set<String>
    ) -> HDPIMDependencySeed? {
        let dependencyProduct = selectPreferredDependencyProduct(
            sapCode: rawDependency.sapCode,
            baseVersion: rawDependency.baseVersion,
            preferredPlatform: rawDependency.selectedPlatform,
            targetArchitecture: targetArchitecture
        )

        guard let dependencyProduct else {
            log(
                "依赖 \(rawDependency.sapCode) 未命中产品：baseVersion=\(rawDependency.baseVersion)，preferredPlatform=\(rawDependency.selectedPlatform)，targetArchitecture=\(targetArchitecture.rawValue)"
            )
            return nil
        }

        let targetPlatform = firstNonEmptyString([
            rawDependency.selectedPlatform,
            targetArchitecture.defaultRequestedPlatform
        ])
        let selectionDiagnostics = makePlatformSelectionDiagnostics(
            targetPlatform: targetPlatform,
            selectedPlatform: dependencyProduct.platform.id
        )

        return HDPIMDependencySeed(
            sapCode: rawDependency.sapCode,
            version: firstNonEmptyString([
                rawDependency.productVersion,
                dependencyProduct.languageSet.productVersion,
                dependencyProduct.product.version
            ]),
            baseVersion: firstNonEmptyString([
                rawDependency.baseVersion,
                dependencyProduct.languageSet.baseVersion,
                dependencyProduct.product.version
            ]),
            buildGuid: firstNonEmptyString([
                rawDependency.buildGuid,
                dependencyProduct.languageSet.buildGuid
            ]),
            platform: dependencyProduct.platform.id,
            targetPlatform: targetPlatform,
            isPlatformMatched: selectionDiagnostics.isMatch,
            selectedReason: selectionDiagnostics.reason,
            isSoftDependency: softDependencySet.contains(rawDependency.sapCode)
        )
    }

    private func selectPreferredDependencyProduct(
        sapCode: String,
        baseVersion: String,
        preferredPlatform: String,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> HDPIMResolvedPlatformMatch? {
        let matchingProducts = getAllProducts().filter { $0.id == sapCode }
        guard !matchingProducts.isEmpty else {
            log("依赖 \(sapCode) 在当前产品池中不存在")
            return nil
        }

        let exactBaseMatches = matchingProducts.filter { product in
            product.version == baseVersion || product.platforms.contains { platform in
                platform.languageSet.contains { $0.baseVersion == baseVersion }
            }
        }

        let candidates = (exactBaseMatches.isEmpty ? matchingProducts : exactBaseMatches)
            .sorted { AppStatics.compareVersions($0.version, $1.version) > 0 }

        for product in candidates {
            if !preferredPlatform.isEmpty,
               let preferred = selectPlatform(
                    for: product,
                    preferredPlatformIds: dependencyPlatformPreference(
                        for: preferredPlatform,
                        targetArchitecture: targetArchitecture
                    ),
                    allowFallback: true
               ) {
                log(
                    "依赖 \(sapCode) 命中首选平台：productVersion=\(product.version)，preferredPlatform=\(preferredPlatform)，selectedPlatform=\(preferred.platform.id)"
                )
                return preferred
            }

            if let selected = selectPlatform(
                for: product,
                preferredPlatformIds: dependencyPlatformPreference(
                    for: "",
                    targetArchitecture: targetArchitecture
                ),
                allowFallback: true
            ) {
                log(
                    "依赖 \(sapCode) 命中兜底平台：productVersion=\(product.version)，preferredPlatform=\(preferredPlatform)，selectedPlatform=\(selected.platform.id)"
                )
                return selected
            }
        }

        log(
            "依赖 \(sapCode) 所有候选产品均未命中：baseVersion=\(baseVersion)，preferredPlatform=\(preferredPlatform)，candidateCount=\(candidates.count)"
        )
        return nil
    }

    private func dependencyPlatformPreference(
        for targetPlatform: String,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> [String] {
        let normalized = targetPlatform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if targetArchitecture == .appleSilicon {
            switch normalized {
            case "macarm64":
                return ["macarm64", "macuniversal", "osx10-64", "osx10"]
            case "macuniversal":
                return ["macuniversal", "osx10-64", "osx10"]
            case "osx10-64":
                return ["osx10-64", "osx10"]
            case "osx10":
                return ["osx10"]
            case "":
                return ["macarm64", "macuniversal", "osx10-64", "osx10"]
            default:
                return ["macarm64", "macuniversal", "osx10-64", "osx10"]
            }
        }

        switch normalized {
        case "macarm64":
            return ["macuniversal", "osx10-64", "osx10"]
        case "macuniversal":
            return ["macuniversal", "osx10-64", "osx10"]
        case "osx10-64":
            return ["osx10-64", "osx10", "macuniversal"]
        case "osx10":
            return ["osx10", "osx10-64", "macuniversal"]
        case "":
            return ["osx10-64", "osx10", "macuniversal"]
        default:
            return ["osx10-64", "osx10", "macuniversal"]
        }
    }

    private func selectPreferredPlatform(
        for product: Product,
        targetArchitecture: HDPIMParityTargetArchitecture,
        allowFallback: Bool
    ) -> HDPIMResolvedPlatformMatch? {
        selectPlatform(
            for: product,
            preferredPlatformIds: targetArchitecture.platformPreference,
            allowFallback: allowFallback
        )
    }

    private func buildPackageDecisions(
        workflow: HDPIMParityWorkflow,
        sapCode: String,
        productVersion: String,
        platform: String,
        applicationInfo: ApplicationInfo,
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture,
        selectedModuleIds: Set<String>,
        expectedInstallDir: String,
        databaseAvailable: Bool
    ) -> [HDPIMResolvedPackageDecision] {
        let targetContext = makeConditionContext(
            requestedLanguage: requestedLanguage,
            targetArchitecture: targetArchitecture,
            installDirectory: expectedInstallDir,
            mode: .target(targetArchitecture)
        )
        let hostPropertyTable = makeScriptPropertyTable(
            installLanguage: requestedLanguage,
            installDirectory: expectedInstallDir
        )
        let hostContext = makeConditionContext(
            requestedLanguage: requestedLanguage,
            targetArchitecture: targetArchitecture,
            installDirectory: expectedInstallDir,
            mode: .host
        )

        if workflow == .install,
           !evaluateSystemRequirements(
                applicationInfo: applicationInfo,
                propertyTable: hostPropertyTable,
                targetArchitecture: currentMachineTargetArchitecture()
           ) {
            log("产品 \(sapCode) 安装前系统要求不满足，直接返回 0 个包")
            return []
        }

        log(
            "开始筛包：sapCode=\(sapCode)，workflow=\(workflow == .download ? "download" : "install")，platform=\(platform)，rawPackages=\(applicationInfo.packages.count)"
        )

        var resolvedPackages: [HDPIMResolvedPackageDecision] = []

        for parsedPackage in applicationInfo.packages {
            let packageIdentifier = firstNonEmptyString([
                parsedPackage.fullPackageName,
                parsedPackage.packageName,
                "<unknown>"
            ])

            guard !parsedPackage.path.isEmpty,
                  !parsedPackage.fullPackageName.isEmpty else {
                log(
                    "包 \(sapCode)/\(packageIdentifier) 被跳过：pathEmpty=\(parsedPackage.path.isEmpty)，fullPackageNameEmpty=\(parsedPackage.fullPackageName.isEmpty)"
                )
                continue
            }

            let packageVersion = firstNonEmptyString([
                parsedPackage.packageVersion,
                productVersion
            ])

            let moduleIds = applicationInfo.modules
                .filter { module in
                    module.referencePackages.contains(parsedPackage.packageName)
                        || module.referencePackages.contains(parsedPackage.fullPackageName)
                        || (!parsedPackage.aliasPackageName.isEmpty && module.referencePackages.contains(parsedPackage.aliasPackageName))
                }
                .map(\.id)
                .filter { !$0.isEmpty }

            let isCorePackage = parsedPackage.type.lowercased() == "core"
            let passesModuleSelection = passesModuleConfiguration(
                package: parsedPackage,
                applicationInfo: applicationInfo,
                selectedModuleIds: selectedModuleIds,
                workflow: workflow
            )

            if workflow == .download {
                var officialFilterReasons: [String] = []

                if !passesModuleSelection {
                    officialFilterReasons.append("模块配置不匹配")
                }

                if !evaluatePackageCompatibility(
                    package: parsedPackage,
                    propertyTable: hostPropertyTable,
                    targetArchitecture: targetArchitecture
                ) {
                    officialFilterReasons.append("兼容性校验失败")
                }

                if !evaluateCondition(parsedPackage.condition, context: targetContext) {
                    officialFilterReasons.append("Condition 不满足")
                }

                let isOfficiallyEligible = officialFilterReasons.isEmpty
                let isLanguageScopedPackage = parsedPackage.condition.localizedCaseInsensitiveContains("[installLanguage]")
                let isRuleRequiredPackage = parsedPackage.fullPackageName.localizedCaseInsensitiveContains("SuperCafModels")
                let isRequired = isOfficiallyEligible && (
                    isCorePackage
                    || isLanguageScopedPackage
                    || isRuleRequiredPackage
                )
                let skipReason = isOfficiallyEligible ? nil : officialFilterReasons.joined(separator: "；")

                if let skipReason {
                    log("包 \(sapCode)/\(packageIdentifier) 不符合官方默认选择：\(skipReason)")
                }

                resolvedPackages.append(
                    HDPIMResolvedPackageDecision(
                        parsedPackage: parsedPackage,
                        packageVersion: packageVersion,
                        isRequired: isRequired,
                        isSelectedByDefault: isOfficiallyEligible && !isRequired,
                        isOfficiallyEligible: isOfficiallyEligible,
                        officialFilterReasons: officialFilterReasons,
                        moduleIds: Array(Set(moduleIds)).sorted(),
                        installedPackageVersion: nil,
                        skipReason: skipReason,
                        hostValidation: nil
                    )
                )
                continue
            }

            if !passesModuleSelection {
                log("包 \(sapCode)/\(packageIdentifier) 被跳过：模块配置不匹配")
                continue
            }

            let isRequired = isCorePackage

            if workflow == .install,
               !evaluatePackageCompatibility(
                    package: parsedPackage,
                    propertyTable: hostPropertyTable,
                    targetArchitecture: currentMachineTargetArchitecture()
               ) {
                log("包 \(sapCode)/\(packageIdentifier) 被跳过：安装兼容性校验失败")
                continue
            }

            if workflow == .install,
               !evaluateCondition(parsedPackage.condition, context: hostContext) {
                log("包 \(sapCode)/\(packageIdentifier) 被跳过：安装 Condition 不满足，condition=\(parsedPackage.condition)")
                continue
            }

            let installedPackageVersion = workflow == .install && databaseAvailable ? installedPackageVersion(
                sapCode: sapCode,
                productVersion: productVersion,
                platform: platform,
                packageName: parsedPackage.packageName,
                packageVersion: packageVersion,
                expectedInstallDir: expectedInstallDir
            ) : nil

            if workflow == .install, installedPackageVersion != nil {
                log("包 \(sapCode)/\(packageIdentifier) 被跳过：已安装同版本 \(installedPackageVersion ?? "")")
                continue
            }

            resolvedPackages.append(
                HDPIMResolvedPackageDecision(
                    parsedPackage: parsedPackage,
                    packageVersion: packageVersion,
                    isRequired: isRequired,
                    isSelectedByDefault: true,
                    isOfficiallyEligible: true,
                    officialFilterReasons: [],
                    moduleIds: Array(Set(moduleIds)).sorted(),
                    installedPackageVersion: installedPackageVersion,
                    skipReason: nil,
                    hostValidation: nil
                )
            )
        }

        log("筛包完成：sapCode=\(sapCode)，finalPackages=\(resolvedPackages.count)")
        return resolvedPackages
    }

    private func passesModuleConfiguration(
        package: ParsedPackage,
        applicationInfo: ApplicationInfo,
        selectedModuleIds: Set<String>,
        workflow: HDPIMParityWorkflow
    ) -> Bool {
        if applicationInfo.modules.isEmpty || selectedModuleIds.isEmpty {
            return true
        }

        if package.type.lowercased() == "core" {
            return true
        }

        let selectedModules = applicationInfo.modules.filter { selectedModuleIds.contains($0.id) }
        guard !selectedModules.isEmpty else {
            return false
        }

        return selectedModules.contains { module in
            module.referencePackages.contains(package.packageName)
                || module.referencePackages.contains(package.fullPackageName)
                || (!package.aliasPackageName.isEmpty && module.referencePackages.contains(package.aliasPackageName))
        }
    }

    private func evaluateCondition(_ condition: String, context: HDPIMParityConditionContext) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let evaluator = HDPIMConditionEvaluator(
            condition: trimmed,
            variables: [
                "installLanguage": context.installLanguage,
                "OSVersion": context.osVersion,
                "OSArchitecture": context.osArchitecture,
                "OSProcessorFamily": context.osProcessorFamily,
                "IsEnterpriseDeployment": context.isEnterpriseDeployment ? "true" : "false"
            ]
        )

        return evaluator.evaluate()
    }

    private func evaluatePackageCompatibility(
        package: ParsedPackage,
        propertyTable: HDPIMPropertyTable,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> Bool {
        guard let script = package.systemRequirements["Content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            return true
        }

        guard let clientInfoJSONString = makePackageCompatibilityClientInfoJSONString(propertyTable: propertyTable),
              let hardwareSummaryJSONString = hardwareSummaryJSONString(
                propertyTable: propertyTable,
                targetArchitecture: targetArchitecture
              ) else {
            return true
        }

        return executeCompatibilityScript(
            script: script,
            functionName: "checkPackageCompatibility",
            clientInfoJSONString: clientInfoJSONString,
            hardwareSummaryJSONString: hardwareSummaryJSONString
        ).isCompatible
    }

    private func makeConditionContext(
        requestedLanguage: String,
        targetArchitecture: HDPIMParityTargetArchitecture,
        installDirectory: String,
        mode: HDPIMConditionEvaluationMode
    ) -> HDPIMParityConditionContext {
        let osArchitecture: String
        let osProcessorFamily: String
        switch mode {
        case .target(let architecture):
            osArchitecture = architecture.conditionArchitecture
            osProcessorFamily = architecture.conditionProcessorFamily
        case .host:
            let _ = targetArchitecture
            osArchitecture = currentMachineOSArchitectureString()
            osProcessorFamily = currentMachineOSProcessorFamilyString()
        }
        return HDPIMParityConditionContext(
            installLanguage: requestedLanguage,
            osVersion: currentOSVersionString(),
            osArchitecture: osArchitecture,
            osProcessorFamily: osProcessorFamily,
            isEnterpriseDeployment: false,
            installDirectory: installDirectory
        )
    }

    func makeInstalledProductSnapshots(databaseAlreadyOpen: Bool = false) -> [HDPIMInstalledProductSnapshot] {
        let shouldClose = databaseAlreadyOpen ? false : openDatabaseIfNeeded()
        guard databaseAlreadyOpen || shouldClose else {
            return []
        }
        defer {
            if shouldClose {
                HDPIMDatabase.shared.close()
            }
        }

        return HDPIMDatabase.shared.getAllInstalledProducts().map { raw in
            let processorFamily = processorFamily(fromRawValue: raw.platform)
            let modules = Set(
                (HDPIMDatabase.shared.getProductMeta(
                    sapCode: raw.sapCode,
                    version: raw.version,
                    processorFamily: processorFamily,
                    key: HDPIMProductExtraMetaKey.modules
                ) ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            )

            return HDPIMInstalledProductSnapshot(
                sapCode: raw.sapCode,
                version: raw.version,
                processorFamily: processorFamily,
                baseVersion: HDPIMDatabase.shared.getProductMeta(
                    sapCode: raw.sapCode,
                    version: raw.version,
                    processorFamily: processorFamily,
                    key: HDPIMProductMetaKey.baseVersion.rawValue
                ) ?? "",
                buildVersion: HDPIMDatabase.shared.getProductMeta(
                    sapCode: raw.sapCode,
                    version: raw.version,
                    processorFamily: processorFamily,
                    key: HDPIMProductMetaKey.buildVersion.rawValue
                ) ?? "",
                modules: modules
            )
        }
    }

    func requestedTargetArchitecture(
        requestInfo: [String: String],
        productInfo: ProductInfoFromDriver,
        packages: [PackageToInstall] = []
    ) -> HDPIMParityTargetArchitecture {
        if let rawValue = requestInfo["TargetArchitecture"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let architecture = HDPIMParityTargetArchitecture(rawValue: rawValue) {
            return architecture
        }

        let candidatePlatforms = [productInfo.platform]
            + productInfo.dependencies.map(\.platform)
            + packages.map(\.platform)

        if candidatePlatforms.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "macarm64"
        }) {
            return .appleSilicon
        }

        return .intel
    }

    private func shouldSkipInstalledProduct(
        sapCode: String,
        targetVersion: String,
        targetPlatform: String,
        installedProducts: [HDPIMInstalledProductSnapshot]
    ) -> Bool {
        let targetProcessorFamily = HDPIMProcessorFamily.from(platform: targetPlatform)
        let matchingProducts = installedProducts.filter {
            $0.sapCode == sapCode && $0.processorFamily == targetProcessorFamily
        }
        guard !matchingProducts.isEmpty else {
            return false
        }

        return matchingProducts.contains { installed in
            AppStatics.compareVersions(installed.version, targetVersion) >= 0
        }
    }

    private func installedPackageVersion(
        sapCode: String,
        productVersion: String,
        platform: String,
        packageName: String,
        packageVersion: String,
        expectedInstallDir: String
    ) -> String? {
        let processorFamily = HDPIMProcessorFamily.from(platform: platform)
        let isInstalled = (try? HDPIMDatabase.shared.hasValidInstalledPackage(
            sapCode: sapCode,
            productVersion: productVersion,
            processorFamily: processorFamily,
            packageName: packageName,
            packageVersion: packageVersion,
            expectedInstallDir: expectedInstallDir
        )) ?? false

        return isInstalled ? packageVersion : nil
    }

    private func makePlatformSelectionDiagnostics(
        targetPlatform: String,
        selectedPlatform: String
    ) -> HDPIMPlatformSelectionDiagnostics {
        guard !selectedPlatform.isEmpty else {
            return HDPIMPlatformSelectionDiagnostics(
                isMatch: false,
                reason: "未找到可用平台"
            )
        }

        if targetPlatform == selectedPlatform {
            return HDPIMPlatformSelectionDiagnostics(
                isMatch: true,
                reason: "成功匹配目标平台"
            )
        }

        if selectedPlatform == "macuniversal" {
            return HDPIMPlatformSelectionDiagnostics(
                isMatch: true,
                reason: "成功匹配通用平台 macuniversal（支持所有 Mac 平台）"
            )
        }

        if (targetPlatform == "osx10-64" && selectedPlatform == "osx10")
            || (targetPlatform == "osx10" && selectedPlatform == "osx10-64") {
            return HDPIMPlatformSelectionDiagnostics(
                isMatch: true,
                reason: "成功匹配兼容平台 \(selectedPlatform)"
            )
        }

        return HDPIMPlatformSelectionDiagnostics(
            isMatch: true,
            reason: "未命中目标平台，已命中可用平台: \(selectedPlatform)"
        )
    }

    private func selectPlatform(
        for product: Product,
        preferredPlatformIds: [String],
        allowFallback: Bool
    ) -> HDPIMResolvedPlatformMatch? {
        for platformId in preferredPlatformIds {
            if let platform = product.platforms.first(where: { $0.id == platformId }),
               let languageSet = platform.languageSet.first {
                return HDPIMResolvedPlatformMatch(product: product, platform: platform, languageSet: languageSet)
            }
        }

        let _ = allowFallback
        return nil
    }

    private func platformPreference(
        for targetPlatform: String,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> [String] {
        let normalized = targetPlatform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if targetArchitecture == .appleSilicon {
            switch normalized {
            case "macarm64":
                return ["macuniversal", "macarm64"]
            case "macuniversal":
                return ["macuniversal", "macarm64"]
            case "", "osx10", "osx10-64":
                return ["macuniversal", "macarm64"]
            default:
                return targetArchitecture.platformPreference
            }
        }

        switch normalized {
        case "macarm64":
            return ["macuniversal", "osx10", "osx10-64"]
        case "macuniversal":
            return ["macuniversal", "osx10", "osx10-64"]
        case "osx10-64":
            return ["osx10-64", "osx10", "macuniversal"]
        case "osx10":
            return ["osx10", "osx10-64", "macuniversal"]
        case "":
            return ["macuniversal", "osx10", "osx10-64"]
        default:
            return targetArchitecture.platformPreference
        }
    }

    private func makeScriptPropertyTable(
        installLanguage: String,
        installDirectory: String
    ) -> HDPIMPropertyTable {
        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        propertyTable.setInstallDir(installDirectory)
        propertyTable.setProperty("installLanguage", installLanguage)
        propertyTable.setProperty("uiDisplayLanguage", resolvedUIDisplayLanguage(installLanguage: installLanguage))
        return propertyTable
    }

    private func evaluateSystemRequirements(
        applicationInfo: ApplicationInfo,
        propertyTable: HDPIMPropertyTable,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> Bool {
        guard let script = propertyString(applicationInfo.properties["SystemRequirement.CheckCompatibility.Content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty,
              let clientInfoJSONString = makeSystemRequirementClientInfoJSONString(propertyTable: propertyTable),
              let hardwareSummaryJSONString = hardwareSummaryJSONString(
                propertyTable: propertyTable,
                targetArchitecture: targetArchitecture
              ) else {
            return true
        }

        let evaluation = executeCompatibilityScript(
            script: script,
            functionName: "checkCompatibility",
            clientInfoJSONString: clientInfoJSONString,
            hardwareSummaryJSONString: hardwareSummaryJSONString,
            applicationInfo: applicationInfo
        )
        propertyTable.setProperty("systemRequirement.checkResult", evaluation.checkResult)
        propertyTable.setProperty("systemRequirement.failingDescription", evaluation.failingDescription)
        propertyTable.setProperty("systemRequirement.messageString", evaluation.messageString)
        propertyTable.setProperty("systemRequirement.failureXML", evaluation.failureXML ?? "")
        return evaluation.isCompatible
    }

    private func executeCompatibilityScript(
        script: String,
        functionName: String,
        clientInfoJSONString: String,
        hardwareSummaryJSONString: String,
        applicationInfo: ApplicationInfo? = nil
    ) -> HDPIMCompatibilityScriptEvaluation {
        guard let context = JSContext() else {
            return compatibleScriptEvaluation()
        }

        let evaluation = context.evaluateScript(script)
        if evaluation == nil, context.exception != nil {
            return compatibleScriptEvaluation()
        }

        guard let function = context.objectForKeyedSubscript(functionName) else {
            return compatibleScriptEvaluation()
        }

        let result = function.call(withArguments: [clientInfoJSONString, hardwareSummaryJSONString])
        if context.exception != nil {
            return compatibleScriptEvaluation()
        }

        guard let resultString = result?.toString(),
              let data = resultString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return compatibleScriptEvaluation()
        }

        let checkResult = firstNonEmptyString([
            propertyString(json["checkResult"])
        ]).lowercased()
        let failingDescription = buildFailingDescription(from: json["failingList"])
        let messageString = firstNonEmptyString([
            propertyString(json["messageString"])
        ])
        let isOverrideMessageEnabled = stringBool(json["overrideMessage"])
        let selectedFailureMessage = isOverrideMessageEnabled ? messageString : failingDescription
        let failureXML = makeSystemRequirementFailureXML(
            failingDescription: selectedFailureMessage,
            applicationInfo: applicationInfo
        )

        return HDPIMCompatibilityScriptEvaluation(
            isCompatible: checkResult != "fail",
            checkResult: checkResult,
            failingDescription: failingDescription,
            messageString: messageString,
            isOverrideMessageEnabled: isOverrideMessageEnabled,
            failureXML: failureXML
        )
    }

    private func makePackageCompatibilityClientInfoJSONString(
        propertyTable: HDPIMPropertyTable
    ) -> String? {
        makeJSONString(from: [
            "context": "ACC",
            "locale": propertyTable.getProperty("installLanguage") ?? StorageData.shared.defaultLanguage,
            "installDirectory": propertyTable.getProperty("INSTALLDIR") ?? "/Applications"
        ])
    }

    private func makeSystemRequirementClientInfoJSONString(
        propertyTable: HDPIMPropertyTable
    ) -> String? {
        let uiDisplayLanguage = firstNonEmptyString([
            propertyTable.getProperty("uiDisplayLanguage"),
            resolvedSystemLocale(),
            firstInstallLanguageToken(propertyTable.getProperty("installLanguage")),
            "en_US"
        ])
        let installDir = propertyTable.expandPath(propertyTable.getProperty("installDir") ?? "/Applications")
        propertyTable.setInstallDir(installDir)

        return makeJSONString(from: [
            "context": "ACC",
            "locale": uiDisplayLanguage,
            "installDirectory": installDir
        ])
    }

    private func hardwareSummaryJSONString(
        propertyTable: HDPIMPropertyTable,
        targetArchitecture: HDPIMParityTargetArchitecture
    ) -> String? {
        let _ = targetArchitecture
        if let cached = propertyTable.getProperty("hardwareSummary"),
           !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached
        }

        let processorBrand = firstNonEmptyString([
            readSysctlString("machdep.cpu.brand_string")
        ])
        let instructionSet = currentInstructionSetList()
        let volumeSummaries = currentVolumeSummaries()
        let displaysSummary = currentDisplaysSummary()

        let osSummary: [String: Any] = [
            "type": "mac",
            "version": currentOSVersionString(),
            "name": currentOSNameString(),
            "architecture": currentOSBitnessString(),
            "osArch": currentOSArchSummaryString()
        ]

        var processorSummary: [String: Any] = [
            "vendorName": currentProcessorVendorName(brandString: processorBrand),
            "instructionSet": instructionSet
        ]
        let processorName = processorBrand
        if !processorName.isEmpty {
            processorSummary["name"] = processorName
        }
        let numberOfCores = currentCPUCoreCountString()
        if !numberOfCores.isEmpty {
            processorSummary["numberOfCores"] = numberOfCores
        }
        let frequencyInGHz = currentCPUFrequencyGHzString()
        if !frequencyInGHz.isEmpty {
            processorSummary["frequencyInGHz"] = frequencyInGHz
        }

        var summary: [String: Any] = [
            "os": osSummary,
            "volumes": volumeSummaries,
            "processor": processorSummary,
            "dpiRatio": currentDPIRatioString()
        ]

        if let openGLVersion = displaysSummary.openGLVersion,
           !openGLVersion.isEmpty {
            summary["openGLVersion"] = openGLVersion
        }
        if !displaysSummary.displays.isEmpty {
            summary["displays"] = displaysSummary.displays
        }
        let accVersion = currentACCVersionString()
        if !accVersion.isEmpty {
            summary["accVersion"] = accVersion
        }

        guard let jsonString = makeJSONString(from: summary) else {
            return nil
        }

        propertyTable.setProperty("hardwareSummary", jsonString)
        return jsonString
    }

    private func resolvedUIDisplayLanguage(installLanguage: String) -> String {
        firstNonEmptyString([
            resolvedSystemLocale(),
            firstInstallLanguageToken(installLanguage),
            "en_US"
        ])
    }

    private func resolvedSystemLocale() -> String {
        let systemLanguage = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if AppStatics.supportedLanguages.contains(where: { $0.code == systemLanguage }) {
            return systemLanguage
        }
        if let matchedLanguage = AppStatics.supportedLanguages.first(where: {
            systemLanguage.hasPrefix($0.code.prefix(2))
        })?.code {
            return matchedLanguage
        }
        return ""
    }

    private func expandedInstallDirectory(for applicationInfo: ApplicationInfo) -> String {
        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        propertyTable.setInstallDir("/Applications")
        if applicationInfo.installDir.isEmpty {
            return "/Applications"
        }
        return propertyTable.expandPath(applicationInfo.installDir)
    }

    private func openDatabaseIfNeeded() -> Bool {
        (try? HDPIMDatabase.shared.open()) != nil
    }

    private func processorFamily(fromRawValue rawValue: String) -> HDPIMProcessorFamily {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case HDPIMProcessorFamily.bit32.rawValue:
            return .bit32
        case HDPIMProcessorFamily.arm64Bit.rawValue:
            return .arm64Bit
        default:
            return .bit64
        }
    }

    private func currentOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func currentOSNameString() -> String {
        "macOS"
    }

    private func currentOSBitnessString() -> String {
        String(MemoryLayout<Int>.size * 8)
    }

    private func currentOSArchSummaryString() -> String {
        AppStatics.isAppleSilicon ? "OS_ARCH_ARM64" : "OS_ARCH_X64"
    }

    private func currentMachineOSArchitectureString() -> String {
        if AppStatics.isAppleSilicon {
            return "arm64"
        }
        return currentOSBitnessString() == "64" ? "x64" : "x86"
    }

    private func currentMachineOSProcessorFamilyString() -> String {
        currentOSBitnessString() == "64" ? "64-bit" : "32-bit"
    }

    private func currentMachineTargetArchitecture() -> HDPIMParityTargetArchitecture {
        AppStatics.isAppleSilicon ? .appleSilicon : .intel
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

    private func makeJSONString(from object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func compatibleScriptEvaluation() -> HDPIMCompatibilityScriptEvaluation {
        HDPIMCompatibilityScriptEvaluation(
            isCompatible: true,
            checkResult: "",
            failingDescription: "",
            messageString: "",
            isOverrideMessageEnabled: false,
            failureXML: nil
        )
    }

    private func buildFailingDescription(from value: Any?) -> String {
        guard let items = value as? [[String: Any]] else {
            return ""
        }

        return items.compactMap { item in
            let message = firstNonEmptyString([
                propertyString(item["message"])
            ])
            guard !message.isEmpty else {
                return nil
            }
            return "- \(message)<br>"
        }.joined()
    }

    private func makeSystemRequirementFailureXML(
        failingDescription: String,
        applicationInfo: ApplicationInfo?
    ) -> String? {
        guard !failingDescription.isEmpty else {
            return nil
        }

        let escapedDescription = escapeXMLText(failingDescription)
        let prodURL = escapeXMLText(applicationInfo?.systemRequirementExternalUrlProd ?? "")
        let stageURL = escapeXMLText(applicationInfo?.systemRequirementExternalUrlStage ?? "")

        return """
        <SystemRequirement><FailingDescription>\(escapedDescription)</FailingDescription><LearnMoreUrl><Prod>\(prodURL)</Prod><Stage>\(stageURL)</Stage></LearnMoreUrl></SystemRequirement>
        """
    }

    private func escapeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func stringBool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        default:
            return false
        }
    }

    private func firstInstallLanguageToken(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private func readSysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func readSysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private func readSysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private func currentProcessorVendorName(brandString: String) -> String {
        if brandString.localizedCaseInsensitiveContains("intel") {
            return "Intel"
        }
        if AppStatics.isAppleSilicon {
            return "Apple"
        }
        return "Intel"
    }

    private func currentCPUCoreCountString() -> String {
        if let coreCount = readSysctlInt32("machdep.cpu.core_count"), coreCount > 0 {
            return String(coreCount)
        }
        return ""
    }

    private func currentCPUFrequencyGHzString() -> String {
        let rawFrequency = readSysctlInt64("hw.cpufrequency") ?? readSysctlInt64("hw.cpufrequency_max")
        guard let rawFrequency, rawFrequency > 0 else {
            return ""
        }
        let frequencyInGHz = Double(rawFrequency) / 1_000_000_000
        return String(format: "%.2f", frequencyInGHz)
    }

    private func currentInstructionSetList() -> [String] {
        guard !AppStatics.isAppleSilicon else {
            return []
        }

        let rawFeatures = [
            readSysctlString("machdep.cpu.features"),
            readSysctlString("machdep.cpu.leaf7_features")
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        guard !rawFeatures.isEmpty else {
            return []
        }

        return Array(
            Set(
                rawFeatures
                    .split(whereSeparator: \.isWhitespace)
                    .map { token in
                        token
                            .lowercased()
                            .replacingOccurrences(of: ".", with: "_")
                    }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private func currentVolumeSummaries() -> [[String: String]] {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: []
        ) ?? []

        return mountedURLs.compactMap { url -> [String: String]? in
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let name = firstNonEmptyString([
                values?.volumeName,
                url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
            ])
            guard !name.isEmpty else {
                return nil
            }

            let availableCapacity = values?.volumeAvailableCapacityForImportantUsage
                ?? Int64(values?.volumeAvailableCapacity ?? 0)
            let freeSpaceInGB = availableCapacity > 0 ? String(availableCapacity / 1_000_000_000) : "0"
            let standardizedPath = url.standardizedFileURL.path
            let isPrimary = standardizedPath == "/"

            return [
                "name": name,
                "freeSpaceInGB": freeSpaceInGB,
                "isPrimary": isPrimary ? "true" : "false"
            ]
        }
    }

    private func currentDisplaysSummary() -> (displays: [[String: String]], openGLVersion: String?) {
        var displays: [[String: String]] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-xml", "SPDisplaysDataType"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ([], nil)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]],
              let firstSection = plist.first,
              let items = firstSection["_items"] as? [[String: Any]] else {
            return ([], nil)
        }

        for item in items {
            var displaySummary: [String: String] = [
                "widthInPixels": "0",
                "heightInPixels": "0",
                "isPrimary": "false"
            ]

            if let modelName = item["sppci_model"] as? String,
               !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displaySummary["gpuModelName"] = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let rawVRAM = firstNonEmptyString([
                item["spdisplays_vram"] as? String,
                item["_spdisplays_vram"] as? String
            ])
            if !rawVRAM.isEmpty {
                displaySummary["vRAMInMB"] = normalizedVRAMString(rawVRAM)
            }

            let drivers = item["spdisplays_ndrvs"] as? [[String: Any]] ?? []
            if drivers.isEmpty {
                displays.append(displaySummary)
                continue
            }

            for driver in drivers {
                var driverSummary = displaySummary
                if let rawResolution = driver["_spdisplays_resolution"] as? String {
                    let resolutionComponents = rawResolution
                        .split(separator: "x", maxSplits: 1)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    if resolutionComponents.count == 2 {
                        let width = resolutionComponents[0]
                        let height = resolutionComponents[1]
                            .split(separator: "@", maxSplits: 1)
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .first ?? ""
                        if !width.isEmpty {
                            driverSummary["widthInPixels"] = width
                        }
                        if !height.isEmpty {
                            driverSummary["heightInPixels"] = height
                        }
                    }
                }

                if let isPrimary = driver["spdisplays_main"] as? String,
                   isPrimary == "spdisplays_yes" {
                    driverSummary["isPrimary"] = "true"
                }

                displays.append(driverSummary)
            }
        }

        return (displays, currentOpenGLVersionString())
    }

    private func currentOpenGLVersionString() -> String? {
        let displayIds = Set(
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { CGDirectDisplayID($0.uint32Value) }
            }
        )
        let candidateDisplayIds = displayIds.isEmpty ? [CGMainDisplayID()] : Array(displayIds)

        var highestMajorVersion: GLint = 0
        for displayId in candidateDisplayIds {
            let displayMask = CGDisplayIDToOpenGLDisplayMask(displayId)
            var rendererInfo: CGLRendererInfoObj?
            var rendererCount: GLint = 0
            let queryResult = CGLQueryRendererInfo(displayMask, &rendererInfo, &rendererCount)
            guard queryResult == kCGLNoError, let rendererInfo else {
                continue
            }
            defer {
                CGLDestroyRendererInfo(rendererInfo)
            }

            for rendererIndex in 0..<rendererCount {
                var majorVersion: GLint = 0
                let describeResult = CGLDescribeRenderer(
                    rendererInfo,
                    rendererIndex,
                    CGLRendererProperty(kCGLRPMajorGLVersion.rawValue),
                    &majorVersion
                )
                if describeResult == kCGLNoError {
                    highestMajorVersion = max(highestMajorVersion, majorVersion)
                }
            }
        }

        guard highestMajorVersion > 0 else {
            return nil
        }
        return String(highestMajorVersion)
    }

    private func normalizedVRAMString(_ rawValue: String) -> String {
        let parts = rawValue
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2 else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let amountString = parts[0].replacingOccurrences(of: ",", with: ".")
        let unit = parts[1].uppercased()
        guard let amount = Double(amountString) else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch unit {
        case "GB":
            return String(Int(amount * 1000))
        case "KB":
            return String(Int(amount / 1000))
        default:
            return String(Int(amount))
        }
    }

    private func currentDPIRatioString() -> String {
        let ratio = NSScreen.main?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 1.0
        return String(format: "%.2f", ratio)
    }

    private func currentACCVersionString() -> String {
        let candidatePaths = [
            "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app",
            "/Applications/Adobe Creative Cloud/ACC/Creative Cloud.app"
        ]

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let bundle = Bundle(path: path) else {
                continue
            }

            let version = firstNonEmptyString([
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ])
            if !version.isEmpty {
                return version
            }
        }

        return ""
    }

    private func firstNonEmptyString(_ values: [String?]) -> String {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
    }
}

private enum HDPIMConditionToken: Equatable {
    case leftParen
    case rightParen
    case and
    case or
    case not
    case equal
    case notEqual
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case variable(String)
    case literal(String)
    case end
}

private final class HDPIMConditionTokenizer {
    private let characters: [Character]
    private var index = 0

    init(source: String) {
        self.characters = Array(source)
    }

    func nextToken() -> HDPIMConditionToken {
        skipWhitespace()
        guard index < characters.count else {
            return .end
        }

        let current = characters[index]
        if current == "(" {
            index += 1
            return .leftParen
        }
        if current == ")" {
            index += 1
            return .rightParen
        }
        if current == "[" {
            return readVariable()
        }
        if current == "&", match("&&") {
            return .and
        }
        if current == "|", match("||") {
            return .or
        }
        if current == "!", match("!=") {
            return .notEqual
        }
        if current == "!" {
            index += 1
            return .not
        }
        if current == "=", match("==") {
            return .equal
        }
        if current == ">", match(">=") {
            return .greaterThanOrEqual
        }
        if current == "<", match("<=") {
            return .lessThanOrEqual
        }
        if current == ">" {
            index += 1
            return .greaterThan
        }
        if current == "<" {
            index += 1
            return .lessThan
        }
        if current == "\"" || current == "'" {
            return readQuotedLiteral(quote: current)
        }

        return readLiteral()
    }

    private func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }

    private func match(_ value: String) -> Bool {
        let endIndex = index + value.count
        guard endIndex <= characters.count else {
            return false
        }
        let candidate = String(characters[index..<endIndex])
        if candidate == value {
            index = endIndex
            return true
        }
        return false
    }

    private func readVariable() -> HDPIMConditionToken {
        index += 1
        let start = index
        while index < characters.count, characters[index] != "]" {
            index += 1
        }
        let variable = String(characters[start..<min(index, characters.count)])
        if index < characters.count, characters[index] == "]" {
            index += 1
        }
        return .variable(variable)
    }

    private func readQuotedLiteral(quote: Character) -> HDPIMConditionToken {
        index += 1
        let start = index
        while index < characters.count, characters[index] != quote {
            index += 1
        }
        let value = String(characters[start..<min(index, characters.count)])
        if index < characters.count, characters[index] == quote {
            index += 1
        }
        return .literal(value)
    }

    private func readLiteral() -> HDPIMConditionToken {
        let start = index
        while index < characters.count {
            let current = characters[index]
            if current.isWhitespace || current == "(" || current == ")" || current == "[" || current == "]" {
                break
            }
            if current == "&" || current == "|" || current == "!" || current == "=" || current == "<" || current == ">" {
                break
            }
            index += 1
        }
        let literal = String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        return .literal(literal)
    }
}

private final class HDPIMConditionEvaluator {
    private let tokenizer: HDPIMConditionTokenizer
    private let variables: [String: String]
    private var currentToken: HDPIMConditionToken

    init(condition: String, variables: [String: String]) {
        self.tokenizer = HDPIMConditionTokenizer(source: condition
            .replacingOccurrences(of: "&amp;&amp;", with: "&&")
            .replacingOccurrences(of: "&amp;||", with: "||"))
        self.variables = variables
        self.currentToken = tokenizer.nextToken()
    }

    func evaluate() -> Bool {
        parseOrExpression()
    }

    private func parseOrExpression() -> Bool {
        var result = parseAndExpression()
        while currentToken == .or {
            advance()
            result = result || parseAndExpression()
        }
        return result
    }

    private func parseAndExpression() -> Bool {
        var result = parseUnaryExpression()
        while currentToken == .and {
            advance()
            result = result && parseUnaryExpression()
        }
        return result
    }

    private func parseUnaryExpression() -> Bool {
        if currentToken == .not {
            advance()
            return !parseUnaryExpression()
        }
        return parsePrimaryExpression()
    }

    private func parsePrimaryExpression() -> Bool {
        if currentToken == .leftParen {
            advance()
            let value = parseOrExpression()
            if currentToken == .rightParen {
                advance()
            }
            return value
        }

        let leftOperand = parseOperand()
        switch currentToken {
        case .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            let comparator = currentToken
            advance()
            let rightOperand = parseOperand()
            return evaluateComparison(left: leftOperand, comparator: comparator, right: rightOperand)
        default:
            return truthy(leftOperand)
        }
    }

    private func parseOperand() -> String {
        switch currentToken {
        case .variable(let name):
            advance()
            return variables[name] ?? ""
        case .literal(let value):
            advance()
            return value
        default:
            return ""
        }
    }

    private func evaluateComparison(left: String, comparator: HDPIMConditionToken, right: String) -> Bool {
        let normalizedLeft = normalizeComparableValue(left)
        let normalizedRight = normalizeComparableValue(right)

        if shouldTreatAsVersion(normalizedLeft) || shouldTreatAsVersion(normalizedRight) {
            let comparison = AppStatics.compareVersions(normalizedLeft, normalizedRight)
            switch comparator {
            case .equal:
                return comparison == 0
            case .notEqual:
                return comparison != 0
            case .greaterThan:
                return comparison > 0
            case .greaterThanOrEqual:
                return comparison >= 0
            case .lessThan:
                return comparison < 0
            case .lessThanOrEqual:
                return comparison <= 0
            default:
                return false
            }
        }

        if let numericLeft = Double(normalizedLeft), let numericRight = Double(normalizedRight) {
            switch comparator {
            case .equal:
                return numericLeft == numericRight
            case .notEqual:
                return numericLeft != numericRight
            case .greaterThan:
                return numericLeft > numericRight
            case .greaterThanOrEqual:
                return numericLeft >= numericRight
            case .lessThan:
                return numericLeft < numericRight
            case .lessThanOrEqual:
                return numericLeft <= numericRight
            default:
                return false
            }
        }

        let leftValues = splitList(normalizedLeft)
        let rightValues = splitList(normalizedRight)
        let leftContainsAll = leftValues.contains("ALL")
        let rightContainsAll = rightValues.contains("ALL")

        switch comparator {
        case .equal:
            if leftContainsAll || rightContainsAll {
                return true
            }
            return !leftValues.isDisjoint(with: rightValues)
        case .notEqual:
            if leftContainsAll || rightContainsAll {
                return false
            }
            return leftValues.isDisjoint(with: rightValues)
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            let comparison = normalizedLeft.caseInsensitiveCompare(normalizedRight)
            switch comparator {
            case .greaterThan:
                return comparison == .orderedDescending
            case .greaterThanOrEqual:
                return comparison == .orderedDescending || comparison == .orderedSame
            case .lessThan:
                return comparison == .orderedAscending
            case .lessThanOrEqual:
                return comparison == .orderedAscending || comparison == .orderedSame
            default:
                return false
            }
        default:
            return false
        }
    }

    private func truthy(_ value: String) -> Bool {
        let normalized = normalizeComparableValue(value).lowercased()
        if normalized.isEmpty {
            return false
        }
        return !["false", "0", "no"].contains(normalized)
    }

    private func normalizeComparableValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private func shouldTreatAsVersion(_ value: String) -> Bool {
        value.contains(".") && value.range(of: #"^[0-9]+(\.[0-9]+)+$"#, options: .regularExpression) != nil
    }

    private func splitList(_ value: String) -> Set<String> {
        Set(
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func advance() {
        currentToken = tokenizer.nextToken()
    }
}
