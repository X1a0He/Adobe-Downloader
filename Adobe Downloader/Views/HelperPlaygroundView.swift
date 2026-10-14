//
//  HelperPlaygroundView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/12/23.
//

import SwiftUI
import AppKit

private enum HelperPlaygroundPreset: String, CaseIterable, Identifiable {
    case whoami, id, swVers, launchctlPrint, listAdobeSupport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whoami: return AppLocalized("管理员身份")
        case .id: return AppLocalized("用户与组")
        case .swVers: return AppLocalized("系统版本")
        case .launchctlPrint: return AppLocalized("后台服务状态")
        case .listAdobeSupport: return AppLocalized("Adobe 支持目录")
        }
    }

    var command: String {
        switch self {
        case .whoami: return "/usr/bin/whoami"
        case .id: return "/usr/bin/id"
        case .swVers: return "/usr/bin/sw_vers"
        case .launchctlPrint: return "/bin/launchctl print system/\(PrivilegedHelperAdapter.machServiceName)"
        case .listAdobeSupport: return "/bin/ls -la '/Library/Application Support/Adobe'"
        }
    }
}

@MainActor
final class HelperPlaygroundViewModel: ObservableObject {
    @Published fileprivate var selectedPreset: HelperPlaygroundPreset = .whoami
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var summary = ""
    @Published fileprivate var checkIDs: [UUID] = []
#if DEBUG
    @Published var allowCustomCommand = false
    @Published var customCommand = ""
    @Published var customTimeout = 30.0
#endif

    private var session: HelperDiagnosticSession?
    private let logStore = HelperExecutionLogStore.shared

    deinit { session?.cancel() }

    func runDiagnostics() {
        guard !isRunning, !HelperManager.shared.isBusy else { return }
        isRunning = true
        isCancelling = false
        summary = AppLocalized("正在检查 Helper…")
        let localID = logStore.begin(title: AppLocalized("注册、授权与连接"))
        checkIDs = [localID]
        Task {
            defer { finishRun() }
            await HelperManager.shared.checkStatus()
            let manager = HelperManager.shared
            let available = manager.state == .enabled && !manager.isBusy
            logStore.finish(localID, status: available ? .passed : .failed, detail: manager.diagnostics)
            for preset in HelperPlaygroundPreset.allCases {
                let id = logStore.begin(title: preset.title, command: preset.command)
                checkIDs.append(id)
                guard available, !isCancelling else {
                    logStore.finish(id, status: .skipped, detail: isCancelling
                        ? AppLocalized("用户已停止检查。") : manager.state.guidance)
                    continue
                }
                await execute(preset.command, timeout: 15, id: id, preset: preset)
            }
            let entries = logStore.entries.filter { checkIDs.contains($0.id) }
            if isCancelling {
                summary = AppLocalized("检查已停止，已完成的结果保留在下方。")
            } else if entries.contains(where: { [.failed, .timedOut].contains($0.status) }) {
                summary = AppLocalized("检查发现异常，请展开对应记录查看原因。")
            } else if entries.contains(where: { $0.status == .warning }) {
                summary = AppLocalized("Helper 检查完成，部分项目需要留意。")
            } else {
                summary = AppLocalized("所有检查已通过。")
            }
        }
    }

    func runPreset() {
        startCommand(selectedPreset.command, title: selectedPreset.title, timeout: 15, preset: selectedPreset)
    }

#if DEBUG
    func runCustomCommand() {
        guard allowCustomCommand else { return }
        startCommand(customCommand, title: AppLocalized("自定义命令"), timeout: customTimeout, preset: nil)
    }
#endif

    private func startCommand(_ command: String, title: String, timeout: Double, preset: HelperPlaygroundPreset?) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !command.isEmpty, command.utf8.count <= 16_384,
              !HelperManager.shared.isBusy else { return }
        isRunning = true
        isCancelling = false
        let id = logStore.begin(title: title, command: command)
        Task {
            defer { finishRun() }
            await execute(command, timeout: timeout, id: id, preset: preset)
        }
    }

    private func execute(_ command: String, timeout: Double, id: UUID, preset: HelperPlaygroundPreset?) async {
        let session = HelperDiagnosticSession()
        self.session = session
        let result = await session.run(command: command, timeout: timeout)
        self.session = nil
        let status: HelperExecutionLogStore.Status
        var detail = ""
        if result.diagnostic?.cancelled == true {
            status = .cancelled
        } else if result.diagnostic?.timedOut == true {
            status = .timedOut
        } else if result.success {
            if preset == .whoami, result.diagnostic?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) != "root" {
                status = .failed
                detail = AppLocalized("Helper 未以 root 身份执行。")
            } else {
                status = .passed
            }
        } else if preset == .listAdobeSupport, result.exitCode != nil {
            status = .warning
            detail = AppLocalized("Adobe 目录不存在或无法列出，不单独代表 Helper 授权失败。")
        } else {
            status = .failed
        }
        logStore.finish(id, status: status, detail: detail, result: result)
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        session?.cancel()
    }

    private func finishRun() {
        session = nil
        isRunning = false
        isCancelling = false
    }
}

struct HelperPlaygroundView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    @ObservedObject var viewModel: HelperPlaygroundViewModel
    @ObservedObject private var manager = HelperManager.shared
    @ObservedObject private var logStore = HelperExecutionLogStore.shared
    @State private var recordsExpanded = false
#if DEBUG
    @State private var customExpanded = false
