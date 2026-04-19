import SwiftUI

private enum GridMetrics {
    static let minCardWidth: CGFloat = 200
    static let spacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 32
    static let maxColumns: Int = 5

    static func columns(for width: CGFloat, spacing: CGFloat = spacing) -> [GridItem] {
        let available = max(width - horizontalPadding, minCardWidth)
        let rawCount = Int((available + spacing) / (minCardWidth + spacing))
        let count = max(1, min(maxColumns, rawCount))
        return Array(
            repeating: GridItem(.flexible(minimum: minCardWidth), spacing: spacing),
            count: count
        )
    }
}

private enum ProductFilter: String, CaseIterable, Identifiable, Hashable {
    case all, downloaded, downloading, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:         return String(localized: "全部")
        case .downloaded:  return String(localized: "已下载")
        case .downloading: return String(localized: "下载中")
        case .failed:      return String(localized: "失败")
        }
    }

    var icon: String {
        switch self {
        case .all:         return "square.grid.2x2"
        case .downloaded:  return "checkmark.circle"
        case .downloading: return "arrow.down.circle"
        case .failed:      return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .all:         return .blue
        case .downloaded:  return .green
        case .downloading: return .blue
        case .failed:      return .red
        }
    }
}

struct MainContentView: View {
    let loadingState: LoadingState
    let filteredProducts: [UniqueProduct]
    let searchText: String
    let onRetry: () -> Void
    let onOpenDownloadManager: () -> Void

    @ObservedObject private var networkManager = globalNetworkManager
    @State private var activeFilter: ProductFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            StatusChipStrip(activeFilter: $activeFilter, counts: statusCounts)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .frame(height: 0.5)
                                .foregroundColor(.secondary.opacity(0.15)),
                            alignment: .bottom
                        )
                )

            ActiveDownloadsBanner(
                tasks: networkManager.downloadTasks,
                onTap: onOpenDownloadManager
            )

            ZStack {
                switch loadingState {
                case .idle, .loading:
                    LoadingSkeletonView()

                case .failed(let error):
                    LoadingFailedView(error: error, onRetry: onRetry)

                case .success:
                    let visible = applyStatusFilter(filteredProducts)
                    if visible.isEmpty {
                        EmptyStateView(searchText: searchText, filter: activeFilter)
                    } else {
                        FeedLayout(
                            products: visible,
                            searchText: searchText,
                            activeFilter: activeFilter
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.clear))
    }

    private var statusCounts: [ProductFilter: Int] {
        var result: [ProductFilter: Int] = [.all: filteredProducts.count]
        var downloaded = Set<String>()
        var downloading = Set<String>()
        var failed = Set<String>()

        for task in networkManager.downloadTasks {
            switch task.status {
            case .completed:
                downloaded.insert(task.productId)
            case .downloading, .preparing, .waiting, .retrying, .paused:
                downloading.insert(task.productId)
            case .failed:
                failed.insert(task.productId)
            }
        }

        let ids = Set(filteredProducts.map(\.id))
        result[.downloaded] = downloaded.intersection(ids).count
        result[.downloading] = downloading.intersection(ids).count
        result[.failed] = failed.intersection(ids).count
        return result
    }

    private func applyStatusFilter(_ products: [UniqueProduct]) -> [UniqueProduct] {
        guard activeFilter != .all else { return products }
        let tasks = networkManager.downloadTasks
        switch activeFilter {
        case .all:
            return products
        case .downloaded:
            let ids = Set(tasks.compactMap { task -> String? in
                if case .completed = task.status { return task.productId }
                return nil
            })
            return products.filter { ids.contains($0.id) }
        case .downloading:
            let ids = Set(tasks.compactMap { task -> String? in
                switch task.status {
                case .downloading, .preparing, .waiting, .retrying, .paused:
                    return task.productId
                default:
                    return nil
                }
            })
            return products.filter { ids.contains($0.id) }
        case .failed:
            let ids = Set(tasks.compactMap { task -> String? in
                if case .failed = task.status { return task.productId }
                return nil
            })
            return products.filter { ids.contains($0.id) }
        }
    }
}

struct EmptyStateView: View {
    let searchText: String
    fileprivate var filter: ProductFilter = .all

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: iconName)
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.85))
            }
            VStack(spacing: 6) {
                Text(primaryMessage)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(secondaryMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    init(searchText: String) {
        self.searchText = searchText
        self.filter = .all
    }

    fileprivate init(searchText: String, filter: ProductFilter) {
        self.searchText = searchText
        self.filter = filter
    }

    private var iconName: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        switch filter {
        case .all:         return "tray"
        case .downloaded:  return "checkmark.circle"
        case .downloading: return "arrow.down.circle"
        case .failed:      return "xmark.circle"
        }
    }

    private var primaryMessage: String {
        if !searchText.isEmpty {
            return String(localized: "未找到 \"\(searchText)\" 相关产品")
        }
        switch filter {
        case .all:         return String(localized: "暂无产品")
        case .downloaded:  return String(localized: "尚无已下载的产品")
        case .downloading: return String(localized: "当前没有下载中的任务")
        case .failed:      return String(localized: "没有失败的任务")
        }
    }

    private var secondaryMessage: String {
        if !searchText.isEmpty {
            return String(localized: "尝试换一个关键词，或清空搜索查看全部")
        }
        switch filter {
        case .all:         return String(localized: "请稍后再试，或到设置中切换 API 版本")
        case .downloaded:  return String(localized: "从全部产品中选择并下载，完成后会在这里展示")
        case .downloading: return String(localized: "选择一款产品开始下载任务")
        case .failed:      return String(localized: "一切就绪，没有需要处理的任务")
        }
    }
}

