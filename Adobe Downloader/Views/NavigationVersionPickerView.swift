//
//  NavigationVersionPickerView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/07/19.
//

import SwiftUI

private enum VersionPickerConstants {
    static let headerPadding: CGFloat = 5
    static let viewWidth: CGFloat = 500
    static let viewHeight: CGFloat = 600
    static let iconSize: CGFloat = 32
    static let verticalSpacing: CGFloat = 8
    static let horizontalSpacing: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let buttonPadding: CGFloat = 8

    static let titleFontSize: CGFloat = 14
    static let captionFontSize: CGFloat = 12
}

enum VersionPickerDestination: Hashable {
    case customDownload(productId: String, version: String)
    case duplicateTaskAlert(productId: String, version: String)

    static func == (lhs: VersionPickerDestination, rhs: VersionPickerDestination) -> Bool {
        switch (lhs, rhs) {
        case (.customDownload(let lProductId, let lVersion), .customDownload(let rProductId, let rVersion)):
            return lProductId == rProductId && lVersion == rVersion
        case (.duplicateTaskAlert(let lProductId, let lVersion), .duplicateTaskAlert(let rProductId, let rVersion)):
            return lProductId == rProductId && lVersion == rVersion
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .customDownload(let productId, let version):
            hasher.combine("customDownload")
            hasher.combine(productId)
            hasher.combine(version)
        case .duplicateTaskAlert(let productId, let version):
            hasher.combine("duplicateTaskAlert")
            hasher.combine(productId)
            hasher.combine(version)
        }
    }
}

enum VersionPickerFilter: String, CaseIterable, Identifiable {
    case all
    case latest
    case downloaded
    case installed
    case hasDependencies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .latest: return "仅最新"
        case .downloaded: return "已下载"
        case .installed: return "已安装"
        case .hasDependencies: return "有依赖"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .latest: return "sparkles"
        case .downloaded: return "checkmark.circle"
        case .installed: return "checkmark.seal"
        case .hasDependencies: return "shippingbox"
        }
    }
}

struct VersionGroup: Identifiable {
    let major: Int
    let items: [(key: String, value: Product.Platform)]
    var id: Int { major }
}

