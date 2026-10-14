import Foundation
import Security

final class SecurityValidator {

    static let allowedPaths: [String] = [
        "/Library/Application Support/Adobe",
        "/Applications",
        "/.adobeTemp",
        "/tmp"
    ]

    static let forbiddenPaths: [String] = [
        "/System",
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
        "/private/var/db"
    ]

    static func validatePath(_ path: String) -> Bool {
        let cleanPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))

        guard !cleanPath.isEmpty else { return false }

        for forbidden in forbiddenPaths {
            if isPath(cleanPath, inside: forbidden) {
                return false
            }
        }

        for allowed in allowedPaths {
            if isPath(cleanPath, inside: allowed) {
                return true
            }
        }

        return false
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }

    static func validateClientConnection(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            [],
            &codeRef
        ) == errSecSuccess, let code = codeRef else {
            return false
        }

        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownInfo: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess,
              let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
              let ownStaticCode,
              SecCodeCopySigningInformation(ownStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
              let info = ownInfo as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty,
              teamID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }

        let bundleID = "com.x1a0he.macOS.Adobe-Downloader"
        let requirementString = "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        ) == errSecSuccess, let req = requirement else {
            return false
        }

        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
