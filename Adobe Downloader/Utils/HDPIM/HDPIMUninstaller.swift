import Foundation

final class HDPIMUninstaller {

    static func uninstall(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) throws {
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
            try uninstallPackage(package)
        }
    }

    private static func uninstallPackage(_ package: HDPIMInstallRecord) throws {
        let fileManager = FileManager.default

        if let pimxPath = package.uninstallPIMXPath,
           fileManager.fileExists(atPath: pimxPath) {
            try? fileManager.removeItem(atPath: pimxPath)
        }

        try? fileManager.removeItem(atPath: package.installPath)
    }
}

enum UninstallError: Error {
    case dependencyExists(String)
}