private struct StatusChipStrip: View {
    @Binding var activeFilter: ProductFilter
    let counts: [ProductFilter: Int]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProductFilter.allCases) { filter in
                StatusChip(
                    filter: filter,
                    count: counts[filter] ?? 0,
                    isActive: filter == activeFilter,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeFilter = filter
                        }
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct StatusChip: View {
    let filter: ProductFilter
    let count: Int
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: filter.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(filter.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isActive ? filter.tint.opacity(0.25) : Color.secondary.opacity(0.12))
                        )
                }
            }
            .foregroundColor(isActive ? filter.tint : .primary.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? filter.tint.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isActive ? filter.tint.opacity(0.25) : Color.secondary.opacity(0.15),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ActiveDownloadsBanner: View {
    let tasks: [NewDownloadTask]
    let onTap: () -> Void

    private var activeTasks: [NewDownloadTask] {
        tasks.filter { $0.status.isActive }
    }

    private var totalSpeed: Double {
        activeTasks.reduce(0) { $0 + $1.totalSpeed }
    }

    private var remainingBytes: Int64 {
        activeTasks.reduce(0) { $0 + max($1.totalSize - $1.totalDownloadedSize, 0) }
    }

    var body: some View {
        if activeTasks.isEmpty {
            EmptyView()
        } else {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(activeTasks.count) 个下载任务进行中")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.9))

                        HStack(spacing: 6) {
                            if totalSpeed > 0 {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.down").font(.system(size: 9))
                                    Text(DownloadFormatters.speed(totalSpeed))
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                }
                                .foregroundColor(.blue.opacity(0.85))

                                if remainingBytes > 0 {
                                    let remaining = DownloadFormatters.remainingTime(
                                        total: remainingBytes,
                                        downloaded: 0,
                                        speed: totalSpeed
                                    )
                                    if !remaining.isEmpty {
                                        Text("·")
                                            .foregroundColor(.secondary.opacity(0.4))
                                        HStack(spacing: 2) {
                                            Image(systemName: "clock").font(.system(size: 9))
                                            Text("剩余 \(remaining)")
                                                .font(.system(size: 11))
                                                .monospacedDigit()
                                        }
                                        .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                Text("等待带宽…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.75))
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 3) {
                        Text("打开下载管理")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.blue.opacity(0.04)
                }
            )
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(.secondary.opacity(0.15)),
                alignment: .bottom
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct FeedLayout: View {
    let products: [UniqueProduct]
    let searchText: String
    fileprivate let activeFilter: ProductFilter

    var body: some View {
        GeometryReader { geo in
            let columns = GridMetrics.columns(for: geo.size.width)
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SectionHeaderView(title: sectionTitle, count: products.count)
                        .padding(.top, 4)

                    LazyVGrid(columns: columns, spacing: GridMetrics.spacing) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                            AppCardView(uniqueProduct: product)
                                .id(product.id)
                                .modifier(AppearAnimationModifier(delay: min(Double(index) * 0.02, 0.24)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FeedFooterView(count: products.count, searchText: searchText)
            }
        }
    }

    private var sectionTitle: String {
        if !searchText.isEmpty {
            return String(localized: "搜索结果")
        }
        switch activeFilter {
        case .all:         return String(localized: "全部产品")
        case .downloaded:  return String(localized: "已下载")
        case .downloading: return String(localized: "下载中")
        case .failed:      return String(localized: "失败任务")
        }
    }
}

private struct SectionHeaderView: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary.opacity(0.9))
            if let count = count {
                Text("· \(count)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.75))
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

private struct FeedFooterView: View {
    let count: Int
    let searchText: String

    @ObservedObject private var networkManager = globalNetworkManager

    private var activeDownloadCount: Int {
        networkManager.downloadTasks.reduce(0) { $0 + ($1.status.isActive ? 1 : 0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(footerText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if activeDownloadCount > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.4))
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                    Text("\(activeDownloadCount) 个任务进行中")
                        .font(.system(size: 12))
                }
                .foregroundColor(.blue.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(.windowBackgroundColor).opacity(0.3)
            }
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.secondary.opacity(0.15)),
            alignment: .top
        )
    }

    private var footerText: String {
        searchText.isEmpty
            ? String(localized: "共 \(count) 款产品")
            : String(localized: "搜索 \"\(searchText)\" 命中 \(count) 款产品")
    }
}

private struct LoadingSkeletonView: View {
    var body: some View {
        GeometryReader { geo in
            let columns = GridMetrics.columns(for: geo.size.width, spacing: 16)
            let skeletonCount = max(4, columns.count * 2)

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载产品列表")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 24)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<skeletonCount, id: \.self) { idx in
                            SkeletonCard(delay: Double(idx) * 0.08)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .opacity(0.75)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct SkeletonCard: View {
    let delay: Double
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 88, height: 88)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.14))
                .frame(height: 14)
                .frame(maxWidth: 160)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 10)
                .frame(maxWidth: 120)
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.16))
                .frame(height: 30)
        }
        .padding(14)
        .frame(height: 220)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.windowBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5)
        )
        .opacity(shimmer ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: shimmer)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                shimmer = true
            }
        }
    }
}

private struct LoadingFailedView: View {
    let error: Error
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.red.opacity(0.85))
            }
            VStack(spacing: 6) {
                Text("加载失败")
                    .font(.system(size: 16, weight: .semibold))
                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
                Text("提示：检查网络连接，或到设置中切换 API 版本")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button(action: onRetry) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct AppearAnimationModifier: ViewModifier {
    let delay: Double
    @State private var opacity: Double = 0

    init(delay: Double = 0) {
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                    opacity = 1
                }
            }
    }
}
