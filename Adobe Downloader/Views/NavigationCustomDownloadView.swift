//
//  NavigationCustomDownloadView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/07/19.
//

import SwiftUI

class CustomDownloadLoadingState: ObservableObject {
    @Published var isLoading = true
    @Published var currentTask = ""
    @Published var error: String?
}

private struct DownloadedPackageScanItem: Sendable {
    let id: UUID
    let sapCode: String
    let fullPackageName: String
    let downloadSize: Int64
}

private enum CustomDownloadPackageInfoLoader {
    static func fetch(
        productId: String,
        version: String,
        useDelta: Bool,
        requestedLanguage: String,
        progressHandler: @escaping (String) -> Void
    ) async throws -> ([Package], [DependenciesToDownload]) {
        guard let snapshot = CatalogStore.shared.snapshot,
              let product = snapshot.product(id: productId, version: version) else {
            throw NetworkError.invalidData(AppLocalized("找不到产品信息"))
        }

        if isManifestInstallerProduct(productId) {
            return try makeInstallerPackageInfo(
                productId: productId,
                version: version,
                requestedLanguage: requestedLanguage,
                product: product,
                snapshot: snapshot
            )
        }

        let decision = try await HDPIMParityDecisionEngine.shared.resolveDownloadDecision(
            productId: product.id,
            version: version,
            requestedLanguage: requestedLanguage,
            catalogSnapshot: snapshot,
            progressHandler: progressHandler
        )

        return HDPIMParityDecisionEngine.shared.makeDownloadPresentation(from: decision, useDelta: useDelta)
    }

    private static func makeInstallerPackageInfo(
        productId: String,
        version: String,
        requestedLanguage: String,
        product: Product,
        snapshot: CatalogSnapshot
    ) throws -> ([Package], [DependenciesToDownload]) {
        let match = try catalogInstallerMatch(
            product: product, targetArchitecture: snapshot.context.architecture, requestedLanguage: requestedLanguage
        )

        let platform = match.platform
        let languageSet = match.languageSet
        let productVersion = installerProductVersion(product: product, languageSet: languageSet, selectedVersion: version)
        let package = Package(
            type: "dmg",
            fullPackageName: installerOutputName(
                productId: productId,
                version: version,
                language: requestedLanguage,
                platform: platform.id
            ),
            downloadSize: Int64(max(languageSet.installSize, 0)),
            downloadURL: normalizedInstallerURL(languageSet.lbsURL, cdn: product.channelCDN ?? snapshot.cdn),
            manifestURL: normalizedInstallerURL(languageSet.manifestURL, cdn: product.channelCDN ?? snapshot.cdn),
            packageVersion: productVersion
        )
        package.isSelected = true
        package.isRequired = true
        package.isDefaultSelected = true

        let dependency = DependenciesToDownload(
            sapCode: productId,
            version: version,
            buildGuid: languageSet.buildGuid,
            platform: platform.id
        )
        dependency.catalogSnapshot = snapshot
        dependency.catalogCDN = product.channelCDN ?? snapshot.cdn
        dependency.catalogLanguage = requestedLanguage
        dependency.packages = [package]
        return ([package], [dependency])
    }
}

