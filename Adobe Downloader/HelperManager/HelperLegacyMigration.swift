import Foundation

/// 只迁移历史版本的两个固定路径，原文件移存到 root 专属备份目录以便恢复。
enum HelperLegacyMigration {
    private static let label = "com.x1a0he.macOS.Adobe-Downloader.helper"
    private static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    private static let toolPath = "/Library/PrivilegedHelperTools/\(label)"

    static var existingPaths: [String] {
        [plistPath, toolPath].filter {
            (try? FileManager.default.attributesOfItem(atPath: $0)) != nil
        }
    }

    static func migrate() async throws -> String {
        guard !existingPaths.isEmpty else { return "" }
        let script = """
        set -eu
        plist='\(plistPath)'
        tool='\(toolPath)'
        for path in /Library/LaunchDaemons /Library/PrivilegedHelperTools "$plist" "$tool"; do
            if [ -L "$path" ]; then echo "Refusing symbolic link: $path" >&2; exit 1; fi
        done
        if [ -e "$plist" ]; then
            [ -f "$plist" ] || exit 1
            [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" = '\(label)' ] || exit 1
        fi
        if [ -e "$tool" ]; then [ -f "$tool" ] || exit 1; fi
        /bin/mkdir -p /Library/PrivilegedHelperTools
        backup=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/AdobeDownloaderHelperBackup.XXXXXXXX)
        /bin/chmod 700 "$backup"
        echo "Backup: $backup"
        if /bin/launchctl print 'system/\(label)' >/dev/null 2>&1; then
            /bin/launchctl bootout 'system/\(label)'
        fi
        if [ -e "$plist" ]; then /bin/mv -n "$plist" "$backup/\(label).plist"; fi
        if [ -e "$tool" ]; then /bin/mv -n "$tool" "$backup/\(label)"; fi
        [ ! -e "$plist" ] && [ ! -e "$tool" ]
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationStatus == 0 else {
                        throw HelperError.operationFailed(output)
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
