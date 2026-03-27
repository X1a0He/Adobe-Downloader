import Foundation

struct HDPIMModule {
    let id: String
    let displayName: String
    let referencePackages: [String]
    var isInstalled: Bool = false
    var isSelected: Bool = true
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
                referencePackages: parsed.referencePackages
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

    func evaluateModuleConfiguration(package: ParsedPackage, installType: String) -> Bool {
        if installType == "complete" { return true }
        return package.type.lowercased() == "baseline"
    }
}
