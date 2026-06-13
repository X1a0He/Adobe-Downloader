//
//  CleanupView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

private extension CleanupOption {
    var icon: String {
        switch self {
        case .adobeApps:           return "app.badge.fill"
        case .adobeCreativeCloud:  return "cloud.fill"
        case .adobeUserData:       return "person.crop.circle.fill"
        case .adobePreferences:    return "slider.horizontal.3"
        case .adobeCaches:         return "internaldrive.fill"
        case .adobeLicenses:       return "key.fill"
        case .adobeLogs:           return "doc.text.fill"
        case .adobeServices:       return "gearshape.2.fill"
        case .adobeKeychain:       return "lock.fill"
        case .adobeGenuineService: return "checkmark.seal.fill"
        case .adobeHosts:          return "network"
        case .c4dRedGiant:         return "cube.box.fill"
        }
    }

    var tint: Color {
        switch self {
        case .adobeApps:           return .red
        case .adobeCreativeCloud:  return .blue
        case .adobeUserData:       return .mint
        case .adobePreferences:    return .orange
        case .adobeCaches:         return .teal
        case .adobeLicenses:       return .yellow
        case .adobeLogs:           return .gray
        case .adobeServices:       return .purple
        case .adobeKeychain:       return .indigo
        case .adobeGenuineService: return .green
        case .adobeHosts:          return .cyan
        case .c4dRedGiant:         return .pink
        }
    }
}

@MainActor
final class CleanupViewModel: ObservableObject {
    @Published var showConfirmation = false
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var selectedOptions = Set<CleanupOption>()
    @Published var isProcessing = false
    @Published var cleanupLogs: [CleanupLog] = []
    @Published var currentCommandIndex = 0
    @Published var totalCommands = 0
    @Published var expandedOptions = Set<CleanupOption>()
    @Published var isCancelled = false
    @Published var isLogExpanded = false
    @Published var estimatedCleanupSize: Int64 = 0
    @Published var releasedCleanupSize: Int64 = 0
    @Published var isPreparingPlan = false
    @Published var prepareProgress = 0.0
    @Published var prepareMessage = ""
    @Published var showFullDiskAccessAlert = false
    #if DEBUG
    @Published var showDebugPlanConfirmation = false
    @Published var debugPlanItems: [CleanupPlanItem] = []
    @Published var debugPlanEstimatedSize: Int64 = 0
    #endif

    private let planner = CleanupPlanner()
    private var cleanupPlan: CleanupPlan?
    private var planItems: [CleanupPlanItem] = []
    private var previewItemsByOption: [CleanupOption: [CleanupPlanItem]] = [:]
    private let errorLogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var hasErrorLogs: Bool {
        cleanupLogs.contains { $0.status == .error }
    }

    func previewItems(for option: CleanupOption) -> [CleanupPlanItem] {
        #if DEBUG
        if previewItemsByOption[option] == nil {
            previewItemsByOption[option] = planner.makePlan(for: [option]).items
        }
        return previewItemsByOption[option] ?? []
        #else
        return []
        #endif
    }

    func prepareCleanup() {
        prepareCleanup(ignoreFullDiskAccessWarning: false)
    }

    func continueCleanupWithoutFullDiskAccess() {
        prepareCleanup(ignoreFullDiskAccessWarning: true)
    }

    private func prepareCleanup(ignoreFullDiskAccessWarning: Bool) {
        guard !selectedOptions.isEmpty else { return }

        if !ignoreFullDiskAccessWarning,
           requiresFullDiskAccess(options: selectedOptions),
           !FullDiskAccessPermission.isGranted {
            showFullDiskAccessAlert = true
            return
        }

        let options = selectedOptions
        isPreparingPlan = true
        prepareProgress = 0
        prepareMessage = String(localized: "正在生成清理计划…")

        Task.detached(priority: .userInitiated) { [planner] in
            let plan = planner.makePlan(for: options) { progress in
                Task { @MainActor in
                    self.prepareProgress = progress.fraction
                    self.prepareMessage = progress.message
                }
            }

            await MainActor.run {
                self.isPreparingPlan = false
                self.prepareProgress = 1
                self.prepareMessage = String(localized: "清理计划生成完成")
                #if DEBUG
                self.cleanupPlan = plan
                self.planItems = plan.items
                self.estimatedCleanupSize = plan.estimatedBytes
                self.totalCommands = plan.items.count
                self.debugPlanItems = plan.items
                self.debugPlanEstimatedSize = plan.estimatedBytes
                self.showDebugPlanConfirmation = true
                #else
                self.startCleanup(with: plan)
                #endif
            }
        }
    }

