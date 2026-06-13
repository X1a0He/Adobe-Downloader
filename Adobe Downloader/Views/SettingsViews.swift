//
//  SettingsViews.swift
//
//  Created by X1a0He on 2024/10/30.
//

import SwiftUI
import Sparkle
import Combine


private enum AboutViewConstants {
    static let appIconSize: CGFloat = 96
    static let titleFontSize: CGFloat = 18
    static let subtitleFontSize: CGFloat = 14
    static let linkFontSize: CGFloat = 14
    static let licenseFontSize: CGFloat = 12

    static let verticalSpacing: CGFloat = 12
    static let formPadding: CGFloat = 8

    static let links: [(title: String, url: String)] = [
        ("@X1a0He", "https://t.me/X1a0He_bot"),
        ("Github: Adobe Downloader", "https://github.com/X1a0He/Adobe-Downloader"),
    ]
}

struct SettingSection<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.9))
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.windowBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )

            if let footer = footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.75))
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let iconTint: Color?
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill((iconTint ?? .secondary).opacity(0.14))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(iconTint ?? .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.9))
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SettingRowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 12)
            .opacity(0.5)
    }
}

struct SettingsStatusChip: View {
    let icon: String?
    let text: String
    let tint: Color

    init(icon: String? = nil, text: String, tint: Color = .secondary) {
        self.icon = icon
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(tint)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        )
    }
}

enum FullDiskAccessPermission {
    static var isGranted: Bool {
        protectedProbePaths.contains { canAccessProtectedPath($0) }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func helperIsGranted() async -> Bool? {
        do {
            let output = try await HelperManager.shared.executeShell(helperProbeCommand)
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "granted"
        } catch {
            return nil
        }
    }

    private static var helperProbeCommand: String {
        let checks = protectedProbePaths.map { path in
            let quotedPath = shellQuoted(path)
            return "p=\(quotedPath); if [ -e \"$p\" ]; then if [ -d \"$p\" ]; then /bin/ls \"$p\" >/dev/null 2>&1 && /bin/echo granted && exit 0; else /bin/cat \"$p\" >/dev/null 2>&1 && /bin/echo granted && exit 0; fi; fi"
        }
        return (checks + ["/bin/echo denied"]).joined(separator: "; ")
    }

    private static var protectedProbePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari",
            "\(home)/Library/Messages",
            "\(home)/Library/Mail",
            "\(home)/Library/Containers/com.apple.Safari"
        ]
    }

    private static func canAccessProtectedPath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }

        try? handle.close()
        return true
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct X1a0HeCCInstallStatus {
    let isInstalled: Bool
    let hdBoxVersion: String
    let ipcBoxVersion: String

    var statusText: String {
        isInstalled ? String(localized: "已安装") : String(localized: "未安装")
    }

    var statusIcon: String {
        isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var statusTint: Color {
        isInstalled ? .green : .orange
    }

    var subtitle: String {
        guard isInstalled else {
            return String(localized: "下载 HDBox 和 IPCBox 组件")
        }

        return "HDBox \(displayVersion(hdBoxVersion)) / IPCBox \(displayVersion(ipcBoxVersion))"
    }

    static func detect() -> X1a0HeCCInstallStatus {
        let baseURL = URL(fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common", isDirectory: true)
        let hdBoxURL = baseURL.appendingPathComponent("HDBox", isDirectory: true)
        let ipcBoxURL = baseURL.appendingPathComponent("IPCBox", isDirectory: true)

        let isInstalled = directoryExists(at: hdBoxURL) && directoryExists(at: ipcBoxURL)

        return X1a0HeCCInstallStatus(
            isInstalled: isInstalled,
            hdBoxVersion: PIMXParser.readPackageVersion(from: hdBoxURL.appendingPathComponent("HDBox.pimx")),
            ipcBoxVersion: PIMXParser.readPackageVersion(from: ipcBoxURL.appendingPathComponent("IPCBox.pimx"))
        )
    }

    private func displayVersion(_ version: String) -> String {
        version.isEmpty ? String(localized: "未知 Setup 组件版本号") : version
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

struct ExternalLinkView: View {
    let title: String
    let url: String

    var body: some View {
        Link(title, destination: URL(string: url)!)
            .font(.system(size: AboutViewConstants.linkFontSize))
            .foregroundColor(.blue)
    }
}

struct HelperView: View {
    @ObservedObject var playgroundViewModel: HelperPlaygroundViewModel

    init(updater: SPUUpdater, playgroundViewModel: HelperPlaygroundViewModel) {
        _ = updater
        self.playgroundViewModel = playgroundViewModel
    }

    var body: some View {
        HelperPlaygroundView(viewModel: playgroundViewModel)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .alert(playgroundViewModel.helperAlertSuccess ? "操作成功" : "操作失败", isPresented: $playgroundViewModel.showHelperAlert) {
                Button("确定") { }
            } message: {
                Text(playgroundViewModel.helperAlertMessage)
            }
    }
}

struct AboutAppView: View {
    @State private var debugTapCount = 0
    @State private var showDebugRestartAlert = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingSection(String(localized: "关于 Adobe Downloader")) {
                VStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: AboutViewConstants.appIconSize, height: AboutViewConstants.appIconSize)

                        if AppDebugMode.isEnabled {
                            Text("DEBUG")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.yellow))
                                .offset(x: 5, y: 3)
                        }
                    }
                    .frame(width: AboutViewConstants.appIconSize, height: AboutViewConstants.appIconSize)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleDebugIconTap()
                    }

                    VStack(spacing: 4) {
                        Text("Adobe Downloader \(appVersion)")
                            .font(.system(size: AboutViewConstants.titleFontSize, weight: .semibold))
                        Text("By X1a0He.")
                            .font(.system(size: AboutViewConstants.subtitleFontSize))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }

            SettingSection(String(localized: "相关链接")) {
                VStack(spacing: 0) {
                    ForEach(Array(AboutViewConstants.links.enumerated()), id: \.offset) { idx, link in
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.blue.opacity(0.14))
                                    .frame(width: 22, height: 22)
                                Image(systemName: idx == 0 ? "paperplane.fill" : "link")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.blue)
                            }
                            ExternalLinkView(title: link.title, url: link.url)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

                        if idx < AboutViewConstants.links.count - 1 {
                            SettingRowDivider()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Text("GNU 通用公共许可证 GPL v3.")
                    .font(.system(size: AboutViewConstants.licenseFontSize))
                    .foregroundColor(.secondary.opacity(0.75))
                Spacer()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("调试模式已开启", isPresented: $showDebugRestartAlert) {
            Button("确定") {
                AppDebugMode.restartApplication()
            }
        } message: {
            Text("需要重启 Adobe Downloader 后生效。")
        }
    }

    private func handleDebugIconTap() {
        debugTapCount += 1

        guard debugTapCount >= 5 else {
            return
        }

        debugTapCount = 0
        AppDebugMode.requestNextLaunch()
        showDebugRestartAlert = true
    }
}

