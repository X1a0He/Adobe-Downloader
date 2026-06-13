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
            #if DEBUG
            HStack(spacing: 8) {
                debugPersistenceButton
                Spacer()
                copyAllButton
            }
            #else
            HStack {
                Spacer()
                copyAllButton
            }
            #endif

            if hasLotsOfPackages {
                packageFilterBar
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 320)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
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

    private var packageFilterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                TextField(String(localized: "搜索包名"), text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
    }

    private var copyAllButton: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(generateAllProductsInfo(), forType: .string)
            showCopyToast(String(localized: "已复制所有信息"))
        }) {
            Label(String(localized: "复制所有信息"), systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: .green))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: .blue))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isMainProduct ? "app.badge.fill" : "cube.box.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isMainProduct ? .blue : .blue.opacity(0.7))

                    Text("\(product.sapCode) \(product.version)\(!isManifestInstallerProduct(product.sapCode) ? " - (\(product.buildGuid))" : "")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isMainProduct {
                        Text(String(localized: "主产品"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }

                    if !isManifestInstallerProduct(product.sapCode) {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(product.buildGuid, forType: .string)
                            onCopyFeedback(String(localized: "已复制 buildGuid"))
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(GlassButtonStyle(tint: .blue))
                        .help(String(localized: "复制 buildGuid"))
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text("\(product.completedPackages)/\(product.totalPackages)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary.opacity(0.75))
                            .monospacedDigit()
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.4))
                        Text(aggregatedSizeText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.85))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(4)

                    if canRemove {
                        Button(action: { showRemoveConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red.opacity(0.85))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "移除本次增量依赖"))
                    }

                    Image(systemName: effectivelyExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isMainProduct ? Color.blue.opacity(0.25) : Color.white.opacity(0.1), lineWidth: isMainProduct ? 1 : 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(isForceExpanded)

            if effectivelyExpanded {
                VStack(spacing: 4) {
                    ForEach(visiblePackages) { package in
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
                .padding(.leading, 20)
            }
        }
        .alert(String(localized: "确认移除"), isPresented: $showRemoveConfirm) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "移除"), role: .destructive) {
                onRemove()
            }
        } message: {
            Text(String(localized: "移除该依赖中本次增量新增的包吗？已存在的包会保留。"))
        }
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
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(package.fullPackageName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(package.type)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue.opacity(0.8))
                    .cornerRadius(3)

                Text(package.formattedSize)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))

                Spacer()

                packageStatusView

                if canRemove {
                    Button(action: { showRemoveConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "移除本次增量包"))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)

            if package.status == .downloading {
                VStack(spacing: 4) {
                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue.opacity(0.8))

                    HStack {
                        Text("\(package.formattedDownloadedSize) / \(package.formattedSize)")
                            .font(.system(size: 10))
                            .foregroundColor(.primary.opacity(0.7))
                        Spacer()
                        if package.speed > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down").font(.system(size: 8))
                                Text(DownloadFormatters.speed(package.speed)).font(.system(size: 10))
                            }
                            .foregroundColor(.blue.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
            HStack(spacing: 3) {
                Image(systemName: "hourglass.circle.fill").font(.system(size: 9))
                Text(package.status.description).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary.opacity(0.8))
        case .downloading:
            Text("\(Int(clampedProgress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue.opacity(0.9))
        case .completed:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                Text(package.status.description).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.green.opacity(0.9))
        case .failed(let message):
            HStack(spacing: 5) {
                Text(package.status.description)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(action: { copyPackageFailureInfo(message) }) {
                    Label(String(localized: "复制"), systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "复制错误信息"))
            }
            .foregroundColor(.red.opacity(0.9))
        default:
            Text(package.status.description)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.8))
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