struct NavigationVersionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StorageValue(\.defaultLanguage) private var defaultLanguage
    @StorageValue(\.downloadAppleSilicon) private var downloadAppleSilicon
    @State private var expandedVersions: Set<String> = []
    @State private var existingFilePath: URL?
    @State private var pendingDependencies: [DependenciesToDownload] = []
    @State private var productIcon: NSImage? = nil
    @State private var navigationPath = NavigationPath()
    @State private var searchText: String = ""
    @State private var activeFilter: VersionPickerFilter = .all

    private let productId: String
    private let onSelect: (String) -> Void

    init(productId: String, onSelect: @escaping (String) -> Void) {
        self.productId = productId
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                VersionPickerHeaderView(
                    productId: productId,
                    productIcon: productIcon,
                    downloadAppleSilicon: downloadAppleSilicon,
                    onToggleArchitecture: { newValue in
                        StorageData.shared.downloadAppleSilicon = newValue
                    },
                    onDismiss: { dismiss() }
                )
                VersionPickerFilterBar(
                    searchText: $searchText,
                    activeFilter: $activeFilter
                )
                VersionListView(
                    productId: productId,
                    searchText: $searchText,
                    activeFilter: $activeFilter,
                    expandedVersions: $expandedVersions,
                    downloadAppleSilicon: downloadAppleSilicon,
                    onSelect: onSelect,
                    dismiss: dismiss,
                    onCustomDownload: { version in
                        navigationPath.append(VersionPickerDestination.customDownload(productId: productId, version: version))
                    }
                )
            }
            .frame(
                minWidth: 520,
                idealWidth: 560,
                maxWidth: 720,
                minHeight: 560,
                idealHeight: VersionPickerConstants.viewHeight,
                maxHeight: 820
            )
            .navigationDestination(for: VersionPickerDestination.self) { destination in
                switch destination {
                case .customDownload(let productId, let version):
                    NavigationCustomDownloadView(
                        productId: productId,
                        version: version,
                        onDownloadStart: { dependencies in
                            handleCustomDownload(dependencies: dependencies)
                        },
                        onDismiss: {
                            dismiss()
                        }
                    )
                case .duplicateTaskAlert(let productId, let version):
                    DuplicateTaskAlertView(
                        productId: productId,
                        version: version,
                        onCancel: {
                            navigationPath.removeLast()
                        },
                        iconImage: productIcon
                    )
                }
            }
        }
        .onAppear {
            loadProductIcon()
        }
    }

    private func getDestinationURL(productId: String, version: String, language: String) async throws -> URL {
        let platform = installerSelectedPlatformId(
            productId: productId,
            version: version
        ) ?? "unknown"
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

    private func handleCustomDownload(dependencies: [DependenciesToDownload]) {
        guard let firstDependency = dependencies.first else { return }
        let version = firstDependency.version

        let existingTask = globalNetworkManager.downloadTasks.first { task in
            task.productId == productId &&
            task.productVersion == version &&
            task.language == StorageData.shared.defaultLanguage &&
            task.status.isActive
        }

        if existingTask != nil {
            navigationPath.append(VersionPickerDestination.duplicateTaskAlert(productId: productId, version: version))
            return
        }

        Task {
            await startCustomDownloadProcess(dependencies: dependencies)
        }
    }

    private func startCustomDownloadProcess(dependencies: [DependenciesToDownload]) async {
        guard let firstDependency = dependencies.first else { return }
        let version = firstDependency.version

        let destinationURL: URL
        do {
            destinationURL = try await getDestinationURL(
                productId: productId,
                version: version,
                language: StorageData.shared.defaultLanguage
            )
        } catch {
            await MainActor.run { dismiss() }
            return
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
            dismiss()
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

private struct VersionPickerHeaderView: View {
    let productId: String
    let productIcon: NSImage?
    let downloadAppleSilicon: Bool
    let onToggleArchitecture: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if let product = findProduct(id: productId) {
                    productIconView
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.92))
                            .lineLimit(1)
                        Text("选择版本")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                architectureMenu

                Button("取消") {
                    onDismiss()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color(NSColor.windowBackgroundColor))
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

    private var architectureMenu: some View {
        Menu {
            Button {
                onToggleArchitecture(true)
            } label: {
                Label("Apple Silicon (arm64)", systemImage: "m.square")
            }
            Button {
                onToggleArchitecture(false)
            } label: {
                Label("Intel (x86_64)", systemImage: "x.square")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: downloadAppleSilicon ? "m.square" : "x.square")
                    .foregroundColor(.blue)
                Text(downloadAppleSilicon ? "Apple Silicon" : "Intel")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                Text("·")
                    .foregroundColor(.secondary.opacity(0.6))
                Text(platformText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.blue.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换下载架构")
    }

    private var platformText: String {
        HDPIMParityDecisionEngine.shared.visiblePlatformText()
    }
}

private struct VersionPickerFilterBar: View {
    @Binding var searchText: String
    @Binding var activeFilter: VersionPickerFilter

    var body: some View {
        VStack(spacing: 8) {
            searchField
            filterChips
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))

            TextField("搜索版本号 / buildGuid", text: $searchText)
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
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(VersionPickerFilter.allCases) { filter in
                FilterChip(
                    filter: filter,
                    isActive: filter == activeFilter,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            activeFilter = filter
                        }
                    }
                )
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FilterChip: View {
    let filter: VersionPickerFilter
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

private struct VersionListView: View {
    let productId: String
    @Binding var searchText: String
    @Binding var activeFilter: VersionPickerFilter
    @Binding var expandedVersions: Set<String>
    let downloadAppleSilicon: Bool
    let onSelect: (String) -> Void
    let dismiss: DismissAction
    let onCustomDownload: (String) -> Void
    @StorageValue(\.defaultLanguage) private var defaultLanguage
    @State private var cachedVersions: [(key: String, value: Product.Platform)] = []
    @State private var cachedPackageSizes: [String: Int64] = [:]
    @State private var sizeLoadingVersions: Set<String> = []

    var body: some View {
        let groups = processedGroups(cachedVersions: cachedVersions)
        let totalCount = cachedVersions.count
        let visibleCount = groups.reduce(0) { $0 + $1.items.count }
        let overallLatestKey: String? = groups.first?.items.first?.key

        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        VersionPickerEmptyView(
                            hint: searchText.isEmpty
                                ? "当前筛选下暂无版本"
                                : "没有匹配 “\(searchText)” 的版本"
                        )
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(groups) { group in
                                VersionGroupSection(
                                    productId: productId,
                                    group: group,
                                    overallLatestKey: overallLatestKey,
                                    expandedVersions: $expandedVersions,
                                    cachedPackageSizes: $cachedPackageSizes,
                                    sizeLoadingVersions: $sizeLoadingVersions,
                                    onSelect: handleVersionSelect,
                                    onToggle: handleVersionToggle,
                                    onCustomDownload: handleCustomDownload
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 6)
                    }

                    VersionListFooterView(
                        totalCount: totalCount,
                        visibleCount: visibleCount,
                        isFiltered: activeFilter != .all || !searchText.isEmpty
                    )
                }
            }
            .background(Color(.clear))
            .onChange(of: expandedVersions) { newValue in
                if let lastExpanded = newValue.sorted().last {
                    withAnimation {
                        proxy.scrollTo(lastExpanded, anchor: .top)
                    }
                }
            }
            .onAppear {
                if cachedVersions.isEmpty {
                    cachedVersions = loadFilteredVersions()
                }
            }
            .onChange(of: downloadAppleSilicon) { _ in
                cachedVersions = loadFilteredVersions()
                cachedPackageSizes.removeAll()
                sizeLoadingVersions.removeAll()
                expandedVersions.removeAll()
            }
        }
    }

    private func processedGroups(cachedVersions: [(key: String, value: Product.Platform)]) -> [VersionGroup] {
        var list = cachedVersions

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter { entry in
                if entry.key.lowercased().contains(query) { return true }
                if let guid = entry.value.languageSet.first?.buildGuid.lowercased(),
                   guid.contains(query) {
                    return true
                }
                return false
            }
        }

        switch activeFilter {
        case .all:
            break
        case .latest:
            let grouped = Dictionary(grouping: list) { majorOf($0.key) }
            list = grouped.values.compactMap { items in
                items.sorted { AppStatics.compareVersions($0.key, $1.key) > 0 }.first
            }
        case .downloaded:
            list = list.filter { entry in
                globalNetworkManager.isVersionDownloaded(
                    productId: productId,
                    version: entry.key,
                    language: defaultLanguage
                ) != nil
            }
        case .installed:
            list = list.filter { entry in
                let platform = installerSelectedPlatformId(
                    productId: productId,
                    version: entry.key
                ) ?? "unknown"
                return globalNetworkManager.isProductInstalled(
                    productId: productId,
                    version: entry.key,
                    platform: platform
                )
            }
        case .hasDependencies:
            list = list.filter { entry in
                !(entry.value.languageSet.first?.dependencies.isEmpty ?? true)
            }
        }

        let grouped = Dictionary(grouping: list) { majorOf($0.key) }
        return grouped.keys.sorted(by: >).map { major in
            VersionGroup(
                major: major,
                items: (grouped[major] ?? []).sorted {
                    AppStatics.compareVersions($0.key, $1.key) > 0
                }
            )
        }
    }

    private func majorOf(_ version: String) -> Int {
        guard let head = version.split(separator: ".").first,
              let value = Int(head) else {
            return 0
        }
        return value
    }

    private func loadFilteredVersions() -> [(key: String, value: Product.Platform)] {
        HDPIMParityDecisionEngine.shared.visibleVersions(productId: productId)
    }

    private func handleVersionSelect(_ version: String) {
        onSelect(version)
        dismiss()
    }

    private func handleVersionToggle(_ version: String) {
        withAnimation {
            if expandedVersions.contains(version) {
                expandedVersions.remove(version)
            } else {
                expandedVersions.insert(version)
            }
        }
    }

    private func handleCustomDownload(_ version: String) {
        onCustomDownload(version)
    }
}

private struct VersionGroupSection: View {
    let productId: String
    let group: VersionGroup
    let overallLatestKey: String?
    @Binding var expandedVersions: Set<String>
    @Binding var cachedPackageSizes: [String: Int64]
    @Binding var sizeLoadingVersions: Set<String>
    let onSelect: (String) -> Void
    let onToggle: (String) -> Void
    let onCustomDownload: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(group.major).x")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary.opacity(0.75))
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 0.5)
                Text("\(group.items.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: VersionPickerConstants.verticalSpacing) {
                ForEach(group.items, id: \.key) { version, info in
                    let isGroupLatest = group.items.first?.key == version
                    let isOverallLatest = overallLatestKey == version
                    VersionRow(
                        productId: productId,
                        version: version,
                        info: info,
                        isExpanded: expandedVersions.contains(version),
                        isGroupLatest: isGroupLatest,
                        isOverallLatest: isOverallLatest,
                        cachedPackageSizes: $cachedPackageSizes,
                        sizeLoadingVersions: $sizeLoadingVersions,
                        onSelect: onSelect,
                        onToggle: onToggle,
                        onCustomDownload: onCustomDownload
                    )
                    .id(version)
                    .transition(.opacity)
                }
            }
        }
    }
}

