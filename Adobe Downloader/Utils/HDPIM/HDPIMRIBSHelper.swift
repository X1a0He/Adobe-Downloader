//
//  HDPIMRIBSHelper.swift
//  Adobe Downloader
//
//  RIBS (Reference Install Base System) dependency management
//  Based on IDA analysis of official HDPIM implementation
//

import Foundation

class HDPIMRIBSHelper {

    private static let ribsDBPath = URL(fileURLWithPath: HDPIMRuntimeEnvironment.userHomeDirectory())
        .appendingPathComponent("Library/Application Support/Adobe/AAMUpdater/Installers/RIBSCoExist")

    static func addRIBSDependency(
        ribsCode: String,
        sapCode: String,
        baseVersion: String,
        productName: String
    ) -> Bool {
        guard !ribsCode.isEmpty else { return false }

        let dependency = "\(sapCode)\(baseVersion)"
        let ribsPath = ribsDBPath.appendingPathComponent(ribsCode)

        do {
            try FileManager.default.createDirectory(at: ribsDBPath, withIntermediateDirectories: true)

            let record = [
                "dependency": dependency,
                "product": productName,
                "baseVersion": baseVersion,
                "timestamp": Date().timeIntervalSince1970
            ] as [String: Any]

            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: ribsPath.appendingPathComponent("dependency.json"))

            mergeMediaDB(ribsPath: ribsPath)

            return true
        } catch {
            return false
        }
    }

    static func removeRIBSDependency(
        ribsCode: String,
        sapCode: String,
        baseVersion: String
    ) -> Bool {
        guard !ribsCode.isEmpty else { return false }

        let ribsPath = ribsDBPath.appendingPathComponent(ribsCode)

        if isRIBSDependent(ribsCode: ribsCode) {
            return true
        }

        if isInstalledViaHDOnly(ribsPath: ribsPath) {
            return cleanupMediaDB(ribsPath: ribsPath)
        }

        mergeMediaDB(ribsPath: ribsPath)
        return uninstallRIBSPayload(ribsCode: ribsCode)
    }

    private static func isRIBSDependent(ribsCode: String) -> Bool {
        let ribsPath = ribsDBPath.appendingPathComponent(ribsCode)
        let refCountPath = ribsPath.appendingPathComponent("refcount.json")

        guard let data = try? Data(contentsOf: refCountPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let count = json["count"] else {
            return false
        }

        return count > 1
    }

    private static func isInstalledViaHDOnly(ribsPath: URL) -> Bool {
        !FileManager.default.fileExists(atPath: ribsPath.path)
    }

    private static func mergeMediaDB(ribsPath: URL) {
        let mediaDBPath = ribsPath.appendingPathComponent("media.db")
        guard FileManager.default.fileExists(atPath: mediaDBPath.path) else { return }

        _ = try? FileManager.default.copyItem(
            at: mediaDBPath,
            to: FileManager.default.temporaryDirectory.appendingPathComponent("merged_\(UUID().uuidString).db")
        )
    }

    private static func cleanupMediaDB(ribsPath: URL) -> Bool {
        let mediaDBPath = ribsPath.appendingPathComponent("media.db")
        guard FileManager.default.fileExists(atPath: mediaDBPath.path) else { return true }

        return (try? FileManager.default.removeItem(at: mediaDBPath)) != nil
    }

    private static func uninstallRIBSPayload(ribsCode: String) -> Bool {
        let ribsPath = ribsDBPath.appendingPathComponent(ribsCode)
        guard FileManager.default.fileExists(atPath: ribsPath.path) else { return true }

        return (try? FileManager.default.removeItem(at: ribsPath)) != nil
    }
}
