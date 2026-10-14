import Foundation
import ServiceManagement
import os.log

@MainActor
final class HelperManager: ObservableObject {
    static let shared = HelperManager()

    static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"
    private static let daemonPlistName = "\(machServiceName).plist"

    private let client = HelperClient()
    private let logger = Logger(subsystem: "com.x1a0he.macOS.Adobe-Downloader", category: "HelperManager")
    private var refreshTask: Task<Void, Never>?
    private var lastError: NSError?

    @Published private(set) var state: HelperServiceState = .checking
    @Published private(set) var isBusy = false
    @Published private(set) var legacyPaths: [String] = []
    @Published private(set) var migrationReport = ""
    @Published private(set) var errorDetails = ""

    var isInstalled: Bool { state == .enabled }
    var status: String { [state.guidance, errorDetails].filter { !$0.isEmpty }.joined(separator: "\n") }

    private init() {}

    var service: SMAppService {
        SMAppService.daemon(plistName: Self.daemonPlistName)
    }

    var diagnostics: String {
        """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App: \(Bundle.main.bundleURL.path)
        Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))
        Service: \(Self.machServiceName)
        System status: \(service.status.rawValue)
        State: \(state.title)
        \(status)
        Legacy files: \(legacyPaths.joined(separator: ", "))
        \(migrationReport)
        """
    }

    /// 刷新只读取注册状态；旧版迁移只能由用户明确触发。
    func checkStatus() async {
        guard !isBusy else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await self.refreshStatus() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func refreshStatus() async {
        legacyPaths = HelperLegacyMigration.existingPaths
        if !legacyPaths.isEmpty {
            state = .legacyDetected
            return
        }
        if let issue = bundleIssue() {
            state = .invalidBundle
            errorDetails = issue
            return
        }

        switch service.status {
        case .enabled:
            do {
                try await client.checkConnection()
                clearError()
                state = .enabled
                saveInstalledVersion()
            } catch {
                record(error)
                state = .connectionFailed
            }
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered:
            // 失败原因在用户返回系统设置或界面刷新时仍需可见。
            state = lastError.map(classifyRegistrationError) ?? .notRegistered
        case .notFound:
            state = lastError.map(classifyRegistrationError) ?? .notFound
        @unknown default:
            state = .registrationFailed
        }
    }

    func install() async throws {
        guard !isBusy else { throw HelperError.operationFailed(AppLocalized("Helper 正在处理其他操作，请稍后重试。")) }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        try await registerService()
    }

    private func registerService() async throws {
        clearError()
        legacyPaths = HelperLegacyMigration.existingPaths
        guard legacyPaths.isEmpty else {
            state = .legacyDetected
            throw HelperError.operationFailed(state.guidance)
        }
        if let issue = bundleIssue() {
            state = .invalidBundle
            errorDetails = issue
            throw HelperError.operationFailed(status)
        }
        // 等待授权时重复注销、注册并不能替用户打开系统开关。
        if service.status == .requiresApproval {
            state = .requiresApproval
            openBackgroundSettings()
            return
        }
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                record(error)
                let failure = classifyRegistrationError(error as NSError)
                if service.status == .requiresApproval || failure == .requiresApproval {
                    state = .requiresApproval
                    openBackgroundSettings()
                    return
                }
                if !isServiceError(error as NSError, code: kSMErrorAlreadyRegistered) {
                    state = failure
                    throw error
                }
            }
        }
        await refreshStatus()
        if state == .requiresApproval {
            openBackgroundSettings()
        } else if !isInstalled {
            throw HelperError.installationFailed(status)
        }
    }

    func uninstall() async throws {
        guard !isBusy else { throw HelperError.operationFailed(AppLocalized("Helper 正在处理其他操作，请稍后重试。")) }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        try await unregisterService()
        await refreshStatus()
    }

    private func unregisterService() async throws {
        do {
            try await service.unregister()
        } catch {
            if !isServiceError(error as NSError, code: kSMErrorJobNotFound) {
                record(error)
                state = .registrationFailed
                throw error
            }
        }
        client.disconnect()
        UserDefaults.standard.removeObject(forKey: "InstalledHelperVersion")
        clearError()
    }

    func reinstall() async throws {
        guard !isBusy else { throw HelperError.operationFailed(AppLocalized("Helper 正在处理其他操作，请稍后重试。")) }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        if service.status == .requiresApproval {
            state = .requiresApproval
            openBackgroundSettings()
            return
        }
        try await unregisterService()
        try await registerService()
    }

    func reconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        client.disconnect()
        await refreshStatus()
    }

    func migrateLegacyHelper() async throws {
        guard !isBusy else { throw HelperError.operationFailed(AppLocalized("Helper 正在处理其他操作，请稍后重试。")) }
        isBusy = true
        defer { isBusy = false }
        await refreshTask?.value
        do {
            migrationReport = try await HelperLegacyMigration.migrate()
        } catch {
            record(error)
            legacyPaths = HelperLegacyMigration.existingPaths
            state = legacyPaths.isEmpty ? .registrationFailed : .legacyDetected
            throw error
        }
        client.disconnect()
        try await registerService()
    }

    func openBackgroundSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func getClient() throws -> HelperClient {
        guard isInstalled else { throw HelperError.operationFailed(status) }
        return client
    }

    private func classifyRegistrationError(_ error: NSError) -> HelperServiceState {
        if isServiceError(error, code: kSMErrorLaunchDeniedByUser) { return .requiresApproval }
        if isServiceError(error, code: kSMErrorInvalidSignature) { return .invalidSignature }
        if isServiceError(error, code: kSMErrorInvalidPlist) || isServiceError(error, code: kSMErrorToolNotValid) || isServiceError(error, code: kSMErrorJobPlistNotFound) {
            return .invalidBundle
        }
        return .registrationFailed
    }

    private func isServiceError(_ error: NSError, code: Int) -> Bool {
        error.domain == (kSMErrorDomainFramework as String) && error.code == code
    }

    private func record(_ error: Error) {
        let error = error as NSError
        lastError = error
        errorDetails = "\(error.localizedDescription) [\(error.domain):\(error.code)]"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            errorDetails += "\n\(underlying.localizedDescription) [\(underlying.domain):\(underlying.code)]"
        }
        logger.error("Helper: \(self.errorDetails, privacy: .public)")
    }

    private func clearError() {
        lastError = nil
        errorDetails = ""
    }

    private func bundleIssue() -> String? {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let plistURL = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(Self.daemonPlistName)")
        do {
            let data = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  plist["Label"] as? String == Self.machServiceName,
                  let program = plist["BundleProgram"] as? String,
                  !program.hasPrefix("/"),
                  (plist["MachServices"] as? [String: Bool])?[Self.machServiceName] == true else {
                return AppLocalized("Helper 服务配置不完整，请重新下载完整应用。") + "\n\(plistURL.path)"
            }
            let helper = bundle.appendingPathComponent(program).resolvingSymlinksInPath()
            guard helper.path.hasPrefix(bundle.path + "/"), FileManager.default.isExecutableFile(atPath: helper.path) else {
                return AppLocalized("Helper 可执行文件缺失或不在当前 App 内。") + "\n\(helper.path)"
            }
            return nil
        } catch {
            return "\(plistURL.path)\n\(error.localizedDescription)"
        }
    }

    private func saveInstalledVersion() {
        if let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            UserDefaults.standard.set(version, forKey: "InstalledHelperVersion")
        }
    }
}
