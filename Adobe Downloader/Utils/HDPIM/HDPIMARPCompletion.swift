import Foundation

enum HDPIMARPNaming {
    static func appGuid(sapCode: String, version: String) -> String {
        let normalizedVersion = version.replacingOccurrences(of: ".", with: "_")
        return "\(sapCode)_\(normalizedVersion)_32"
    }
}

enum HDPIMARPCompletion {
    private static let uninstallerSourcePath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Uninstaller.app"
    private static let uninstallRoot = "/Library/Application Support/Adobe/Uninstall"
    private static let adobeInstallersDir = "/Applications/Utilities/Adobe Installers"

    static func createARPEntries(
        for contexts: [HDPIMNativeProductContext],
        progressHandler: (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) {
        let targets = contexts.filter { $0.isVisibleProduct }
        guard !targets.isEmpty else {
            return
        }

        for context in targets {
            do {
                try createARPEntry(for: context, logHandler: logHandler)
            } catch {
                logHandler?("[HDPIM ARP] 创建卸载条目失败 (\(context.sapCode)): \(error.localizedDescription)")
            }
        }
    }

    private static func createARPEntry(for context: HDPIMNativeProductContext, logHandler: ((String) -> Void)?) throws {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: uninstallerSourcePath) else {
            throw HDPIMARPError.uninstallerMissing(uninstallerSourcePath)
        }

        let appGuid = HDPIMARPNaming.appGuid(
            sapCode: context.sapCode,
            version: context.codexVersion
        )
        let uninstallAppPath = "\(uninstallRoot)/\(appGuid).app"
        let adbargPath = "\(uninstallRoot)/\(appGuid).adbarg"

        try fileManager.createDirectory(atPath: uninstallRoot, withIntermediateDirectories: true)
        try copyReplacing(from: uninstallerSourcePath, to: uninstallAppPath)

        if let adbargData = makeAdbargContent(for: context).data(using: .utf8) {
            try adbargData.write(to: URL(fileURLWithPath: adbargPath))
        }

        let aliasName = sanitizedAliasName(context.uninstallDisplayName, fallback: context.productName)

        try fileManager.createDirectory(atPath: adobeInstallersDir, withIntermediateDirectories: true)
        let installersAliasPath = "\(adobeInstallersDir)/\(aliasName)"
        try writeAlias(targetPath: uninstallAppPath, aliasPath: installersAliasPath)
        setOwnerToRootWheelIfInApplications(installersAliasPath)

        if let productDir = productDirectory(for: context) {
            try? fileManager.createDirectory(atPath: productDir, withIntermediateDirectories: true)
            let productAliasPath = "\(productDir)/\(aliasName)"
            try writeAlias(targetPath: uninstallAppPath, aliasPath: productAliasPath)
            setOwnerToRootWheelIfInApplications(productAliasPath)
        }

        logHandler?("[HDPIM ARP] 已创建卸载条目: \(appGuid)")
    }

    private static func makeAdbargContent(for context: HDPIMNativeProductContext) -> String {
        var lines = [
            "--sapCode=\(context.sapCode)",
            "--productVersion=\(context.codexVersion)",
            "--productPlatform=\(context.platform)"
        ]

        if let appID = context.amtConfigAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !appID.isEmpty {
            lines.append("--productAdobeCode=\(appID)")
        }

        lines.append("--productName=\(context.productName)")
        lines.append("--mode=2")

        if context.isNonCCProduct {
            lines.append("--isNonCCProduct=true")
        }

        return lines.joined(separator: "\n")
    }

    private static func productDirectory(for context: HDPIMNativeProductContext) -> String? {
        let launch = context.resolvedAppLaunchPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launch.isEmpty {
            var url = URL(fileURLWithPath: launch)
            for _ in 0..<4 {
                url = url.deletingLastPathComponent()
            }
            let path = url.path
            if !path.isEmpty, path != "/" {
                return path
            }
        }

        let installDir = context.installDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return installDir.isEmpty ? nil : installDir
    }

    private static func sanitizedAliasName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        return base.replacingOccurrences(of: "/", with: ":")
    }

    private static func copyReplacing(from source: String, to target: String) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target) {
            try fileManager.removeItem(atPath: target)
        }

        do {
            try fileManager.copyItem(atPath: source, toPath: target)
        } catch {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [source, target]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw HDPIMARPError.copyFailed(source, target)
            }
        }
    }

    private static func writeAlias(targetPath: String, aliasPath: String) throws {
        let targetURL = URL(fileURLWithPath: targetPath)
        let aliasURL = URL(fileURLWithPath: aliasPath)

        if FileManager.default.fileExists(atPath: aliasPath) {
            try FileManager.default.removeItem(at: aliasURL)
        }

        let bookmark = try targetURL.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmark, to: aliasURL)
    }

    private static func setOwnerToRootWheelIfInApplications(_ path: String) {
        guard path.hasPrefix("/Applications/") else {
            return
        }
        chown(path, 0, 0)
    }
}

enum HDPIMARPError: Error, LocalizedError {
    case uninstallerMissing(String)
    case copyFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .uninstallerMissing(let path):
            return "Uninstaller.app 不存在: \(path)"
        case .copyFailed(let source, let target):
            return "复制失败: \(source) -> \(target)"
        }
    }
}
