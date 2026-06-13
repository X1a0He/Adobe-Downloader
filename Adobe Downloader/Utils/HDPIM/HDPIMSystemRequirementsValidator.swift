import Foundation

final class HDPIMSystemRequirementsValidator {

    static func validateOSVersion(ranges: [(min: String, max: String)]) -> Bool {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let currentVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        for range in ranges {
            if isVersionInRange(currentVersion, min: range.min, max: range.max) {
                return true
            }
        }

        return false
    }

    static func checkDiskSpace(requiredBytes: Int64, path: String = "/") -> Bool {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let freeSize = attributes[.systemFreeSize] as? Int64 else {
            return false
        }

        return freeSize >= requiredBytes
    }

    static func checkMemory(requiredBytes: Int64) -> Bool {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return physicalMemory >= UInt64(requiredBytes)
    }

    private static func isVersionInRange(_ version: String, min: String, max: String) -> Bool {
        return compareVersion(version, min) >= 0 && compareVersion(version, max) <= 0
    }

    private static func compareVersion(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0

            if p1 < p2 { return -1 }
            if p1 > p2 { return 1 }
        }

        return 0
    }
}
