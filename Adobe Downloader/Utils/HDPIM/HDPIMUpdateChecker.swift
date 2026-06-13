import Foundation

struct InstalledProduct {
    let sapCode: String
    let version: String
    let processorFamily: HDPIMProcessorFamily
    let platform: String
}

struct AvailableUpdate {
    let sapCode: String
    let displayName: String
    let installedVersion: String
    let availableVersion: String
    let buildGuid: String
    let availablePlatform: String
}

final class HDPIMUpdateChecker {

    static let shared = HDPIMUpdateChecker()
    private init() {}

    func getInstalledProducts(databaseAlreadyOpen: Bool = false) -> [InstalledProduct] {
        let shouldClose = databaseAlreadyOpen ? false : openDatabaseIfNeeded()
        guard databaseAlreadyOpen || shouldClose else { return [] }
        defer {
            if shouldClose {
                HDPIMDatabase.shared.close()
            }
        }

        let raw = HDPIMDatabase.shared.getAllInstalledProducts()
        return raw.map { product in
            let processorFamily = processorFamily(fromRawValue: product.platform)
            let installedPlatform = firstNonEmptyString([
                HDPIMDatabase.shared.getProductMeta(
                    sapCode: product.sapCode,
                    version: product.version,
                    processorFamily: processorFamily,
                    key: HDPIMProductMetaKey.platform.rawValue
                ),
                mapProcessorFamilyToPlatform(product.platform)
            ])

            return InstalledProduct(
                sapCode: product.sapCode,
                version: product.version,
                processorFamily: processorFamily,
                platform: installedPlatform
            )
        }
    }

    func checkForUpdates() async -> [AvailableUpdate] {
        let shouldClose = openDatabaseIfNeeded()
        guard shouldClose else { return [] }
        defer {
            if shouldClose {
                HDPIMDatabase.shared.close()
            }
        }

        let installed = getInstalledProducts(databaseAlreadyOpen: true)
        guard !installed.isEmpty else { return [] }

        var updates: [AvailableUpdate] = []

        for product in installed {
            let targetPlatform = product.platform.isEmpty
                ? mapProcessorFamilyToPlatform(product.processorFamily.rawValue)
                : product.platform

            guard let ccmProduct = findLatestCcmProduct(
                sapCode: product.sapCode,
                platform: targetPlatform
            ) else {
                continue
            }

            let comparison = compareVersions(product.version, ccmProduct.version)
            let requiresUniversalRepair = comparison == 0 && requiresUniversalArchitectureRepair(product: product)
            if comparison < 0 || requiresUniversalRepair {
                updates.append(AvailableUpdate(
                    sapCode: product.sapCode,
                    displayName: ccmProduct.displayName,
                    installedVersion: product.version,
                    availableVersion: ccmProduct.version,
                    buildGuid: ccmProduct.buildGuid,
                    availablePlatform: ccmProduct.platform
                ))
            }
        }

        return updates
    }

    func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").map { Int($0) ?? 0 }
        let parts2 = v2.split(separator: ".").map { Int($0) ?? 0 }

        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }
        return 0
    }

    private struct CcmProductMatch {
        let displayName: String
        let version: String
        let buildGuid: String
        let platform: String
    }

    private func findLatestCcmProduct(sapCode: String, platform: String) -> CcmProductMatch? {
        let matching = globalCcmResult.products.filter { $0.id == sapCode }
        guard let latest = matching.sorted(by: {
            AppStatics.compareVersions($0.version, $1.version) > 0
        }).first else {
            return nil
        }

        let targetArchitecture = targetArchitecture(for: platform)
        let platformMatch = HDPIMParityDecisionEngine.shared.matchingPlatform(
            for: latest,
            targetPlatform: platform,
            targetArchitecture: targetArchitecture,
            allowFallback: false
        )

        guard let plat = platformMatch,
              let langSet = plat.languageSet.first else {
            return nil
        }

        return CcmProductMatch(
            displayName: latest.displayName,
            version: latest.version,
            buildGuid: langSet.buildGuid,
            platform: plat.id
        )
    }

    private func mapProcessorFamilyToPlatform(_ processorFamily: String) -> String {
        switch processorFamily {
        case "Arm64Bit": return "macarm64"
        case "64Bit": return "osx10-64"
        case "32Bit": return "osx10"
        default: return "macarm64"
        }
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

    private func targetArchitecture(for platform: String) -> HDPIMParityTargetArchitecture {
        switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "macarm64":
            return .appleSilicon
        case "macuniversal":
            return AppStatics.isAppleSilicon ? .appleSilicon : .intel
        default:
            return .intel
        }
    }

    private func requiresUniversalArchitectureRepair(product: InstalledProduct) -> Bool {
        guard product.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "macuniversal" else {
            return false
        }

        let installedPackageNames = HDPIMDatabase.shared.getInstalledPackageNames(
            sapCode: product.sapCode,
            version: product.version,
            processorFamily: product.processorFamily
        )
        guard !installedPackageNames.isEmpty else {
            return false
        }

        let normalizedPackageNames = installedPackageNames.map(normalizedPackageName)
        let hasIntelStrippedPackage = normalizedPackageNames.contains { $0.hasSuffix("_stripped") }
        let hasArmStrippedPackage = normalizedPackageNames.contains { $0.hasSuffix("_stripped_arm") }

        if AppStatics.isAppleSilicon {
            return hasIntelStrippedPackage
        }
        return hasArmStrippedPackage
    }

    private func normalizedPackageName(_ packageName: String) -> String {
        let normalized = packageName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix(".zip") {
            return String(normalized.dropLast(4))
        }
        return normalized
    }

    private func firstNonEmptyString(_ values: [String?]) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private func openDatabaseIfNeeded() -> Bool {
        (try? HDPIMDatabase.shared.open()) != nil
    }
}
