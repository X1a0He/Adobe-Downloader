//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import SwiftUI

enum InstallProgressOutcome: Equatable {
    case running
    case completed
    case failed
}

enum InstallProgressOperation: Equatable {
    case install
    case uninstall

    var actionName: String {
        switch self {
        case .install:
            return String(localized: "安装")
        case .uninstall:
            return String(localized: "卸载")
        }
    }

    var runningBadge: String {
        switch self {
        case .install:
            return String(localized: "安装中")
        case .uninstall:
            return String(localized: "卸载中")
        }
    }

    var completedBadge: String {
        switch self {
        case .install:
            return String(localized: "安装完成")
        case .uninstall:
            return String(localized: "卸载完成")
        }
    }

    var failedBadge: String {
        switch self {
        case .install:
            return String(localized: "安装失败")
        case .uninstall:
            return String(localized: "卸载失败")
        }
    }

    var completedStatusText: String {
        switch self {
        case .install:
            return String(localized: "安装已完成")
        case .uninstall:
            return String(localized: "卸载已完成")
        }
    }

    var phaseSectionTitle: String {
        switch self {
        case .install:
            return String(localized: "安装阶段")
        case .uninstall:
            return String(localized: "卸载阶段")
        }
    }

    var infoSectionTitle: String {
        switch self {
        case .install:
            return String(localized: "安装信息")
        case .uninstall:
            return String(localized: "卸载信息")
        }
    }

    var logPanelTitle: String {
        switch self {
        case .install:
            return String(localized: "安装日志")
        case .uninstall:
            return String(localized: "卸载日志")
        }
    }

    var emptyLogTitle: String {
        switch self {
        case .install:
            return String(localized: "暂无安装日志")
        case .uninstall:
            return String(localized: "暂无卸载日志")
        }
    }

    var emptyLogMessage: String {
        switch self {
        case .install:
            return String(localized: "安装进行后，这里会实时展示输出内容。")
        case .uninstall:
            return String(localized: "卸载进行后，这里会实时展示输出内容。")
        }
    }

    var copiedLogsMessage: String {
        switch self {
        case .install:
            return String(localized: "安装日志已复制到剪贴板")
        case .uninstall:
            return String(localized: "卸载日志已复制到剪贴板")
        }
    }

    var commandTitle: String {
        switch self {
        case .install:
            return String(localized: "安装命令")
        case .uninstall:
            return String(localized: "卸载命令")
        }
    }
}

enum InstallProgressPhase: Int, CaseIterable {
    case preparing
    case parsing
    case backingUp
    case extracting
    case installing
    case finishing

    var title: String {
        switch self {
        case .preparing:
            return String(localized: "准备")
        case .parsing:
            return String(localized: "解析")
        case .backingUp:
            return String(localized: "备份")
        case .extracting:
            return String(localized: "解压")
        case .installing:
            return String(localized: "安装")
        case .finishing:
            return String(localized: "收尾")
        }
    }

    func title(for operation: InstallProgressOperation) -> String {
        switch (self, operation) {
        case (.parsing, .uninstall):
            return String(localized: "分析")
        case (.installing, .uninstall):
            return String(localized: "卸载")
        default:
            return title
        }
    }

    var icon: String {
        switch self {
        case .preparing:
            return "wand.and.rays"
        case .parsing:
            return "doc.text.magnifyingglass"
        case .backingUp:
            return "externaldrive.badge.timemachine"
        case .extracting:
            return "shippingbox"
        case .installing:
            return "square.and.arrow.down"
        case .finishing:
            return "checkmark.seal"
        }
    }

    func icon(for operation: InstallProgressOperation) -> String {
        if operation == .uninstall, self == .installing {
            return "trash"
        }
        return icon
    }
}

struct InstallProgressViewData {
    let productName: String
    let progress: Double
    let status: String
    let logs: [String]
    let installCommand: String
    let errorDetails: String?
    let phase: InstallProgressPhase
    let outcome: InstallProgressOutcome
    let operation: InstallProgressOperation
    let currentPackageName: String?
    private let contextStatus: String

    init(
        productName: String,
        progress: Double,
        status: String,
        logs: [String],
        installCommand: String,
        errorDetails: String?,
        phase: InstallProgressPhase,
        outcome: InstallProgressOutcome,
        operation: InstallProgressOperation = .install,
        contextStatus: String? = nil
    ) {
        self.productName = productName
        self.progress = progress
        self.status = status
        self.logs = logs
        self.installCommand = installCommand
        self.errorDetails = errorDetails
        self.phase = phase
        self.outcome = outcome
        self.operation = operation
        self.contextStatus = contextStatus ?? status
        self.currentPackageName = InstallProgressTextParser.currentPackageName(from: self.contextStatus, logs: logs)
    }