struct NavigationCustomDownloadView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @StateObject private var loadingState = CustomDownloadLoadingState()
    @State private var allPackages: [Package] = []
    @State private var dependenciesToDownload: [DependenciesToDownload] = []
    @State private var showExistingFileAlert = false
    @State private var showInstalledAlert = false
    @State private var existingFilePath: URL?
    @State private var pendingDependencies: [DependenciesToDownload] = []
    @State private var productIcon: NSImage? = nil

    let productId: String
    let version: String
    let useDelta: Bool
    let onDownloadStart: ([DependenciesToDownload]) -> Void
    let onDismiss: () -> Void

    init(productId: String, version: String, useDelta: Bool = false, onDownloadStart: @escaping ([DependenciesToDownload]) -> Void, onDismiss: @escaping () -> Void) {
        self.productId = productId
        self.version = version
        self.useDelta = useDelta
        self.onDownloadStart = onDownloadStart
        self.onDismiss = onDismiss
    }

    var body: some View {
        let _ = interfaceLanguage
        Group {
            if loadingState.isLoading {
                NavigationCustomDownloadLoadingView(
                    loadingState: loadingState,
                    productId: productId,
                    version: version,
                    productIcon: productIcon,
                    onCancel: onDismiss
                )
            } else if loadingState.error != nil {
                NavigationCustomDownloadErrorView(
                    productId: productId,
                    version: version,
                    productIcon: productIcon,
                    errorMessage: loadingState.error ?? "",
                    onRetry: {
                        loadingState.error = nil
                        loadingState.isLoading = true
                        loadPackageInfo()
                    },
                    onBack: onDismiss
                )
            } else {
                NavigationCustomPackageSelectorView(
                    productId: productId,
                    version: version,
                    productIcon: productIcon,
                    packages: allPackages,
                    dependenciesToDownload: dependenciesToDownload,
                    onDownloadStart: { dependencies in
                        onDownloadStart(dependencies)
                    },
                    onCancel: onDismiss,
                    onFileExists: { path, dependencies in
                        startCustomDownloadProcess(dependencies: dependencies, destinationURL: path)
                    },
                    onInstalledProduct: {
                        showInstalledAlert = true
                    }
                )
            }
        }
        .onAppear {
            if loadingState.isLoading {
                loadPackageInfo()
            }
            loadProductIcon()
        }
        .sheet(isPresented: $showExistingFileAlert) {
            if let existingPath = existingFilePath {
                ExistingFileAlertView(
                    path: existingPath,
                    onUseExisting: {
                        showExistingFileAlert = false
                        if let existingPath = existingFilePath {
                            startCustomDownloadProcess(dependencies: pendingDependencies, destinationURL: existingPath)
                        }
                        pendingDependencies = []
                    },
                    onRedownload: {
                        showExistingFileAlert = false
                        startCustomDownloadProcess(dependencies: pendingDependencies)
                    },
                    onCancel: {
                        showExistingFileAlert = false
                        pendingDependencies = []
                    },
                    iconImage: productIcon
                )
            }
        }
        .alert(AppLocalized("提示"), isPresented: $showInstalledAlert) {
            Button(AppLocalized("确定"), role: .cancel) { }
        } message: {
            Text(AppLocalized("该产品版本已安装"))
        }
    }

    private func loadPackageInfo() {
        Task {
            do {
                let (packages, dependencies) = try await fetchPackageInfo()
                await MainActor.run {
                    allPackages = packages
                    dependenciesToDownload = dependencies
                    loadingState.isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadingState.isLoading = false
                    loadingState.error = error.localizedDescription
                }
            }
        }
    }

    private func fetchPackageInfo() async throws -> ([Package], [DependenciesToDownload]) {
        try await CustomDownloadPackageInfoLoader.fetch(
            productId: productId,
            version: version,
            useDelta: useDelta,
            requestedLanguage: StorageData.shared.defaultLanguage
        ) { message in
            Task { @MainActor in
                loadingState.currentTask = message
            }
        }
    }

    private func createCompletedCustomTask(path: URL, dependencies: [DependenciesToDownload]) async {
        guard let main = dependencies.first(where: { $0.sapCode == productId }),
              let snapshot = main.catalogSnapshot else { return }
        let language = main.catalogLanguage ?? StorageData.shared.defaultLanguage
        let platform = main.platform
        let existingTask = globalNetworkManager.downloadTasks.first { task in
            return task.productId == productId &&
                   task.productVersion == version &&
                   task.language == language &&
                   task.platform == platform &&
                   task.targetArchitecture == snapshot.context.architecture.rawValue &&
                   task.directory == path
        }

        if existingTask != nil {
            return
        }

        let task = NewDownloadTask(
            productId: productId,
            productVersion: version,
            language: language,
            displayName: snapshot.product(id: productId, version: version)?.displayName ?? productId,
            directory: path,
            dependenciesToDownload: dependencies,
            retryCount: 0,
            createAt: Date(),
            totalProgress: 1.0,
            platform: platform,
            targetArchitecture: snapshot.context.architecture.rawValue
        )

        task.catalogSnapshot = snapshot
        task.dependenciesToDownload = dependencies

        let totalSize = dependencies.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }
        task.totalSize = totalSize
        task.totalDownloadedSize = totalSize
        task.totalProgress = 1.0

        for dependency in dependencies {
            for package in dependency.packages where package.isSelected {
                package.downloaded = true
                package.progress = 1.0
                package.downloadedSize = package.downloadSize
                package.status = .completed
            }
        }

        task.setStatus(DownloadStatus.completed(DownloadStatus.CompletionInfo(
            timestamp: Date(),
            totalTime: 0,
            totalSize: totalSize
        )))

        await MainActor.run {
            globalNetworkManager.downloadTasks.append(task)
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }

        await globalNetworkManager.saveTask(task)
    }

    private func startCustomDownloadProcess(dependencies: [DependenciesToDownload], destinationURL existingDestinationURL: URL? = nil) {
        guard let main = dependencies.first(where: { $0.sapCode == productId }) else { return }
        let language = main.catalogLanguage ?? StorageData.shared.defaultLanguage
        let platform = main.platform
        Task {
            let destinationURL: URL
            if let existingDestinationURL {
                destinationURL = existingDestinationURL
            } else {
                do {
                    destinationURL = try await getDestinationURL(
                        productId: productId,
                        version: version,
                        language: language,
                        mainPlatform: platform
                    )
                } catch {
                    await MainActor.run { onDismiss() }
                    return
                }
            }

            do {
                try await globalNetworkManager.startCustomDownload(
                    productId: productId,
                    selectedVersion: version,
                    language: language,
                    destinationURL: destinationURL,
                    customDependencies: dependencies
                )
            } catch {
                print("自定义下载失败: \(error.localizedDescription)")
            }

            await MainActor.run {
                onDismiss()
            }
        }
    }

    private func getDestinationURL(productId: String, version: String, language: String, mainPlatform: String) async throws -> URL {
        let platform = mainPlatform
        let installerName = installerOutputName(
            productId: productId,
            version: version,
            language: language,
            platform: platform
        )

        if StorageData.shared.useDefaultDirectory && !StorageData.shared.defaultDirectory.isEmpty {
            return URL(fileURLWithPath: StorageData.shared.defaultDirectory)
                .appendingPathComponent(installerName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = AppLocalized("选择保存位置")
                panel.canCreateDirectories = true
                panel.canChooseDirectories = true
                panel.canChooseFiles = false

                if let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    panel.directoryURL = downloadsDir
                }

                let result = panel.runModal()
                if result == .OK, let selectedURL = panel.url {
                    continuation.resume(returning: selectedURL.appendingPathComponent(installerName))
                } else {
                    continuation.resume(throwing: NetworkError.cancelled)
                }
            }
        }
    }

    private func loadProductIcon() {
        guard let product = findProduct(id: productId),
              let icon = product.getBestIcon(),
              let iconURL = URL(string: icon.value) else {
            return
        }

        if let cached = IconCache.shared.getIcon(for: icon.value) {
            productIcon = cached
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: iconURL)
                if let image = NSImage(data: data) {
                    IconCache.shared.setIcon(image, for: icon.value)
                    await MainActor.run {
                        productIcon = image
                    }
                }
            } catch {
                print("加载产品图标失败: \(error.localizedDescription)")
            }
        }
    }

}