    func startCleanup() {
        if let cleanupPlan {
            startCleanup(with: cleanupPlan)
        } else {
            startCleanup(with: planner.makePlan(for: selectedOptions))
        }
    }

    func selectDefaultOptions() {
        selectedOptions = Set(CleanupOption.defaultSelectedOptions)
    }

    private func startCleanup(with plan: CleanupPlan) {
        isProcessing = true
        cleanupLogs.removeAll()
        currentCommandIndex = 0
        isCancelled = false
        releasedCleanupSize = 0

        cleanupPlan = plan
        planItems = plan.items
        estimatedCleanupSize = plan.estimatedBytes
        totalCommands = planItems.count

        #if DEBUG
        cleanupLogs.append(CleanupLog(
            timestamp: Date(),
            command: "[Cleanup][Context] userHome=\(plan.context.userHome) uid=\(plan.context.userUID) loginKeychain=\(plan.context.loginKeychain)",
            status: .success,
            message: String(localized: "清理计划已生成")
        ))
        #endif

        guard !planItems.isEmpty else {
            finishCleanup(message: String(localized: "未发现可清理项目"))
            return
        }

        executeNextCommand()
    }

    func cancelCleanup() {
        isCancelled = true
    }

    private func finishCleanup(message: String) {
        if let cleanupPlan {
            releasedCleanupSize = planner.releasedSpace(from: cleanupPlan)
        }
        isProcessing = false
        let estimatedText = ByteCountFormatter.string(fromByteCount: estimatedCleanupSize, countStyle: .file)
        let releasedText = ByteCountFormatter.string(fromByteCount: releasedCleanupSize, countStyle: .file)
        if estimatedCleanupSize > 0 || releasedCleanupSize > 0 {
            alertMessage = "\(message)\n预计可清理：\(estimatedText)\n实际释放：\(releasedText)"
        } else {
            alertMessage = message
        }
        refreshPreviewItems()
        showAlert = true
        selectedOptions.removeAll()
    }

