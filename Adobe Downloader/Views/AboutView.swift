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
        ("@X1a0He", "https://t.me/X1a0He_bot"),
        ("Github: Adobe Downloader", "https://github.com/X1a0He/Adobe-Downloader"),
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
    @State private var selectedTab = "general_settings"

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(updater: updater)
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
                .tag("general_settings")
            
            HelperView(updater: updater)
                .tabItem {
                    Label("Helper 设置", systemImage: "lock.shield")
                }
                .tag("helper_view")

            CleanupView()
                .tabItem {
                    Label("清理工具", systemImage: "trash")
                }
                .tag("cleanup_view")

            QAView()
                .tabItem {
                    Label("常见问题", systemImage: "questionmark.circle")
                }
                .tag("qa_view")

            AboutAppView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag("about_app")
        }
        .background(Color(.clear))
        .frame(width: 600)
        .onAppear {
            selectedTab = "general_settings"
        }
    }
}

struct HelperView: View {
    @State private var showHelperAlert = false
    @State private var helperAlertMessage = ""
    @State private var helperAlertSuccess = false

    init(updater: SPUUpdater) {
        _ = updater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelperPlaygroundView(
                showHelperAlert: $showHelperAlert,
                helperAlertMessage: $helperAlertMessage,
                helperAlertSuccess: $helperAlertSuccess
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(helperAlertSuccess ? "操作成功" : "操作失败", isPresented: $showHelperAlert) {
            Button("确定") { }
        } message: {
            Text(helperAlertMessage)
        }
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
    @Published var showDownloadOnlyConfirmAlert = false
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
        case checking
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
        Form {
            DownloadSettingsView(viewModel: viewModel)
                .padding(.bottom, 8)
            CCSettingsView(viewModel: viewModel)
                .padding(.bottom, 8)
            UpdateSettingsView(viewModel: viewModel)
                .padding(.bottom, 8)
            CleanConfigView()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GeneralSettingsAlerts(
            viewModel: viewModel,
            showHelperAlert: $showHelperAlert,
            helperAlertMessage: $helperAlertMessage,
            helperAlertSuccess: $helperAlertSuccess
        ))
        .task {
            viewModel.setupVersion = ModifySetup.checkComponentVersion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageDidChange)) { _ in
            viewModel.objectWillChange.send()
        }
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
            .alert("需要下载 Setup 组件", isPresented: $viewModel.showDownloadAlert) {
                Button("取消", role: .cancel) { }
                Button("下载") {
                    Task {
                        startDownloadSetup(shouldProcess: false)
                    }
                }
            } message: {
                Text("检测到系统中不存在 Setup 组件，需要先下载组件才能继续操作。")
            }
            .alert("确认下载并处理", isPresented: $viewModel.showDownloadConfirmAlert) {
                Button("取消", role: .cancel) { }
                Button("确定") {
                    Task {
                        startDownloadSetup(shouldProcess: true)
                    }
                }
            } message: {
                Text("确定要下载并处理 X1a0He CC 吗？这将完成下载并自动对 Setup 组件进行处理")
            }
            .alert("确认处理", isPresented: $viewModel.showReprocessConfirmAlert) {
                Button("取消", role: .cancel) { }
                Button("确定") {
                    Task {
                        viewModel.isProcessing = true
                        ModifySetup.backupAndModifySetupFile { success, message in
                            viewModel.setupVersion = ModifySetup.checkComponentVersion()
                            viewModel.isSuccess = success
                            viewModel.alertMessage = success ? "Setup 组件处理成功" : "处理失败: \(message)"
                            viewModel.showAlert = true
                            viewModel.isProcessing = false
                        }
                    }
                }
            } message: {
                Text("确定要重新处理 Setup 组件吗？这将对 Setup 组件进行修改以启用安装功能。")
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
                        startDownloadSetup(shouldProcess: false)
                    }
                }
            } message: {
                Text("确定要下载 X1a0He CC 吗？下载完成后需要手动处理。")
            }
    }
    
    private func startDownloadSetup(shouldProcess: Bool) {
        viewModel.isDownloadingSetup = true
        viewModel.isCancelled = false
        
        Task {
            do {
                try await globalNewDownloadUtils.downloadX1a0HeCCPackages(
                    progressHandler: { progress, status in
                        viewModel.setupDownloadProgress = progress
                        viewModel.setupDownloadStatus = status
                    },
                    cancellationHandler: { viewModel.isCancelled },
                    shouldProcess: shouldProcess
                )
                viewModel.setupVersion = ModifySetup.checkComponentVersion()
                viewModel.isSuccess = true
                viewModel.alertMessage = String(localized: shouldProcess ? 
                                              "X1a0He CC 下载并处理成功" : 
                                              "X1a0He CC 下载成功")
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
        BeautifulGroupBox(label: { 
            Text("下载设置")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                LanguageSettingRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                DirectorySettingRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                RedownloadConfirmRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                DeleteCompletedTasksRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 1)
                    Spacer()
                }
                
                ArchitectureSettingRow(viewModel: viewModel)

                Divider()

                ConcurrentDownloadsSettingRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HelperSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool

    var body: some View {
        BeautifulGroupBox(label: { 
            Text("Helper 设置")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HelperStatusRow(viewModel: viewModel, showHelperAlert: $showHelperAlert,
                              helperAlertMessage: $helperAlertMessage,
                              helperAlertSuccess: $helperAlertSuccess)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CCSettingsView: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        BeautifulGroupBox(label: { 
            Text("X1a0He CC设置")
        }) {
            VStack(alignment: .leading, spacing: 16) {
                SetupComponentRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        BeautifulGroupBox(label: { 
            Text("更新设置")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("当前版本: ")
                        .font(.system(size: 14, weight: .medium))
                    
                    HStack(spacing: 4) {
                        Image(systemName: "number.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                        Text(appVersion)
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                        Text("(\(buildVersion))")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(5)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)

                Divider()

                AutoUpdateRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                AutoDownloadRow(viewModel: viewModel)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        HStack(spacing: 10) {
            Toggle("使用默认语言", isOn: Binding(
                get: { viewModel.useDefaultLanguage },
                set: { viewModel.useDefaultLanguage = $0 }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.green))
                .padding(.leading, 5)
                .controlSize(.small)
                .labelsHidden()
                
            Text("使用默认语言")
                .font(.system(size: 14))
                
            Spacer()
            
            if viewModel.useDefaultLanguage {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Text(getLanguageName(code: viewModel.defaultLanguage))
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(5)
                
                Button(action: {
                    viewModel.showLanguagePicker = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("选择")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 60)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
                .padding(.trailing, 5)
                .disabled(!viewModel.useDefaultLanguage)
            }
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
        HStack(spacing: 10) {
            Toggle("使用默认目录", isOn: $viewModel.useDefaultDirectory)
                .toggleStyle(SwitchToggleStyle(tint: Color.green))
                .padding(.leading, 5)
                .controlSize(.small)
                .labelsHidden()
                
            Text("使用默认目录")
                .font(.system(size: 14))
                
            Spacer()
            
            if viewModel.useDefaultDirectory {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                        .frame(width: 16)
                    Text(formatPath(viewModel.defaultDirectory))
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(5)
                
                Button(action: {
                    selectDirectory()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 10))
                        Text("选择")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 60)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
                .padding(.trailing, 5)
                .disabled(!viewModel.useDefaultDirectory)
            }
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
        HStack(spacing: 10) {
            Toggle("重新下载时需要确认", isOn: $viewModel.confirmRedownload)
                .toggleStyle(SwitchToggleStyle(tint: Color.green))
                .padding(.leading, 5)
                .controlSize(.small)
                .labelsHidden()
                
            Text("重新下载时需要确认")
                .font(.system(size: 14))
            
            Spacer()
            
            if viewModel.confirmRedownload {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text("已启用确认")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(5)
                .padding(.trailing, 5)
            }
        }
    }
}

struct ArchitectureSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    @ObservedObject private var networkManager = globalNetworkManager

    var body: some View {
        HStack(spacing: 10) {
            Toggle("下载 Apple Silicon 架构", isOn: $viewModel.downloadAppleSilicon)
                .toggleStyle(SwitchToggleStyle(tint: Color.green))
                .padding(.leading, 5)
                .controlSize(.small)
                .disabled(networkManager.loadingState == .loading)
                .labelsHidden()
                
            Text("下载 Apple Silicon 架构")
                .font(.system(size: 14))
            
            Spacer()
            
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                Text("当前架构: \(AppStatics.cpuArchitecture)")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(5)
            .padding(.trailing, 5)
            
            if networkManager.loadingState == .loading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 5)
            }
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
    @State private var helperStatus: PrivilegedHelperAdapter.HelperStatus = .noFound

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("安装状态: ")
                    .font(.system(size: 14, weight: .medium))
                    
                if helperStatus == .installed {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("已安装 (build \(UserDefaults.standard.string(forKey: "InstalledHelperBuild") ?? "0"))")
                            .font(.system(size: 14))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                        Text("未安装")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }
                
                Spacer()

                if isReinstallingHelper {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 5)
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
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                        Text("重新安装")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
                .disabled(isReinstallingHelper)
                .help("完全卸载并重新安装 Helper")
            }

            if helperStatus != .installed {
                Text("Helper 未安装将导致无法执行需要管理员权限的操作")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            HStack(spacing: 10) {
                Text("连接状态: ")
                    .font(.system(size: 14, weight: .medium))
                
                HStack(alignment: .center, spacing: 5) {
                    PulsingCircle(color: helperStatusColor)
                        .layoutPriority(1)

                    Text(helperStatusText)
                        .font(.system(size: 14))
                        .foregroundColor(helperStatusColor)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(helperStatusBackgroundColor)
                .cornerRadius(6)

                Spacer()

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
                        Image(systemName: "network")
                            .font(.system(size: 12))
                        Text("重新连接")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: shouldDisableReconnectButton ? Color.gray.opacity(0.6) : Color.blue.opacity(0.8)))
                .foregroundColor(shouldDisableReconnectButton ? Color.white.opacity(0.8) : .white)
                .disabled(shouldDisableReconnectButton)
                .help("尝试重新连接到已安装的 Helper")
            }
        }
        .task {
            PrivilegedHelperAdapter.shared.getHelperStatus { status in
                helperStatus = status
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
    
    private var shouldDisableReconnectButton: Bool {
        // 只在重新安装Helper时禁用按钮，其他情况都允许用户点击
        return isReinstallingHelper
    }

    private var helperStatusBackgroundColor: Color {
        switch viewModel.helperConnectionStatus {
        case .connected: return Color.green.opacity(0.1)
        case .connecting: return Color.orange.opacity(0.1)
        case .disconnected: return Color.red.opacity(0.1)
        case .checking: return Color.orange.opacity(0.1)
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
    @State private var chipInfo: String = ""
    
    private func getChipInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        let chipName = String(cString: machine)
        
        if chipName.contains("Apple") {
            return chipName
        } else {
            return chipName.components(separatedBy: "@")[0].trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("备份状态: ")
                    .font(.system(size: 14, weight: .medium))
                    
                #if DEBUG
                HStack(spacing: 4) {
                    Image(systemName: "ladybug.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("Debug 模式")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(5)
                #else
                if ModifySetup.isSetupBackup() {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                        Text("已备份")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(5)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                        Text("未备份")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(5)
                    
                    Text("(可能导致处理失败)")
                        .foregroundColor(.red.opacity(0.8))
                        .font(.system(size: 12))
                        .padding(.leading, 2)
                }
                #endif
                
                Spacer()
            }
            Divider()
            
            HStack {
                Text("处理状态: ")
                    .font(.system(size: 14, weight: .medium))
                    
                #if DEBUG
                HStack(spacing: 4) {
                    Image(systemName: "ladybug.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("Debug 模式")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(5)
                #else
                if ModifySetup.isSetupModified() {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                        Text("已处理")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(5)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 12))
                            .frame(width: 16, height: 16)
                        Text("未处理")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(5)
                    
                    Text("(无法使用安装功能)")
                        .foregroundColor(.red.opacity(0.8))
                        .font(.system(size: 12))
                        .padding(.leading, 2)
                }
                #endif
                
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
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
            }
            Divider()
            
            HStack {
                Text("版本信息: ")
                    .font(.system(size: 14, weight: .medium))
                    
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("\(viewModel.setupVersion)")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(5)

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
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.red.opacity(0.8)))
                    .foregroundColor(.white)
                } else {
                    Menu {
                        Button(action: {
                            viewModel.showDownloadConfirmAlert = true
                        }) {
                            Label("下载并处理", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: {
                            viewModel.showDownloadOnlyConfirmAlert = true
                        }) {
                            Label("仅下载", systemImage: "arrow.down")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        Text("X1a0He CC")
                            .frame(width: 100)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("选择下载 X1a0He CC 的方式")
                }
            }
        }
        .onAppear {
            chipInfo = getChipInfo()
        }
    }
}

struct AutoUpdateRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { viewModel.automaticallyChecksForUpdates },
                set: { viewModel.updateAutomaticallyChecksForUpdates($0) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.green))
            .controlSize(.small)
            .labelsHidden()
            
            Text("自动检查更新版本")
                .font(.system(size: 14))
            
            Spacer()
            
            if viewModel.automaticallyChecksForUpdates {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("已启用")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(5)
            }
            
            CheckForUpdatesView(updater: viewModel.updater)
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
        }
    }
}

struct AutoDownloadRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { viewModel.automaticallyDownloadsUpdates },
                set: { viewModel.updateAutomaticallyDownloadsUpdates($0) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.green))
            .controlSize(.small)
            .labelsHidden()
            .disabled(viewModel.isAutomaticallyDownloadsUpdatesDisabled)
            
            Text("自动下载最新版本")
                .font(.system(size: 14))
                .foregroundColor(viewModel.isAutomaticallyDownloadsUpdatesDisabled ? .gray : .primary)
            
            Spacer()
            
            if viewModel.automaticallyDownloadsUpdates && !viewModel.isAutomaticallyDownloadsUpdatesDisabled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("已启用")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(5)
            } else if viewModel.isAutomaticallyDownloadsUpdatesDisabled {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.gray)
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                    Text("需先启用自动检查")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
        }
    }
}

struct ConcurrentDownloadsSettingRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    
    var body: some View {
        HStack(spacing: 10) {
            Text("并发下载数")
                .font(.system(size: 14))
                .padding(.leading, 5)
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: {
                    if viewModel.maxConcurrentDownloads > 1 {
                        viewModel.maxConcurrentDownloads -= 1
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(viewModel.maxConcurrentDownloads > 1 ? .blue : .gray)
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.maxConcurrentDownloads <= 1)
                
                Text("\(viewModel.maxConcurrentDownloads)")
                    .font(.system(size: 14, weight: .medium))
                    .frame(minWidth: 30)
                
                Button(action: {
                    if viewModel.maxConcurrentDownloads < 10 {
                        viewModel.maxConcurrentDownloads += 1
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(viewModel.maxConcurrentDownloads < 10 ? .blue : .gray)
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(viewModel.maxConcurrentDownloads >= 10)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(5)
            .padding(.trailing, 5)
            
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                Text("1-10")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(4)
        }
    }
}

struct DeleteCompletedTasksRow: View {
    @ObservedObject var viewModel: GeneralSettingsViewModel
    
    var body: some View {
        HStack(spacing: 10) {
            Toggle("删除已完成任务时同时删除本地文件", isOn: $viewModel.deleteCompletedTasksWithFiles)
                .toggleStyle(SwitchToggleStyle(tint: Color.red))
                .padding(.leading, 5)
                .controlSize(.small)
                .labelsHidden()
                
            Text("删除已完成任务时同时删除本地文件")
                .font(.system(size: 14))
            
            Spacer()
            
            if viewModel.deleteCompletedTasksWithFiles {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                    Text("将删除文件")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(5)
                .padding(.trailing, 5)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                        .font(.system(size: 12))
                    Text("保留文件")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(5)
                .padding(.trailing, 5)
            }
        }
    }
}