private struct CustomDownloadPageConstants {
    static let minWidth: CGFloat = 780
    static let idealWidth: CGFloat = 840
    static let maxWidth: CGFloat = 1100
    static let minHeight: CGFloat = 600
    static let idealHeight: CGFloat = 680
    static let maxHeight: CGFloat = 900
}

private struct CustomDownloadHeaderView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let productId: String
    let version: String
    let productIcon: NSImage?
    var architecture: HDPIMParityTargetArchitecture? = nil
    var onCopyAll: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @StorageValue(\.downloadAppleSilicon) private var downloadAppleSilicon

    var body: some View {
        let _ = interfaceLanguage
        HStack(spacing: 12) {
            productIconView
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(findProduct(id: productId)?.displayName ?? productId)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(version)")
                        .monospacedDigit()
                    Text("·")
                        .foregroundColor(.secondary.opacity(0.5))
                    architectureChip
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            if let onCopyAll {
                Button(action: onCopyAll) {
                    Label(AppLocalized("复制清单"), systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(AppLocalized("复制所有包信息"))
            }

            if let onCancel {
                Button(AppLocalized("取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    @ViewBuilder
    private var productIconView: some View {
        if let nsImage = productIcon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if let product = findProduct(id: productId),
                  let icon = product.getBestIcon(),
                  let iconURL = URL(string: icon.value) {
            AsyncImage(url: iconURL) { image in
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.blue)
            }
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.blue)
        }
    }

    private var architectureChip: some View {
        let isAppleSilicon = architecture.map { $0 == .appleSilicon } ?? downloadAppleSilicon
        return Text(isAppleSilicon ? "Apple Silicon" : "Intel")
            .font(.system(size: 11, weight: .medium))
    }

}

private struct NavigationCustomDownloadLoadingView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @ObservedObject var loadingState: CustomDownloadLoadingState

    let productId: String
    let version: String
    let productIcon: NSImage?
    let onCancel: () -> Void

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            CustomDownloadHeaderView(
                productId: productId,
                version: version,
                productIcon: productIcon,
                onCancel: onCancel
            )

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.08))
                        .frame(width: 72, height: 72)
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .controlSize(.large)
                }

                VStack(spacing: 6) {
                    Text(AppLocalized("正在获取包信息"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.9))

                    if !loadingState.currentTask.isEmpty {
                        Text(loadingState.currentTask)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text(AppLocalized("正在解析依赖与包清单…"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LoadingStageRow(title: AppLocalized("解析版本信息"))
                    LoadingStageRow(title: AppLocalized("下载产品清单"))
                    LoadingStageRow(title: AppLocalized("展开依赖与可选模块"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            HStack {
                Spacer()
                Button(AppLocalized("取消")) {
                    onCancel()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))
            }
            .padding()
        }
        .frame(
            minWidth: CustomDownloadPageConstants.minWidth,
            idealWidth: CustomDownloadPageConstants.idealWidth,
            maxWidth: CustomDownloadPageConstants.maxWidth,
            minHeight: CustomDownloadPageConstants.minHeight,
            idealHeight: CustomDownloadPageConstants.idealHeight,
            maxHeight: CustomDownloadPageConstants.maxHeight
        )
        .navigationTitle(AppLocalized("自定义下载"))
    }
}

private struct LoadingStageRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
            Spacer(minLength: 0)
        }
    }
}

private struct NavigationCustomDownloadErrorView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let productId: String
    let version: String
    let productIcon: NSImage?
    let errorMessage: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            CustomDownloadHeaderView(
                productId: productId,
                version: version,
                productIcon: productIcon,
                onCancel: onBack
            )

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.1))
                        .frame(width: 80, height: 80)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.orange)
                }

                VStack(spacing: 8) {
                    Text(AppLocalized("加载失败"))
                        .font(.system(size: 16, weight: .semibold))

                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .textSelection(.enabled)

                    Text(AppLocalized("提示：请检查网络连接或尝试返回重新选择版本"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11))
                            Text(AppLocalized("返回选择版本"))
                        }
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))

                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text(AppLocalized("重试"))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
        .frame(
            minWidth: CustomDownloadPageConstants.minWidth,
            idealWidth: CustomDownloadPageConstants.idealWidth,
            maxWidth: CustomDownloadPageConstants.maxWidth,
            minHeight: CustomDownloadPageConstants.minHeight,
            idealHeight: CustomDownloadPageConstants.idealHeight,
            maxHeight: CustomDownloadPageConstants.maxHeight
        )
        .navigationTitle(AppLocalized("自定义下载"))
    }
}

