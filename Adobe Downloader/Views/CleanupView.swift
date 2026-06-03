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
        case .adobePreferences:    return "slider.horizontal.3"
        case .adobeCaches:         return "internaldrive.fill"
        case .adobeLicenses:       return "key.fill"
        case .adobeLogs:           return "doc.text.fill"
        case .adobeServices:       return "gearshape.2.fill"
        case .adobeKeychain:       return "lock.fill"
        case .adobeGenuineService: return "checkmark.seal.fill"
        case .adobeHosts:          return "network"
        }
    }

    var tint: Color {
        switch self {
        case .adobeApps:           return .red
        case .adobeCreativeCloud:  return .blue
        case .adobePreferences:    return .orange
        case .adobeCaches:         return .teal
        case .adobeLicenses:       return .yellow
        case .adobeLogs:           return .gray
        case .adobeServices:       return .purple
        case .adobeKeychain:       return .indigo
        case .adobeGenuineService: return .green
        case .adobeHosts:          return .cyan
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

    private var commands: [String] = []

    func startCleanup() {
        isProcessing = true
        cleanupLogs.removeAll()
        currentCommandIndex = 0
        isCancelled = false

        let userHome = NSHomeDirectory()
        var collected: [String] = []
        for option in selectedOptions {
            let userCommands = option.commands.map { $0.replacingOccurrences(of: "~/", with: "\(userHome)/") }
            collected.append(contentsOf: userCommands)
        }
        commands = collected
        totalCommands = commands.count
        executeNextCommand()
    }

    func cancelCleanup() {
        isCancelled = true
    }

    private func finishCleanup(message: String) {
        isProcessing = false
        alertMessage = message
        showAlert = true
        selectedOptions.removeAll()
    }

    private func executeNextCommand() {
        guard currentCommandIndex < commands.count else {
            DispatchQueue.main.async {
                self.finishCleanup(message: self.isCancelled ? String(localized: "清理已取消") : String(localized: "清理完成"))
            }
            return
        }

        if isCancelled {
            DispatchQueue.main.async { self.finishCleanup(message: String(localized: "清理已取消")) }
            return
        }

        let command = commands[currentCommandIndex]
        cleanupLogs.append(CleanupLog(timestamp: Date(), command: command, status: .running, message: String(localized: "正在执行...")))

        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global())
        timeoutTimer.schedule(deadline: .now() + 30)
        timeoutTimer.setEventHandler { [weak self] in
            guard let self else { return }
            if let index = self.cleanupLogs.lastIndex(where: { $0.command == command }) {
                DispatchQueue.main.async {
                    self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: command, status: .error, message: String(localized: "执行结果：执行超时\n执行命令：\(command)"))
                    self.currentCommandIndex += 1
                    self.executeNextCommand()
                }
            }
        }
        timeoutTimer.resume()

        PrivilegedHelperAdapter.shared.executeCommand(command) { [weak self] (output: String) in
            timeoutTimer.cancel()
            guard let self else { return }
            DispatchQueue.main.async {
                if let index = self.cleanupLogs.lastIndex(where: { $0.command == command }) {
                    if self.isCancelled {
                        self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: command, status: .cancelled, message: String(localized: "已取消"))
                    } else {
                        let isSuccess = output.isEmpty || output.lowercased() == "success"
                        let message = isSuccess ? String(localized: "执行成功") : String(localized: "执行结果：\(output)\n执行命令：\(command)")
                        self.cleanupLogs[index] = CleanupLog(timestamp: Date(), command: command, status: isSuccess ? .success : .error, message: message)
                    }
                }
                self.currentCommandIndex += 1
                self.executeNextCommand()
            }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            optionsSection
            if viewModel.isProcessing { progressSection }
            logSection
            actionBar
        }
        .alert("确认清理", isPresented: $viewModel.showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) { viewModel.startCleanup() }
        } message: {
            Text("这将删除所选的 Adobe 相关文件，该操作不可撤销。清理过程不会影响 Adobe Downloader 的文件和下载数据。是否继续？")
        }
        .alert(isPresented: $viewModel.showAlert) {
            Alert(title: Text("清理结果"), message: Text(viewModel.alertMessage), dismissButton: .default(Text("确定")))
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
                    isProcessing: viewModel.isProcessing,
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
            Button(action: { viewModel.selectedOptions = Set(CleanupOption.allCases) }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.square").font(.system(size: 10))
                    Text("全选").font(.system(size: 12))
                }
                .foregroundColor(.white)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
            .disabled(viewModel.isProcessing)

            Button(action: { viewModel.selectedOptions.removeAll() }) {
                HStack(spacing: 4) {
                    Image(systemName: "square").font(.system(size: 10))
                    Text("取消全选").font(.system(size: 12))
                }
                .foregroundColor(.primary.opacity(0.85))
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: Color.secondary.opacity(0.2)))
            .disabled(viewModel.isProcessing)

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
            .disabled(viewModel.isProcessing)
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
            .disabled(viewModel.selectedOptions.isEmpty || viewModel.isProcessing)
            .opacity(viewModel.selectedOptions.isEmpty || viewModel.isProcessing ? 0.5 : 1)
        }
    }
}

private struct CleanupOptionRow: View {
    let option: CleanupOption
    let isProcessing: Bool
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
                CommandListView(option: option)
            }
            #endif
        }
    }
}

struct CommandListView: View {
    let option: CleanupOption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将执行的命令：")
                .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .padding(.top, 2).padding(.horizontal, 12)

            LazyVStack(spacing: 6) {
                ForEach(option.commands, id: \.self) { command in
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(6)
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
