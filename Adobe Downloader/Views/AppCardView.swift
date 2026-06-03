//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//

import SwiftUI
import Combine

private enum AppCardConstants {
    static let cardMinWidth: CGFloat = 200
    static let cardIdealWidth: CGFloat = 220
    static let cardMinHeight: CGFloat = 220
    static let iconSize: CGFloat = 72
    static let iconContainerSize: CGFloat = 88
    static let cornerRadius: CGFloat = 14
    static let buttonHeight: CGFloat = 30
    static let titleFontSize: CGFloat = 14
    static let buttonFontSize: CGFloat = 13
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

    func isProductInstalled(version: String) -> Bool {
        let platform = HDPIMParityDecisionEngine.shared.preferredPlatformId(
            productId: uniqueProduct.id,
            version: version
        ) ?? "unknown"
        return globalNetworkManager.isProductInstalled(
            productId: uniqueProduct.id,
            version: version,
            platform: platform
        )
    }

    func checkAndStartDownload(version: String, language: String) async {
        if isProductInstalled(version: version) {
            await MainActor.run {
                errorMessage = "该产品版本已安装"
                showError = true
            }
            return
        }

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

    private var latestVisibleMatch: (Product, Product.Platform)? {
        let products = globalCcmResult.products.filter { $0.id == uniqueProduct.id }
        return products.compactMap { product -> (Product, Product.Platform)? in
            guard let platform = HDPIMParityDecisionEngine.shared.preferredPlatform(for: product) else {
                return nil
            }
            return (product, platform)
        }.sorted {
            AppStatics.compareVersions($0.0.version, $1.0.version) > 0
        }.first
    }

    var uniqueVersionCount: Int {
        let products = globalCcmResult.products.filter { $0.id == uniqueProduct.id }
        let versions = products.compactMap { product -> String? in
            guard HDPIMParityDecisionEngine.shared.preferredPlatform(for: product) != nil else {
                return nil
            }
            return product.version
        }
        return Set(versions).count
    }

    var latestDependenciesCount: Int {
        latestVisibleMatch?.1.languageSet.first?.dependencies.count ?? 0
    }

    var latestMinOSVersion: String {
        let raw = latestVisibleMatch?.1.range.first?.min ?? ""
        return raw.replacingOccurrences(of: "-", with: "")
    }

    var latestModulesCount: Int {
        latestVisibleMatch?.1.modules.count ?? 0
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

    var activeDownloadTask: NewDownloadTask? {
        globalNetworkManager.downloadTasks.first { task in
            task.productId == uniqueProduct.id && isTaskActive(task.status)
        }
    }

    var isAnyVersionDownloaded: Bool {
        globalNetworkManager.downloadTasks.contains { task in
            guard task.productId == uniqueProduct.id else { return false }
            if case .completed = task.status { return true }
            return false
        }
    }

    var isArchitectureCompatible: Bool {
        !HDPIMParityDecisionEngine.shared.visibleVersions(productId: uniqueProduct.id).isEmpty
    }

    var minOSMajor: Int? {
        let raw = latestVisibleMatch?.1.range.first?.min ?? ""
        let cleaned = raw.replacingOccurrences(of: "-", with: ".")
        let head = cleaned.split(separator: ".").first.map(String.init) ?? ""
        return Int(head)
    }

    var minOSDisplayFormatted: String {
        let raw = latestVisibleMatch?.1.range.first?.min ?? ""
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "." }).map(String.init)
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return "\(parts[0]).\(parts[1])"
        }
    }

    var requiresHighOS: Bool {
        (minOSMajor ?? 0) >= 14
    }

    var shouldHideVersionMetric: Bool {
        uniqueVersionCount > 1
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
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            CardIconView(viewModel: viewModel)
                .frame(width: 96, height: 96)

            Spacer(minLength: 16)

            Text(viewModel.uniqueProduct.displayName)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.primary)
                .padding(.horizontal, 12)

            Spacer(minLength: 8)

            DotBadgeRow(viewModel: viewModel)

            Spacer(minLength: 0)

            if let active = viewModel.activeDownloadTask {
                ActiveDownloadBar(task: active)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            DownloadActionButton(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
        }
        .frame(
            minWidth: 200,
            idealWidth: 220,
            maxWidth: .infinity,
            minHeight: 260,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHovered ? Color(.controlBackgroundColor).opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isHovered ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .modifier(SheetModifier(viewModel: viewModel))
        .modifier(AlertModifier(viewModel: viewModel, confirmRedownload: true))
        .onAppear {
            viewModel.updateDownloadingStatus()
        }
        .onChange(of: globalNetworkManager.downloadTasks.count) { _ in
            viewModel.updateDownloadingStatus()
        }
    }
}

