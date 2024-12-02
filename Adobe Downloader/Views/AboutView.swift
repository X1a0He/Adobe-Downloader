//
//  Adobe Downloader
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
        ("@X1a0He", "https://t.me/X1a0He"),
        ("Github: Adobe Downloader", "https://github.com/X1a0He/Adobe-Downloader"),
        ("Drovosek01: adobe-packager", "https://github.com/Drovosek01/adobe-packager"),
        ("QiuChenly: InjectLib", "https://github.com/QiuChenly/InjectLib")
    ]
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

struct AboutView: View {
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
    }
    
    var body: some View {
        TabView {
            GeneralSettingsView(updater: updater)
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
                .id("general_settings")
            
            AboutAppView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .id("about_app")
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(width: 600)
    }
}

struct AboutAppView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
    
    var body: some View {
        VStack(spacing: AboutViewConstants.verticalSpacing) {
            appIconSection
            appInfoSection
            linksSection
            licenseSection
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var appIconSection: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: AboutViewConstants.appIconSize, height: AboutViewConstants.appIconSize)
    }
    
    private var appInfoSection: some View {
        Group {
            Text("Adobe Downloader \(appVersion)")
                .font(.system(size: AboutViewConstants.titleFontSize))
                .bold()
            
            Text("By X1a0He. ❤️ Love from China. 🇨🇳")
                .font(.system(size: AboutViewConstants.subtitleFontSize))
                .foregroundColor(.secondary)
        }
    }
    
    private var linksSection: some View {
        ForEach(AboutViewConstants.links, id: \.url) { link in
            ExternalLinkView(title: link.title, url: link.url)
        }
    }
    
    private var licenseSection: some View {
        Text("GNU通用公共许可证GPL v3.")
            .font(.system(size: AboutViewConstants.licenseFontSize))
            .foregroundColor(.secondary)
    }
}

struct PulsingCircle: View {
    let color: Color
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .animation(
                Animation.easeInOut(duration: 1.0)
                    .repeatForever(autoreverses: true),
                value: scale
            )
            .onAppear {
                scale = 1.5
            }
    }
}

final class GeneralSettingsViewModel: ObservableObject {
    @Published var setupVersion: String = ""
    @Published var isDownloadingSetup = false
    @Published var setupDownloadProgress = 0.0
    @Published var setupDownloadStatus = ""
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var isSuccess = false
    @Published var showDownloadAlert = false
    @Published var showLanguagePicker = false
    @Published var showDownloadConfirmAlert = false
    @Published var showReprocessConfirmAlert = false
    @Published var isProcessing = false
    @Published var helperConnectionStatus: HelperConnectionStatus = .disconnected
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

    @Published var automaticallyChecksForUpdates: Bool
    @Published var automaticallyDownloadsUpdates: Bool

    @Published var isCancelled = false

    private var cancellables = Set<AnyCancellable>()
    let updater: SPUUpdater

    enum HelperConnectionStatus {
        case connected
        case connecting
        case disconnected
        case checking
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        self.downloadAppleSilicon = StorageData.shared.downloadAppleSilicon
        
        self.helperConnectionStatus = .connecting
        
        PrivilegedHelperManager.shared.$connectionState
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
        
