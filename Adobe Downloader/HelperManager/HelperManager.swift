import Foundation
import ServiceManagement
import os.log

@MainActor
final class HelperManager: ObservableObject {
    static let shared = HelperManager()

    private static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"
    private static let daemonPlistName = "\(machServiceName).plist"

    private let client = HelperClient()
    private let logger = Logger(subsystem: "com.x1a0he.macOS.Adobe-Downloader", category: "HelperManager")

    @Published private(set) var isInstalled = false
    @Published private(set) var status: String = "检查中..."

    private init() {}

    var service: SMAppService {
        SMAppService.daemon(plistName: Self.daemonPlistName)
    }

    func checkStatus() async {
        status = "检查中..."

        guard isRunningFromValidLocation() else {
            status = "应用必须从 /Applications 运行"
            isInstalled = false
            return
        }

        await checkAndMigrateLegacyHelper()

        switch service.status {
        case .enabled:
            let canConnect = await testConnection()
            isInstalled = canConnect
            status = canConnect ? "已启用" : "服务异常，需要重装"

        case .requiresApproval:
            status = "需要在系统设置中授权"
            isInstalled = false

        case .notRegistered, .notFound:
            status = "未安装"
            isInstalled = false

        @unknown default:
            status = "未知状态"
            isInstalled = false
        }
    }

    func install() async throws {
        guard isRunningFromValidLocation() else {
            throw HelperError.operationFailed("应用必须从 /Applications 运行")
        }

        try service.register()

        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            status = "请在系统设置中授权"
            throw HelperError.notAuthorized
        }

        await checkStatus()

        if !isInstalled {
            throw HelperError.installationFailed("安装后验证失败")
        }

        saveInstalledVersion()
    }

    func uninstall() async throws {
        try await service.unregister()
        client.disconnect()
        clearInstalledVersion()
        await checkStatus()
    }

    func reinstall() async throws {
        do {
            try await uninstall()
        } catch {
            logger.warning("卸载时出现错误: \(error.localizedDescription)")
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await install()
    }

    func getClient() throws -> HelperClient {
        guard isInstalled else {
            throw HelperError.notInstalled
        }
        return client
    }

    private func testConnection() async -> Bool {
        do {
            let conn = try client.connect()
            return conn.remoteObjectProxy != nil
        } catch {
            return false
        }
    }

    private func isRunningFromValidLocation() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        return bundlePath.hasPrefix("/Applications/")
    }

    private func saveInstalledVersion() {
        if let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            UserDefaults.standard.set(version, forKey: "InstalledHelperVersion")
        }
    }

    private func clearInstalledVersion() {
        UserDefaults.standard.removeObject(forKey: "InstalledHelperVersion")
    }

    private func checkAndMigrateLegacyHelper() async {
        let legacyPlist = "/Library/LaunchDaemons/\(Self.machServiceName).plist"
        let legacyHelper = "/Library/PrivilegedHelperTools/\(Self.machServiceName)"

        guard FileManager.default.fileExists(atPath: legacyPlist) ||
              FileManager.default.fileExists(atPath: legacyHelper) else {
            return
        }

        logger.notice("检测到旧版 Helper，尝试清理")

        let script = """
        #!/bin/bash
        sudo /bin/launchctl unload \(legacyPlist) 2>/dev/null || true
        sudo /bin/rm -f \(legacyPlist) || true
        sudo /bin/rm -f \(legacyHelper) || true
        sudo /usr/bin/killall -9 \(Self.machServiceName) 2>/dev/null || true
        exit 0
        """

        do {
            try await executeSudoScript(script)
            logger.notice("旧版 Helper 已清理")
        } catch {
            logger.error("清理旧版 Helper 失败: \(error.localizedDescription)")
        }
    }

    private func executeSudoScript(_ script: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("helper_migration_\(UUID().uuidString).sh")

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(scriptURL.path)\" with administrator privileges"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw HelperError.operationFailed("迁移脚本执行失败")
        }
    }
}