private struct VersionRow: View, Equatable {
    @StorageValue(\.defaultLanguage) private var defaultLanguage

    let productId: String
    let version: String
    let info: Product.Platform
    let isExpanded: Bool
    let isGroupLatest: Bool
    let isOverallLatest: Bool
    @Binding var cachedPackageSizes: [String: Int64]
    @Binding var sizeLoadingVersions: Set<String>
    let onSelect: (String) -> Void
    let onToggle: (String) -> Void
    let onCustomDownload: (String) -> Void

	static func == (lhs: VersionRow, rhs: VersionRow) -> Bool {
		lhs.productId == rhs.productId &&
		lhs.version == rhs.version &&
		lhs.isExpanded == rhs.isExpanded &&
		lhs.isGroupLatest == rhs.isGroupLatest &&
		lhs.isOverallLatest == rhs.isOverallLatest &&
		lhs.installedProduct == rhs.installedProduct &&
		lhs.cachedPackageSizes[rhs.version] == rhs.cachedPackageSizes[rhs.version] &&
		lhs.sizeLoadingVersions.contains(rhs.version) == rhs.sizeLoadingVersions.contains(rhs.version)
	}

	@State private var cachedExistingPath: URL? = nil
	@State private var cachedDownloadedPath: URL? = nil
	@State private var installedProduct: HDPIMInstalledProductForUninstall? = nil
	@State private var isHovered = false

    private var existingPath: URL? {
        cachedExistingPath
    }

    private var downloadedPath: URL? {
        cachedDownloadedPath
    }

