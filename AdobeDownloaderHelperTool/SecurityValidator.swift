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

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCodeRef = staticCode else {
            return false
        }

        let bundleID = "com.x1a0he.macOS.Adobe-Downloader"
        let requirementString = "identifier \"\(bundleID)\" and anchor apple generic"

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        ) == errSecSuccess, let req = requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(staticCodeRef, [], req) == errSecSuccess
    }
}