private struct CardIconView: View {
    @ObservedObject var viewModel: AppCardViewModel
    @State private var opacity = 0.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.secondary.opacity(0.05))
                .frame(width: AppCardConstants.iconContainerSize, height: AppCardConstants.iconContainerSize)

            Group {
                if let image = viewModel.iconImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .opacity(opacity)
                        .onAppear {
                            withAnimation(.easeIn(duration: 0.3)) {
                                opacity = 1.0
                            }
                        }
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }
            .frame(width: AppCardConstants.iconSize, height: AppCardConstants.iconSize)
        }
        .onAppear(perform: viewModel.loadIcon)
    }
}

private struct DotBadgeRow: View {
    @ObservedObject var viewModel: AppCardViewModel

    var body: some View {
        let badges = makeBadges()
        if badges.isEmpty {
            Text(fallbackText)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        } else {
            HStack(spacing: 10) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    badge
                }
            }
            .font(.system(size: 11, weight: .medium))
        }
    }

    private var fallbackText: String {
        if viewModel.latestDependenciesCount > 0 {
            return "\(viewModel.latestDependenciesCount) 个依赖组件"
        }
        return String(localized: "最新版本可用")
    }

    private func makeBadges() -> [AnyView] {
        var list: [AnyView] = []
        if viewModel.isAnyVersionDownloaded {
            list.append(AnyView(DotBadge(text: "已下载", tint: .green)))
        }
        if !viewModel.isArchitectureCompatible {
            list.append(AnyView(DotBadge(text: "需切架构", tint: .orange)))
        }
        if viewModel.uniqueVersionCount > 1 && list.count < 2 {
            list.append(AnyView(DotBadge(text: "\(viewModel.uniqueVersionCount) 版本", tint: .secondary)))
        }
        if viewModel.requiresHighOS && list.count < 2 {
            let label = viewModel.minOSDisplayFormatted.isEmpty
                ? String(localized: "高系统需求")
                : "macOS \(viewModel.minOSDisplayFormatted)+"
            list.append(AnyView(DotBadge(text: label, tint: .yellow)))
        }
        return list
    }
}

private struct DotBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

private struct ActiveDownloadBar: View {
    @ObservedObject var task: NewDownloadTask

    private var clampedProgress: Double {
        min(max(task.totalProgress, 0), 1)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 9))
                Text("\(Int(clampedProgress * 100))%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                if task.totalSpeed > 0 {
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(DownloadFormatters.speed(task.totalSpeed))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.blue.opacity(0.85))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.blue.opacity(0.12))
                        .frame(height: 3)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.6), Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * clampedProgress), height: 3)
                        .animation(.linear(duration: 0.3), value: clampedProgress)
                }
            }
            .frame(height: 3)
        }
    }
}

private struct DownloadActionButton: View {
    @ObservedObject var viewModel: AppCardViewModel

    var body: some View {
        Button(action: { viewModel.showVersionPicker = true }) {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isDownloading ? "hourglass.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 12))
                Text(viewModel.isDownloading ? String(localized: "下载中") : String(localized: "下载"))
                    .font(.system(size: AppCardConstants.buttonFontSize, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: AppCardConstants.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: viewModel.isDownloading ? Color.gray.opacity(0.6) : Color.blue))
        .disabled(viewModel.isDownloading)
        .help(viewModel.isDownloading ? String(localized: "已有下载任务进行中，可在下载管理查看进度") : String(localized: "选择版本并下载"))
    }
}

struct SheetModifier: ViewModifier {
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