    var body: some View {
        VStack(spacing: 0) {
            VersionHeader(
                productId: productId,
                version: version,
                info: info,
                isExpanded: isExpanded,
                isGroupLatest: isGroupLatest,
                isOverallLatest: isOverallLatest,
                hasExistingPath: existingPath != nil,
                hasDownloadedPackage: existingPath == nil && downloadedPath != nil,
                onSelect: { onToggle(version) },
                onToggle: { onToggle(version) }
            )

            if isExpanded {
                Divider()
                    .padding(.horizontal, 4)

				VersionDetails(
					productId: productId,
					info: info,
					version: version,
					installedProduct: installedProduct,
					cachedPackageSizes: $cachedPackageSizes,
					sizeLoadingVersions: $sizeLoadingVersions,
					onSelect: onSelect,
					onCustomDownload: onCustomDownload,
					onUninstallFinished: refreshInstallState
				)
			}
		}
        .padding(.horizontal)
        .background(
            RoundedRectangle(cornerRadius: VersionPickerConstants.cornerRadius)
                .fill(isHovered ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VersionPickerConstants.cornerRadius)
                .stroke(
                    isOverallLatest ? Color.blue.opacity(0.25) : Color.clear,
                    lineWidth: 1
                )
        )
        .cornerRadius(VersionPickerConstants.cornerRadius)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
		.onAppear {
			refreshInstallState()

			if cachedDownloadedPath == nil {
				cachedDownloadedPath = globalNetworkManager.isVersionDownloaded(
                    productId: productId,
                    version: version,
                    language: defaultLanguage
                )
			}
		}
	}

	private func refreshInstallState() {
		let platform = installerSelectedPlatformId(
			productId: productId,
			version: version
		) ?? "unknown"
		let processorFamily = HDPIMProcessorFamily.from(platform: platform)
		installedProduct = HDPIMUninstaller.installedProducts(
			sapCode: productId,
			version: version
		).first { $0.processorFamily == processorFamily }
		cachedExistingPath = installedProduct == nil ? nil : URL(fileURLWithPath: "/")
	}
}

private struct VersionHeader: View {
    let productId: String
    let version: String
    let info: Product.Platform
    let isExpanded: Bool
    let isGroupLatest: Bool
    let isOverallLatest: Bool
    let hasExistingPath: Bool
    let hasDownloadedPackage: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    private var hasDependencies: Bool {
        !(info.languageSet.first?.dependencies.isEmpty ?? true)
    }

    private var dependencyCount: Int {
        info.languageSet.first?.dependencies.count ?? 0
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                VersionInfo(
                    productId: productId,
                    version: version,
                    platform: info.id,
                    info: info,
                    isGroupLatest: isGroupLatest,
                    isOverallLatest: isOverallLatest,
                    hasExistingPath: hasExistingPath,
                    hasDownloadedPackage: hasDownloadedPackage
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if hasDependencies {
                        HStack(spacing: 3) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 9))
                            Text("\(dependencyCount) 依赖")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary.opacity(0.8))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.vertical, VersionPickerConstants.buttonPadding + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct VersionDetails: View {
	let productId: String
	let info: Product.Platform
	let version: String
	let installedProduct: HDPIMInstalledProductForUninstall?
	@Binding var cachedPackageSizes: [String: Int64]
	@Binding var sizeLoadingVersions: Set<String>
	let onSelect: (String) -> Void
	let onCustomDownload: (String) -> Void
	let onUninstallFinished: () -> Void

    private var hasRawDependencies: Bool {
        !(info.languageSet.first?.dependencies.isEmpty ?? true)
    }

    private var shouldShowDependencySection: Bool {
        hasRawDependencies
    }

    private var hasModules: Bool {
        !(info.modules.isEmpty)
    }

    private var displayedDependencies: [Product.Platform.LanguageSet.Dependency] {
        info.languageSet.first?.dependencies ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VersionPickerConstants.verticalSpacing) {
			VersionSizeEstimateView(
				version: version,
				cachedPackageSizes: $cachedPackageSizes,
                sizeLoadingVersions: $sizeLoadingVersions
            )
            .task(id: version) {
                await preloadSize(for: version)
			}

			if let installedProduct {
				InstalledProductUninstallSection(
					productId: productId,
					version: version,
					info: info,
					installedProduct: installedProduct,
					onUninstallFinished: onUninstallFinished
				)
			}

			if shouldShowDependencySection || hasModules {
				VStack(alignment: .leading, spacing: 8) {
                    if shouldShowDependencySection {
                        HStack(spacing: 5) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue.opacity(0.8))
                            Text("依赖组件")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("(\(displayedDependencies.count))")
                                .font(.system(size: 11))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.blue.opacity(0.1))
                                )
                                .foregroundColor(.blue.opacity(0.8))
                        }
                        .padding(.vertical, 4)
                        DependenciesList(dependencies: displayedDependencies)
                            .padding(.leading, 8)
                    }
                    #if DEBUG
                    if hasModules {
                        if shouldShowDependencySection {
                            Divider()
                                .padding(.vertical, 4)
                        }

                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.purple.opacity(0.8))
                            Text("可选模块")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("(\(info.modules.count))")
                                .font(.system(size: 11))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.purple.opacity(0.1))
                                )
                                .foregroundColor(.purple.opacity(0.8))
                        }
                        .padding(.vertical, 4)
                        ModulesList(modules: info.modules)
                            .padding(.leading, 8)
                    }
                    #endif
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }

            VersionDownloadButton(
                productId: productId,
                version: version,
                onSelect: onSelect,
                onCustomDownload: { version in
                    onCustomDownload(version)
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private func preloadSize(for version: String) async {
        if cachedPackageSizes[version] != nil { return }
        if sizeLoadingVersions.contains(version) { return }
        await MainActor.run {
            _ = sizeLoadingVersions.insert(version)
        }

        if isManifestInstallerProduct(productId) {
            let size = await resolveInstallerSize(version: version)
            await MainActor.run {
                cachedPackageSizes[version] = size
                _ = sizeLoadingVersions.remove(version)
            }
            return
        }

        do {
            let decision = try await HDPIMParityDecisionEngine.shared.resolveDownloadDecision(
                productId: productId,
                version: version,
                requestedLanguage: StorageData.shared.defaultLanguage
            )
            let (_, deps) = HDPIMParityDecisionEngine.shared.makeDownloadPresentation(from: decision)
            let total = deps.reduce(Int64(0)) { acc, dep in
                acc + dep.packages.filter { $0.isSelected }
                    .reduce(Int64(0)) { $0 + $1.downloadSize }
            }
            await MainActor.run {
                cachedPackageSizes[version] = total
                _ = sizeLoadingVersions.remove(version)
            }
        } catch {
            await MainActor.run {
                _ = sizeLoadingVersions.remove(version)
            }
        }
    }

    private func resolveInstallerSize(version: String) async -> Int64 {
        guard let product = findProduct(id: productId, version: version, scope: .ccm) ?? findProduct(id: productId, version: version),
              let match = installerPlatformMatch(product: product, selectedVersion: version) else {
            return Int64(max(info.languageSet.first?.installSize ?? 0, 0))
        }

        if let manifestSize = await installerManifestAssetSize(match.languageSet.manifestURL) {
            return manifestSize
        }

        if let downloadSize = await installerContentLength(match.languageSet.lbsURL) {
            return downloadSize
        }

        return Int64(max(match.languageSet.installSize, 0))
    }

    private func installerManifestAssetSize(_ manifestPath: String) async -> Int64? {
        let manifestURL = normalizedInstallerURL(manifestPath)
        guard !manifestURL.isEmpty,
              let url = URL(string: manifestURL) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let doc = try XMLDocument(data: data)
            let sizeNodes = try doc.nodes(forXPath: "//asset_size")
            return sizeNodes.compactMap { node in
                Int64(node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }.first { $0 > 0 }
        } catch {
            return nil
        }
    }

    private func installerContentLength(_ downloadPath: String) async -> Int64? {
        let downloadURL = normalizedInstallerURL(downloadPath)
        guard !downloadURL.isEmpty,
              let url = URL(string: downloadURL) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            if let length = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let size = Int64(length),
               size > 0 {
                return size
            }

            return httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil
        } catch {
            return nil
        }
    }
}

