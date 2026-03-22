import Foundation

struct InstalledProduct {
    let sapCode: String
    let version: String
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

    func getInstalledProducts() -> [InstalledProduct] {
        let raw = HDPIMDatabase.shared.getAllInstalledProducts()
        return raw.map { InstalledProduct(sapCode: $0.sapCode, version: $0.version, platform: $0.platform) }
    }

    func checkForUpdates() async -> [AvailableUpdate] {
        let installed = getInstalledProducts()
        guard !installed.isEmpty else { return [] }

        var updates: [AvailableUpdate] = []

        for product in installed {
            let targetPlatform = mapProcessorFamilyToPlatform(product.platform)
            guard let ccmProduct = findLatestCcmProduct(sapCode: product.sapCode, platform: targetPlatform) else {
                continue
            }

            let comparison = compareVersions(product.version, ccmProduct.version)
            if comparison < 0 {
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

        let platformMatch = latest.platforms.first(where: {
            $0.id == platform || $0.id == "macuniversal"
        }) ?? latest.platforms.first

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
}