    private func executeNextCommand() {
        guard currentCommandIndex < planItems.count else {
            DispatchQueue.main.async {
                self.finishCleanup(message: self.isCancelled ? String(localized: "清理已取消") : String(localized: "清理完成"))
            }
            return
        }

        if isCancelled {
            DispatchQueue.main.async { self.finishCleanup(message: String(localized: "清理已取消")) }
            return
        }

        let item = planItems[currentCommandIndex]
        let runningLog = CleanupLog(
            timestamp: Date(),
            command: item.debugSummary,
            status: .running,
            message: item.title
        )
        cleanupLogs.append(runningLog)

        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global())
        timeoutTimer.schedule(deadline: .now() + 30)
        timeoutTimer.setEventHandler { [weak self] in
            guard let self else { return }
            if let index = self.cleanupLogs.lastIndex(where: { $0.id == runningLog.id }) {
                DispatchQueue.main.async {
                    self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: item.debugSummary, status: .error, message: self.failureMessage(for: item, output: String(localized: "执行超时")))
                    self.currentCommandIndex += 1
                    self.executeNextCommand()
                }
            }
        }
        timeoutTimer.resume()

        PrivilegedHelperAdapter.shared.executeCommand(item.command) { [weak self] (output: String) in
            timeoutTimer.cancel()
            guard let self else { return }
            DispatchQueue.main.async {
                if let index = self.cleanupLogs.lastIndex(where: { $0.id == runningLog.id }) {
                    if self.isCancelled {
                        self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: item.debugSummary, status: .cancelled, message: String(localized: "已取消"))
                    } else {
                        let isSuccess = self.isExecutionSuccess(output)
                        let message = isSuccess ? String(localized: "执行成功") : self.failureMessage(for: item, output: output)
                        self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: item.debugSummary, status: isSuccess ? .success : .error, message: message)
                    }
                }
                self.currentCommandIndex += 1
                self.executeNextCommand()
            }
        }
    }

    private func refreshPreviewItems() {
        previewItemsByOption.removeAll()
    }

    private func requiresFullDiskAccess(options: Set<CleanupOption>) -> Bool {
        !options.isDisjoint(with: Set([
            .adobeApps,
            .adobeCreativeCloud,
            .adobeUserData,
            .adobePreferences,
            .adobeLicenses
        ]))
    }

    func copyErrorLogs() {
        let errorLogs = cleanupLogs.filter { $0.status == .error }
        guard !errorLogs.isEmpty else { return }

        let content = errorLogs.enumerated().map { index, log in
            [
                "==== Error \(index + 1) ====",
                "Time: \(errorLogDateFormatter.string(from: log.timestamp))",
                "Command: \(log.command)",
                "Message: \(log.message)"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func failureMessage(for item: CleanupPlanItem, output: String) -> String {
        #if DEBUG
        return String(localized: "执行结果：\(output)\n执行命令：\(item.command)")
        #else
        let title = CleanupLog.getCleanupDescription(for: item.debugSummary)
        return String(localized: "执行失败：\(title)\n执行结果：\(output)\n执行命令：\(item.command)")
        #endif
    }

    private func isExecutionSuccess(_ output: String) -> Bool {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        guard normalized.lowercased() != "success" else { return true }
        return !normalized.lowercased().hasPrefix("error:")
    }
}

struct CleanupView: View {
    @ObservedObject var viewModel: CleanupViewModel

    init() {
        self.viewModel = CleanupViewModel()
    }

    init(viewModel: CleanupViewModel) {
        self.viewModel = viewModel
    }

    private var percentage: Int {
        viewModel.totalCommands > 0
            ? Int((Double(viewModel.currentCommandIndex) / Double(viewModel.totalCommands)) * 100)
            : 0
    }

    private func progressWidth(for totalWidth: CGFloat) -> CGFloat {
        guard viewModel.totalCommands > 0 else { return 0 }
        return totalWidth * CGFloat(min(1.0, max(0.0, Double(viewModel.currentCommandIndex) / Double(viewModel.totalCommands))))
    }

    private func prepareProgressWidth(for totalWidth: CGFloat) -> CGFloat {
        totalWidth * CGFloat(min(1.0, max(0.04, viewModel.prepareProgress)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            optionsSection
            if viewModel.isPreparingPlan { preparePlanSection }
            if viewModel.isProcessing { progressSection }
            logSection
            actionBar
        }
        .alert("确认清理", isPresented: $viewModel.showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) { viewModel.prepareCleanup() }
        } message: {
            Text("这将删除所选的 Adobe 相关文件，该操作不可撤销。清理过程不会影响 Adobe Downloader 的文件和下载数据。是否继续？")
        }
        .alert("需要全磁盘访问权限", isPresented: $viewModel.showFullDiskAccessAlert) {
            Button("打开设置") {
                FullDiskAccessPermission.openSettings()
            }
            Button("继续清理", role: .destructive) {
                viewModel.continueCleanupWithoutFullDiskAccess()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("未授权时，Containers、Group Containers、Documents 等用户受保护目录可能清理失败。请将 Adobe Downloader 与 Helper 加入全磁盘访问，授权后重新启动 Adobe Downloader 或重新启用 Helper。")
        }
        #if DEBUG
        .sheet(isPresented: $viewModel.showDebugPlanConfirmation) {
            DebugCleanupPlanSheet(
                items: viewModel.debugPlanItems,
                estimatedBytes: viewModel.debugPlanEstimatedSize,
                onCancel: {
                    viewModel.showDebugPlanConfirmation = false
                },
                onConfirm: {
                    viewModel.showDebugPlanConfirmation = false
                    viewModel.startCleanup()
                }
            )
        }
        #endif
        .alert(isPresented: $viewModel.showAlert) {
            Alert(title: Text("清理结果"), message: Text(viewModel.alertMessage), dismissButton: .default(Text("确定")))
        }
    }

    private var preparePlanSection: some View {
        SettingSection(String(localized: "生成清理计划")) {
            VStack(spacing: 0) {
                SettingRow(title: String(localized: "正在扫描残留"), icon: "magnifyingglass", iconTint: .blue) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                        Text("\(Int(viewModel.prepareProgress * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue)
                            .monospacedDigit()
                    }
                }

                SettingRowDivider()

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(height: 8)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.65), Color.blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: prepareProgressWidth(for: geo.size.width), height: 8)
                    }
                }
                .frame(height: 8)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.linear(duration: 0.2), value: viewModel.prepareProgress)

                SettingRowDivider()

                HStack {
                    Text(viewModel.prepareMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var optionsSection: some View {
        SettingSection(
            String(localized: "选择清理内容"),
            footer: String(localized: "清理过程不会影响 Adobe Downloader 的文件和下载数据")
        ) {
            ForEach(Array(CleanupOption.allCases.enumerated()), id: \.element.id) { index, option in
                CleanupOptionRow(
                    option: option,
                    isProcessing: viewModel.isProcessing || viewModel.isPreparingPlan,
                    previewItems: viewModel.expandedOptions.contains(option) ? viewModel.previewItems(for: option) : [],
                    selectedOptions: $viewModel.selectedOptions,
                    expandedOptions: $viewModel.expandedOptions
                )
                if index < CleanupOption.allCases.count - 1 {
                    SettingRowDivider()
                }
            }
        }
    }

    private var progressSection: some View {
        SettingSection(String(localized: "清理进度")) {
            VStack(spacing: 0) {
                SettingRow(title: String(localized: "当前进度"), icon: "arrow.triangle.2.circlepath", iconTint: .blue) {
                    HStack(spacing: 8) {
                        Text("\(viewModel.currentCommandIndex)/\(viewModel.totalCommands)")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(.secondary)
                        Text("\(percentage)%")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.blue).monospacedDigit()
                    }
                }

                SettingRowDivider()

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(height: 8)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.7), Color.blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: progressWidth(for: geo.size.width), height: 8)
                    }
                }
                .frame(height: 8)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .animation(.linear(duration: 0.3), value: viewModel.currentCommandIndex)

                if let lastLog = viewModel.cleanupLogs.last {
                    SettingRowDivider()
                    CurrentLogView(lastLog: lastLog).padding(.horizontal, 12).padding(.vertical, 8)
                }

                SettingRowDivider()

                HStack {
                    Spacer()
                    Button(action: { viewModel.cancelCleanup() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle").font(.system(size: 10))
                            Text("取消清理").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.red))
                    .disabled(viewModel.isCancelled)
                    .opacity(viewModel.isCancelled ? 0.5 : 1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
    }

    private var logSection: some View {
        SettingSection(String(localized: "执行日志")) {
            VStack(spacing: 0) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.isLogExpanded.toggle() } }) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).fill(Color.indigo.opacity(0.14)).frame(width: 22, height: 22)
                            Image(systemName: "terminal.fill").font(.system(size: 11, weight: .medium)).foregroundColor(.indigo)
                        }
                        Text("最近日志").font(.system(size: 13)).foregroundColor(.primary.opacity(0.9))
                        if viewModel.isPreparingPlan {
                            SettingsStatusChip(icon: "circle.fill", text: String(localized: "生成中"), tint: .blue)
                        }
                        if viewModel.isProcessing {
                            SettingsStatusChip(icon: "circle.fill", text: String(localized: "执行中"), tint: .green)
                        }
                        Spacer()
                        Text(viewModel.isLogExpanded ? String(localized: "收起") : String(localized: "展开"))
                            .font(.system(size: 11)).foregroundColor(.blue)
                        Image(systemName: viewModel.isLogExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if viewModel.hasErrorLogs {
                    SettingRowDivider()

                    HStack {
                        Spacer()
                        Button(action: { viewModel.copyErrorLogs() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("复制全部错误日志")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.white)
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: Color.red))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }

                ScrollView {
                    if viewModel.cleanupLogs.isEmpty {
                        EmptyLogView()
                    } else {
                        LogContentView(logs: viewModel.cleanupLogs, isExpanded: viewModel.isLogExpanded)
                    }
                }
                .frame(height: viewModel.cleanupLogs.isEmpty ? 80 : (viewModel.isLogExpanded ? 220 : 54))
                .animation(.easeInOut(duration: 0.2), value: viewModel.isLogExpanded)
                .background(Color(NSColor.textBackgroundColor).opacity(0.55))
                .clipShape(
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 0)
                )
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.selectDefaultOptions() }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.square").font(.system(size: 10))
                    Text("全选").font(.system(size: 12))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
            .disabled(viewModel.isProcessing || viewModel.isPreparingPlan)

            Button(action: { viewModel.selectedOptions.removeAll() }) {
                HStack(spacing: 4) {
                    Image(systemName: "square").font(.system(size: 10))
                    Text("取消全选").font(.system(size: 12))
                }
                .foregroundColor(.primary.opacity(0.85))
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.secondary.opacity(0.2)))
            .disabled(viewModel.isProcessing || viewModel.isPreparingPlan)

            #if DEBUG
            Button(action: {
                if viewModel.expandedOptions.count == CleanupOption.allCases.count {
                    viewModel.expandedOptions.removeAll()
                } else {
                    viewModel.expandedOptions = Set(CleanupOption.allCases)
                }
            }) {
                Text(viewModel.expandedOptions.count == CleanupOption.allCases.count
                     ? String(localized: "折叠全部") : String(localized: "展开全部"))
                    .font(.system(size: 12)).foregroundColor(.white)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.purple))
            .disabled(viewModel.isProcessing || viewModel.isPreparingPlan)
            #endif

            Spacer()

            Button(action: { if !viewModel.selectedOptions.isEmpty { viewModel.showConfirmation = true } }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash.fill").font(.system(size: 10))
                    Text("开始清理").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.red))
            .disabled(viewModel.selectedOptions.isEmpty || viewModel.isProcessing || viewModel.isPreparingPlan)
            .opacity(viewModel.selectedOptions.isEmpty || viewModel.isProcessing || viewModel.isPreparingPlan ? 0.5 : 1)
        }
    }
}