private struct VersionSizeEstimateView: View {
	let version: String
	@Binding var cachedPackageSizes: [String: Int64]
	@Binding var sizeLoadingVersions: Set<String>

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.75))
            if let size = cachedPackageSizes[version], size > 0 {
                Text("预计下载 ~\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
            } else if sizeLoadingVersions.contains(version) {
                ProgressView()
                    .controlSize(.mini)
                Text("计算中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 2)
	}
}

private enum PendingUninstallAction: Identifiable, Equatable {
	case product
	case modules(Set<String>)
	case package(HDPIMPackageUninstallKey)

	var id: String {
		switch self {
		case .product:
			return "product"
		case .modules(let moduleIds):
			return "modules|\(moduleIds.sorted().joined(separator: ","))"
		case .package(let packageKey):
			return "package|\(packageKey.id)"
		}
	}

	var title: String {
		switch self {
		case .product:
			return String(localized: "卸载产品")
		case .modules(let moduleIds):
			return moduleIds.count > 1 ? String(localized: "移除多个模块") : String(localized: "移除模块")
		case .package:
			return String(localized: "卸载包")
		}
	}
}

private struct InstalledProductUninstallSection: View {
	let productId: String
	let version: String
	let info: Product.Platform
	let installedProduct: HDPIMInstalledProductForUninstall
	let onUninstallFinished: () -> Void

	@ObservedObject private var networkManager = globalNetworkManager
	@State private var pendingAction: PendingUninstallAction?
	@State private var showUninstallProgress = false
	@State private var showPackageUninstall = false
	@State private var selectedModuleIds: Set<String> = []

	private var displayName: String {
		findProduct(id: productId, version: version)?.displayName ?? productId
	}

	private var installedModuleRows: [(id: String, displayName: String, deploymentType: String)] {
		installedProduct.modules.map { moduleId in
			let catalog = info.modules.first { $0.id == moduleId }
			return (
				id: moduleId,
				displayName: catalog?.displayName.isEmpty == false ? catalog?.displayName ?? moduleId : moduleId,
				deploymentType: catalog?.deploymentType ?? ""
			)
		}
	}

	private var packageCountText: String {
		String(format: String(localized: "%d 个包"), installedProduct.packages.count)
	}

	private var canSelectMultipleModules: Bool {
		installedModuleRows.count > 1
	}

	private var selectedModuleCountText: String {
		selectedModuleIds.isEmpty
			? String(localized: "未选择模块")
			: String(format: String(localized: "已选择 %d 个模块"), selectedModuleIds.count)
	}

	private var selectableModuleIds: Set<String> {
		Set(installedModuleRows.map(\.id))
	}

	private struct InstalledPackageRow: Identifiable {
		let key: HDPIMPackageUninstallKey
		let package: HDPIMNativePackageContext

		var id: String {
			key.id
		}
	}

	private var installedPackageRows: [InstalledPackageRow] {
		installedProduct.packages.sorted { lhs, rhs in
			if lhs.sequenceNumber != rhs.sequenceNumber {
				return lhs.sequenceNumber < rhs.sequenceNumber
			}
			if lhs.packageName != rhs.packageName {
				return lhs.packageName < rhs.packageName
			}
			return AppStatics.compareVersions(lhs.packageVersion, rhs.packageVersion) < 0
		}.map { package in
			InstalledPackageRow(
				key: HDPIMPackageUninstallKey(
					packageName: package.packageName,
					packageVersion: package.packageVersion
				),
				package: package
			)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: "checkmark.seal.fill")
					.font(.system(size: 12))
					.foregroundColor(.green)
				Text("已安装")
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.primary.opacity(0.9))
				Text(packageCountText)
					.font(.system(size: 11))
					.foregroundColor(.secondary)
				if !installedProduct.installDir.isEmpty {
					Text(installedProduct.installDir)
						.font(.system(size: 10))
						.foregroundColor(.secondary.opacity(0.8))
						.lineLimit(1)
						.truncationMode(.middle)
						.textSelection(.enabled)
				}
				Spacer()
				Button(role: .destructive) {
					pendingAction = .product
				} label: {
					Label("卸载产品", systemImage: "trash")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(isUninstalling)
			}

			if !installedModuleRows.isEmpty {
				VStack(alignment: .leading, spacing: 4) {
					if canSelectMultipleModules {
						HStack(spacing: 8) {
							Button {
								if selectedModuleIds.count == installedModuleRows.count {
									selectedModuleIds.removeAll()
								} else {
									selectedModuleIds = Set(installedModuleRows.map(\.id))
								}
							} label: {
								Label(
									selectedModuleIds.count == installedModuleRows.count ? "清空" : "全选",
									systemImage: selectedModuleIds.count == installedModuleRows.count ? "checkmark.square.fill" : "square"
								)
							}
							.buttonStyle(.borderless)
							.controlSize(.small)
							.disabled(isUninstalling)

							Text(selectedModuleCountText)
								.font(.system(size: 10))
								.foregroundColor(.secondary)

							Spacer()

							Button(role: .destructive) {
								pendingAction = .modules(selectedModuleIds.intersection(selectableModuleIds))
							} label: {
								Label("移除选中", systemImage: "minus.circle.fill")
							}
							.buttonStyle(.bordered)
							.controlSize(.small)
							.disabled(isUninstalling || selectedModuleIds.isEmpty)
						}
						.padding(.bottom, 2)
					}

					ForEach(installedModuleRows, id: \.id) { module in
						HStack(spacing: 8) {
							if canSelectMultipleModules {
								Button {
									toggleModuleSelection(module.id)
								} label: {
									Image(systemName: selectedModuleIds.contains(module.id) ? "checkmark.square.fill" : "square")
										.font(.system(size: 12))
										.foregroundColor(selectedModuleIds.contains(module.id) ? .accentColor : .secondary)
										.frame(width: 14)
								}
								.buttonStyle(.plain)
								.disabled(isUninstalling)
							}
							Image(systemName: "puzzlepiece.extension.fill")
								.font(.system(size: 10))
								.foregroundColor(.purple.opacity(0.85))
								.frame(width: 14)
							Text(module.displayName)
								.font(.system(size: 12, weight: .medium))
								.foregroundColor(.primary.opacity(0.85))
							if !module.deploymentType.isEmpty {
								Text(module.deploymentType)
									.font(.system(size: 10))
									.foregroundColor(.secondary)
							}
							Spacer()
							Button(role: .destructive) {
								pendingAction = .modules([module.id])
							} label: {
								Label("移除", systemImage: "minus.circle")
							}
							.buttonStyle(.borderless)
							.controlSize(.small)
							.disabled(isUninstalling)
						}
						.padding(.vertical, 3)
					}
				}
				.padding(.leading, 2)
			}

			if !installedPackageRows.isEmpty {
				DisclosureGroup(isExpanded: $showPackageUninstall) {
					VStack(alignment: .leading, spacing: 4) {
						ForEach(installedPackageRows) { row in
							let package = row.package
							HStack(spacing: 8) {
								Image(systemName: "shippingbox.fill")
									.font(.system(size: 10))
									.foregroundColor(.orange.opacity(0.85))
									.frame(width: 14)
								VStack(alignment: .leading, spacing: 1) {
									Text(package.packageName)
										.font(.system(size: 12, weight: .medium))
										.foregroundColor(.primary.opacity(0.85))
										.lineLimit(1)
										.truncationMode(.middle)
									Text(package.packageVersion)
										.font(.system(size: 10))
										.foregroundColor(.secondary)
										.lineLimit(1)
								}
								if let module = package.module, !module.isEmpty {
									Text(module)
										.font(.system(size: 10))
										.foregroundColor(.secondary)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								Spacer()
							}
							.padding(.vertical, 3)
						}
					}
					.padding(.top, 4)
				} label: {
					HStack(spacing: 6) {
						Image(systemName: "shippingbox")
							.font(.system(size: 10))
							.foregroundColor(.secondary)
						Text("已安装包")
							.font(.system(size: 12, weight: .medium))
							.foregroundColor(.primary.opacity(0.85))
					}
				}
				.padding(.leading, 2)
			}
		}
		.padding(10)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Color.green.opacity(0.08))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.stroke(Color.green.opacity(0.18), lineWidth: 0.5)
		)
		.alert(item: $pendingAction) { action in
			Alert(
				title: Text(action.title),
				message: Text(confirmMessage(for: action)),
				primaryButton: .destructive(Text("确认")) {
					startUninstall(action)
				},
				secondaryButton: .cancel()
			)
		}
		.sheet(isPresented: $showUninstallProgress, onDismiss: {
			if case .completed = networkManager.uninstallState {
				onUninstallFinished()
			}
		}) {
			InstallProgressView(
				data: networkManager.makeUninstallProgressViewData(productName: displayName),
				onCancel: {
					showUninstallProgress = false
					if case .completed = networkManager.uninstallState {
						onUninstallFinished()
					}
				}
			)
		}
	}

	private var isUninstalling: Bool {
		if case .installing = networkManager.uninstallState {
			return true
		}
		return false
	}

	private func toggleModuleSelection(_ moduleId: String) {
		if selectedModuleIds.contains(moduleId) {
			selectedModuleIds.remove(moduleId)
		} else {
			selectedModuleIds.insert(moduleId)
		}
	}

	private func confirmMessage(for action: PendingUninstallAction) -> String {
		switch action {
		case .product:
			return String(format: String(localized: "将按 HDPIM 产品卸载流程移除 %@ %@。"), displayName, version)
		case .modules(let moduleIds):
			let names = moduleIds.sorted().joined(separator: "、")
			if moduleIds.count > 1 {
				return String(format: String(localized: "将按 HDPIM 模块卸载流程移除 %d 个模块：%@。"), moduleIds.count, names)
			}
			return String(format: String(localized: "将按 HDPIM 模块卸载流程移除模块 %@。"), names)
		case .package(let packageKey):
			return String(format: String(localized: "将按 HDPIM 包级卸载流程移除包 %@ %@。"), packageKey.packageName, packageKey.packageVersion)
		}
	}

	private func startUninstall(_ action: PendingUninstallAction) {
		if case .package = action {
			pendingAction = nil
			return
		}

		showUninstallProgress = true
		Task {
			switch action {
			case .product:
				await networkManager.uninstallProduct(
					sapCode: installedProduct.sapCode,
					version: installedProduct.version,
					processorFamily: installedProduct.processorFamily,
					productName: displayName
				)
			case .modules(let moduleIds):
				await networkManager.uninstallModules(
					sapCode: installedProduct.sapCode,
					version: installedProduct.version,
					processorFamily: installedProduct.processorFamily,
					moduleIds: moduleIds,
					productName: displayName
				)
			case .package(let packageKey):
				await networkManager.uninstallPackages(
					sapCode: installedProduct.sapCode,
					version: installedProduct.version,
					processorFamily: installedProduct.processorFamily,
					packageKeys: [packageKey],
					productName: displayName
				)
			}
		}
	}
}