        PrivilegedHelperManager.shared.executeCommand("whoami") { _ in }
        
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
        Form {
            DownloadSettingsView(viewModel: viewModel)
            HelperSettingsView(viewModel: viewModel,
                            showHelperAlert: $showHelperAlert,
                            helperAlertMessage: $helperAlertMessage,
                            helperAlertSuccess: $helperAlertSuccess)
            CCSettingsView(viewModel: viewModel)
            UpdateSettingsView(viewModel: viewModel)
            CleanConfigView()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .alert(helperAlertSuccess ? "操作成功" : "操作失败", isPresented: $showHelperAlert) {
            Button("确定") { }
        } message: {
            Text(helperAlertMessage)
        }
        .alert("需要下载 Setup 组件", isPresented: $viewModel.showDownloadAlert) {
            Button("取消", role: .cancel) { }
            Button("下载") {
                Task {
                    viewModel.isDownloadingSetup = true
                    viewModel.isCancelled = false
                    do {
                        try await networkManager.downloadUtils.downloadX1a0HeCCPackages(
                            progressHandler: { progress, status in
                                viewModel.setupDownloadProgress = progress
                                viewModel.setupDownloadStatus = status
                            },
                            cancellationHandler: { viewModel.isCancelled }
                        )
                        viewModel.setupVersion = ModifySetup.checkComponentVersion()
                        viewModel.isSuccess = true
                        viewModel.alertMessage = "Setup 组件安装成功"
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
        } message: {
            Text("检测到系统中不存在 Setup 组件，需要先下载组件才能继续操作。")
        }
        .alert("确认下载", isPresented: $viewModel.showDownloadConfirmAlert) {
            Button("取消", role: .cancel) { }
            Button("确定") {
                Task {
                    viewModel.isDownloadingSetup = true
                    viewModel.isCancelled = false
                    do {
                        try await networkManager.downloadUtils.downloadX1a0HeCCPackages(
                            progressHandler: { progress, status in
                                viewModel.setupDownloadProgress = progress
                                viewModel.setupDownloadStatus = status
                            },
                            cancellationHandler: { viewModel.isCancelled }
                        )
                        viewModel.setupVersion = ModifySetup.checkComponentVersion()
                        viewModel.isSuccess = true
                        viewModel.alertMessage = String(localized: "Setup 组件安装成功")
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
        } message: {
            Text("确定要下载并安装 X1a0He CC 吗?")
        }
        .alert("确认重新处理", isPresented: $viewModel.showReprocessConfirmAlert) {
            Button("取消", role: .cancel) { }
            Button("确定") {
                viewModel.isProcessing = true
                ModifySetup.backupAndModifySetupFile { success, message in
                    viewModel.isProcessing = false
                    viewModel.isSuccess = success
                    viewModel.alertMessage = message
                    viewModel.showAlert = true
                }
            }
        } message: {
            Text("确定要重新处理 Setup 组件吗?")
        }
        .alert(viewModel.isSuccess ? "操作成功" : "操作失败", isPresented: $viewModel.showAlert) {
            Button("确定") { }
        } message: {
            Text(viewModel.alertMessage)
        }
        .task {
            viewModel.setupVersion = ModifySetup.checkComponentVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageDidChange)) { _ in
            viewModel.objectWillChange.send()
        }
    }
}

struct DownloadSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        GroupBox(label: Text("下载设置").padding(.bottom, 8)) {
            VStack(alignment: .leading, spacing: 12) {
                LanguageSettingRow(viewModel: viewModel)
                Divider()
                DirectorySettingRow(viewModel: viewModel)
                Divider()
                RedownloadConfirmRow(viewModel: viewModel)
                Divider()
                ArchitectureSettingRow(viewModel: viewModel)
            }
            .padding(8)
        }
    }
}

struct HelperSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool

    var body: some View {
        GroupBox(label: Text("Helper 设置").padding(.bottom, 8)) {
            VStack(alignment: .leading, spacing: 12) {
                HelperStatusRow(viewModel: viewModel, showHelperAlert: $showHelperAlert,
                              helperAlertMessage: $helperAlertMessage,
                              helperAlertSuccess: $helperAlertSuccess)
            }
            .padding(8)
        }
    }
}

struct CCSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        GroupBox(label: Text("X1a0He CC设置").padding(.bottom, 8)) {
            VStack(alignment: .leading, spacing: 12) {
                SetupComponentRow(viewModel: viewModel)
            }
            .padding(8)
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        GroupBox(label: Text("更新设置").padding(.bottom, 8)) {
            VStack(alignment: .leading, spacing: 12) {
                AutoUpdateRow(viewModel: viewModel)
                Divider()
                AutoDownloadRow(viewModel: viewModel)
            }
            .padding(8)
        }
    }
}

struct CleanConfigView: View {
    @State private var showConfirmation = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        GroupBox(label: Text("重置程序").padding(.bottom, 8)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("重置程序") {
                        showConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(8)
        }
        .alert("确认重置程序", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                cleanConfig()
            }
        } message: {
            Text("这将清空所有配置并结束应用程序，确定要继续吗？")
        }
        .alert("操作结果", isPresented: $showAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func cleanConfig() {
        do {
            let downloadsURL = try FileManager.default.url(for: .downloadsDirectory, 
                                                         in: .userDomainMask, 
                                                         appropriateFor: nil, 
                                                         create: false)
            let scriptURL = downloadsURL.appendingPathComponent("clean-config.sh")
            
            guard let scriptPath = Bundle.main.path(forResource: "clean-config", ofType: "sh"),
                  let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
                throw NSError(domain: "ScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取脚本文件"])
            }
            
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            
            try FileManager.default.setAttributes([.posixPermissions: 0o755], 
                                                ofItemAtPath: scriptURL.path)
            
            if PrivilegedHelperManager.getHelperStatus {
                PrivilegedHelperManager.shared.executeCommand("open -a Terminal \(scriptURL.path)") { output in
                    if output.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            exit(0)
                        }
                    } else {
                        alertMessage = "清空配置失败: \(output)"
                        showAlert = true
                    }
                }
            } else {
                let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                NSWorkspace.shared.open([scriptURL], 
                                        withApplicationAt: terminalURL,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        alertMessage = "打开终端失败: \(error.localizedDescription)"
                        showAlert = true
                        return
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        exit(0)
                    }
                }
            }
            
        } catch {
            alertMessage = "清空配置失败: \(error.localizedDescription)"
            showAlert = true
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
        HStack {
            Toggle("使用默认语言", isOn: Binding(
                get: { viewModel.useDefaultLanguage },
                set: { viewModel.useDefaultLanguage = $0 }
            ))
                .padding(.leading, 5)
            Spacer()
            Text(getLanguageName(code: viewModel.defaultLanguage))
                .foregroundColor(.secondary)
            Button("选择") {
                viewModel.showLanguagePicker = true
            }
            .padding(.trailing, 5)
        }
        .sheet(isPresented: $viewModel.showLanguagePicker) {
            LanguagePickerView(languages: AppStatics.supportedLanguages) { language in
                viewModel.defaultLanguage = language
                viewModel.showLanguagePicker = false
            }
        }
    }

    private func getLanguageName(code: String) -> String {
        AppStatics.supportedLanguages.first { $0.code == code }?.name ?? code
    }
}

