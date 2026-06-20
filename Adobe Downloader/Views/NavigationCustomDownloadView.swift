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

struct NavigationCustomDownloadView: View {
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
        .alert("提示", isPresented: $showInstalledAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("该产品版本已安装")
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
        guard let product = findProduct(id: productId, version: version) else {
            throw NetworkError.invalidData("找不到产品信息")
        }

        if isManifestInstallerProduct(productId) {
            return makeInstallerPackageInfo(product: product)
        }

        let decision = try await HDPIMParityDecisionEngine.shared.resolveDownloadDecision(
            productId: product.id,
            version: version,
            requestedLanguage: StorageData.shared.defaultLanguage
        ) { message in
            Task { @MainActor in
                loadingState.currentTask = message
            }
        }

        return HDPIMParityDecisionEngine.shared.makeDownloadPresentation(from: decision, useDelta: useDelta)
    }

    private func makeInstallerPackageInfo(product: Product) -> ([Package], [DependenciesToDownload]) {
        guard let match = installerPlatformMatch(product: product, selectedVersion: version) else {
            return ([], [])
        }

        let platform = match.platform
        let languageSet = match.languageSet
        let productVersion = installerProductVersion(product: product, languageSet: languageSet, selectedVersion: version)
        let package = Package(
            type: "dmg",
            fullPackageName: installerOutputName(
                productId: productId,
                version: version,
                language: StorageData.shared.defaultLanguage,
                platform: platform.id
            ),
            downloadSize: Int64(max(languageSet.installSize, 0)),
            downloadURL: languageSet.lbsURL,
            manifestURL: languageSet.manifestURL,
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
        dependency.packages = [package]
        return ([package], [dependency])
    }

    private func createCompletedCustomTask(path: URL, dependencies: [DependenciesToDownload]) async {
        let existingTask = globalNetworkManager.downloadTasks.first { task in
            return task.productId == productId &&
                   task.productVersion == version &&
                   task.language == StorageData.shared.defaultLanguage &&
                   task.directory == path
        }

        if existingTask != nil {
            return
        }

        let platform = dependencies.first(where: { $0.sapCode == productId })?.platform
            ?? installerSelectedPlatformId(
                productId: productId,
                version: version
            )
            ?? "unknown"

        let task = NewDownloadTask(
            productId: productId,
            productVersion: version,
            language: StorageData.shared.defaultLanguage,
            displayName: findProduct(id: productId)?.displayName ?? productId,
            directory: path,
            dependenciesToDownload: dependencies,
            retryCount: 0,
            createAt: Date(),
            totalProgress: 1.0,
            platform: platform,
            targetArchitecture: HDPIMParityTargetArchitecture.currentSelection.rawValue
        )

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
        Task {
            let destinationURL: URL
            if let existingDestinationURL {
                destinationURL = existingDestinationURL
            } else {
                do {
                    destinationURL = try await getDestinationURL(
                        productId: productId,
                        version: version,
                        language: StorageData.shared.defaultLanguage,
                        mainPlatform: dependencies.first(where: { $0.sapCode == productId })?.platform
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
                    language: StorageData.shared.defaultLanguage,
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

    private func getDestinationURL(productId: String, version: String, language: String, mainPlatform: String?) async throws -> URL {
        let platform = mainPlatform
            ?? installerSelectedPlatformId(
                productId: productId,
                version: version
            )
            ?? "unknown"
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
                panel.title = "选择保存位置"
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
    let productId: String
    let version: String
    let productIcon: NSImage?
    var onCopyAll: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @StorageValue(\.downloadAppleSilicon) private var downloadAppleSilicon

    var body: some View {
        HStack(spacing: 12) {
            productIconView
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                if let product = findProduct(id: productId) {
                    Text(product.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.92))
                        .lineLimit(1)
                } else {
                    Text(productId)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("v\(version)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                    architectureChip
                }
            }

            Spacer()

            if let onCopyAll = onCopyAll {
                Button(action: onCopyAll) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text("复制全部")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                .help("复制所有包信息")
            }

            if let onCancel = onCancel {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.secondary.opacity(0.2)),
            alignment: .bottom
        )
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
        HStack(spacing: 3) {
            Image(systemName: downloadAppleSilicon ? "m.square" : "x.square")
                .font(.system(size: 10))
            Text(downloadAppleSilicon ? "Apple Silicon" : "Intel")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.blue.opacity(0.85))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

private struct NavigationCustomDownloadLoadingView: View {
    @ObservedObject var loadingState: CustomDownloadLoadingState

    let productId: String
    let version: String
    let productIcon: NSImage?
    let onCancel: () -> Void

    var body: some View {
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
                    Text("正在获取包信息")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.9))

                    if !loadingState.currentTask.isEmpty {
                        Text(loadingState.currentTask)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else {
                        Text("正在解析依赖与包清单…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    LoadingStageRow(title: "解析版本信息")
                    LoadingStageRow(title: "下载产品清单")
                    LoadingStageRow(title: "展开依赖与可选模块")
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
                Button("取消") {
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
        .navigationTitle("自定义下载")
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
    let productId: String
    let version: String
    let productIcon: NSImage?
    let errorMessage: String
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
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
                    Text("加载失败")
                        .font(.system(size: 16, weight: .semibold))

                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .textSelection(.enabled)

                    Text("提示：请检查网络连接或尝试返回重新选择版本")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11))
                            Text("返回选择版本")
                        }
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))

                    Button(action: onRetry) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("重试")
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
        .navigationTitle("自定义下载")
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
        case .required: return "必需"
        case .optional: return "可选"
        case .core: return "核心"
        case .nonCore: return "非核心"
        case .selectedOnly: return "仅已选"
        }
    }

    var icon: String {
        switch self {
        case .required: return "exclamationmark.lock.fill"
        case .optional: return "slider.horizontal.3"
        case .core: return "cube.fill"
        case .nonCore: return "cube.transparent"
        case .selectedOnly: return "checkmark.circle.fill"
        }
    }
}

private struct CustomFilterChip: View {
    let filter: CustomPackageFilter
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(filter.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? .blue : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.blue.opacity(0.12) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CustomDownloadFilterBar: View {
    @Binding var searchText: String
    @Binding var activeFilters: Set<CustomPackageFilter>
    let onSelectAllVisible: () -> Void
    let onClearAllSelection: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))

                TextField("搜索包名、版本、类型", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
            )

            HStack(spacing: 6) {
                ForEach(CustomPackageFilter.allCases) { filter in
                    CustomFilterChip(
                        filter: filter,
                        isActive: activeFilters.contains(filter),
                        onTap: { toggle(filter) }
                    )
                }
                Spacer(minLength: 12)

                Button(action: onSelectAllVisible) {
                    Text("全选当前")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("选中当前筛选下可见的全部包")

                Text("·")
                    .foregroundColor(.secondary.opacity(0.4))

                Button(action: onClearAllSelection) {
                    Text("清空选择")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("仅保留必需包")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
    @State private var selectedPackages: Set<UUID> = []
    @State private var showCopiedAlert = false
    @State private var isDownloading = false
    @State private var requiredPackages: Set<UUID> = []
    @State private var downloadedPackages: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var activeFilters: Set<CustomPackageFilter> = []
    @State private var collapsedDependencies: Set<String> = []
    @State private var didInitializeCollapse = false
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
        VStack(spacing: 0) {
            CustomDownloadHeaderView(
                productId: productId,
                version: version,
                productIcon: productIcon,
                onCopyAll: copyAllInfo,
                onCancel: onCancel
            )

            CustomDownloadFilterBar(
                searchText: $searchText,
                activeFilters: $activeFilters,
                onSelectAllVisible: selectAllVisiblePackages,
                onClearAllSelection: clearAllSelection
            )

            let grouped = filteredDependencies

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
                                onCopyBuildGuid: copyToClipboard
                            )
                        }
                    }
                    .padding()
                }
                .background(Color.clear)
            }

            CustomDownloadActionBar(
                selectedCount: selectedDownloadPackageCount,
                totalCount: packages.count,
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
        .navigationTitle("自定义下载")
        .onAppear {
            initializeSelection()
            initializeDownloadedPackages()
            initializeCollapseIfNeeded()
        }
        .overlay(alignment: .top) {
            if showCopiedAlert {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("已复制")
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

    private var formattedTotalSize: String {
        let totalSize = selectedDownloadPackageIds.compactMap { id in
            packages.first { $0.id == id }?.downloadSize
        }.reduce(0, +)

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    private func initializeSelection() {
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

    private func initializeDownloadedPackages() {
        guard let existingDirectory = existingDownloadDirectory() else { return }

        for dependency in dependenciesToDownload {
            for package in dependency.packages {
                guard isDownloadedPackage(package, in: dependency, existingDirectory: existingDirectory) else {
                    continue
                }

                downloadedPackages.insert(package.id)
                selectedPackages.insert(package.id)
                package.isSelected = true
                package.downloaded = true
                package.status = .completed
                package.downloadedSize = package.downloadSize
                package.progress = 1
                package.speed = 0
            }
        }
    }

    private func existingDownloadDirectory() -> URL? {
        let language = StorageData.shared.defaultLanguage

        if let task = globalNetworkManager.downloadTasks.first(where: {
            $0.productId == productId &&
            $0.productVersion == version &&
            $0.language == language &&
            FileManager.default.fileExists(atPath: $0.directory.path)
        }) {
            return task.directory
        }

        guard StorageData.shared.useDefaultDirectory,
              !StorageData.shared.defaultDirectory.isEmpty else {
            return nil
        }

        let platform = dependenciesToDownload.first(where: { $0.sapCode == productId })?.platform
            ?? installerSelectedPlatformId(
                productId: productId,
                version: version
            )
            ?? "unknown"
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

    private func isDownloadedPackage(
        _ package: Package,
        in dependency: DependenciesToDownload,
        existingDirectory: URL
    ) -> Bool {
        let packageURL = isManifestInstallerProduct(productId)
            ? existingDirectory
            : existingDirectory
                .appendingPathComponent(dependency.sapCode)
                .appendingPathComponent(package.fullPackageName)

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return false
        }

        guard package.downloadSize > 0 else {
            return true
        }

        let actualSize = ((try? FileManager.default.attributesOfItem(atPath: packageURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return actualSize == package.downloadSize
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
    let productId: String
    let dependency: DependenciesToDownload
    let visiblePackages: [Package]
    @Binding var selectedPackages: Set<UUID>
    let requiredPackages: Set<UUID>
    let downloadedPackages: Set<UUID>
    let isForceExpanded: Bool
    let isCollapsed: Bool
    let onToggleCollapse: (String) -> Void
    let onSelectGroup: (String) -> Void
    let onClearGroup: (String) -> Void
    let onCopyBuildGuid: (String) -> Void

    private var effectiveCollapsed: Bool {
        isForceExpanded ? false : isCollapsed
    }

    private var isMainProduct: Bool {
        dependency.sapCode == productId
    }

    private var selectedCountInGroup: Int {
        dependency.packages.filter {
            selectedPackages.contains($0.id) && !downloadedPackages.contains($0.id)
        }.count
    }

    private var totalSizeInGroup: Int64 {
        dependency.packages
            .filter { selectedPackages.contains($0.id) && !downloadedPackages.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.downloadSize }
    }

    private var groupSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalSizeInGroup, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !effectiveCollapsed {
                Divider()
                    .padding(.horizontal, 4)
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
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(effectiveCollapsed ? 0.25 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isMainProduct ? Color.blue.opacity(0.25) : Color.secondary.opacity(0.1),
                    lineWidth: isMainProduct ? 1 : 0.5
                )
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: { onToggleCollapse(dependency.sapCode) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(effectiveCollapsed ? 0 : 90))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isForceExpanded)
            .help(isForceExpanded ? "筛选激活时无法折叠" : (effectiveCollapsed ? "展开" : "折叠"))

            HStack(spacing: 6) {
                Image(systemName: isMainProduct ? "app.badge.fill" : "shippingbox.fill")
                    .font(.system(size: 12))
                    .foregroundColor(isMainProduct ? .blue : .blue.opacity(0.7))

                Text(dependency.sapCode)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                    .textSelection(.enabled)

                Text(dependency.version)
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .foregroundColor(.blue.opacity(0.8))

                if isMainProduct {
                    Text("主产品")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.blue.opacity(0.12))
                        )
                }

                if !isManifestInstallerProduct(dependency.sapCode), !dependency.buildGuid.isEmpty {
                    Button(action: { onCopyBuildGuid(dependency.buildGuid) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                            Text("buildGuid")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制 buildGuid: \(dependency.buildGuid)")
                }
            }

            Spacer(minLength: 8)

            Text("\(selectedCountInGroup) / \(dependency.packages.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.85))
                .monospacedDigit()

            Text("·")
                .foregroundColor(.secondary.opacity(0.4))

            Text(groupSizeText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.85))
                .monospacedDigit()

            HStack(spacing: 4) {
                Button(action: { onSelectGroup(dependency.sapCode) }) {
                    Text("全选")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("选中该依赖下所有包")

                Text("·")
                    .foregroundColor(.secondary.opacity(0.4))

                Button(action: { onClearGroup(dependency.sapCode) }) {
                    Text("清空")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消该依赖下非必需包")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isForceExpanded {
                onToggleCollapse(dependency.sapCode)
            }
        }
    }

    private func copyPackageInfoInline(_ package: Package) {
        let packageInfo = "\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(packageInfo, forType: .string)
    }
}

private struct CustomDownloadActionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let totalSizeText: String
    let isDownloading: Bool
    let canDownload: Bool
    let onCancel: () -> Void
    let onStartDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.85))
                Text("已选 \(selectedCount) / \(totalCount) 个包")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                    .monospacedDigit()
                Text("·")
                    .foregroundColor(.secondary.opacity(0.4))
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                Text(totalSizeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                    .monospacedDigit()
            }

            Spacer()

            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 13))
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))

            Button(action: onStartDownload) {
                HStack(spacing: 6) {
                    if isDownloading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13))
                    }
                    Text(isDownloading ? "正在下载..." : "开始下载")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 4)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: canDownload && !isDownloading ? Color.blue : Color.gray))
            .disabled(!canDownload || isDownloading)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(
            Color(NSColor.windowBackgroundColor)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.secondary.opacity(0.2)),
                    alignment: .top
                )
        )
    }
}