private struct VersionDownloadButton: View {
	let productId: String
	let version: String
    let onSelect: (String) -> Void
    let onCustomDownload: (String) -> Void

    var body: some View {
        Button(action: {
            if isManifestInstallerProduct(productId) {
                onSelect(version)
            } else {
                onCustomDownload(version)
            }
        }) {
            Text("下载")
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
        .padding(.top, 8)
    }
}

struct VersionInfo: View {
    let productId: String
    let version: String
    let platform: String
    let info: Product.Platform
    let isGroupLatest: Bool
    let isOverallLatest: Bool
    let hasExistingPath: Bool
    let hasDownloadedPackage: Bool

    @State private var didCopyBuildGuid = false

    private var productVersion: String {
        info.languageSet.first?.productVersion ?? ""
    }

    private var buildGuid: String? {
        info.languageSet.first?.buildGuid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(version)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.92))

                if isOverallLatest {
                    OverallLatestBadge()
                } else if isGroupLatest {
                    GroupLatestBadge()
                }

                if hasExistingPath {
                    ExistingPathButton(isVisible: true)
                } else if hasDownloadedPackage {
                    DownloadedPackageButton(isVisible: true)
                }

                if !productVersion.isEmpty, productVersion != version {
                    Text("v\(productVersion)")
                        .font(.system(size: 11))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(0.08))
                        )
                        .foregroundColor(.blue.opacity(0.8))
                }
            }

            HStack(spacing: 4) {
                Text(platform)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.85))

                if let guid = buildGuid, !guid.isEmpty {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(guid)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: { copyBuildGuid(guid) }) {
                        Image(systemName: didCopyBuildGuid ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(GlassButtonStyle(tint: didCopyBuildGuid ? .green : .blue))
                    .help(String(localized: "复制 buildGuid"))
                }
            }
        }
    }

    private func copyBuildGuid(_ guid: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(guid, forType: .string)
        withAnimation { didCopyBuildGuid = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { didCopyBuildGuid = false }
        }
    }
}