#if DEBUG
private struct DebugCleanupPlanSheet: View {
    let items: [CleanupPlanItem]
    let estimatedBytes: Int64
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var estimatedText: String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("确认清理计划")
                        .font(.system(size: 16, weight: .semibold))
                    Text("将执行 \(items.count) 项，预计可清理 \(estimatedText)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("未扫描到当前存在的路径；动态命令会在执行时处理。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(item.resolvedTarget)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                Text(item.command)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.85))
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 280, maxHeight: 420)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("确认清理", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 760)
    }
}
#endif

private struct CleanupOptionRow: View {
    let option: CleanupOption
    let isProcessing: Bool
    let previewItems: [CleanupPlanItem]
    @Binding var selectedOptions: Set<CleanupOption>
    @Binding var expandedOptions: Set<CleanupOption>

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: option.localizedName, subtitle: option.description, icon: option.icon, iconTint: option.tint) {
                HStack(spacing: 8) {
                    #if DEBUG
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedOptions.contains(option) { expandedOptions.remove(option) }
                            else { expandedOptions.insert(option) }
                        }
                    }) {
                        Image(systemName: expandedOptions.contains(option) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain).disabled(isProcessing)
                    #endif

                    Toggle("", isOn: Binding(
                        get: { selectedOptions.contains(option) },
                        set: { if $0 { selectedOptions.insert(option) } else { selectedOptions.remove(option) } }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: option.tint))
                    .controlSize(.small).labelsHidden().disabled(isProcessing)
                }
            }

            #if DEBUG
            if expandedOptions.contains(option) {
                CommandListView(option: option, previewItems: previewItems)
            }
            #endif
        }
    }
}