    var normalizedProgress: Double {
        min(max(progress, 0), 1)
    }

    var isCompleted: Bool {
        outcome == .completed
    }

    var isFailed: Bool {
        outcome == .failed
    }

    var isRunning: Bool {
        outcome == .running
    }

    var summaryTitle: String {
        if isRunning {
            return operation == .uninstall ? statusTitle : productName
        }
        return statusTitle
    }

    var shouldShowCurrentPackage: Bool {
        guard currentPackageName != nil else {
            return false
        }
        return phase == .extracting || phase == .installing
    }

    var currentPhaseTitle: String {
        phase.title(for: operation)
    }

    var statusTitle: String {
        switch outcome {
        case .completed:
            switch operation {
            case .install:
                return String(format: String(localized: "%@ 安装完成"), productName)
            case .uninstall:
                return String(format: String(localized: "%@ 卸载完成"), productName)
            }
        case .failed:
            switch operation {
            case .install:
                return String(format: String(localized: "%@ 安装失败"), productName)
            case .uninstall:
                return String(format: String(localized: "%@ 卸载失败"), productName)
            }
        case .running:
            switch operation {
            case .install:
                return String(format: String(localized: "正在安装 %@"), productName)
            case .uninstall:
                return String(format: String(localized: "正在卸载 %@"), productName)
            }
        }
    }

    var statusIcon: String {
        switch outcome {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .running:
            return operation == .uninstall ? "trash.circle.fill" : "arrow.down.circle.fill"
        }
    }

    var statusColor: Color {
        switch outcome {
        case .completed:
            return .green
        case .failed:
            return .red
        case .running:
            return .blue
        }
    }

    var statusBadge: String {
        switch outcome {
        case .completed:
            return operation.completedBadge
        case .failed:
            return operation.failedBadge
        case .running:
            return "\(Int(normalizedProgress * 100))%"
        }
    }

    var phaseStatus: String {
        contextStatus
    }
}

enum InstallProgressTextParser {
    static func phase(from status: String, logs: [String], outcome: InstallProgressOutcome) -> InstallProgressPhase {
        let source = phaseSource(from: status, logs: logs, outcome: outcome)

        if outcome == .completed || source.contains("安装完成") || source.contains("卸载完成") || source.contains("Install completed") || source.contains("Uninstall completed") || source.contains("No packages need to be installed") {
            return .finishing
        }
        if source.contains("回滚") || source.contains("清理") || source.contains("rollback") || source.contains("clean") {
            return .finishing
        }
        if source.contains("正在安装") || source.contains("正在卸载") || source.contains("正在处理:") || source.contains("Installing ") || source.contains("Uninstalling ") || source.contains("Processing:") {
            return .installing
        }
        if source.contains("解压") || source.contains("Extracting ") {
            return .extracting
        }
        if source.contains("备份") || source.contains("Backing up ") {
            return .backingUp
        }
        if source.contains("解析 driver.xml") || source.contains("收集包信息") {
            return .parsing
        }
        if source.contains("分析 HDPIM 卸载") || source.contains("准备安装") || source.contains("准备卸载") || source.contains("重试安装") || source.contains("临时安装目录") || source.contains("Analyzing HDPIM uninstall") || source.contains("Preparing install") || source.contains("Preparing uninstall") || source.contains("Retrying install") || source.contains("temporary install") {
            return .preparing
        }
        return .preparing
    }

    static func currentPackageName(from status: String, logs: [String]) -> String? {
        if let packageName = extractPackageName(from: status) {
            return packageName
        }

        return logs.reversed().compactMap { extractPackageName(from: $0) }.first
    }

    private static func phaseSource(from status: String, logs: [String], outcome: InstallProgressOutcome) -> String {
        if hasPhaseKeyword(status) || outcome != .failed {
            return status
        }

        return logs.reversed().first(where: hasPhaseKeyword) ?? status
    }

    private static func hasPhaseKeyword(_ text: String) -> Bool {
        let keywords = ["准备安装", "准备卸载", "重试安装", "解析 driver.xml", "收集包信息", "分析 HDPIM 卸载", "备份", "解压", "正在安装", "正在卸载", "正在处理:", "清理", "回滚", "安装完成", "卸载完成", "Preparing install", "Preparing uninstall", "Retrying install", "Analyzing HDPIM uninstall", "Backing up", "Extracting", "Installing", "Uninstalling", "Processing:", "clean", "rollback", "Install completed", "Uninstall completed"]
        return keywords.contains { text.contains($0) }
    }

