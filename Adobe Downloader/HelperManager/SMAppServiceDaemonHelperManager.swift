//
//  SMAppServiceDaemonHelperManager.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/12/23.
//

import AppKit
import ServiceManagement

@objcMembers
final class SMAppServiceDaemonHelperManager: NSObject, ObservableObject {
    enum HelperToolAction {
        case none
        case install
        case uninstall
        case reinstall
    }

    enum HelperStatus {
        case installed
        case noFound
        case needUpdate
    }

    static let shared = SMAppServiceDaemonHelperManager()
    static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"
    static let daemonPlistName = "\(machServiceName).plist"

    var connectionSuccessBlock: (() -> Void)?

    private var connection: NSXPCConnection?
    private var shouldAutoReconnect = true
    private var autoReconnectTimer: Timer?
    private var isAutoRecoveringDesync = false
    private let connectionQueue = DispatchQueue(label: "com.x1a0he.helper.connection")

    @Published private(set) var isHelperToolInstalled: Bool = false
    @Published private(set) var message: String = String(localized: "检测中...")
    @Published private(set) var isInitialCheckComplete: Bool = false

    @Published private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            if oldValue != connectionState, connectionState == .disconnected {
                connection?.invalidate()
                connection = nil
            }
        }
    }

    enum ConnectionState {
        case connected
        case disconnected
        case connecting

        var description: String {
            switch self {
            case .connected:
                return String(localized: "已连接")
            case .disconnected:
                return String(localized: "未连接")
            case .connecting:
                return String(localized: "正在连接")
            }
        }
    }

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionInvalidation),
            name: .NSXPCConnectionInvalid,
            object: nil
        )
    }

    private func updateOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    @objc private func handleConnectionInvalidation() {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .disconnected
            self?.connection?.invalidate()
            self?.connection = nil
        }
    }

    private var daemonService: SMAppService {
        SMAppService.daemon(plistName: Self.daemonPlistName)
    }

    private func daemonPlistExistsInBundle() -> Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(Self.daemonPlistName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func helperExecutableExistsInBundle() -> Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices")
            .appendingPathComponent(Self.machServiceName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func isRunningFromInstalledAppLocation() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.hasPrefix("/Applications/") { return true }
        let userApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .path
        return bundlePath.hasPrefix(userApplicationsPath + "/")
    }

    private func isOperationNotPermittedError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == 1 { return true }
        if error.localizedDescription.range(of: "Operation not permitted", options: [.caseInsensitive]) != nil { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOperationNotPermittedError(underlying)
        }
        return false
    }

    func checkInstall() {
        Task { [weak self] in
            await self?.manageHelperTool(action: .none)
        }
    }

    func getHelperStatus(callback: @escaping ((HelperStatus) -> Void)) {
        var called = false
        let reply: ((HelperStatus) -> Void) = { status in
            if called { return }
            called = true
            callback(status)
        }

        guard daemonPlistExistsInBundle(), helperExecutableExistsInBundle() else {
            reply(.noFound)
            return
        }

        switch daemonService.status {
        case .enabled:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let worksAsRoot = self.connectToHelper() != nil
                DispatchQueue.main.async {
                    reply(worksAsRoot ? .installed : .needUpdate)
                }
            }
        case .requiresApproval:
            reply(.noFound)
        case .notRegistered:
            reply(.noFound)
        case .notFound:
            reply(.noFound)
        @unknown default:
            reply(.noFound)
        }
    }

    func manageHelperTool(action: HelperToolAction = .none) async {
        let service = daemonService
        var occurredError: NSError?

        if action == .none,
           service.status == .enabled,
           let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           let installedBuild = UserDefaults.standard.string(forKey: "InstalledHelperBuild"),
           currentBuild != installedBuild {
            updateOnMain {
                self.message = String(localized: "检测到版本更新，正在更新后台服务…")
            }
            await manageHelperTool(action: .reinstall)
            return
        }

        switch action {
        case .install:
            switch service.status {
            case .requiresApproval:
                updateOnMain {
                    self.message = String(localized: "已注册，但需要在「系统设置 → 登录项」中允许后台运行。")
                }
                SMAppService.openSystemSettingsLoginItems()
            case .enabled:
                let worksAsRoot = connectToHelper() != nil
                if !worksAsRoot {
                    updateOnMain {
                        self.message = String(localized: "服务状态异常（已启用但无法使用），正在尝试修复…")
                    }
                    await manageHelperTool(action: .reinstall)
                    return
                }
                updateOnMain {
                    self.message = String(localized: "后台服务已启用。")
                }
            default:
                do {
                    try service.register()
                    if service.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } catch let nsError as NSError {
                    occurredError = nsError
                    if isOperationNotPermittedError(nsError) {
                        updateOnMain {
                            self.message = String(localized: "权限不足。请在「系统设置 → 登录项」中允许后台运行。")
                        }
                        SMAppService.openSystemSettingsLoginItems()
                    } else {
                        updateOnMain {
                            self.message = String(localized: "注册后台服务失败: \(nsError.localizedDescription)")
                        }
                    }
                }
            }

        case .uninstall:
            do {
                try await service.unregister()
                disconnectHelper()
            } catch let nsError as NSError {
                occurredError = nsError
            }

        case .reinstall:
            do {
                try await service.unregister()
                disconnectHelper()
            } catch {
                
            }

            try? await Task.sleep(nanoseconds: 500_000_000)

            do {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch let nsError as NSError {
                occurredError = nsError
            }

        case .none:
            break
        }

        let didStartRecovery = await updateStatusMessages(with: service, occurredError: occurredError, currentAction: action)
        if didStartRecovery { return }

        let isEnabled = (service.status == .enabled)
        let worksAsRoot = isEnabled && (connectToHelper() != nil)

        updateOnMain {
            self.isHelperToolInstalled = worksAsRoot
            self.isInitialCheckComplete = true
        }

        if worksAsRoot {
            updateOnMain { [weak self] in
                self?.connectionSuccessBlock?()
            }
        }

        if worksAsRoot, let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            UserDefaults.standard.set(currentBuild, forKey: "InstalledHelperBuild")
        }
    }

    static var getHelperStatus: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(Self.daemonPlistName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices")
            .appendingPathComponent(Self.machServiceName)
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return false }

        return SMAppService.daemon(plistName: Self.daemonPlistName).status == .enabled
    }

    func enableHelperService(completion: @escaping (Bool, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            await self.manageHelperTool(action: .install)
            await MainActor.run {
                completion(self.isHelperToolInstalled, self.message)
            }
        }
    }

    func disableHelperService(completion: @escaping (Bool, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            await self.manageHelperTool(action: .uninstall)
            await MainActor.run {
                let ok = (self.daemonService.status != .enabled)
                completion(ok, ok ? String(localized: "后台服务已关闭") : self.message)
            }
        }
    }

    func reinstallHelper(completion: @escaping (Bool, String) -> Void) {
        shouldAutoReconnect = false

        uninstallLegacySMJobBlessIfNeeded { [weak self] legacyUninstallSuccess, legacyMessage in
            guard let self else { return }

            Task { [weak self] in
                guard let self else { return }
                await self.manageHelperTool(action: .reinstall)
                self.shouldAutoReconnect = true

                let ok = self.isHelperToolInstalled
                let baseMessage = ok ? String(localized: "Helper 启用成功") : self.message
                let finalMessage = legacyUninstallSuccess ? baseMessage : "\(baseMessage)\n\(legacyMessage)"
                await MainActor.run {
                    completion(ok, finalMessage)
                }
            }
        }
    }

    private func uninstallLegacySMJobBlessIfNeeded(completion: @escaping (Bool, String) -> Void) {
        let legacyLaunchDaemon = "/Library/LaunchDaemons/\(Self.machServiceName).plist"
        let legacyHelperTool = "/Library/PrivilegedHelperTools/\(Self.machServiceName)"

        guard FileManager.default.fileExists(atPath: legacyLaunchDaemon) || FileManager.default.fileExists(atPath: legacyHelperTool) else {
            completion(true, "")
            return
        }

        let script = """
        #!/bin/bash
        sudo /bin/launchctl unload \(legacyLaunchDaemon) >/dev/null 2>&1 || true
        sudo /bin/rm -f \(legacyLaunchDaemon) || true
        sudo /bin/rm -f \(legacyHelperTool) || true
        sudo /usr/bin/killall -u root -9 \(Self.machServiceName) >/dev/null 2>&1 || true
        exit 0
        """

        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("uninstall_legacy_helper.sh")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"\(scriptURL.path)\" with administrator privileges"]

            let errorPipe = Pipe()
            task.standardError = errorPipe

            do {
                try task.run()
                task.waitUntilExit()

                if task.terminationStatus == 0 {
                    completion(true, String(localized: "已检测到旧版 Helper，已完成卸载"))
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? "未知错误"
                    completion(false, String(localized: "检测到旧版 Helper，但卸载失败: \(errorString)"))
                }
            } catch {
                completion(false, String(localized: "卸载旧版 Helper 失败: \(error.localizedDescription)"))
            }

            try? FileManager.default.removeItem(at: scriptURL)
        } catch {
            completion(false, String(localized: "准备卸载旧版 Helper 脚本失败: \(error.localizedDescription)"))
        }
    }

    private func setupAutoReconnect() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.connectionState == .disconnected && self.shouldAutoReconnect {
                _ = self.connectToHelper()
            }
        }
    }

    func reconnectHelper(completion: @escaping (Bool, String) -> Void) {
        shouldAutoReconnect = true

        connectionQueue.async { [weak self] in
            guard let self else { return }

            if let existingConnection = self.connection {
                existingConnection.invalidate()
            }
            self.connection = nil

            let ok = (self.createConnection() != nil)
            DispatchQueue.main.async {
                completion(ok, ok ? String(localized: "连接已重新创建") : String(localized: "无法创建连接"))
            }
        }
    }

    func removeInstallHelper(completion: ((Bool) -> Void)? = nil) {
        disableHelperService { success, _ in
            if success {
                UserDefaults.standard.removeObject(forKey: "InstalledHelperBuild")
            }
            completion?(success)
        }
    }

    func forceCleanAndReinstallHelper(completion: @escaping (Bool, String) -> Void) {
        UserDefaults.standard.removeObject(forKey: "InstalledHelperBuild")
        reinstallHelper(completion: completion)
    }

    func disconnectHelper() {
        connectionQueue.sync {
            shouldAutoReconnect = false
            connection?.invalidate()
            connection = nil
            connectionState = .disconnected
        }
    }

    func uninstallHelperViaTerminal(completion: @escaping (Bool, String) -> Void) {
        disableHelperService { success, message in
            if success {
                UserDefaults.standard.removeObject(forKey: "InstalledHelperBuild")
            }
            completion(success, message)
        }
    }

    func connectToHelper() -> NSXPCConnection? {
        connectionQueue.sync {
            createConnection()
        }
    }

    private func createConnection() -> NSXPCConnection? {
        DispatchQueue.main.async {
            self.connectionState = .connecting
        }

        if let existingConnection = connection {
            existingConnection.invalidate()
            connection = nil
        }

        let newConnection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)

        let interface = NSXPCInterface(with: HelperToolProtocol.self)
        interface.setClasses(
            NSSet(array: [NSString.self, NSNumber.self]) as! Set<AnyHashable>,
            for: #selector(HelperToolProtocol.executeCommand(type:path1:path2:permissions:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        newConnection.remoteObjectInterface = interface

        newConnection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connectionState = .disconnected
                self?.connection = nil
            }
        }

        newConnection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connectionState = .disconnected
                self?.connection = nil
            }
        }

        newConnection.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var isConnected = false

        if let helper = newConnection.remoteObjectProxy as? HelperToolProtocol {
            helper.executeCommand(type: .shellCommand, path1: "whoami", path2: "", permissions: 0) { [weak self] result in
                let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedResult == "root" {
                    isConnected = true
                    DispatchQueue.main.async {
                        self?.connection = newConnection
                        self?.connectionState = .connected
                    }
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.0)
        }

        if !isConnected {
            newConnection.invalidate()
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
            return nil
        }

        return newConnection
    }

    public func getHelperProxy() throws -> HelperToolProtocol {
        guard let connection = connectToHelper() else {
            throw HelperError.connectionFailed
        }

        guard let helper = connection.remoteObjectProxy as? HelperToolProtocol else {
            throw HelperError.proxyError
        }

        return helper
    }

    private func tryConnect(retryCount: Int, delay: TimeInterval = 2.0, completion: @escaping (Bool, String) -> Void) {
        struct Static {
            static var currentAttempt = 0
        }

        if retryCount == 3 {
            Static.currentAttempt = 0
        }

        Static.currentAttempt += 1

        guard retryCount > 0 else {
            completion(false, String(localized: "多次尝试连接失败"))
            return
        }

        guard connectToHelper() != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tryConnect(retryCount: retryCount - 1, delay: delay, completion: completion)
            }
            return
        }

        completion(true, String(localized: "Helper 启用成功"))
    }

    private func updateStatusMessages(with service: SMAppService, occurredError: NSError?, currentAction: HelperToolAction) async -> Bool {
        if let nsError = occurredError {
            updateOnMain {
                self.message = String(localized: "操作失败: \(nsError.localizedDescription)")
            }
            return false
        }

        switch service.status {
        case .notRegistered:
            updateOnMain {
                self.message = String(localized: "后台服务尚未注册，你可以选择现在注册。")
            }
        case .enabled:
            let worksAsRoot = connectToHelper() != nil
            if !worksAsRoot {
                updateOnMain {
                    self.message = String(localized: "服务状态异常（已启用但无法使用），正在尝试修复…")
                }
                guard currentAction != .reinstall else { return false }
                guard !isAutoRecoveringDesync else { return false }
                isAutoRecoveringDesync = true
                await manageHelperTool(action: .reinstall)
                isAutoRecoveringDesync = false
                return true
            }

            updateOnMain {
                self.message = String(localized: "后台服务已启用并可用。")
            }
        case .requiresApproval:
            updateOnMain {
                self.message = String(localized: "后台服务已注册，但需要在「系统设置 → 登录项」中允许后台运行。")
            }
        case .notFound:
            updateOnMain {
                self.message = String(localized: "后台服务未安装。")
            }
        @unknown default:
            updateOnMain {
                self.message = String(localized: "未知服务状态（\(service.status.rawValue)）。")
            }
        }

        return false
    }

    func executeCommand(_ command: String, completion: @escaping (String) -> Void) {
        HelperExecutionLogStore.shared.append(kind: .command, command: command, result: "")
        do {
            let helper = try getHelperProxy()

            if command.contains("perl") || command.contains("codesign") || command.contains("xattr") {
                helper.executeCommand(type: .shellCommand, path1: command, path2: "", permissions: 0) { [weak self] result in
                    DispatchQueue.main.async {
                        if result.starts(with: "Error:") {
                            self?.connectionState = .disconnected
                        } else {
                            self?.connectionState = .connected
                        }
                        HelperExecutionLogStore.shared.append(
                            kind: .output,
                            command: command,
                            result: result,
                            isError: result.starts(with: "Error:")
                        )
                        completion(result)
                    }
                }
                return
            }

            let (type, path1, path2, permissions) = parseCommand(command)
            helper.executeCommand(type: type, path1: path1, path2: path2, permissions: permissions) { [weak self] result in
                DispatchQueue.main.async {
                    if result.starts(with: "Error:") {
                        self?.connectionState = .disconnected
                    } else {
                        self?.connectionState = .connected
                    }
                    HelperExecutionLogStore.shared.append(
                        kind: .output,
                        command: command,
                        result: result,
                        isError: result.starts(with: "Error:")
                    )
                    completion(result)
                }
            }
        } catch {
            connectionState = .disconnected
            let result = "Error: \(error.localizedDescription)"
            HelperExecutionLogStore.shared.append(kind: .output, command: command, result: result, isError: true)
            completion(result)
        }
    }

    private func parseCommand(_ command: String) -> (CommandType, String, String, Int) {
        let components = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        if command.hasPrefix("installer -pkg") {
            return (.install, components[2], "", 0)
        } else if command.hasPrefix("rm -rf") {
            let path = components.dropFirst(2).joined(separator: " ")
            return (.uninstall, path, "", 0)
        } else if command.hasPrefix("mv") || command.hasPrefix("cp") {
            let paths = components.dropFirst(1)
            let sourcePath = String(paths.first ?? "")
            let destPath = paths.dropFirst().joined(separator: " ")
            return (.moveFile, sourcePath, destPath, 0)
        } else if command.hasPrefix("chmod") {
            return (
                .setPermissions,
                components.dropFirst(2).joined(separator: " "),
                "",
                Int(components[1]) ?? 0
            )
        }

        return (.shellCommand, command, "", 0)
    }

    func executeInstallation(_ command: String, progress: @escaping (String) -> Void) async throws {
        HelperExecutionLogStore.shared.append(kind: .command, command: command, result: "")
        var logBuffer = ""

        do {
        let helper: HelperToolProtocol = try connectionQueue.sync {
            if let existingConnection = connection,
               let proxy = existingConnection.remoteObjectProxy as? HelperToolProtocol {
                return proxy
            }

            guard let newConnection = createConnection() else {
                throw HelperError.connectionFailed
            }

            connection = newConnection

            guard let proxy = newConnection.remoteObjectProxy as? HelperToolProtocol else {
                throw HelperError.proxyError
            }

            return proxy
        }

        let (type, path1, path2, permissions) = parseCommand(command)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helper.executeCommand(type: type, path1: path1, path2: path2, permissions: permissions) { result in
                if result == "Started" || result == "Success" {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HelperError.installationFailed(result))
                }
            }
        }

        while true {
            let output = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                helper.getInstallationOutput { result in
                    continuation.resume(returning: result)
                }
            }

            if !output.isEmpty {
                progress(output)
                logBuffer.append(output)
                if !output.hasSuffix("\n") { logBuffer.append("\n") }
            }

            if output.contains("Exit Code:") || output.range(of: "Progress: \\d+/\\d+", options: .regularExpression) != nil {
                if output.range(of: "Progress: \\d+/\\d+", options: .regularExpression) != nil {
                    progress("Exit Code: 0")
                    logBuffer.append("Exit Code: 0\n")
                }
                break
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let normalized = logBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        HelperExecutionLogStore.shared.append(
            kind: .output,
            command: command,
            result: normalized.isEmpty ? "Success" : normalized,
            isError: false
        )
        } catch {
            let message: String
            let normalized = logBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                message = "Error: \(error.localizedDescription)"
            } else {
                message = "\(normalized)\nError: \(error.localizedDescription)"
            }
            HelperExecutionLogStore.shared.append(kind: .output, command: command, result: message, isError: true)
            throw error
        }
    }
}