struct CommandListView: View {
    let option: CleanupOption
    let previewItems: [CleanupPlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将执行的清理计划：")
                .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .padding(.top, 2).padding(.horizontal, 12)

            LazyVStack(spacing: 6) {
                ForEach(previewItems) { item in
                    Text(item.debugSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(6)
                }
                if previewItems.isEmpty {
                    Text("未扫描到当前存在的路径；动态命令会在执行时处理。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct CurrentLogView: View {
    let lastLog: CleanupLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .foregroundColor(.blue.opacity(0.8)).font(.system(size: 14))
                Text("当前执行：").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            }

            Group {
                #if DEBUG
                Text(lastLog.command)
                #else
                Text(CleanupLog.getCleanupDescription(for: lastLog.command))
                #endif
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
            .lineLimit(2).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 70)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

struct EmptyLogView: View {
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 20)).foregroundColor(.secondary.opacity(0.6))
                Text("暂无清理记录").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }
}

struct LogContentView: View {
    let logs: [CleanupLog]
    let isExpanded: Bool

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 8) {
                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(logs.reversed()) { log in
                            LogEntryView(log: log).id(log.id)
                        }
                    }
                } else if let lastLog = logs.last {
                    LogEntryView(log: lastLog).id(lastLog.id)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 2)
            .onChange(of: logs.count) { _ in
                if let lastLog = logs.last {
                    withAnimation { scrollProxy.scrollTo(lastLog.id, anchor: .bottom) }
                }
            }
        }
    }
}