struct PulsingCircle: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: isAnimating ? 20 : 8, height: isAnimating ? 20 : 8)
                .opacity(isAnimating ? 0 : 0.8)
                .animation(
                    .easeOut(duration: 2.5)
                    .repeatForever(autoreverses: false),
                    value: isAnimating
                )

            Circle()
                .fill(color.opacity(0.3))
                .frame(width: isAnimating ? 14 : 6, height: isAnimating ? 14 : 6)
                .opacity(isAnimating ? 0 : 0.7)
                .animation(
                    .easeOut(duration: 2.0)
                    .delay(0.4)
                    .repeatForever(autoreverses: false),
                    value: isAnimating
                )

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .scaleEffect(isAnimating ? 1.15 : 1.0)
                .opacity(0.95)
                .animation(
                    .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true),
                    value: isAnimating
                )

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.8),
                            color.opacity(0.3),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 1,
                        endRadius: 4
                    )
                )
                .frame(width: 8, height: 8)
                .scaleEffect(isAnimating ? 1.3 : 0.8)
                .opacity(isAnimating ? 0.6 : 1.0)
                .animation(
                    .easeInOut(duration: 2.2)
                    .repeatForever(autoreverses: true),
                    value: isAnimating
                )
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation {
                isAnimating = true
            }
        }
        .onDisappear {
            isAnimating = false
        }
    }
}

