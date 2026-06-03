import Foundation

final class HDPIMUninstaller {

    static func uninstall(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) async throws {
        let canUninstall = HDPIMDependencyManager.shared.canUninstall(
            sapCode: sapCode,
            version: version
        )

        guard canUninstall.canUninstall else {
            throw UninstallError.dependencyExists(canUninstall.reason ?? "")
        }

        let packages = HDPIMDatabase.shared.getInstalledPackages(
            sapCode: sapCode,
            version: version
        )

        for package in packages {
            try await uninstallPackage(package)
            try updateDBForUninstall(package: package)
        }

        try performProductUninstallCompletion(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily
        )
    }

    private static func uninstallPackage(_ package: HDPIMInstallRecord) async throws {
        if let pimxPath = package.uninstallPIMXPath,
           FileManager.default.fileExists(atPath: pimxPath) {
            let propertyTable = HDPIMPropertyTable()
            propertyTable.setupSystemDirectories()
            propertyTable.setInstallDir(package.installPath)
            propertyTable.setProductInstallDir(package.installPath)

            try await HDPIMRollbackHelper.executeUninstallPIMX(
                at: URL(fileURLWithPath: pimxPath),
                propertyTable: propertyTable
            )
        }
    }

    private static func updateDBForUninstall(package: HDPIMInstallRecord) throws {
        let packageContext = HDPIMNativePackageContext(
            sapCode: package.sapCode,
            productVersion: package.codexVersion,
            platform: package.platform,
            packageName: package.packageName,
            packageVersion: package.packageVersion,
            packageType: "",
            packageProcessorFamily: "",
            sequenceNumber: 0,
            installDir: package.installPath,
            uninstallPIMXPath: package.uninstallPIMXPath,
            uninstallPIMXHash: package.uninstallPIMXHash,
            uninstallPIMXHash256: nil,
            repairPIMXPath: nil,
            repairPIMXHash: nil,
            repairPIMXHash256: nil,
            installSize: "0",
            targetFolders: [],
            ribsCoexistenceCode: nil,
            module: nil,
            uwpInfoXML: nil,
            isShared: false
        )
        try HDPIMDatabase.shared.removeInstalledPackages([packageContext])
    }

    private static func performProductUninstallCompletion(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws {
        let remainingPackages = HDPIMDatabase.shared.getInstalledPackages(
            sapCode: sapCode,
            version: version
        )

        if remainingPackages.isEmpty {
            let productKey = HDPIMNativeProductKey(
                sapCode: sapCode,
                version: version,
                platform: platform(for: processorFamily)
            )
            try HDPIMDatabase.shared.removeInstallations(productKeys: [productKey])
        }
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
}

enum UninstallError: Error {
    case dependencyExists(String)
}
