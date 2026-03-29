//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//

import SwiftUI
import Combine

private enum AppCardConstants {
    static let cardWidth: CGFloat = 250
    static let cardHeight: CGFloat = 200
    static let iconSize: CGFloat = 64
    static let cornerRadius: CGFloat = 12
    static let buttonHeight: CGFloat = 24
    static let titleFontSize: CGFloat = 16
    static let buttonFontSize: CGFloat = 14
    
    static let shadowOpacity: Double = 0.1
    static let shadowRadius: CGFloat = 4
    static let strokeOpacity: Double = 0.15
    static let strokeWidth: CGFloat = 1
    static let backgroundOpacity: Double = 0.05
    static let hoverScale: CGFloat = 1.02
    
    static let iconPlaceholderOpacity: Double = 0.6
    static let iconLoadingDuration: Double = 0.3
}

final class IconCache {
    static let shared = IconCache()
    private var cache = NSCache<NSString, NSImage>()
    
    func getIcon(for url: String) -> NSImage? {
        cache.object(forKey: url as NSString)
    }
    
    func setIcon(_ image: NSImage, for url: String) {
        cache.setObject(image, forKey: url as NSString)
    }
}

@MainActor
final class AppCardViewModel: ObservableObject {
    @Published var iconImage: NSImage?
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showVersionPicker = false
    @Published var selectedVersion = ""
    @Published var showLanguagePicker = false
    @Published var selectedLanguage = ""
    @Published var showExistingFileAlert = false
    @Published var existingFilePath: URL?
    @Published var pendingVersion = ""
    @Published var pendingLanguage = ""
    @Published var showRedownloadConfirm = false
    
    let uniqueProduct: UniqueProduct
    
    @Published var isDownloading = false
    private let userDefaults = UserDefaults.standard
    
    private var useDefaultDirectory: Bool {
        StorageData.shared.useDefaultDirectory
    }
    
    private var defaultDirectory: String {
        StorageData.shared.defaultDirectory
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    init(uniqueProduct: UniqueProduct) {
        self.uniqueProduct = uniqueProduct

        Task { @MainActor in
            setupObservers()
        }
    }
    
    @MainActor
    private func setupObservers() {
        globalNetworkManager.$downloadTasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                guard let self = self else { return }
                let hasActiveTask = tasks.contains { 
                    $0.productId == self.uniqueProduct.id && self.isTaskActive($0.status)
                }
                
                if hasActiveTask != self.isDownloading {
                    self.isDownloading = hasActiveTask
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        
        globalNetworkManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDownloadingStatus()
            }
            .store(in: &cancellables)
    }
    
    private func isTaskActive(_ status: DownloadStatus) -> Bool {
        switch status {
        case .downloading, .preparing, .waiting, .retrying:
            return true
        case .paused:
            return false
        case .completed, .failed:
            return false
        }
    }
    
    @MainActor
    func updateDownloadingStatus() {
        let hasActiveTask = globalNetworkManager.downloadTasks.contains { 
            $0.productId == uniqueProduct.id && isTaskActive($0.status)
        }
        
        if hasActiveTask != self.isDownloading {
            self.isDownloading = hasActiveTask
            self.objectWillChange.send()
        }
    }
    
    func getDestinationURL(version: String, language: String) async throws -> URL {
        let platform = HDPIMParityDecisionEngine.shared.preferredPlatformId(
            productId: uniqueProduct.id,
            version: version
        ) ?? "unknown"
        let installerName = uniqueProduct.id == "APRO"
            ? "Adobe Downloader \(uniqueProduct.id)_\(version)_\(platform).dmg"
            : "Adobe Downloader \(uniqueProduct.id)_\(version)-\(language)-\(platform)"

        if useDefaultDirectory && !defaultDirectory.isEmpty {
            return URL(fileURLWithPath: defaultDirectory)
                .appendingPathComponent(installerName)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "选择保存位置"
                panel.canCreateDirectories = true
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                
                if panel.runModal() == .OK, let selectedURL = panel.url {
                    continuation.resume(returning: selectedURL.appendingPathComponent(installerName))
                } else {
                    continuation.resume(throwing: NetworkError.cancelled)
                }
            }
        }
    }