@MainActor
final class GeneralSettingsViewModel: ObservableObject {
    @Published var isDownloadingSetup = false
    @Published var setupDownloadProgress = 0.0
    @Published var setupDownloadStatus = ""
    @Published var ccInstallStatus = X1a0HeCCInstallStatus.detect()
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var isSuccess = false
    @Published var showLanguagePicker = false
    @Published var showDownloadOnlyConfirmAlert = false
    @Published var helperConnectionStatus: HelperConnectionStatus = .disconnected
    @Published var fullDiskAccessGranted = FullDiskAccessPermission.isGranted
    @Published var helperFullDiskAccessGranted: Bool?
    @Published var isCheckingHelperFullDiskAccess = false
    @Published var downloadAppleSilicon: Bool {
        didSet {
            StorageData.shared.downloadAppleSilicon = downloadAppleSilicon
        }
    }

    var defaultLanguage: String {
        get { StorageData.shared.defaultLanguage }
        set { StorageData.shared.defaultLanguage = newValue }
    }

    var defaultDirectory: String {
        get { StorageData.shared.defaultDirectory }
        set { StorageData.shared.defaultDirectory = newValue }
    }

    var useDefaultLanguage: Bool {
        get { StorageData.shared.useDefaultLanguage }
        set { StorageData.shared.useDefaultLanguage = newValue }
    }

    var useDefaultDirectory: Bool {
        get { StorageData.shared.useDefaultDirectory }
        set { StorageData.shared.useDefaultDirectory = newValue }
    }

    var confirmRedownload: Bool {
        get { StorageData.shared.confirmRedownload }
        set {
            StorageData.shared.confirmRedownload = newValue
            objectWillChange.send()
        }
    }

    var deleteCompletedTasksWithFiles: Bool {
        get { StorageData.shared.deleteCompletedTasksWithFiles }
        set {
            StorageData.shared.deleteCompletedTasksWithFiles = newValue
            objectWillChange.send()
        }
    }

    var maxConcurrentDownloads: Int {
        get { StorageData.shared.maxConcurrentDownloads }
        set {
            StorageData.shared.maxConcurrentDownloads = newValue
            objectWillChange.send()
        }
    }

    @Published var automaticallyChecksForUpdates: Bool
    @Published var automaticallyDownloadsUpdates: Bool

    @Published var isCancelled = false

    private var cancellables = Set<AnyCancellable>()
    let updater: SPUUpdater

    enum HelperConnectionStatus {
        case connected
        case connecting
        case disconnected
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        self.downloadAppleSilicon = StorageData.shared.downloadAppleSilicon

        self.helperConnectionStatus = .connecting

        PrivilegedHelperAdapter.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.helperConnectionStatus = .connected
                case .disconnected:
                    self?.helperConnectionStatus = .disconnected
                case .connecting:
                    self?.helperConnectionStatus = .connecting
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .storageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.removeAll()
    }

    func updateAutomaticallyChecksForUpdates(_ newValue: Bool) {
        automaticallyChecksForUpdates = newValue
        updater.automaticallyChecksForUpdates = newValue
    }

    func updateAutomaticallyDownloadsUpdates(_ newValue: Bool) {
        automaticallyDownloadsUpdates = newValue
        updater.automaticallyDownloadsUpdates = newValue
    }

    var isAutomaticallyDownloadsUpdatesDisabled: Bool {
        !automaticallyChecksForUpdates
    }

    func cancelDownload() {
        isCancelled = true
    }

    func refreshCCInstallStatus() {
        ccInstallStatus = X1a0HeCCInstallStatus.detect()
    }

    func refreshFullDiskAccessStatus() {
        refreshAppFullDiskAccessStatus()
        refreshHelperFullDiskAccessStatus()
    }

    func refreshAppFullDiskAccessStatus() {
        fullDiskAccessGranted = FullDiskAccessPermission.isGranted
    }

    func refreshHelperFullDiskAccessStatus() {
        isCheckingHelperFullDiskAccess = true

        Task { [weak self] in
            let helperGranted = await FullDiskAccessPermission.helperIsGranted()
            await MainActor.run {
                self?.helperFullDiskAccessGranted = helperGranted
                self?.isCheckingHelperFullDiskAccess = false
            }
        }
    }
}

struct GeneralSettingsView: View {
    @StateObject private var viewModel: GeneralSettingsViewModel
    @State private var showHelperAlert = false
    @State private var helperAlertMessage = ""
    @State private var helperAlertSuccess = false
    @EnvironmentObject private var networkManager: NetworkManager

    init(updater: SPUUpdater) {
        _viewModel = StateObject(wrappedValue: GeneralSettingsViewModel(updater: updater))
    }

