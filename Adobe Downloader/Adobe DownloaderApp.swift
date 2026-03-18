import SwiftUI
import Sparkle

@main
struct Adobe_DownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showBackupAlert = false
    @State private var showTipsSheet = false
    @State private var showLanguagePicker = false
    @State private var showCreativeCloudAlert = false
    @State private var showBackupResultAlert = false
    @State private var showSettingsView = false
    
    @StateObject private var backupResult = BackupResult()
    
    private var storage: StorageData { StorageData.shared }
    private let updaterController: SPUStandardUpdaterController

    init() {
        HDPIMHeadlessInstallRunner.runIfNeeded()

        globalNetworkService = NewNetworkService()
        globalNetworkManager = NetworkManager()
        globalNewDownloadUtils = NewDownloadUtils()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        if storage.installedHelperBuild == "0" {
            storage.installedHelperBuild = "0"
        }

        if storage.isFirstLaunch {
            initializeFirstLaunch()
        }

        if storage.apiVersion == "6" {
            storage.apiVersion = "6"
        }
    }
    
    private func initializeFirstLaunch() {
        storage.downloadAppleSilicon = AppStatics.isAppleSilicon
        storage.confirmRedownload = true
        
        let systemLanguage = Locale.current.identifier
        let matchedLanguage = AppStatics.supportedLanguages.first {
            systemLanguage.hasPrefix($0.code.prefix(2))
        }?.code ?? "ALL"
        storage.defaultLanguage = matchedLanguage
        storage.useDefaultLanguage = true
        
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            storage.defaultDirectory = downloadsURL.path
            storage.useDefaultDirectory = true
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                BlurView()
                    .ignoresSafeArea()

                ContentView(showSettingsView: $showSettingsView)
                    .environmentObject(globalNetworkManager)
                    .frame(minWidth: 792, minHeight: 600)
                    .tint(.blue)
                    .task {
                        await setupApplication()
                    }
                    .sheet(isPresented: $showCreativeCloudAlert) {
                        ShouldExistsSetUpView()
                            .environmentObject(globalNetworkManager)
                    }
                    .sheet(isPresented: $showBackupAlert) {
                        SetupBackupAlertView(
                            onConfirm: {
                                showBackupAlert = false
                                handleBackup()
                            },
                            onCancel: {
                                showBackupAlert = false
                            }
                        )
                    }
                    .sheet(isPresented: $showBackupResultAlert) {
                        SetupBackupResultView(
                            isSuccess: backupResult.success, 
                            message: backupResult.message,
                            onDismiss: {
                                showBackupResultAlert = false
                            }
                        )
                    }
                    .sheet(isPresented: $showTipsSheet) {
                        TipsSheetView(
                            showTipsSheet: $showTipsSheet,
                            showLanguagePicker: $showLanguagePicker
                        )
                        .environmentObject(globalNetworkManager)
                        .sheet(isPresented: $showLanguagePicker) {
                            LanguagePickerView(languages: AppStatics.supportedLanguages) { language in
                                storage.defaultLanguage = language
                                showLanguagePicker = false
                            }
                        }
                    }
                    .sheet(isPresented: $showSettingsView) {
                        CustomSettingsView(updater: updaterController.updater)
                            .interactiveDismissDisabled(false)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizabilityContentSize()
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                
                Divider()
                
                Button("设置...") {
                    showSettingsView = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
    
    private func setupApplication() async {
         Task {
             PrivilegedHelperAdapter.shared.checkInstall()
         }

        await MainActor.run {
            globalNetworkManager.loadSavedTasks()
        }

        await MainActor.run {
            if storage.isFirstLaunch {
                showTipsSheet = true
                storage.isFirstLaunch = false
            }
        }
    }
    
    private func handleBackup() {
        ModifySetup.backupAndModifySetupFile { success, message in
            DispatchQueue.main.async {
                self.backupResult.success = success
                self.backupResult.message = message
                self.showBackupResultAlert = true
            }
        }
    }
}

extension Scene {
    func windowResizabilityContentSize() -> some Scene {
        if #available(macOS 13.0, *) {
            return windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

class BackupResult: ObservableObject {
    @Published var success: Bool = false
    @Published var message: String = ""
}
