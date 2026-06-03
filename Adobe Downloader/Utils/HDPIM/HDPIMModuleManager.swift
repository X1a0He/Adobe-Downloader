import Foundation

struct HDPIMModule {
    let id: String
    let displayName: String
    let referencePackages: [String]
    let properties: [String: String]
    var isInstalled: Bool = false
    var isSelected: Bool = true
    var isBaseline: Bool = false
}

enum ModuleAction {
    case install
    case uninstall
}

final class HDPIMModuleManager {

    static let shared = HDPIMModuleManager()
    private init() {}

    func parseModules(from appInfo: ApplicationInfo) -> [HDPIMModule] {
        appInfo.modules.map { parsed in
            HDPIMModule(
                id: parsed.id,
                displayName: parsed.id,
                referencePackages: parsed.referencePackages,
                properties: parsed.properties
            )
        }
    }

    func getInstalledModules(sapCode: String, version: String, platform: String) -> [String] {
        let processorFamily = HDPIMProcessorFamily.from(platform: platform)
        guard let raw = HDPIMDatabase.shared.getProductMeta(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily,
            key: "modules"
        ) else {
            return []
        }
        return raw.split(separator: ",").map { String($0) }
    }

    func filterPackagesByModules(
        packages: [ParsedPackage],
        selectedModules: [HDPIMModule],
        action: ModuleAction
    ) -> [ParsedPackage] {
        let selectedModuleIds = Set(selectedModules.filter(\.isSelected).map(\.id))

        switch action {
        case .install:
            let referencedPackageNames = Set(
                selectedModules
                    .filter(\.isSelected)
                    .flatMap(\.referencePackages)
            )
            return packages.filter { pkg in
                if pkg.type == "core" { return true }
                if referencedPackageNames.isEmpty { return true }
                return referencedPackageNames.contains(pkg.packageName) || referencedPackageNames.contains(pkg.fullPackageName)
            }

        case .uninstall:
            let referencedPackageNames = Set(
                selectedModules
                    .filter(\.isSelected)
                    .flatMap(\.referencePackages)
            )
            return packages.filter { pkg in
                referencedPackageNames.contains(pkg.packageName) || referencedPackageNames.contains(pkg.fullPackageName)
            }
        }
    }

    func markModulesInstalled(sapCode: String, version: String, platform: String, moduleIds: [String]) {
        let processorFamily = HDPIMProcessorFamily.from(platform: platform)
        let value = moduleIds.joined(separator: ",")
        HDPIMDatabase.shared.setProductMeta(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily,
            key: "modules",
            value: value
        )
    }

    func evaluateModuleConfiguration(package: ParsedPackage, installType: String, modules: [HDPIMModule]) -> Bool {
        if installType == "complete" { return true }
        if package.type.lowercased() == "core" { return true }

        for module in modules where module.isSelected {
            for refPkg in module.referencePackages {
                if refPkg == package.packageName || refPkg == package.fullPackageName {
                    return true
                }
            }
        }
        return false
    }

    func validateModuleReferences(modules: [HDPIMModule], packages: [ParsedPackage]) -> [String] {
        let packageNames = Set(packages.map(\.packageName) + packages.map(\.fullPackageName))
        var missingPackages: [String] = []

        for module in modules {
            for refPkg in module.referencePackages {
                if !packageNames.contains(refPkg) {
                    missingPackages.append("Module \(module.id): missing package \(refPkg)")
                }
            }
        }
        return missingPackages
    }
}