    var body: some View {
        GeneralSettingsContent(
            viewModel: viewModel,
            showHelperAlert: $showHelperAlert,
            helperAlertMessage: $helperAlertMessage,
            helperAlertSuccess: $helperAlertSuccess
        )
    }
}

private struct GeneralSettingsContent: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PermissionSettingsView(viewModel: viewModel)
            DownloadSettingsView(viewModel: viewModel)
            CCSettingsView(viewModel: viewModel)
            UpdateSettingsView(viewModel: viewModel)
            CleanConfigView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GeneralSettingsAlerts(
            viewModel: viewModel,
            showHelperAlert: $showHelperAlert,
            helperAlertMessage: $helperAlertMessage,
            helperAlertSuccess: $helperAlertSuccess
        ))
        .onReceive(NotificationCenter.default.publisher(for: .storageDidChange)) { _ in
            viewModel.objectWillChange.send()
        }
    }
}

struct PermissionSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @State private var showAppPermissionGuide = false
    @State private var showHelperPermissionGuide = false

    var body: some View {
        SettingSection(
            String(localized: "权限设置"),
            footer: String(localized: "清理用户容器、群组容器和文档目录时，Adobe Downloader 与 Helper 都建议加入全磁盘访问")
        ) {
            SettingRow(
                title: String(localized: "App 全磁盘访问权限"),
                subtitle: viewModel.fullDiskAccessGranted
                    ? String(localized: "Adobe Downloader 已具备访问受保护用户目录的权限")
                    : String(localized: "未授权时，Containers、Group Containers 和 Documents 清理可能失败"),
                icon: "externaldrive.badge.checkmark",
                iconTint: viewModel.fullDiskAccessGranted ? .green : .orange
            ) {
                HStack(spacing: 8) {
                    SettingsStatusChip(
                        icon: viewModel.fullDiskAccessGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        text: viewModel.fullDiskAccessGranted ? String(localized: "已授权") : String(localized: "未授权"),
                        tint: viewModel.fullDiskAccessGranted ? .green : .orange
                    )

                    Button(action: { showAppPermissionGuide = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.fill").font(.system(size: 10))
                            Text("打开设置").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))

                    PermissionRefreshButton {
                        viewModel.refreshAppFullDiskAccessStatus()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            SettingRowDivider()

            SettingRow(
                title: String(localized: "Helper 全磁盘访问权限"),
                subtitle: helperPermissionSubtitle,
                icon: "lock.shield.fill",
                iconTint: helperPermissionTint
            ) {
                HStack(spacing: 8) {
                    SettingsStatusChip(
                        icon: helperPermissionIcon,
                        text: helperPermissionText,
                        tint: helperPermissionTint
                    )

                    Button(action: { showHelperPermissionGuide = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.fill").font(.system(size: 10))
                            Text("打开设置").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))

                    PermissionRefreshButton(isLoading: viewModel.isCheckingHelperFullDiskAccess) {
                        viewModel.refreshHelperFullDiskAccessStatus()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .onAppear {
            viewModel.refreshFullDiskAccessStatus()
        }
        .alert("设置 Adobe Downloader 全磁盘访问", isPresented: $showAppPermissionGuide) {
            Button("取消", role: .cancel) { }
            Button("前往设置") {
                FullDiskAccessPermission.openSettings()
            }
        } message: {
            Text("1. 在系统设置中找到「Adobe Downloader」\n2. 勾选以授予全磁盘访问权限\n3. 返回此界面点击刷新按钮验证")
        }
        .alert("Helper 权限说明", isPresented: $showHelperPermissionGuide) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("Helper 的权限状态可通过右侧刷新按钮检测。\n\n如需访问受保护目录，Helper 会在执行操作时自动请求授权。")
        }
    }

    private var helperPermissionSubtitle: String {
        switch viewModel.helperFullDiskAccessGranted {
        case .some(true):
            return String(localized: "Helper 已具备访问受保护用户目录的权限")
        case .some(false):
            return "com.x1a0he.macOS.Adobe-Downloader.helper " + String(localized: "未授权")
        case .none:
            return viewModel.helperConnectionStatus == .disconnected
                ? String(localized: "Helper 未连接，无法检测权限状态")
                : String(localized: "正在检测权限...")
        }
    }

    private var helperPermissionIcon: String {
        switch viewModel.helperFullDiskAccessGranted {
        case .some(true):
            return "checkmark.circle.fill"
        case .some(false):
            return "exclamationmark.triangle.fill"
        case .none:
            return "questionmark.circle.fill"
        }
    }

    private var helperPermissionText: String {
        switch viewModel.helperFullDiskAccessGranted {
        case .some(true):
            return String(localized: "已授权")
        case .some(false):
            return String(localized: "未授权")
        case .none:
            return String(localized: "无法检测")
        }
    }

    private var helperPermissionTint: Color {
        switch viewModel.helperFullDiskAccessGranted {
        case .some(true):
            return .green
        case .some(false):
            return .orange
        case .none:
            return .secondary
        }
    }
}

private struct PermissionRefreshButton: View {
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ProgressView()
                    .scaleEffect(0.55)
                    .opacity(isLoading ? 1 : 0)

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .opacity(isLoading ? 0 : 1)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help(String(localized: "刷新权限状态"))
    }
}

private struct GeneralSettingsAlerts: ViewModifier {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool
    @EnvironmentObject private var networkManager: NetworkManager

    func body(content: Content) -> some View {
        content
            .alert(helperAlertSuccess ? "操作成功" : "操作失败", isPresented: $showHelperAlert) {
                Button("确定") { }
            } message: {
                Text(helperAlertMessage)
            }
            .alert(viewModel.isSuccess ? "操作成功" : "操作失败", isPresented: $viewModel.showAlert) {
                Button("确定") { }
            } message: {
                Text(viewModel.alertMessage)
            }
            .alert("确认下载", isPresented: $viewModel.showDownloadOnlyConfirmAlert) {
                Button("取消", role: .cancel) { }
                Button("确定") {
                    Task {
                        startDownloadSetup()
                    }
                }
            } message: {
                Text("确定要下载 HDBox 和 IPCBox 组件吗？")
            }
    }

    private func startDownloadSetup() {
        guard viewModel.helperConnectionStatus == .connected else {
            viewModel.isSuccess = false
            viewModel.alertMessage = String(localized: "Helper 未启用或未连接，无法下载 IPCBox 和 HDBox。请先在 Helper 设置中点击「重新启用」，前往系统设置 → 登录项与扩展打开 Adobe Downloader.app，重启 App 后再点击「重新启用」或「重新连接」。")
            viewModel.showAlert = true
            return
        }

        viewModel.isDownloadingSetup = true
        viewModel.isCancelled = false

        Task {
            do {
                try await globalNewDownloadUtils.downloadX1a0HeCCPackages(
                    progressHandler: { progress, status in
                        viewModel.setupDownloadProgress = progress
                        viewModel.setupDownloadStatus = status
                    },
                    cancellationHandler: { viewModel.isCancelled }
                )
                viewModel.isSuccess = true
                viewModel.alertMessage = String(localized: "HDBox 和 IPCBox 下载成功")
                viewModel.refreshCCInstallStatus()
            } catch NetworkError.cancelled {
                viewModel.isSuccess = false
                viewModel.alertMessage = String(localized: "下载已取消")
            } catch {
                viewModel.isSuccess = false
                viewModel.alertMessage = error.localizedDescription
            }

            viewModel.showAlert = true
            viewModel.isDownloadingSetup = false
        }
    }
}

struct DownloadSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingSection(
            String(localized: "下载设置"),
            footer: String(localized: "控制默认语言、保存目录、架构与并发等下载行为")
        ) {
            LanguageSettingRow(viewModel: viewModel)
            SettingRowDivider()
            DirectorySettingRow(viewModel: viewModel)
            SettingRowDivider()
            RedownloadConfirmRow(viewModel: viewModel)
            SettingRowDivider()
            DeleteCompletedTasksRow(viewModel: viewModel)
            SettingRowDivider()
            ArchitectureSettingRow(viewModel: viewModel)
            SettingRowDivider()
            ConcurrentDownloadsSettingRow(viewModel: viewModel)
        }
    }
}

struct HelperSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool

    var body: some View {
        SettingSection(
            String(localized: "Helper 设置"),
            footer: String(localized: "Helper 负责执行特权操作；连接异常时可尝试重新启用或创建连接")
        ) {
            HelperStatusRow(
                viewModel: viewModel,
                showHelperAlert: $showHelperAlert,
                helperAlertMessage: $helperAlertMessage,
                helperAlertSuccess: $helperAlertSuccess
            )
        }
    }
}

struct CCSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingSection(
            String(localized: "X1a0He CC 设置"),
            footer: String(localized: "下载 HDBox 和 IPCBox 组件")
        ) {
            SetupComponentRow(viewModel: viewModel)
        }
        .onAppear {
            viewModel.refreshCCInstallStatus()
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    var body: some View {
        SettingSection(
            String(localized: "更新设置"),
            footer: String(localized: "通过 Sparkle 自动检查并更新到最新版本")
        ) {
            SettingRow(
                title: String(localized: "当前版本"),
                subtitle: nil,
                icon: "number.circle.fill",
                iconTint: .blue
            ) {
                SettingsStatusChip(
                    icon: nil,
                    text: "\(appVersion) (\(buildVersion))",
                    tint: .blue
                )
            }
            SettingRowDivider()
            AutoUpdateRow(viewModel: viewModel)
            SettingRowDivider()
            AutoDownloadRow(viewModel: viewModel)
        }
    }
}

private class PreviewUpdater: SPUUpdater {
    init() {
        let hostBundle = Bundle.main
        let applicationBundle = Bundle.main
        let userDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)

        super.init(
            hostBundle: hostBundle,
            applicationBundle: applicationBundle,
            userDriver: userDriver,
            delegate: nil
        )
    }

    override var automaticallyChecksForUpdates: Bool {
        get { true }
        set { }
    }

    override var automaticallyDownloadsUpdates: Bool {
        get { true }
        set { }
    }
}

