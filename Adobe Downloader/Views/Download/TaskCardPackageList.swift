import SwiftUI

private enum PackageListFilter: String, CaseIterable, Identifiable {
    case all, waiting, downloading, completed, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "全部")
        case .waiting: return String(localized: "等待")
        case .downloading: return String(localized: "下载中")
        case .completed: return String(localized: "已完成")
        case .other: return String(localized: "其他")
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .waiting: return "hourglass"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .other: return "ellipsis.circle"
        }
    }
}

struct TaskCardPackageList: View {
    let task: NewDownloadTask
    let onRemovePackage: (String, UUID) -> Void
    let onRemoveDependency: (String) -> Void
    @State private var expandedProducts: Set<String> = []
    @State private var searchText: String = ""
    @State private var activeFilter: PackageListFilter = .all
    @State private var showCopiedToast = false
    @State private var copiedToastText = ""
    @State private var copyToastTask: Task<Void, Never>?

    private var hasLotsOfPackages: Bool {
        task.totalPackages > 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if hasLotsOfPackages {
                    packageSearchField
                } else {
                    Spacer(minLength: 0)
                }
                #if DEBUG
                debugPersistenceButton
                #endif
                copyAllButton
            }

            if hasLotsOfPackages {
                packageFilterBar
            }

            VStack(alignment: .leading, spacing: 8) {
                if isFilteringActive && !task.dependenciesToDownload.contains(where: { !visiblePackages(in: $0).isEmpty }) {
                    VStack(spacing: 8) {
                        Text(String(localized: "没有匹配的包"))
                            .foregroundColor(.secondary)
                        Button(String(localized: "重置筛选")) {
                            searchText = ""
                            activeFilter = .all
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                ForEach(task.dependenciesToDownload, id: \.sapCode) { product in
                    let visible = visiblePackages(in: product)
                    if !visible.isEmpty || !isFilteringActive {
                        PackageProductRow(
                            task: task,
                            product: product,
                            visiblePackages: visible,
                            isExpanded: expandedProducts.contains(product.sapCode),
                            isMainProduct: product.sapCode == task.productId,
                            isForceExpanded: isFilteringActive,
                            canRemove: globalNewDownloadUtils.canRemoveIncrementalDependency(task: task, dependency: product),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedProducts.contains(product.sapCode) {
                                        expandedProducts.remove(product.sapCode)
                                    } else {
                                        expandedProducts.insert(product.sapCode)
                                    }
                                }
                            },
                            onRemove: {
                                onRemoveDependency(product.sapCode)
                            },
                            onRemovePackage: { packageId in
                                onRemovePackage(product.sapCode, packageId)
                            },
                            onCopyFeedback: { message in
                                showCopyToast(message)
                            }
                        )
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showCopiedToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(copiedToastText)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var isFilteringActive: Bool {
        activeFilter != .all || !searchText.isEmpty
    }

    private func visiblePackages(in product: DependenciesToDownload) -> [Package] {
        product.packages.filter { pkg in
            passesSearch(pkg) && passesFilter(pkg)
        }
    }

    private func passesSearch(_ pkg: Package) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return pkg.fullPackageName.lowercased().contains(q)
            || pkg.packageVersion.lowercased().contains(q)
            || pkg.type.lowercased().contains(q)
    }

    private func passesFilter(_ pkg: Package) -> Bool {
        switch activeFilter {
        case .all: return true
        case .waiting: return pkg.status == .waiting
        case .downloading: return pkg.status == .downloading
        case .completed: return pkg.status == .completed
        case .other:
            switch pkg.status {
            case .waiting, .downloading, .completed: return false
            default: return true
            }
        }
    }

    private var packageSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(String(localized: "搜索包名、版本、类型"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "清空搜索"))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var packageFilterBar: some View {
        HStack(spacing: 4) {
            ForEach(PackageListFilter.allCases) { filter in
                PackageFilterChip(
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

    private var copyAllButton: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(generateAllProductsInfo(), forType: .string)
            showCopyToast(String(localized: "已复制所有信息"))
        }) {
            Label(String(localized: "复制清单"), systemImage: "doc.on.clipboard")
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(String(localized: "复制所有信息"))
    }

    private func showCopyToast(_ message: String) {
        copyToastTask?.cancel()
        copiedToastText = message
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedToast = true
        }
        copyToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedToast = false
            }
        }
    }

    #if DEBUG
    private var debugPersistenceButton: some View {
        Button(action: {
            let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let tasksDirectory = containerURL.appendingPathComponent("Adobe Downloader/tasks", isDirectory: true)
            let fileName = "\(installerOutputName(productId: task.productId, version: task.productVersion, language: task.language, platform: task.platform))-task.json"
            let fileURL = tasksDirectory.appendingPathComponent(fileName)
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: tasksDirectory.path)
        }) {
            Label(String(localized: "持久化文件"), systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    #endif

    private func generateAllProductsInfo() -> String {
        var result = ""
        for (index, product) in task.dependenciesToDownload.enumerated() {
            if isManifestInstallerProduct(product.sapCode) {
                result += "\(product.sapCode) \(product.version)\n"
            } else {
                result += "\(product.sapCode) \(product.version) - (\(product.buildGuid))\n"
            }
            for (pkgIndex, package) in product.packages.enumerated() {
                let prefix = pkgIndex == product.packages.count - 1 ? "    └── " : "    ├── "
                result += "\(prefix)\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)\n"
            }
            if !product.selectedReason.isEmpty {
                result += "    依赖详情:\n"
                result += "    - targetReason: \(product.selectedReason.isEmpty ? "(无)" : product.selectedReason)\n"
            }
            if index < task.dependenciesToDownload.count - 1 { result += "\n" }
        }
        return result
    }
}

private struct PackageFilterChip: View {
    let filter: PackageListFilter
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: filter.icon)
                    .font(.system(size: 9))
                Text(filter.title)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? .blue : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isActive ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PackageProductRow: View {
    let task: NewDownloadTask
    @ObservedObject var product: DependenciesToDownload
    let visiblePackages: [Package]
    let isExpanded: Bool
    let isMainProduct: Bool
    let isForceExpanded: Bool
    let canRemove: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onRemovePackage: (UUID) -> Void
    let onCopyFeedback: (String) -> Void
    @State private var showRemoveConfirm = false

    private var effectivelyExpanded: Bool {
        isForceExpanded || isExpanded
    }

    private var aggregatedSize: Int64 {
        product.packages.reduce(Int64(0)) { $0 + $1.downloadSize }
    }

    private var aggregatedSizeText: String {
        ByteCountFormatter.string(fromByteCount: aggregatedSize, countStyle: .file)
    }

    private var platformName: String {
        switch product.platform {
        case "macarm64": return "Apple Silicon"
        case "macuniversal": return String(localized: "通用")
        case "osx10", "osx10-64": return "Intel"
        default: return product.platform
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    productHeading
                }
                .buttonStyle(.plain)
                .disabled(isForceExpanded)
                .accessibilityValue(effectivelyExpanded ? String(localized: "已展开") : String(localized: "已收起"))

                if canRemove {
                    Button(action: { showRemoveConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "移除本次增量依赖"))
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.025))

            if effectivelyExpanded {
                if !isManifestInstallerProduct(product.sapCode), !product.buildGuid.isEmpty {
                    Divider().opacity(0.4)
                    buildGuidButton
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                ForEach(visiblePackages) { package in
                    Divider().opacity(0.35)
                    PackageItemRow(
                        package: package,
                        canRemove: globalNewDownloadUtils.canRemoveIncrementalPackage(task: task, package: package),
                        onRemove: {
                            onRemovePackage(package.id)
                        },
                        onCopyFeedback: onCopyFeedback
                    )
                }
            }
        }
        .background(Color(.controlBackgroundColor).opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isMainProduct ? Color.blue.opacity(0.25) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .alert(String(localized: "确认移除"), isPresented: $showRemoveConfirm) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "移除"), role: .destructive) {
                onRemove()
            }
        } message: {
            Text(String(localized: "移除该依赖中本次增量新增的包吗？已存在的包会保留。"))
        }
    }

    private var productHeading: some View {
        HStack(spacing: 8) {
            Image(systemName: effectivelyExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 10)
            Image(systemName: isMainProduct ? "app.badge.fill" : "cube.box.fill")
                .font(.system(size: 14))
                .foregroundColor(isMainProduct ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(product.sapCode)
                        .font(.system(size: 12, weight: .semibold))
                    Text(product.version)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(isMainProduct ? String(localized: "主产品") : String(localized: "依赖组件"))
                        .foregroundColor(isMainProduct ? .blue : .secondary)
                    if !platformName.isEmpty {
                        Text("·")
                        Text(platformName)
                            .help(product.platform)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(aggregatedSizeText)
                    .font(.system(size: 12, weight: .medium))
                Text(String(localized: "已完成 \(product.completedPackages) / \(product.totalPackages)"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .monospacedDigit()
            .fixedSize()
        }
        .foregroundColor(.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var buildGuidButton: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(product.buildGuid, forType: .string)
            onCopyFeedback(String(localized: "已复制 buildGuid"))
        }) {
            HStack(spacing: 8) {
                Text("BuildGuid")
                    .foregroundColor(.secondary)
                Text(product.buildGuid)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            }
            .font(.system(size: 10))
            .foregroundColor(.primary.opacity(0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(product.buildGuid)
        .accessibilityLabel(String(localized: "复制 buildGuid"))
        .accessibilityValue(product.buildGuid)
    }
}

private struct PackageItemRow: View {
    @ObservedObject var package: Package
    let canRemove: Bool
    let onRemove: () -> Void
    let onCopyFeedback: (String) -> Void
    @State private var showRemoveConfirm = false

    private var clampedProgress: Double {
        min(max(package.progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(package.fullPackageName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(package.fullPackageName)
                Spacer(minLength: 8)
                Text(package.formattedSize)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                if canRemove {
                    Button(action: { showRemoveConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "移除本次增量包"))
                }
            }
            .frame(minHeight: 20)

            HStack(spacing: 6) {
                if !package.type.isEmpty {
                    let isCore = package.type.lowercased() == "core"
                    DownloadPackageBadge(
                        title: isCore ? String(localized: "核心包") : String(localized: "非核心包"),
                        icon: isCore ? "cube.fill" : "cube.transparent",
                        tint: isCore ? .purple : .teal
                    )
                    .help(package.type)
                }
                DownloadPackageBadge(
                    title: package.isRequired ? String(localized: "必需") : String(localized: "可选"),
                    icon: package.isRequired ? "lock.fill" : "slider.horizontal.3",
                    tint: package.isRequired ? .orange : .blue
                )
                if !package.packageVersion.isEmpty {
                    Text(package.packageVersion)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(package.packageVersion)
                }
                Spacer(minLength: 8)
                packageStatusView
                    .fixedSize()
            }

            if package.status == .downloading {
                VStack(spacing: 4) {
                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue)

                    HStack {
                        Text("\(package.formattedDownloadedSize) / \(package.formattedSize)")
                            .foregroundColor(.secondary)
                        Spacer()
                        if package.speed > 0 {
                            Label(DownloadFormatters.speed(package.speed), systemImage: "arrow.down")
                                .foregroundColor(.blue)
                        }
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                }
            }

            if case .failed(let message) = package.status {
                HStack(alignment: .top, spacing: 8) {
                    Text(message)
                        .font(.system(size: 10))
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(message)
                    Spacer(minLength: 0)
                    Button(action: { copyPackageFailureInfo(message) }) {
                        Label(String(localized: "复制错误"), systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(String(localized: "复制错误信息"))
                }
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(package.status == .downloading ? Color.blue.opacity(0.04) : Color.clear)
        .alert(String(localized: "确认移除"), isPresented: $showRemoveConfirm) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "移除"), role: .destructive) {
                onRemove()
            }
        } message: {
            Text(String(localized: "移除该增量包并重新计算任务进度吗？"))
        }
    }

    @ViewBuilder
    private var packageStatusView: some View {
        switch package.status {
        case .waiting:
            Label(String(localized: "等待中"), systemImage: "hourglass")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        case .downloading:
            Label("\(Int(clampedProgress * 100))%", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue)
                .monospacedDigit()
        case .completed:
            Label(String(localized: "已完成"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .failed:
            Label(String(localized: "失败"), systemImage: "xmark.circle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.red)
        case .paused:
            Label(String(localized: "已暂停"), systemImage: "pause.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        }
    }

    private func copyPackageFailureInfo(_ message: String) {
        var lines: [String] = []
        lines.append("包名: \(package.fullPackageName)")
        lines.append("版本: \(package.packageVersion)")
        lines.append("类型: \(package.type)")
        lines.append("大小: \(package.formattedSize)")
        lines.append("下载地址: \(package.downloadURL)")
        if !package.manifestURL.isEmpty {
            lines.append("Manifest: \(package.manifestURL)")
        }
        lines.append("错误: \(message)")
        if let error = package.lastError {
            lines.append("错误详情: \(error.localizedDescription)")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        onCopyFeedback(String(localized: "已复制错误信息"))
    }
}

private struct DownloadPackageBadge: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(title)
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
}