    func handleError(_ error: Error) {
        Task { @MainActor in
            if case NetworkError.cancelled = error { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func loadIcon() {
        if iconImage != nil { return }
        
        if let bestIcon = globalProducts.first(where: { $0.id == uniqueProduct.id })?.getBestIcon(),
           let iconURL = URL(string: bestIcon.value) {
            if let cachedImage = IconCache.shared.getIcon(for: bestIcon.value) {
                self.iconImage = cachedImage
                return
            }
            
            Task {
                do {
                    var request = URLRequest(url: iconURL)
                    request.timeoutInterval = 10
                    
                    let (data, response) = try await URLSession.shared.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    
                    await MainActor.run {
                        if let image = NSImage(data: data) {
                            IconCache.shared.setIcon(image, for: bestIcon.value)
                            self.iconImage = image
                        }
                    }
                } catch {
                    await MainActor.run {
                        if let localImage = NSImage(named: uniqueProduct.id) {
                            self.iconImage = localImage
                        }
                    }
                }
            }
        } else {
            if let localImage = NSImage(named: uniqueProduct.id) {
                self.iconImage = localImage
            }
        }
    }

    func handleDownloadRequest(_ version: String, useDefaultLanguage: Bool, defaultLanguage: String) async {
        await MainActor.run {
            if useDefaultLanguage {
                Task {
                    await checkAndStartDownload(version: version, language: defaultLanguage)
                }
            } else {
                selectedVersion = version
                showLanguagePicker = true
            }
        }
    }
    
    func checkAndStartDownload(version: String, language: String) async {
        if let existingPath = globalNetworkManager.isVersionDownloaded(productId: uniqueProduct.id, version: version, language: language) {
            await MainActor.run {
                existingFilePath = existingPath
                pendingVersion = version
                pendingLanguage = language
                showExistingFileAlert = true
            }
        } else {
            if uniqueProduct.id == "APRO" {
                await startAPRODownload(version: version, language: language)
            } else {
                await MainActor.run {
                    selectedVersion = version
                    selectedLanguage = language
                    showVersionPicker = true
                }
            }
        }
    }
    
    func startAPRODownload(version: String, language: String) async {
        do {
            let destinationURL = try await getDestinationURL(version: version, language: language)
            
            try await globalNetworkManager.startCustomDownload(
                productId: uniqueProduct.id,
                selectedVersion: version,
                language: language,
                destinationURL: destinationURL,
                customDependencies: []
            )
        } catch {
            handleError(error)
        }
    }

    func createCompletedTask(_ path: URL) async {
        let existingTask = globalNetworkManager.downloadTasks.first { task in
            return task.productId == uniqueProduct.id &&
                   task.productVersion == pendingVersion &&
                   task.language == pendingLanguage &&
                   task.directory == path
        }
        
        if existingTask != nil {
            return
        }

        await TaskPersistenceManager.shared.createExistingProgramTask(
            productId: uniqueProduct.id,
            version: pendingVersion,
            language: pendingLanguage,
            displayName: uniqueProduct.displayName,
            platform: HDPIMParityDecisionEngine.shared.preferredPlatformId(
                productId: uniqueProduct.id,
                version: pendingVersion
            ) ?? "unknown",
            directory: path
        )
        
        let savedTasks = await TaskPersistenceManager.shared.loadTasks()
        await MainActor.run {
            globalNetworkManager.downloadTasks = savedTasks
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }
    }
    
    var dependenciesCount: Int {
        let latestVisible = HDPIMParityDecisionEngine.shared.visibleVersions(productId: uniqueProduct.id).first
        return latestVisible?.value.languageSet.first?.dependencies.count ?? 0
    }
    
    var hasValidIcon: Bool {
        iconImage != nil
    }
    
    var canDownload: Bool {
        !isDownloading
    }
    
    var downloadButtonTitle: String {
        isDownloading ? String(localized: "下载中") : String(localized: "下载")
    }
    
    var downloadButtonIcon: String {
        isDownloading ? "hourglass.circle.fill" : "arrow.down.circle"
    }
}

struct AppCardView: View {
    @StateObject private var viewModel: AppCardViewModel
    @StorageValue(\.useDefaultLanguage) private var useDefaultLanguage
    @StorageValue(\.defaultLanguage) private var defaultLanguage
    @State private var isHovered = false

    init(uniqueProduct: UniqueProduct) {
        _viewModel = StateObject(wrappedValue: AppCardViewModel(uniqueProduct: uniqueProduct))
    }
    
    var body: some View {
        CardContainer {
            VStack {
                IconView(viewModel: viewModel)
                ProductInfoView(viewModel: viewModel)
                Spacer()
                DownloadButtonView(viewModel: viewModel)
            }
            .drawingGroup()
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color(.controlBackgroundColor) : Color(.windowBackgroundColor).opacity(0.5))
                .animation(.easeInOut(duration: 0.2), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? Color.blue.opacity(0.5) : Color.gray.opacity(0.1), lineWidth: isHovered ? 2 : 1)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
        )
        .shadow(color: isHovered ? Color.black.opacity(0.1) : Color.black.opacity(0.05),
                radius: isHovered ? 4 : 2,
                x: 0,
                y: isHovered ? 2 : 1)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            self.isHovered = hovering
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .contentShape(Rectangle())
        .modifier(CardModifier())
        .modifier(SheetModifier(viewModel: viewModel))
        .modifier(AlertModifier(viewModel: viewModel, confirmRedownload: true))
        .onAppear(perform: setupViewModel)
        .onChange(of: globalNetworkManager.downloadTasks.count) { _ in
            updateDownloadStatus()
        }
    }
    
    private func setupViewModel() {
        viewModel.updateDownloadingStatus()
    }
    
    private func updateDownloadStatus() {
        viewModel.updateDownloadingStatus()
    }
}

private struct CardContainer<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding()
            .frame(width: AppCardConstants.cardWidth, height: AppCardConstants.cardHeight)
    }
}