struct LanguageSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "使用默认语言"),
            subtitle: subtitleText,
            icon: "globe",
            iconTint: .blue
        ) {
            HStack(spacing: 8) {
                if viewModel.useDefaultLanguage {
                    Button(action: { viewModel.showLanguagePicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 10))
                            Text("选择").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                }
                Toggle("", isOn: Binding(
                    get: { viewModel.useDefaultLanguage },
                    set: { viewModel.useDefaultLanguage = $0 }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .controlSize(.small)
                .labelsHidden()
            }
        }
        .sheet(isPresented: $viewModel.showLanguagePicker) {
            LanguagePickerView(languages: AppStatics.supportedLanguages) { language in
                viewModel.defaultLanguage = language
                viewModel.showLanguagePicker = false
            }
        }
    }

    private var subtitleText: String {
        if viewModel.useDefaultLanguage {
            return String(format: String(localized: "当前: %@"), getLanguageName(code: viewModel.defaultLanguage))
        }
        return String(localized: "关闭时，每次下载前都会让你选择语言")
    }

    private func getLanguageName(code: String) -> String {
        AppStatics.supportedLanguages.first { $0.code == code }?.name ?? code
    }
}

struct DirectorySettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "使用默认目录"),
            subtitle: subtitleText,
            icon: "folder.fill",
            iconTint: .orange
        ) {
            HStack(spacing: 8) {
                if viewModel.useDefaultDirectory {
                    Button(action: { selectDirectory() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 10))
                            Text("选择").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                }
                Toggle("", isOn: $viewModel.useDefaultDirectory)
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    private var subtitleText: String {
        if viewModel.useDefaultDirectory {
            let path = viewModel.defaultDirectory
            if path.isEmpty {
                return String(localized: "尚未设置目录")
            }
            return String(format: String(localized: "当前: %@"), formatPath(path))
        }
        return String(localized: "关闭时，每次下载前都会让你选择保存位置")
    }

    private func formatPath(_ path: String) -> String {
        if path.isEmpty { return String(localized: "未设置") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择默认下载目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK {
            viewModel.defaultDirectory = panel.url?.path ?? ""
            viewModel.useDefaultDirectory = true
        }
    }
}

struct RedownloadConfirmRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "重新下载时需要确认"),
            subtitle: viewModel.confirmRedownload
                ? String(localized: "重新下载会弹出确认对话框，避免误操作")
                : String(localized: "关闭后重新下载将直接覆盖现有文件"),
            icon: "exclamationmark.triangle.fill",
            iconTint: .orange
        ) {
            Toggle("", isOn: $viewModel.confirmRedownload)
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

struct ArchitectureSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @ObservedObject private var networkManager = globalNetworkManager

    var body: some View {
        SettingRow(
            title: String(localized: "下载 Apple Silicon 架构"),
            subtitle: subtitleText,
            icon: "cpu.fill",
            iconTint: .purple
        ) {
            HStack(spacing: 8) {
                SettingsStatusChip(
                    icon: "memorychip",
                    text: String(format: String(localized: "本机: %@"), AppStatics.cpuArchitecture),
                    tint: .secondary
                )
                if networkManager.loadingState == .loading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }
                Toggle("", isOn: $viewModel.downloadAppleSilicon)
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(networkManager.loadingState == .loading)
            }
        }
        .onChange(of: viewModel.downloadAppleSilicon) { _ in
            Task {
                await networkManager.fetchProducts()
            }
        }
    }

    private var subtitleText: String {
        viewModel.downloadAppleSilicon
            ? String(localized: "下载 arm64 架构包，适配 Apple Silicon 芯片")
            : String(localized: "下载 x86_64 架构包，兼容 Intel 芯片")
    }
}