#endif

    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 20) {
            HelperStatusSection()
            diagnosticsSection
#if DEBUG
            customSection
#endif
            recordsSection
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsSection: some View {
        SettingSection(AppLocalized("快速诊断"), footer: AppLocalized("检查注册、连接、权限及系统信息，不修改安装内容。")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(viewModel.summary.isEmpty ? AppLocalized("一键检查 Helper 是否可用") : viewModel.summary)
                        .font(.callout)
                    Spacer()
                    if viewModel.isRunning {
                        ProgressView().controlSize(.small)
                        Button(viewModel.isCancelling ? AppLocalized("正在停止…") : AppLocalized("停止")) { viewModel.cancel() }
                            .disabled(viewModel.isCancelling)
                    } else {
                        Button(AppLocalized("开始检查")) { viewModel.runDiagnostics() }
                            .disabled(manager.isBusy)
                    }
                }
                ForEach(logStore.entries.filter { viewModel.checkIDs.contains($0.id) }) { entry in
                    HStack {
                        statusIcon(entry.status)
                        Text(entry.title)
                        Spacer()
                        Text(entry.status.title).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                DisclosureGroup(AppLocalized("单项检查")) {
                    HStack {
                        Picker(AppLocalized("检查项目"), selection: $viewModel.selectedPreset) {
                            ForEach(HelperPlaygroundPreset.allCases) { Text($0.title).tag($0) }
                        }
                        Button(AppLocalized("运行")) { recordsExpanded = true; viewModel.runPreset() }
                    }
                    .disabled(viewModel.isRunning || manager.isBusy)
                    .padding(.top, 6)
                }
            }
            .padding(12)
        }
    }

#if DEBUG
    private var customSection: some View {
        SettingSection(AppLocalized("自定义命令 (Debug)")) {
            DisclosureGroup(isExpanded: $customExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalized("以 root 身份执行非交互命令。不支持后台任务；超时或取消会终止命令进程组。"))
                        .font(.caption).foregroundColor(.secondary)
                    Toggle(AppLocalized("允许自定义命令（高风险）"), isOn: $viewModel.allowCustomCommand)
                        .disabled(viewModel.isRunning)
                    TextEditor(text: $viewModel.customCommand)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 90)
                        .border(Color.secondary.opacity(0.25))
                        .disabled(!viewModel.allowCustomCommand || viewModel.isRunning)
                    HStack {
                        Picker(AppLocalized("超时"), selection: $viewModel.customTimeout) {
                            Text(AppLocalized("15 秒")).tag(15.0)
                            Text(AppLocalized("30 秒")).tag(30.0)
                            Text(AppLocalized("60 秒")).tag(60.0)
                            Text(AppLocalized("120 秒")).tag(120.0)
                        }
                        .frame(width: 170)
                        .disabled(viewModel.isRunning)
                        Spacer()
                        Button(AppLocalized("运行")) { recordsExpanded = true; viewModel.runCustomCommand() }
                            .disabled(viewModel.isRunning || manager.isBusy || !viewModel.allowCustomCommand ||
                                viewModel.customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                viewModel.customCommand.utf8.count > 16_384)
                    }
                    if viewModel.customCommand.utf8.count > 16_384 {
                        Text(AppLocalized("命令不能超过 16 KiB。")).font(.caption).foregroundColor(.orange)
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(AppLocalized("开发调试工具"), systemImage: "terminal")
            }
            .padding(12)
        }
    }
#endif

    private var recordsSection: some View {
        SettingSection(AppLocalized("执行记录"), footer: AppLocalized("仅保留本次运行最近 30 条记录；输出在命令结束后显示。")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(format: AppLocalized("共 %d 条记录"), logStore.entries.count)).font(.caption)
                    Spacer()
                    Button(AppLocalized("清空")) { logStore.clear(); viewModel.checkIDs = [] }
                        .disabled(viewModel.isRunning || logStore.entries.isEmpty)
                    Button(AppLocalized("复制全部")) { copy(logStore.exportText()) }
                        .disabled(logStore.entries.isEmpty)
                }
                if logStore.discardedCount > 0 {
                    Text(String(format: AppLocalized("较早的 %d 条记录已移出本次会话。"), logStore.discardedCount))
                        .font(.caption).foregroundColor(.secondary)
                }
                DisclosureGroup(AppLocalized("查看命令与输出"), isExpanded: $recordsExpanded) {
                    if logStore.entries.isEmpty {
                        Text(AppLocalized("运行检查后在这里查看详情。")).foregroundColor(.secondary).padding(.vertical, 8)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(logStore.entries.reversed()) { entry in
                                    HelperExecutionEntryRow(entry: entry)
                                    Divider()
                                }
                            }.padding(.vertical, 8)
                        }.frame(maxHeight: 360)
                    }
                }
            }.padding(12)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct HelperExecutionEntryRow: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let entry: HelperExecutionLogStore.Entry

    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusIcon(entry.status)
                Text(entry.title).fontWeight(.medium)
                Text(entry.status.title).foregroundColor(.secondary)
                Spacer()
                if entry.status == .running {
                    TimelineView(.periodic(from: entry.date, by: 1)) { context in
                        Text(String(format: AppLocalized("已等待 %.0f 秒"), max(0, context.date.timeIntervalSince(entry.date))))
                            .foregroundColor(.secondary)
                    }
                }
                Button(AppLocalized("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.exportText, forType: .string)
                }
            }
            Text(entry.exportText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }
}

private func statusIcon(_ status: HelperExecutionLogStore.Status) -> some View {
    let icon: String
    let color: Color
    switch status {
    case .running: icon = "clock"; color = .blue
    case .passed: icon = "checkmark.circle.fill"; color = .green
    case .warning: icon = "exclamationmark.triangle.fill"; color = .orange
    case .failed, .timedOut: icon = "xmark.circle.fill"; color = .red
    case .cancelled, .skipped: icon = "minus.circle"; color = .secondary
    }
    return Image(systemName: icon).foregroundColor(color)
}