private struct IconView: View {
    @ObservedObject var viewModel: AppCardViewModel
    @State private var isLoading = true
    @State private var opacity = 0.0
    
    var body: some View {
        Group {
            if viewModel.hasValidIcon {
                Image(nsImage: viewModel.iconImage!)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .opacity(opacity)
                    .onAppear {
                        withAnimation(.easeIn(duration: AppCardConstants.iconLoadingDuration)) {
                            opacity = 1.0
                        }
                    }
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
                    .opacity(AppCardConstants.iconPlaceholderOpacity)
            }
        }
        .frame(width: AppCardConstants.iconSize, height: AppCardConstants.iconSize)
        .onAppear(perform: viewModel.loadIcon)
    }
}

private struct ProductInfoView: View {
    @ObservedObject var viewModel: AppCardViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            Text(viewModel.uniqueProduct.displayName)
                .font(.system(size: AppCardConstants.titleFontSize))
                .fontWeight(.semibold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            
            let products = globalCcmResult.products.filter { $0.id == viewModel.uniqueProduct.id }
            let visibleMatches = products.compactMap { product -> (Product, Product.Platform)? in
                guard let platform = HDPIMParityDecisionEngine.shared.preferredPlatform(for: product) else {
                    return nil
                }
                return (product, platform)
            }
            let versions = visibleMatches.map(\.0.version)
            let uniqueVersions = Set(versions)
            
            let latestVisibleMatch = visibleMatches.sorted {
                AppStatics.compareVersions($0.0.version, $1.0.version) > 0
            }.first
            let dependenciesCount = latestVisibleMatch?.1.languageSet.first?.dependencies.count ?? 0
            let minOSVersion = latestVisibleMatch?.1.range.first?.min ?? ""
            let modulesCount = latestVisibleMatch?.1.modules.count ?? 0
            
            HStack(spacing: 12) {
                MetricView(icon: "tag", value: "\(uniqueVersions.count)")

                if dependenciesCount > 0 {
                    Divider()
                        .frame(height: 12)
                    MetricView(icon: "shippingbox", value: "\(dependenciesCount)")
                }

                if !minOSVersion.isEmpty {
                    Divider()
                        .frame(height: 12)
                    MetricView(icon: "macwindow", value: minOSVersion.replacingOccurrences(of: "-", with: ""))
                }
                
                if modulesCount > 0 {
                    Divider()
                        .frame(height: 12)
                    MetricView(icon: "square.stack.3d.up", value: "\(modulesCount)")
                }
            }
            .background(Color(.clear))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .background(Color(.clear))
    }
}

private struct MetricView: View {
    let icon: String
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(value)
                .fontWeight(.medium)
        }
    }
}

private struct DownloadButtonView: View {
    @ObservedObject var viewModel: AppCardViewModel
    @State private var isHovered = false
    