struct HelperStatusRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool
    @State private var isReinstallingHelper = false
    @State private var helperStatus: PrivilegedHelperAdapter.HelperStatus = .noFound

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(
                title: String(localized: "启用状态"),
                subtitle: helperStatus == .installed
                    ? String(localized: "Helper 已安装并运行中")
                    : String(localized: "Helper 未启用，无法执行安装/清理操作"),
                icon: "lock.shield.fill",
                iconTint: helperStatus == .installed ? .green : .red
            ) {
                HStack(spacing: 8) {
                    if helperStatus == .installed {
                        SettingsStatusChip(icon: "checkmark.circle.fill", text: String(localized: "已启用"), tint: .green)
                    } else {
                        SettingsStatusChip(icon: "xmark.circle.fill", text: String(localized: "未启用"), tint: .red)
                    }
                    if isReinstallingHelper {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    }
                    Button(action: {
                        isReinstallingHelper = true
                        PrivilegedHelperAdapter.shared.reinstallHelper { success, message in
                            DispatchQueue.main.async {
                                helperAlertSuccess = success
                                helperAlertMessage = message
                                showHelperAlert = true
                                isReinstallingHelper = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            Text("重新启用").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                    .disabled(isReinstallingHelper)
                    .help("注销并重新注册后台服务（修复不同步/更新）")
                }
            }

            SettingRowDivider()

            SettingRow(
                title: String(localized: "连接状态"),
                subtitle: connectionSubtitle,
                icon: "bolt.horizontal.fill",
                iconTint: helperStatusColor
            ) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        PulsingCircle(color: helperStatusColor)
                        Text(helperStatusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(helperStatusColor.opacity(0.9))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(helperStatusColor.opacity(0.12))
                    )
                    .overlay(
                        Capsule().strokeBorder(helperStatusColor.opacity(0.22), lineWidth: 0.5)
                    )

                    Button(action: {
                        PrivilegedHelperAdapter.shared.reconnectHelper { success, message in
                            DispatchQueue.main.async {
                                helperAlertSuccess = success
                                helperAlertMessage = message
                                showHelperAlert = true
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "network").font(.system(size: 10))
                            Text("重新连接").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: shouldDisableReconnectButton ? Color.gray.opacity(0.6) : Color.blue))
                    .disabled(shouldDisableReconnectButton)
                    .help("尝试重新创建连接到已启用的 Helper")
                }
            }
        }
        .task {
            PrivilegedHelperAdapter.shared.getHelperStatus { status in
                helperStatus = status
            }
        }
    }

    private var connectionSubtitle: String {
        switch viewModel.helperConnectionStatus {
        case .connected:    return String(localized: "XPC 通道运行正常，可执行特权命令")
        case .connecting:   return String(localized: "正在建立连接…")
        case .disconnected: return String(localized: "连接已断开，点击右侧按钮重新连接")
        }
    }

    private var helperStatusColor: Color {
        switch viewModel.helperConnectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    private var shouldDisableReconnectButton: Bool {
        return isReinstallingHelper
            || helperStatus != .installed
            || viewModel.helperConnectionStatus == .connecting
            || viewModel.helperConnectionStatus == .connected
    }

    private var helperStatusText: String {
        switch viewModel.helperConnectionStatus {
        case .connected: return String(localized: "运行正常")
        case .connecting: return String(localized: "正在连接")
        case .disconnected: return String(localized: "连接断开")
        }
    }
}

struct SetupComponentRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "X1a0He CC"),
            subtitle: viewModel.isDownloadingSetup
                ? viewModel.setupDownloadStatus
                : viewModel.ccInstallStatus.subtitle,
            icon: "arrow.down.circle.fill",
            iconTint: .blue
        ) {
            HStack(spacing: 8) {
                if viewModel.isDownloadingSetup {
                    ProgressView(value: viewModel.setupDownloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Button(action: { viewModel.cancelDownload() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.system(size: 10))
                            Text("取消").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.red))
                } else {
                    SettingsStatusChip(
                        icon: viewModel.ccInstallStatus.statusIcon,
                        text: viewModel.ccInstallStatus.statusText,
                        tint: viewModel.ccInstallStatus.statusTint
                    )

                    Button(action: { viewModel.showDownloadOnlyConfirmAlert = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 10))
                            Text("下载").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                }
            }
        }
    }
}