private struct CustomPackageEmptyView: View {
    let hasFilters: Bool
    let totalCount: Int
    let onClearFilters: () -> Void

    var body: some View {
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
                Text(hasFilters ? "没有匹配的包" : "暂无可下载的包")
                    .font(.system(size: 14, weight: .semibold))
                if hasFilters {
                    Text("当前筛选下隐藏了 \(totalCount) 个包")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if hasFilters {
                Button(action: onClearFilters) {
                    Text("清空筛选")
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
        HStack(alignment: .top, spacing: 10) {
            Button(action: {
                guard !isLocked else { return }
                onToggle(!isSelected)
            }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(checkboxColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isLocked)
            .help(checkboxHelp)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(package.fullPackageName) (\(package.packageVersion))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    packageTypeBadge

                    if isDownloaded {
                        subtleBadge(text: "已下载", color: .green)
                    }

                    if isRequiredPackage {
                        subtleBadge(text: "必需", color: .red)
                    } else if package.isAdobeDownloaderPreselected {
                        subtleBadge(text: "Adobe Downloader 预选", color: .purple)
                    } else if package.isDefaultSelected {
                        subtleBadge(text: "默认选择", color: .blue)
                    }

                    if !package.isOfficiallyEligible {
                        subtleBadge(text: "可选", color: .orange)
                    }

                    Spacer(minLength: 8)

                    Text(package.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.85))
                        .monospacedDigit()

                    if isHovered {
                        Button(action: onCopyPackageInfo) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("复制包信息")
                        .transition(.opacity)
                    }
                }

                #if DEBUG
                if !package.condition.isEmpty {
                    Text("条件: \(package.condition)")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay(
            Rectangle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                .opacity(0.5),
            alignment: .bottom
        )
    }

    private var checkboxColor: Color {
        if isDownloaded {
            return .green.opacity(0.85)
        }
        if isRequiredPackage {
            return .secondary.opacity(0.6)
        }
        return isSelected ? .blue : .secondary
    }

    private var checkboxHelp: String {
        if isDownloaded {
            return "此包已存在于离线源目录，无法取消选择"
        }
        if isRequiredPackage {
            return "此包为必需包，无法取消选择"
        }
        return "点击切换选择状态"
    }

    @ViewBuilder
    private var packageTypeBadge: some View {
        let isCore = package.type.lowercased() == "core"
        Text(package.type)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill((isCore ? Color.blue : Color.purple).opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke((isCore ? Color.blue : Color.purple).opacity(0.25), lineWidth: 0.5)
            )
            .foregroundColor(isCore ? .blue.opacity(0.85) : .purple.opacity(0.85))
    }

    private func subtleBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.3), lineWidth: 0.5)
            )
            .foregroundColor(color.opacity(0.9))
    }
}