struct GroupLatestBadge: View {
    var body: some View {
        Text("最新")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
            )
    }
}

struct OverallLatestBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
            Text("最新")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.blue)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.blue.opacity(0.35), lineWidth: 0.5)
        )
    }
}

struct ExistingPathButton: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Text("已安装")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.green.opacity(0.25), lineWidth: 0.5)
                )
        }
    }
}

struct DownloadedPackageButton: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Text("已下载")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.blue.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue.opacity(0.25), lineWidth: 0.5)
                )
        }
    }
}

struct ExpandButton: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    let hasDependencies: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
            .foregroundColor(.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
    }
}

struct DependenciesList: View {
    let dependencies: [Product.Platform.LanguageSet.Dependency]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(dependencies, id: \.sapCode) { dependency in
                DependencyRow(dependency: dependency)
                    .padding(.vertical, 4)
            }
        }
    }
}

struct DependencyRow: View, Equatable {
    let dependency: Product.Platform.LanguageSet.Dependency

    static func == (lhs: DependencyRow, rhs: DependencyRow) -> Bool {
        lhs.dependency.sapCode == rhs.dependency.sapCode &&
        lhs.dependency.productVersion == rhs.dependency.productVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                getPlatformIcon(for: dependency.selectedPlatform)
                    .foregroundColor(.blue.opacity(0.8))
                    .font(.system(size: 12))
                    .frame(width: 16)

                Text(dependency.sapCode)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))

                Text("\(dependency.productVersion)")
                    .font(.system(size: 11))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .foregroundColor(.blue.opacity(0.8))

                if dependency.baseVersion != dependency.productVersion {
                    HStack(spacing: 3) {
                        Text("base:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text(dependency.baseVersion)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.9))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.1))
                    )
                }

                Spacer(minLength: 4)

                #if DEBUG
                DependencyDebugChip(dependency: dependency)
                #endif
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                if !dependency.buildGuid.isEmpty {
                    HStack(spacing: 3) {
                        Text("buildGuid:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text(dependency.buildGuid)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.9))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.leading, 24)
        }
    }

    private func getPlatformIcon(for platform: String) -> Image {
        switch platform {
        case "macarm64":
            return Image(systemName: "m.square")
        case "macuniversal":
            return Image(systemName: "m.circle")
        case "osx10", "osx10-64":
            return Image(systemName: "x.square")
        default:
            return Image(systemName: "questionmark.square")
        }
    }
}

#if DEBUG
struct DependencyDebugChip: View {
    let dependency: Product.Platform.LanguageSet.Dependency

    private var tooltip: String {
        var parts: [String] = []
        parts.append("Target: \(dependency.targetPlatform)")
        if !dependency.selectedReason.isEmpty {
            parts.append("Reason: \(dependency.selectedReason)")
        }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: dependency.isMatchPlatform ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(dependency.isMatchPlatform ? "match" : "mismatch")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(dependency.isMatchPlatform ? .green : .orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill((dependency.isMatchPlatform ? Color.green : Color.orange).opacity(0.12))
        )
        .help(tooltip)
    }
}
#endif

struct ModulesList: View {
    let modules: [Product.Platform.Module]

    var body: some View {
        ForEach(modules, id: \.id) { module in
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.purple.opacity(0.35))
                    .frame(width: 6, height: 6)

                Text(module.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))

                if !module.deploymentType.isEmpty {
                    Text("(\(module.deploymentType))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }

                Spacer()
            }
            .padding(.vertical, 3)
        }
    }
}