struct AutoUpdateRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "自动检查更新版本"),
            subtitle: viewModel.automaticallyChecksForUpdates
                ? String(localized: "启动时自动检查 GitHub 新版本")
                : String(localized: "关闭后需要手动点击右侧按钮检查"),
            icon: "arrow.triangle.2.circlepath",
            iconTint: .blue
        ) {
            HStack(spacing: 8) {
                CheckForUpdatesView(updater: viewModel.updater)
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                    .foregroundColor(.white)
                Toggle("", isOn: Binding(
                    get: { viewModel.automaticallyChecksForUpdates },
                    set: { viewModel.updateAutomaticallyChecksForUpdates($0) }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .controlSize(.small)
                .labelsHidden()
            }
        }
    }
}

struct AutoDownloadRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "自动下载最新版本"),
            subtitle: subtitleText,
            icon: "arrow.down.circle.fill",
            iconTint: viewModel.isAutomaticallyDownloadsUpdatesDisabled ? .secondary : .blue
        ) {
            Toggle("", isOn: Binding(
                get: { viewModel.automaticallyDownloadsUpdates },
                set: { viewModel.updateAutomaticallyDownloadsUpdates($0) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .controlSize(.small)
            .labelsHidden()
            .disabled(viewModel.isAutomaticallyDownloadsUpdatesDisabled)
        }
    }

    private var subtitleText: String {
        if viewModel.isAutomaticallyDownloadsUpdatesDisabled {
            return String(localized: "需先启用\"自动检查更新版本\"")
        }
        return viewModel.automaticallyDownloadsUpdates
            ? String(localized: "检测到新版本后自动下载")
            : String(localized: "需手动点击更新按钮进行下载")
    }
}

struct ConcurrentDownloadsSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "并发下载数"),
            subtitle: String(format: String(localized: "同时进行的下载任务数（范围 1-10，推荐 %d）"), 3),
            icon: "square.stack.3d.up.fill",
            iconTint: .teal
        ) {
            HStack(spacing: 8) {
                Button(action: {
                    if viewModel.maxConcurrentDownloads > 1 {
                        viewModel.maxConcurrentDownloads -= 1
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(viewModel.maxConcurrentDownloads > 1 ? .blue : .gray.opacity(0.5))
                        .font(.system(size: 15))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.maxConcurrentDownloads <= 1)

                Text("\(viewModel.maxConcurrentDownloads)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 20)

                Button(action: {
                    if viewModel.maxConcurrentDownloads < 10 {
                        viewModel.maxConcurrentDownloads += 1
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(viewModel.maxConcurrentDownloads < 10 ? .blue : .gray.opacity(0.5))
                        .font(.system(size: 15))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.maxConcurrentDownloads >= 10)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
    }
}

struct DeleteCompletedTasksRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        SettingRow(
            title: String(localized: "删除任务时同时删除本地文件"),
            subtitle: viewModel.deleteCompletedTasksWithFiles
                ? String(localized: "删除任务记录时会一并删除本地安装包")
                : String(localized: "仅删除任务记录，保留本地安装包"),
            icon: "trash.slash.fill",
            iconTint: viewModel.deleteCompletedTasksWithFiles ? .red : .blue
        ) {
            HStack(spacing: 8) {
                if viewModel.deleteCompletedTasksWithFiles {
                    SettingsStatusChip(icon: "trash.fill", text: String(localized: "将删除文件"), tint: .red)
                } else {
                    SettingsStatusChip(icon: "doc.on.doc.fill", text: String(localized: "保留文件"), tint: .blue)
                }
                Toggle("", isOn: $viewModel.deleteCompletedTasksWithFiles)
                    .toggleStyle(SwitchToggleStyle(tint: .red))
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }
}