    private static func extractPackageName(from text: String) -> String? {
        if let packageName = extractSegment(after: "正在解压 ", in: text) {
            return packageName
        }

        if let packageName = extractSegment(after: "正在安装 ", in: text) {
            return packageName
        }

        if let packageName = extractSegment(after: "正在卸载 ", in: text) {
            return packageName
        }

        if let packageName = extractSegment(after: "Extracting ", in: text) {
            return packageName
        }

        if let packageName = extractSegment(after: "Installing ", in: text) {
            return packageName
        }

        if let packageName = extractSegment(after: "Uninstalling ", in: text) {
            return packageName
        }

        if text.hasPrefix("["),
           let endIndex = text.firstIndex(of: "]") {
            let startIndex = text.index(after: text.startIndex)
            let packageName = text[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return packageName.isEmpty ? nil : packageName
        }

        return nil
    }

    private static func extractSegment(after prefix: String, in text: String) -> String? {
        guard let range = text.range(of: prefix) else {
            return nil
        }

        let source = String(text[range.upperBound...])
        let separators = ["...", "…", "(", "（", ":", "：", "，", "。"]
        let endIndex = separators
            .compactMap { source.range(of: $0)?.lowerBound }
            .min() ?? source.endIndex
        let value = source[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private enum InstallProgressPanel: String, CaseIterable {
    case overview = "进度详情"
    case logs = "安装日志"

    func title(for operation: InstallProgressOperation) -> String {
        switch self {
        case .overview:
            return rawValue
        case .logs:
            return operation.logPanelTitle
        }
    }
}

struct InstallProgressView: View {
    let data: InstallProgressViewData
    let onCancel: () -> Void
    let onRetry: (() -> Void)?

    @State private var selectedPanel: InstallProgressPanel
    @State private var lastOutcome: InstallProgressOutcome
    @State private var scrollViewportHeight: CGFloat = 0

    init(
        data: InstallProgressViewData,
        onCancel: @escaping () -> Void,
        onRetry: (() -> Void)? = nil
    ) {
        self.data = data
        self.onCancel = onCancel
        self.onRetry = onRetry
        let defaultPanel: InstallProgressPanel = data.outcome == .failed ? .logs : .overview
        _selectedPanel = State(initialValue: defaultPanel)
        _lastOutcome = State(initialValue: data.outcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    InstallSummarySection(data: data)

                    InstallPhaseSection(data: data)

                    if let currentPackageName = data.currentPackageName,
                       data.shouldShowCurrentPackage,
                       !data.isCompleted {
                        CurrentPackageSection(packageName: currentPackageName, phase: data.phase, operation: data.operation)
                    }

                    VStack(spacing: 14) {
                        Picker("", selection: $selectedPanel) {
                            ForEach(InstallProgressPanel.allCases, id: \.self) { panel in
                                Text(panel.title(for: data.operation))
                                    .tag(panel)
                            }
                        }
                        .pickerStyle(.segmented)

                        Group {
                            switch selectedPanel {
                            case .overview:
                                InstallOverviewPanel(data: data)
                            case .logs:
                                InstallLogPanel(data: data)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, minHeight: scrollViewportHeight, alignment: .top)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { scrollViewportHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { newValue in
                            scrollViewportHeight = newValue
                        }
                }
            )

            Divider()

            InstallActionSection(
                data: data,
                onCancel: onCancel,
                onRetry: onRetry
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: data.outcome) { newValue in
            guard newValue != lastOutcome else {
                return
            }
            selectedPanel = newValue == .failed ? .logs : .overview
            lastOutcome = newValue
        }
    }
}

private struct InstallSummarySection: View {
    let data: InstallProgressViewData

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(data.statusColor.opacity(0.12))
                    .frame(width: 50, height: 50)

                Image(systemName: data.statusIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(data.statusColor)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text(data.summaryTitle)
                        .font(.system(size: 20, weight: .semibold))

                    Spacer()

                    if data.isRunning {
                        Text(data.operation.runningBadge)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    } else if data.isCompleted || data.isFailed {
                        Text(data.statusBadge)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(data.statusColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(data.statusColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if !data.isRunning {
                    Text(data.status)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                if !data.isFailed {
                    ProgressSection(
                        progress: data.normalizedProgress,
                        progressText: data.outcome == .running ? data.statusBadge : nil,
                        tintColor: data.statusColor
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ProgressSection: View {
    let progress: Double
    let progressText: String?
    let tintColor: Color

    var body: some View {
        VStack(spacing: 8) {
            if let progressText {
                HStack {
                    Spacer()

                    Text(progressText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [tintColor.opacity(0.55), tintColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: CGFloat(max(0, progress)) * geometry.size.width, height: 8)
                        .animation(.linear(duration: 0.25), value: progress)
                }
            }
            .frame(height: 8)
        }
    }
}

private struct InstallPhaseSection: View {
    let data: InstallProgressViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label(data.operation.phaseSectionTitle, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Text(data.currentPhaseTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(data.statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(data.statusColor.opacity(0.1))
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                ForEach(InstallProgressPhase.allCases, id: \.self) { phase in
                    InstallPhaseItem(
                        phase: phase,
                        operation: data.operation,
                        state: phaseState(for: phase)
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func phaseState(for phase: InstallProgressPhase) -> InstallPhaseItemState {
        switch data.outcome {
        case .completed:
            return .completed
        case .failed:
            if phase.rawValue < data.phase.rawValue {
                return .completed
            }
            if phase == data.phase {
                return .failed
            }
            return .pending
        case .running:
            if phase.rawValue < data.phase.rawValue {
                return .completed
            }
            if phase == data.phase {
                return .current
            }
            return .pending
        }
    }
}

private enum InstallPhaseItemState {
    case completed
    case current
    case pending
    case failed

    var backgroundColor: Color {
        switch self {
        case .completed:
            return .green.opacity(0.14)
        case .current:
            return .blue.opacity(0.14)
        case .pending:
            return Color.secondary.opacity(0.08)
        case .failed:
            return .red.opacity(0.14)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .completed:
            return .green
        case .current:
            return .blue
        case .pending:
            return .secondary
        case .failed:
            return .red
        }
    }

    var borderColor: Color {
        switch self {
        case .completed:
            return .green.opacity(0.18)
        case .current:
            return .blue.opacity(0.18)
        case .pending:
            return .secondary.opacity(0.12)
        case .failed:
            return .red.opacity(0.18)
        }
    }
}

private struct InstallPhaseItem: View {
    let phase: InstallProgressPhase
    let operation: InstallProgressOperation
    let state: InstallPhaseItemState

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(state.backgroundColor)

                VStack(spacing: 6) {
                    Image(systemName: phase.icon(for: operation))
                        .font(.system(size: 14, weight: .semibold))

                    Text(phase.title(for: operation))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                .foregroundColor(state.foregroundColor)
                .padding(.horizontal, 8)
            }
            .frame(height: 62)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(state.borderColor, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CurrentPackageSection: View {
    let packageName: String
    let phase: InstallProgressPhase
    let operation: InstallProgressOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .foregroundColor(.blue)

            Text("当前包")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(packageName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(phase.title(for: operation))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct InstallOverviewPanel: View {
    let data: InstallProgressViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BeautifulGroupBox(label: {
                Label(data.operation.infoSectionTitle, systemImage: "info.circle")
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    InstallInfoRow(title: "当前阶段", value: data.currentPhaseTitle)

                    if data.isRunning {
                        InstallInfoRow(title: "当前状态", value: data.phaseStatus)
                    }

                    if data.shouldShowCurrentPackage,
                       let currentPackageName = data.currentPackageName {
                        InstallInfoRow(title: "当前包", value: currentPackageName)
                    }

                    if data.isCompleted {
                        InstallInfoRow(title: "状态", value: data.operation.completedStatusText)
                    } else if data.isFailed {
                        InstallInfoRow(title: "最后状态", value: data.phaseStatus)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if data.isFailed {
                BeautifulGroupBox(label: {
                    Label("错误摘要", systemImage: "exclamationmark.triangle.fill")
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(data.status)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        if let errorDetails = data.errorDetails, !errorDetails.isEmpty {
                            Text(errorDetails)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.red.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InstallInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct InstallLogPanel: View {
    let data: InstallProgressViewData

    @State private var showCopiedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorDetails = data.errorDetails, !errorDetails.isEmpty {
                BeautifulGroupBox(label: {
                    Label("错误详情", systemImage: "exclamationmark.triangle.fill")
                }) {
                    Text(errorDetails)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(data.operation.logPanelTitle, systemImage: "text.alignleft")
                        .font(.system(size: 13, weight: .semibold))

                    Text("(\(data.logs.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: copyLogs) {
                        Label("复制日志", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                    .disabled(data.logs.isEmpty)
                }

                if data.logs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.page")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.6))

                        Text(data.operation.emptyLogTitle)
                            .font(.system(size: 13, weight: .medium))

                        Text(data.operation.emptyLogMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(data.logs.enumerated()), id: \.offset) { index, line in
                                    Text(installLogDisplayText(line))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(index)
                                }
                            }
                            .padding(12)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(NSColor.textBackgroundColor).opacity(0.52))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                        .onAppear {
                            if let lastIndex = data.logs.indices.last {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                        .onChange(of: data.logs.count) { _ in
                            if let lastIndex = data.logs.indices.last {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }

                if showCopiedAlert {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(data.operation.copiedLogsMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copyLogs() {
        copyText(data.logs.joined(separator: "\n"))
        showCopiedAlert = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedAlert = false
        }
    }
}

private struct InstallActionSection: View {
    let data: InstallProgressViewData
    let onCancel: () -> Void
    let onRetry: (() -> Void)?

    @State private var copiedMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            if data.isFailed {
                Button(action: copyErrorDetails) {
                    Label("复制错误", systemImage: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .orange))

                Button(action: copyLogs) {
                    Label("复制日志", systemImage: "text.append")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                .disabled(data.logs.isEmpty)

                if let onRetry = onRetry {
                    Button(action: onRetry) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                }

                Button(action: onCancel) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .red))
            } else if data.isCompleted {
                Button(action: onCancel) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .green))
            } else {
                Button(action: onCancel) {
                    Label("取消", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .red))
                .disabled(data.status.contains("回滚") || data.logs.last?.contains("回滚") == true)
            }

            Spacer()

            if let copiedMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(copiedMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
            }
        }
    }

    private func copyErrorDetails() {
        let content = data.errorDetails?.isEmpty == false ? data.errorDetails! : data.status
        copyText(content)
        showCopiedMessage("错误详情已复制到剪贴板")
    }

    private func copyLogs() {
        copyText(data.logs.joined(separator: "\n"))
        showCopiedMessage(data.operation.copiedLogsMessage)
    }

    private func showCopiedMessage(_ message: String) {
        copiedMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedMessage = nil
        }
    }
}

private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func installLogDisplayText(_ line: String) -> String {
    let prefixes = [
        "[HDPIM Pipeline] ",
        "[HDPIM InstallHelper] ",
        "[HDPIM Install] ",
        "[HDPIM Backup] "
    ]

    for prefix in prefixes where line.hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count))
    }

    return line
}

#Preview("安装中") {
    InstallProgressView(
        data: InstallProgressViewData(
            productName: "Adobe Photoshop",
            progress: 0.45,
            status: "正在安装核心组件...",
            logs: [
                "[HDPIM Pipeline] driver.xml 解析成功",
                "[HDPIM Pipeline] 开始解压 CorePackage"
            ],
            installCommand: "",
            errorDetails: nil,
            phase: .installing,
            outcome: .running
        ),
        onCancel: {},
        onRetry: nil
    )
}

#Preview("安装失败") {
    InstallProgressView(
        data: InstallProgressViewData(
            productName: "Adobe Photoshop",
            progress: 0.62,
            status: "安装失败: 核心组件安装异常",
            logs: [
                "[HDPIM Pipeline] 开始解压 CorePackage",
                "[HDPIM Pipeline] 正在安装 CorePackage"
            ],
            installCommand: "HDPIM Engine (内置安装引擎，无需外部命令)",
            errorDetails: "CorePackage: file copy failed",
            phase: .installing,
            outcome: .failed,
            contextStatus: "正在安装 CorePackage..."
        ),
        onCancel: {},
        onRetry: {}
    )
}

#Preview("安装完成") {
    InstallProgressView(
        data: InstallProgressViewData(
            productName: "Adobe Photoshop",
            progress: 1.0,
            status: "安装完成",
            logs: [
                "[HDPIM Pipeline] 正在清理临时文件",
                "[HDPIM Pipeline] 安装完成"
            ],
            installCommand: "",
            errorDetails: nil,
            phase: .finishing,
            outcome: .completed
        ),
        onCancel: {},
        onRetry: nil
    )
}

#Preview("在深色模式下") {
    InstallProgressView(
        data: InstallProgressViewData(
            productName: "Adobe Photoshop",
            progress: 0.75,
            status: "正在解压 CameraRawPackage (3/6)... 72%",
            logs: [
                "[HDPIM Pipeline] 解压完成 CorePackage",
                "[HDPIM Pipeline] 开始解压 CameraRawPackage"
            ],
            installCommand: "",
            errorDetails: nil,
            phase: .extracting,
            outcome: .running
        ),
        onCancel: {},
        onRetry: nil
    )
    .preferredColorScheme(.dark)
}