struct DirectorySettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        HStack {
            Toggle("使用默认目录", isOn: $viewModel.useDefaultDirectory)
                .padding(.leading, 5)
            Spacer()
            Text(formatPath(viewModel.defaultDirectory))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("选择") {
                selectDirectory()
            }
            .padding(.trailing, 5)
        }
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
        HStack {
            Toggle("重新下载时需要确认", isOn: $viewModel.confirmRedownload)
                .padding(.leading, 5)
            Spacer()
        }
    }
}

struct ArchitectureSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @EnvironmentObject private var networkManager: NetworkManager

    var body: some View {
        HStack {
            Toggle("下载 Apple Silicon 架构", isOn: $viewModel.downloadAppleSilicon)
                .padding(.leading, 5)
                .disabled(networkManager.loadingState == .loading)
            Spacer()
            Text("当前架构: \(AppStatics.cpuArchitecture)")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onChange(of: viewModel.downloadAppleSilicon) { newValue in
            Task {
                await networkManager.fetchProducts()
            }
        }
    }
}

struct HelperStatusRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool
    @State private var isReinstallingHelper = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Helper 状态: ")
                if PrivilegedHelperManager.getHelperStatus {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已安装 (build \(UserDefaults.standard.string(forKey: "InstalledHelperBuild") ?? "0"))")
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("未安装")
                        .foregroundColor(.red)
                }
                Spacer()
                
                if isReinstallingHelper {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                
                Button(action: {
                    isReinstallingHelper = true
                    PrivilegedHelperManager.shared.removeInstallHelper()
                    PrivilegedHelperManager.shared.reinstallHelper { success, message in
                        helperAlertSuccess = success
                        helperAlertMessage = message
                        showHelperAlert = true
                        isReinstallingHelper = false
                    }
                }) {
                    Text("重新安装")
                }
                .disabled(isReinstallingHelper)
                .help("完全卸载并重新安装 Helper")
            }
            
            if !PrivilegedHelperManager.getHelperStatus {
                Text("Helper 未安装将导致无法执行需要管理员权限的操作")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Divider()

            HStack {
                Text("Helper 连接状态: ")
                PulsingCircle(color: helperStatusColor)
                    .padding(.horizontal, 4)
                Text(helperStatusText)
                    .foregroundColor(helperStatusColor)
                
                Spacer()
                
                Button(action: {
                    if PrivilegedHelperManager.getHelperStatus && 
                       viewModel.helperConnectionStatus != .connected {
                        PrivilegedHelperManager.shared.reconnectHelper { success, message in
                            helperAlertSuccess = success
                            helperAlertMessage = message
                            showHelperAlert = true
                        }
                    }
                }) {
                    Text("重新连接")
                }
                .disabled(!PrivilegedHelperManager.getHelperStatus || 
                         viewModel.helperConnectionStatus == .connected ||
                         isReinstallingHelper)
                .help("尝试重新连接到已安装的 Helper")
            }
        }
    }
    
    private var helperStatusColor: Color {
        switch viewModel.helperConnectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        case .checking: return .orange
        }
    }
    
    private var helperStatusText: String {
        switch viewModel.helperConnectionStatus {
        case .connected: return String(localized: "运行正常")
        case .connecting: return String(localized: "正在连接")
        case .disconnected: return String(localized: "连接断开")
        case .checking: return String(localized: "检查中")
        }
    }
}