private enum CustomPackageFilter: String, CaseIterable, Identifiable {
    case required
    case optional
    case core
    case nonCore
    case selectedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .required: return AppLocalized("必需")
        case .optional: return AppLocalized("可选")
        case .core: return AppLocalized("核心包")
        case .nonCore: return AppLocalized("非核心包")
        case .selectedOnly: return AppLocalized("仅已选")
        }
    }

    var icon: String {
        switch self {
        case .required: return "lock.fill"
        case .optional: return "slider.horizontal.3"
        case .core: return "cube.fill"
        case .nonCore: return "cube.transparent"
        case .selectedOnly: return "checkmark.circle.fill"
        }
    }

    var categoryColor: Color? {
        switch self {
        case .required: return .orange
        case .optional: return .blue
        case .core: return .purple
        case .nonCore: return .teal
        case .selectedOnly: return nil
        }
    }
}

private struct CustomFilterChip: View {
    let title: String
    let icon: String
    var categoryColor: Color? = nil
    let isActive: Bool
    let onTap: () -> Void

    private var tint: Color {
        categoryColor ?? .accentColor
    }

    var body: some View {
        Button(action: onTap) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: isActive || categoryColor != nil ? .semibold : .regular))
                .foregroundColor(categoryColor ?? (isActive ? .accentColor : .secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(isActive ? 0.16 : (categoryColor == nil ? 0 : 0.06)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(isActive ? 0.45 : (categoryColor == nil ? 0 : 0.25)), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct CustomDownloadFilterBar: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @Binding var searchText: String
    @Binding var activeFilters: Set<CustomPackageFilter>
    let visibleCount: Int
    let totalCount: Int
    let onSelectAllVisible: () -> Void
    let onClearAllSelection: () -> Void

    private var hasFilters: Bool {
        !searchText.isEmpty || !activeFilters.isEmpty
    }

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                TextField(AppLocalized("搜索包名、版本、类型"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalized("清除搜索"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )

            HStack(spacing: 4) {
                CustomFilterChip(
                    title: AppLocalized("全部"),
                    icon: "square.grid.2x2",
                    isActive: activeFilters.isEmpty,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            activeFilters.removeAll()
                        }
                    }
                )

                ForEach(CustomPackageFilter.allCases) { filter in
                    CustomFilterChip(
                        title: filter.title,
                        icon: filter.icon,
                        categoryColor: filter.categoryColor,
                        isActive: activeFilters.contains(filter),
                        onTap: { toggle(filter) }
                    )
                }

                Spacer(minLength: 8)

                if hasFilters {
                    Button(AppLocalized("清除筛选")) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            searchText = ""
                            activeFilters.removeAll()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }

            HStack(spacing: 12) {
                Text(AppLocalized("显示 \(visibleCount) / \(totalCount) 个包"))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Spacer(minLength: 12)

                Button(AppLocalized("全选当前"), action: onSelectAllVisible)
                    .buttonStyle(.borderless)
                    .disabled(visibleCount == 0)
                    .help(AppLocalized("选中当前筛选下可见的全部包"))

                Button(AppLocalized("取消可选"), action: onClearAllSelection)
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help(AppLocalized("保留必需包和已下载包"))
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func toggle(_ filter: CustomPackageFilter) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if activeFilters.contains(filter) {
                activeFilters.remove(filter)
                return
            }
            switch filter {
            case .required:
                activeFilters.remove(.optional)
            case .optional:
                activeFilters.remove(.required)
            case .core:
                activeFilters.remove(.nonCore)
            case .nonCore:
                activeFilters.remove(.core)
            case .selectedOnly:
                break
            }
            activeFilters.insert(filter)
        }
    }
}

private struct NavigationCustomPackageSelectorView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @State private var selectedPackages: Set<UUID> = []
    @State private var showCopiedAlert = false
    @State private var isDownloading = false
    @State private var requiredPackages: Set<UUID> = []
    @State private var downloadedPackages: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var activeFilters: Set<CustomPackageFilter> = []
    @State private var collapsedDependencies: Set<String> = []
    @State private var didInitializeSelection = false
    @State private var didInitializeCollapse = false
    @State private var downloadedScanTask: Task<Void, Never>?
    @State private var copyToastTask: Task<Void, Never>?

    let productId: String
    let version: String
    let productIcon: NSImage?
    let packages: [Package]
    let dependenciesToDownload: [DependenciesToDownload]
    let onDownloadStart: ([DependenciesToDownload]) -> Void
    let onCancel: () -> Void
    let onFileExists: (URL, [DependenciesToDownload]) -> Void
    let onInstalledProduct: () -> Void

    var body: some View {
        let _ = interfaceLanguage
        let grouped = filteredDependencies
        let selectedStats = selectedStatsByDependency

        VStack(spacing: 0) {
            CustomDownloadHeaderView(
                productId: productId,
                version: version,
                productIcon: productIcon,
                architecture: dependenciesToDownload.compactMap(\.catalogSnapshot).first?.context.architecture,
                onCopyAll: copyAllInfo
            )

            CustomDownloadFilterBar(
                searchText: $searchText,
                activeFilters: $activeFilters,
                visibleCount: grouped.reduce(0) { $0 + $1.packages.count },
                totalCount: packages.count,
                onSelectAllVisible: selectAllVisiblePackages,
                onClearAllSelection: clearAllSelection
            )

            if grouped.isEmpty {
                CustomPackageEmptyView(
                    hasFilters: !searchText.isEmpty || !activeFilters.isEmpty,
                    totalCount: packages.count,
                    onClearFilters: {
                        withAnimation {
                            searchText = ""
                            activeFilters.removeAll()
                        }
                    }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(grouped, id: \.dependency.sapCode) { entry in
                            DependencySection(
                                productId: productId,
                                dependency: entry.dependency,
                                visiblePackages: entry.packages,
                                selectedPackages: $selectedPackages,
                                requiredPackages: requiredPackages,
                                downloadedPackages: downloadedPackages,
                                selectedCount: selectedStats[entry.dependency.sapCode]?.count ?? 0,
                                selectedSize: selectedStats[entry.dependency.sapCode]?.size ?? 0,
                                isForceExpanded: shouldForceExpand,
                                isCollapsed: collapsedDependencies.contains(entry.dependency.sapCode),
                                onToggleCollapse: { sapCode in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if collapsedDependencies.contains(sapCode) {
                                            collapsedDependencies.remove(sapCode)
                                        } else {
                                            collapsedDependencies.insert(sapCode)
                                        }
                                    }
                                },
                                onSelectGroup: selectAllInDependency,
                                onClearGroup: clearAllInDependency,
                                onCopyInfo: copyToClipboard
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .background(Color.clear)
            }

            CustomDownloadActionBar(
                selectedCount: selectedPackages.count,
                totalCount: packages.count,
                downloadCount: selectedDownloadPackageCount,
                downloadedCount: selectedPackages.intersection(downloadedPackages).count,
                totalSizeText: formattedTotalSize,
                isDownloading: isDownloading,
                canDownload: !selectedPackages.isEmpty,
                onCancel: onCancel,
                onStartDownload: startCustomDownload
            )
        }
        .frame(
            minWidth: CustomDownloadPageConstants.minWidth,
            idealWidth: CustomDownloadPageConstants.idealWidth,
            maxWidth: CustomDownloadPageConstants.maxWidth,
            minHeight: CustomDownloadPageConstants.minHeight,
            idealHeight: CustomDownloadPageConstants.idealHeight,
            maxHeight: CustomDownloadPageConstants.maxHeight
        )
        .navigationTitle(AppLocalized("自定义下载"))
        .onAppear {
            initializeSelectionIfNeeded()
            scanDownloadedPackagesIfNeeded()
            initializeCollapseIfNeeded()
        }
        .onDisappear {
            downloadedScanTask?.cancel()
            downloadedScanTask = nil
        }
        .overlay(alignment: .top) {
            if showCopiedAlert {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(AppLocalized("已复制"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                )
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var shouldForceExpand: Bool {
        !searchText.isEmpty || !activeFilters.isEmpty
    }

    private var filteredDependencies: [(dependency: DependenciesToDownload, packages: [Package])] {
        dependenciesToDownload.map { dep in
            let visible = dep.packages.filter(passesAllFilters)
            return (dependency: dep, packages: visible)
        }
        .filter { !$0.packages.isEmpty }
    }

    private func passesAllFilters(_ pkg: Package) -> Bool {
        passesSearch(pkg) && passesType(pkg) && passesCore(pkg) && passesSelectedOnly(pkg)
    }

    private func passesSearch(_ pkg: Package) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return pkg.fullPackageName.lowercased().contains(query)
            || pkg.packageVersion.lowercased().contains(query)
            || pkg.type.lowercased().contains(query)
    }

    private func passesType(_ pkg: Package) -> Bool {
        let wantRequired = activeFilters.contains(.required)
        let wantOptional = activeFilters.contains(.optional)
        if !wantRequired && !wantOptional { return true }
        if wantRequired { return pkg.isRequired }
        return !pkg.isRequired
    }

    private func passesCore(_ pkg: Package) -> Bool {
        let wantCore = activeFilters.contains(.core)
        let wantNonCore = activeFilters.contains(.nonCore)
        if !wantCore && !wantNonCore { return true }
        let isCore = pkg.type.lowercased() == "core"
        if wantCore { return isCore }
        return !isCore
    }

    private func passesSelectedOnly(_ pkg: Package) -> Bool {
        guard activeFilters.contains(.selectedOnly) else { return true }
        return selectedPackages.contains(pkg.id)
    }

    private var selectedDownloadPackageIds: Set<UUID> {
        selectedPackages.subtracting(downloadedPackages)
    }

    private var selectedDownloadPackageCount: Int {
        selectedDownloadPackageIds.count
    }

    private var selectedStatsByDependency: [String: (count: Int, size: Int64)] {
        var result: [String: (count: Int, size: Int64)] = [:]
        let selectedIds = selectedPackages
        for dependency in dependenciesToDownload {
            var count = 0
            var size: Int64 = 0
            for package in dependency.packages where selectedIds.contains(package.id) {
                count += 1
                if !downloadedPackages.contains(package.id) {
                    size += package.downloadSize
                }
            }
            result[dependency.sapCode] = (count, size)
        }
        return result
    }

    private var packageById: [UUID: Package] {
        Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
    }

    private var formattedTotalSize: String {
        let lookup = packageById
        let totalSize = selectedDownloadPackageIds.compactMap { id in
            lookup[id]?.downloadSize
        }.reduce(0, +)

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    private func initializeSelectionIfNeeded() {
        guard !didInitializeSelection else { return }
        didInitializeSelection = true
        selectedPackages.removeAll()
        requiredPackages.removeAll()
        downloadedPackages.removeAll()

        for package in packages {
            if package.isRequired {
                requiredPackages.insert(package.id)
                selectedPackages.insert(package.id)
                continue
            }

            if package.isSelected {
                selectedPackages.insert(package.id)
            }
        }
    }

    private func scanDownloadedPackagesIfNeeded() {
        guard downloadedScanTask == nil else { return }
        guard let existingDirectory = existingDownloadDirectory() else { return }
        let isInstallerProduct = isManifestInstallerProduct(productId)
        let scanItems = dependenciesToDownload.flatMap { dependency in
            dependency.packages.map { package in
                DownloadedPackageScanItem(
                    id: package.id,
                    sapCode: dependency.sapCode,
                    fullPackageName: package.fullPackageName,
                    downloadSize: package.downloadSize
                )
            }
        }

        downloadedScanTask = Task {
            let downloadedIds = await Task.detached(priority: .utility) {
                var ids = Set<UUID>()

                for item in scanItems {
                    guard !Task.isCancelled else { return ids }
                    guard Self.isDownloadedPackage(
                        item,
                        existingDirectory: existingDirectory,
                        isInstallerProduct: isInstallerProduct
                    ) else {
                        continue
                    }
                    ids.insert(item.id)
                }

                return ids
            }.value

            guard !Task.isCancelled else { return }
            applyDownloadedPackages(downloadedIds)
            downloadedScanTask = nil
        }
    }

    private func existingDownloadDirectory() -> URL? {
        guard let main = dependenciesToDownload.first(where: { $0.sapCode == productId }),
              let snapshot = main.catalogSnapshot else { return nil }
        let language = main.catalogLanguage ?? StorageData.shared.defaultLanguage
        let platform = main.platform

        if let task = globalNetworkManager.downloadTasks.first(where: {
            $0.productId == productId &&
            $0.productVersion == version &&
            $0.language == language &&
            $0.platform == platform &&
            $0.targetArchitecture == snapshot.context.architecture.rawValue &&
            FileManager.default.fileExists(atPath: $0.directory.path)
        }) {
            return task.directory
        }

        guard StorageData.shared.useDefaultDirectory,
              !StorageData.shared.defaultDirectory.isEmpty else {
            return nil
        }

        let directoryName = installerOutputName(
            productId: productId,
            version: version,
            language: language,
            platform: platform
        )
        let directory = URL(fileURLWithPath: StorageData.shared.defaultDirectory)
            .appendingPathComponent(directoryName)

        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    private static func isDownloadedPackage(
        _ item: DownloadedPackageScanItem,
        existingDirectory: URL,
        isInstallerProduct: Bool
    ) -> Bool {
        let packageURL = isInstallerProduct
            ? existingDirectory
            : existingDirectory
                .appendingPathComponent(item.sapCode)
                .appendingPathComponent(item.fullPackageName)

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return false
        }

        guard item.downloadSize > 0 else {
            return true
        }

        let actualSize = ((try? FileManager.default.attributesOfItem(atPath: packageURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return actualSize == item.downloadSize
    }

    private func applyDownloadedPackages(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        downloadedPackages.formUnion(ids)
        selectedPackages.formUnion(ids)

        for dependency in dependenciesToDownload {
            for package in dependency.packages where ids.contains(package.id) {
                package.isSelected = true
                package.downloaded = true
                package.status = .completed
                package.downloadedSize = package.downloadSize
                package.progress = 1
                package.speed = 0
            }
        }
    }

    private func initializeCollapseIfNeeded() {
        guard !didInitializeCollapse else { return }
        didInitializeCollapse = true
        collapsedDependencies = Set(
            dependenciesToDownload
                .map { $0.sapCode }
                .filter { $0 != productId }
        )
    }

    private func selectAllVisiblePackages() {
        let visibleIds = filteredDependencies.flatMap { $0.packages.map { $0.id } }
        for id in visibleIds {
            selectedPackages.insert(id)
        }
    }

    private func clearAllSelection() {
        selectedPackages = requiredPackages.union(downloadedPackages)
    }

    private func selectAllInDependency(_ sapCode: String) {
        guard let dependency = dependenciesToDownload.first(where: { $0.sapCode == sapCode }) else { return }
        for package in dependency.packages {
            selectedPackages.insert(package.id)
        }
    }

    private func clearAllInDependency(_ sapCode: String) {
        guard let dependency = dependenciesToDownload.first(where: { $0.sapCode == sapCode }) else { return }
        for package in dependency.packages where !package.isRequired && !downloadedPackages.contains(package.id) {
            selectedPackages.remove(package.id)
        }
    }

    private func startCustomDownload() {
        guard !isDownloading else { return }

        isDownloading = true

        for dependency in dependenciesToDownload {
            for package in dependency.packages {
                package.isSelected = package.isRequired || downloadedPackages.contains(package.id) || selectedPackages.contains(package.id)
            }
        }

        let finalDependencies = dependenciesToDownload

        if let existingPath = existingDownloadDirectory() {
            onFileExists(existingPath, finalDependencies)
            onCancel()
        } else {
            onDownloadStart(finalDependencies)
            onCancel()
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            showCopiedAlert = true
        }
        copyToastTask?.cancel()
        copyToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                showCopiedAlert = false
            }
        }
    }

    private func copyPackageInfo(_ package: Package) {
        let packageInfo = "\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)"
        copyToClipboard(packageInfo)
    }

    private func copyAllInfo() {
        var result = ""

        for (index, dependency) in dependenciesToDownload.enumerated() {
            let dependencyInfo: String
            if isManifestInstallerProduct(dependency.sapCode) {
                dependencyInfo = "\(dependency.sapCode) \(dependency.version)"
            } else {
                dependencyInfo = "\(dependency.sapCode) \(dependency.version) - (\(dependency.buildGuid))"
            }
            result += dependencyInfo + "\n"

            for (pkgIndex, package) in dependency.packages.enumerated() {
                let isLastPackage = pkgIndex == dependency.packages.count - 1
                let prefix = isLastPackage ? "    └── " : "    ├── "
                result += "\(prefix)\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)\n"
            }

            if index < dependenciesToDownload.count - 1 {
                result += "\n"
            }
        }

        copyToClipboard(result)
    }
}

private struct DependencySection: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let productId: String
    let dependency: DependenciesToDownload
    let visiblePackages: [Package]
    @Binding var selectedPackages: Set<UUID>
    let requiredPackages: Set<UUID>
    let downloadedPackages: Set<UUID>
    let selectedCount: Int
    let selectedSize: Int64
    let isForceExpanded: Bool
    let isCollapsed: Bool
    let onToggleCollapse: (String) -> Void
    let onSelectGroup: (String) -> Void
    let onClearGroup: (String) -> Void
    let onCopyInfo: (String) -> Void

    private var effectiveCollapsed: Bool {
        isForceExpanded ? false : isCollapsed
    }

    private var isMainProduct: Bool {
        dependency.sapCode == productId
    }

    private var groupSizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)
    }

    private var platformTitle: String {
        switch dependency.platform.lowercased() {
        case "macarm64": return AppLocalized("Apple Silicon")
        case "macuniversal": return AppLocalized("通用")
        case "osx10", "osx10-64": return AppLocalized("Intel")
        default: return dependency.platform
        }
    }

    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 0) {
            header

            if !effectiveCollapsed {
                VStack(alignment: .leading, spacing: 10) {
                    if !isManifestInstallerProduct(dependency.sapCode), !dependency.buildGuid.isEmpty {
                        buildGuidButton
                    }

                    HStack(spacing: 12) {
                        Text(AppLocalized("包清单"))
                            .foregroundColor(.secondary)

                        Spacer(minLength: 8)

                        Button(AppLocalized("全选此组")) {
                            onSelectGroup(dependency.sapCode)
                        }
                        .buttonStyle(.borderless)
                        .help(AppLocalized("选中该依赖下所有包"))

                        Button(AppLocalized("取消可选")) {
                            onClearGroup(dependency.sapCode)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .help(AppLocalized("保留此组的必需包和已下载包"))
                    }
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider().opacity(0.6)

                VStack(spacing: 0) {
                    ForEach(visiblePackages) { package in
                        NavigationEnhancedPackageRow(
                            package: package,
                            isSelected: selectedPackages.contains(package.id),
                            isDownloaded: downloadedPackages.contains(package.id),
                            isLocked: requiredPackages.contains(package.id) || downloadedPackages.contains(package.id),
                            onToggle: { isSelected in
                                guard !requiredPackages.contains(package.id), !downloadedPackages.contains(package.id) else { return }
                                if isSelected {
                                    selectedPackages.insert(package.id)
                                } else {
                                    selectedPackages.remove(package.id)
                                }
                            },
                            onCopyPackageInfo: {
                                copyPackageInfoInline(package)
                            }
                        )

                        if package.id != visiblePackages.last?.id {
                            Divider()
                                .opacity(0.3)
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isMainProduct ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
    }

    private var header: some View {
        Button(action: { onToggleCollapse(dependency.sapCode) }) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(effectiveCollapsed ? 0 : 90))
                    .foregroundColor(.secondary)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(dependency.sapCode)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(dependency.version)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    HStack(spacing: 8) {
                        Text(isMainProduct ? AppLocalized("主产品") : AppLocalized("依赖组件"))
                            .foregroundColor(isMainProduct ? .accentColor : .secondary)

                        if !platformTitle.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(platformTitle)
                                .foregroundColor(.secondary)
                                .help(dependency.platform)
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(AppLocalized("已选 \(selectedCount) / \(dependency.packages.count) 个包"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(AppLocalized("需下载"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(groupSizeText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                    }
                }
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isForceExpanded)
        .help(isForceExpanded ? AppLocalized("筛选激活时无法折叠") : (effectiveCollapsed ? AppLocalized("展开") : AppLocalized("折叠")))
        .accessibilityValue(effectiveCollapsed ? AppLocalized("已收起") : AppLocalized("已展开"))
    }

    private var buildGuidButton: some View {
        Button(action: { onCopyInfo(dependency.buildGuid) }) {
            HStack(spacing: 8) {
                Text("BuildGuid")
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(dependency.buildGuid)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
            }
            .font(.system(size: 10))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(format: AppLocalized("复制 buildGuid: %@"), dependency.buildGuid))
        .accessibilityLabel(AppLocalized("复制 buildGuid"))
        .accessibilityValue(dependency.buildGuid)
    }

    private func copyPackageInfoInline(_ package: Package) {
        let packageInfo = "\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)"
        onCopyInfo(packageInfo)
    }
}

private struct CustomDownloadActionBar: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let selectedCount: Int
    let totalCount: Int
    let downloadCount: Int
    let downloadedCount: Int
    let totalSizeText: String
    let isDownloading: Bool
    let canDownload: Bool
    let onCancel: () -> Void
    let onStartDownload: () -> Void

    var body: some View {
        let _ = interfaceLanguage
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(totalSizeText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(AppLocalized("需下载 \(downloadCount) 个包"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text(AppLocalized("已选 \(selectedCount) / \(totalCount) 个包"))
                    if downloadedCount > 0 {
                        Text("·")
                        Text(AppLocalized("已下载 \(downloadedCount) 个包"))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .monospacedDigit()

            Spacer(minLength: 12)

            Button(AppLocalized("取消"), action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.large)

            Button(action: onStartDownload) {
                HStack(spacing: 6) {
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down")
                    }
                    Text(isDownloading ? AppLocalized("正在下载...") : AppLocalized("开始下载"))
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canDownload || isDownloading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }
}

private struct CustomPackageEmptyView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let hasFilters: Bool
    let totalCount: Int
    let onClearFilters: () -> Void

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 64, height: 64)
                Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle" : "tray")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 4) {
                Text(hasFilters ? AppLocalized("没有匹配的包") : AppLocalized("暂无可下载的包"))
                    .font(.system(size: 14, weight: .semibold))
                if hasFilters {
                    Text(AppLocalized("当前筛选下隐藏了 \(totalCount) 个包"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if hasFilters {
                Button(action: onClearFilters) {
                    Text(AppLocalized("清空筛选"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct NavigationEnhancedPackageRow: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let package: Package
    let isSelected: Bool
    let isDownloaded: Bool
    let isLocked: Bool
    let onToggle: (Bool) -> Void
    let onCopyPackageInfo: () -> Void

    @State private var isHovered = false

    private var isRequiredPackage: Bool {
        package.isRequired
    }

    var body: some View {
        let _ = interfaceLanguage
        HStack(alignment: .top, spacing: 10) {
            Button(action: {
                guard !isLocked else { return }
                onToggle(!isSelected)
            }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(checkboxColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .help(checkboxHelp)
            .accessibilityLabel(package.fullPackageName)
            .accessibilityValue(isSelected ? AppLocalized("已选择") : AppLocalized("未选择"))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(package.fullPackageName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(package.fullPackageName)

                    Spacer(minLength: 12)

                    Text(package.formattedSize)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
                .frame(minHeight: 20)

                packageMetadata

                #if DEBUG
                if !package.condition.isEmpty {
                    Text(String(format: AppLocalized("条件: %@"), package.condition))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                #endif

                #if DEBUG
                if !package.isOfficiallyEligible, !package.officialFilterReasonText.isEmpty {
                    Text("\(package.officialFilterReasonText)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCopyPackageInfo) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(isHovered ? .primary : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppLocalized("复制包信息"))
            .accessibilityLabel(AppLocalized("复制包信息"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.05)
                : (isHovered ? Color.primary.opacity(0.025) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var requirementBadge: some View {
        packageBadge(for: isRequiredPackage ? .required : .optional)
            .help(requirementHelp)
    }

    private var requirementHelp: String {
        if isLocked {
            return checkboxHelp
        }
        if !package.isOfficiallyEligible, !package.officialFilterReasonText.isEmpty {
            return package.officialFilterReasonText
        }
        return checkboxHelp
    }

    private var packageTypeBadge: some View {
        packageBadge(for: package.type.lowercased() == "core" ? .core : .nonCore)
            .help(package.type)
    }

    private func packageBadge(for category: CustomPackageFilter) -> some View {
        let tint = category.categoryColor ?? .secondary

        return HStack(spacing: 4) {
            Image(systemName: category.icon)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(category.title)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(tint.opacity(0.4), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var packageMetadata: some View {
        HStack(spacing: 8) {
            if !package.type.isEmpty {
                packageTypeBadge
            }

            requirementBadge

            if !package.packageVersion.isEmpty {
                Text(package.packageVersion)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            if isDownloaded {
                Label(AppLocalized("已下载"), systemImage: "checkmark.circle")
                    .foregroundColor(.green)
            }

            if !isRequiredPackage {
                if package.isAdobeDownloaderPreselected {
                    Text(AppLocalized("Adobe Downloader 预选"))
                } else if package.isDefaultSelected {
                    Text(AppLocalized("默认选择"))
                }
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
    }

    private var checkboxColor: Color {
        if isDownloaded {
            return .green.opacity(0.85)
        }
        if isRequiredPackage {
            return .secondary.opacity(0.6)
        }
        return isSelected ? .accentColor : .secondary
    }

    private var checkboxHelp: String {
        if isDownloaded {
            return AppLocalized("此包已存在于离线源目录，无法取消选择")
        }
        if isRequiredPackage {
            return AppLocalized("此包为必需包，无法取消选择")
        }
        return AppLocalized("点击切换选择状态")
    }
}