private struct VersionPickerEmptyView: View {
    let hint: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 64, height: 64)
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 4) {
                Text("没有结果")
                    .font(.system(size: 14, weight: .semibold))
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct VersionListFooterView: View {
    let totalCount: Int
    let visibleCount: Int
    let isFiltered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(footerText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var footerText: String {
        if isFiltered && visibleCount != totalCount {
            return "显示 \(visibleCount) / \(totalCount) 个版本"
        }
        return "获取到 \(totalCount) 个版本"
    }
}

private struct DuplicateTaskAlertView: View {
    let productId: String
    let version: String
    let onCancel: () -> Void
    let iconImage: NSImage?

    private var productName: String {
        findProduct(id: productId)?.displayName ?? productId
    }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if let iconImage = iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .foregroundColor(.blue)
                }

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                    .background(Color.white)
                    .clipShape(Circle())
                    .offset(x: 24, y: -24)
            }

            Text("下载任务已存在")
                .font(.headline)

            VStack(spacing: 8) {
                Text("产品 \(productName) (版本 \(version)) 已有正在进行的下载任务")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)

                Text("请在下载管理器中查看进度")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("确定") {
                onCancel()
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
            .frame(width: 200)
        }
        .padding()
        .frame(width: 400, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(radius: 10)
        )
        .navigationTitle("任务提示")
    }
}