struct SetupComponentRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("X1a0He CC 备份状态: ")
                if ModifySetup.isSetupBackup() {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已备份")
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("(可能导致处理 Setup 组件失败)")
                }
            }
            Divider()
            HStack {
                Text("X1a0He CC 处理状态: ")
                if ModifySetup.isSetupModified() {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已处理")
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("(将导致无法使用安装功能)")
                }
                Spacer()

                Button(action: {
                    if !ModifySetup.isSetupExists() {
                        viewModel.showDownloadAlert = true
                    } else {
                        viewModel.showReprocessConfirmAlert = true
                    }
                }) {
                    Text("重新处理")
                }
            }
            Divider()
            HStack {
                Text("X1a0He CC 版本信息: \(viewModel.setupVersion) [\(AppStatics.cpuArchitecture)]")
                Spacer()

                if viewModel.isDownloadingSetup {
                    ProgressView(value: viewModel.setupDownloadProgress) {
                        Text(viewModel.setupDownloadStatus)
                            .font(.caption)
                    }
                    .frame(width: 150)
                    Button("取消") {
                        viewModel.cancelDownload()
                    }
                } else {
                    Button(action: {
                        viewModel.showDownloadConfirmAlert = true
                    }) {
                        Text("下载 X1a0He CC")
                    }
                }
            }
        }
    }
}

struct AutoUpdateRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        HStack {
            Toggle("自动检查更新版本", isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { viewModel.updateAutomaticallyChecksForUpdates($0) }
            ))
            Spacer()
            CheckForUpdatesView(updater: viewModel.updater)
        }
    }
}

struct AutoDownloadRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        Toggle("自动下载最新版本", isOn: Binding(
            get: { viewModel.automaticallyDownloadsUpdates },
            set: { viewModel.updateAutomaticallyDownloadsUpdates($0) }
        ))
        .disabled(viewModel.isAutomaticallyDownloadsUpdatesDisabled)
    }
}


#Preview("About Tab") {
    AboutAppView()
}

#Preview("General Settings") {
    let networkManager = NetworkManager()
    VStack {
        GeneralSettingsView(updater: PreviewUpdater())
            .environmentObject(networkManager)
    }
    .fixedSize()
}