    var body: some View {
        Button(action: { viewModel.showVersionPicker = true }) {
            Label(viewModel.downloadButtonTitle,
                  systemImage: viewModel.downloadButtonIcon)
                .font(.system(size: AppCardConstants.buttonFontSize, weight: .medium))
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: AppCardConstants.buttonHeight)
                .contentShape(Rectangle())
                .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: viewModel.isDownloading ? Color.gray : Color.blue))
        .disabled(!viewModel.canDownload)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct CardModifier: ViewModifier {
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            .background(Color(NSColor.clear))
            .overlay(
                RoundedRectangle(cornerRadius: AppCardConstants.cornerRadius)
                    .stroke(Color.gray.opacity(AppCardConstants.strokeOpacity), 
                           lineWidth: AppCardConstants.strokeWidth)
            )
            .shadow(
                color: Color.primary.opacity(isHovered ? AppCardConstants.shadowOpacity * 2 : AppCardConstants.shadowOpacity),
                radius: isHovered ? AppCardConstants.shadowRadius * 1.5 : AppCardConstants.shadowRadius,
                x: 0,
                y: isHovered ? 4 : 2
            )
            .scaleEffect(isHovered ? AppCardConstants.hoverScale : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct SheetModifier: ViewModifier {
    @ObservedObject var viewModel: AppCardViewModel
    @StorageValue(\.useDefaultLanguage) private var useDefaultLanguage
    @StorageValue(\.defaultLanguage) private var defaultLanguage
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showVersionPicker) {
                if findProduct(id: viewModel.uniqueProduct.id) != nil {
                    NavigationVersionPickerView(productId: viewModel.uniqueProduct.id) { version in
                        Task {
                            await viewModel.handleDownloadRequest(
                                version,
                                useDefaultLanguage: useDefaultLanguage,
                                defaultLanguage: defaultLanguage
                            )
                        }
                    }
                }
            }
            .sheet(isPresented: $viewModel.showLanguagePicker) {
                LanguagePickerView(languages: AppStatics.supportedLanguages) { language in
                    Task {
                        await viewModel.checkAndStartDownload(
                            version: viewModel.selectedVersion,
                            language: language
                        )
                    }
                }
            }
    }
}

struct AlertModifier: ViewModifier {
    @ObservedObject var viewModel: AppCardViewModel
    let confirmRedownload: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showExistingFileAlert) {
                if let path = viewModel.existingFilePath {
                    ExistingFileAlertView(
                        path: path,
                        onUseExisting: {
                            viewModel.showExistingFileAlert = false
                            if !viewModel.pendingVersion.isEmpty && !viewModel.pendingLanguage.isEmpty {
                                Task {
                                    if !globalNetworkManager.downloadTasks.contains(where: { task in
                                           task.productId == viewModel.uniqueProduct.id &&
                                           task.productVersion == viewModel.pendingVersion &&
                                           task.language == viewModel.pendingLanguage
                                       }) {
                                        await viewModel.createCompletedTask(path)
                                    }
                                }
                            }
                        },
                        onRedownload: {
                            viewModel.showExistingFileAlert = false
                            if !viewModel.pendingVersion.isEmpty && !viewModel.pendingLanguage.isEmpty {
                                if confirmRedownload {
                                    viewModel.showRedownloadConfirm = true
                                } else {
                                    Task {
                                        await startRedownload()
                                    }
                                }
                            }
                        },
                        onCancel: {
                            viewModel.showExistingFileAlert = false
                        },
                        iconImage: viewModel.iconImage
                    )
                }
            }
            .alert("确认重新下载", isPresented: $viewModel.showRedownloadConfirm) {
                Button("取消", role: .cancel) { }
                Button("确认") {
                    Task {
                        await startRedownload()
                    }
                }
            } message: {
                Text("是否确认重新下载？这将覆盖现有的安装程序。")
            }
            .alert("下载错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) { }
                Button("重试") {
                    if !viewModel.selectedVersion.isEmpty {
                        Task {
                            await viewModel.checkAndStartDownload(
                                version: viewModel.selectedVersion,
                                language: viewModel.selectedLanguage
                            )
                        }
                    }
                }
            } message: {
                Text(viewModel.errorMessage)
            }
    }
    
    private func startRedownload() async {
        globalNetworkManager.downloadTasks.removeAll { task in
            task.productId == viewModel.uniqueProduct.id &&
            task.productVersion == viewModel.pendingVersion &&
            task.language == viewModel.pendingLanguage
        }
        
        if let existingPath = viewModel.existingFilePath {
            try? FileManager.default.removeItem(at: existingPath)
        }
        
        await MainActor.run {
            viewModel.selectedVersion = viewModel.pendingVersion
            viewModel.selectedLanguage = viewModel.pendingLanguage
            viewModel.showVersionPicker = true
        }
    }
}
