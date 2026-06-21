//
//  HelperPlaygroundView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/12/23.
//

import SwiftUI
import AppKit
import ServiceManagement

private enum HelperPlaygroundPreset: String, CaseIterable, Identifiable {
    case whoami
    case id
    case swVers
    case launchctlPrint
    case listAdobeSupport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whoami:
            return String(localized: "whoami（检查是否 root）")
        case .id:
            return String(localized: "id（用户/组信息）")
        case .swVers:
            return String(localized: "sw_vers（系统版本）")
        case .launchctlPrint:
            return String(localized: "launchctl print system/...（服务状态）")
        case .listAdobeSupport:
            return "ls /Library/Application Support/Adobe"
        }
    }

    var shortTitle: String {
        switch self {
        case .whoami:           return "whoami"
        case .id:               return "id"
        case .swVers:           return "sw_vers"
        case .launchctlPrint:   return String(localized: "服务状态")
        case .listAdobeSupport: return "ls Adobe"
        }
    }

    var command: String {
        switch self {
        case .whoami:
            return "whoami"
        case .id:
            return "id"
        case .swVers:
            return "sw_vers"
        case .launchctlPrint:
            return "launchctl print system/\(PrivilegedHelperAdapter.machServiceName)"
        case .listAdobeSupport:
            return "ls -la '/Library/Application Support/Adobe'"
        }
    }
}

@MainActor
final class HelperPlaygroundViewModel: ObservableObject {
    @Published fileprivate var selectedPreset: HelperPlaygroundPreset = .whoami
    @Published var isRunning = false
    @Published var isReinstallingHelper = false
    @Published var output = ""
    @Published var helperStatus: PrivilegedHelperAdapter.HelperStatus = .noFound

#if DEBUG
    @Published var allowCustomCommand = false
    @Published var customCommand = ""
#endif

    @Published var showHelperAlert = false
    @Published var helperAlertMessage = ""
    @Published var helperAlertSuccess = false
    @Published var statusRefreshAttempt: Int = 0
    let statusRefreshMaxAttempts: Int = 8

    private let helperAdapter = PrivilegedHelperAdapter.shared
    private var statusRefreshTask: Task<Void, Never>?

    private let maxOutputLength = 24_000

    deinit {
        statusRefreshTask?.cancel()
    }

    var isBusy: Bool {
        isRunning || isReinstallingHelper
    }

    func reinstallHelper() {
        guard !isBusy else { return }
        isReinstallingHelper = true

        helperAdapter.reinstallHelper { [weak self] success, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperAlertSuccess = success
                self.helperAlertMessage = message
                self.showHelperAlert = true
                self.isReinstallingHelper = false
                if success {
                    self.helperStatus = .installed
                }
                self.refreshHelperStatusEventually()
            }
        }
    }

    func recreateConnection() {
        guard !isBusy else { return }

        helperAdapter.reconnectHelper { [weak self] success, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperAlertSuccess = success
                self.helperAlertMessage = message
                self.showHelperAlert = true
                if success {
                    self.helperStatus = .installed
                }
                self.refreshHelperStatusEventually()
            }
        }
    }

    func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isBusy else { return }
        isRunning = true

        appendOutput("$ \(trimmed)\n")

        helperAdapter.executeCommand(trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appendOutput("\(result)\n\n")
                self.isRunning = false
                self.refreshHelperStatusEventually()
            }
        }
    }

    func refreshHelperStatusEventually(maxAttempts: Int = 8, delayNanoseconds: UInt64 = 250_000_000) {
        statusRefreshTask?.cancel()
        statusRefreshAttempt = 0
        statusRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 0..<maxAttempts {
                if Task.isCancelled { return }

                self.statusRefreshAttempt = attempt + 1

                let status = await withCheckedContinuation { continuation in
                    PrivilegedHelperAdapter.shared.getHelperStatus { value in
                        continuation.resume(returning: value)
                    }
                }

                if PrivilegedHelperAdapter.shared.connectionState == .connected {
                    self.helperStatus = .installed
                    self.statusRefreshAttempt = 0
                    return
                }

                self.helperStatus = status
                if status == .installed {
                    self.statusRefreshAttempt = 0
                    return
                }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            self.statusRefreshAttempt = 0
        }
    }

    func clearOutput() {
        output = ""
    }

    private func appendOutput(_ text: String) {
        output.append(text)
        if output.count > maxOutputLength {
            output = String(output.suffix(maxOutputLength))
        }
    }
}

struct HelperPlaygroundView: View {
    @ObservedObject var viewModel: HelperPlaygroundViewModel

    @ObservedObject private var helperAdapter = PrivilegedHelperAdapter.shared
    @ObservedObject private var logStore = HelperExecutionLogStore.shared

    private let outputHeight: CGFloat = 220
    private let logHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            helperStatusSection
            quickDiagnosticsSection
#if DEBUG
            debugCustomCommandSection
#endif
            outputSection
            logSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            viewModel.refreshHelperStatusEventually()
        }
        .onChange(of: helperAdapter.connectionState) { newValue in
            if newValue == .connected {
                viewModel.helperStatus = .installed
            }
        }
    }

    private var helperStatusSection: some View {
        SettingSection(
            String(localized: "Helper 状态"),
            footer: viewModel.helperStatus == .installed ? nil : viewModel.helperStatus == .needUpdate
                ? String(localized: "Helper 状态异常，可能无法执行需要管理员权限的操作")
                : String(localized: "Helper 未启用将导致无法执行需要管理员权限的操作")
        ) {
            SettingRow(
                title: String(localized: "启用状态"),
                subtitle: installStatusSubtitle,
                icon: "lock.shield.fill",
                iconTint: installStatusColor
            ) {
                HStack(spacing: 8) {
                    SettingsStatusChip(icon: installStatusIcon, text: installStatusLabel, tint: installStatusColor)
                    if viewModel.isReinstallingHelper {
                        ProgressView().scaleEffect(0.65).frame(width: 16, height: 16)
                    }
                    Button(action: { viewModel.reinstallHelper() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            Text("重新启用").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                    .disabled(viewModel.isBusy)
                    .help(String(localized: "注销并重新注册后台服务（修复不同步/更新）"))
                }
            }

            SettingRowDivider()

            SettingRow(
                title: String(localized: "连接状态"),
                subtitle: connectionSubtitle,
                icon: "bolt.horizontal.fill",
                iconTint: connectionColor
            ) {
                HStack(spacing: 8) {
                    connectionPulseChip
                    Button(action: { viewModel.recreateConnection() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "network").font(.system(size: 10))
                            Text("重新连接").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: viewModel.isBusy ? Color.gray.opacity(0.6) : Color.blue))
                    .disabled(viewModel.isBusy)
                    .help(String(localized: "重新创建到 Helper 的 XPC 连接"))
                }
            }
        }
    }

    private var quickDiagnosticsSection: some View {
        SettingSection(
            String(localized: "快速诊断"),
            footer: String(localized: "用于快速验证 Helper 行为、权限与服务状态")
        ) {
            SettingRow(
                title: String(localized: "预置命令"),
                subtitle: viewModel.selectedPreset.title,
                icon: "terminal.fill",
                iconTint: .indigo
            ) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(HelperPlaygroundPreset.allCases) { preset in
                            Button(action: { viewModel.selectedPreset = preset }) {
                                Text(preset.title)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.selectedPreset.shortTitle)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button(action: { viewModel.runCommand(viewModel.selectedPreset.command) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("运行").font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                    .disabled(viewModel.isBusy)
                }
            }

            SettingRowDivider()

            SettingRow(
                title: String(localized: "打开登录项"),
                subtitle: String(localized: "跳转到系统设置 → 登录项查看 Helper 注册情况"),
                icon: "gearshape.fill",
                iconTint: .gray
            ) {
                Button(action: { SMAppService.openSystemSettingsLoginItems() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                        Text("打开").font(.system(size: 12))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.6)))
                .disabled(viewModel.isBusy)
            }
        }
    }

#if DEBUG
    private var debugCustomCommandSection: some View {
        SettingSection(
            String(localized: "自定义命令 (Debug)"),
            footer: String(localized: "仅 Debug 构建可用；执行任意命令时请谨慎")
        ) {
            DebugCustomCommandSection(
                isRunning: viewModel.isBusy,
                onRun: viewModel.runCommand,
                allowCustomCommand: $viewModel.allowCustomCommand,
                customCommand: $viewModel.customCommand
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
#endif

    private var outputSection: some View {
        SettingSection(
            String(localized: "命令输出"),
            footer: viewModel.output.isEmpty ? nil : String(format: String(localized: "共 %d 字符"), viewModel.output.count)
        ) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        Text(viewModel.output.isEmpty
                             ? String(localized: "（输出会显示在这里）")
                             : viewModel.output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(viewModel.output.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: outputHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    if viewModel.isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(18)
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    secondaryActionButton(icon: "trash", title: String(localized: "清空")) {
                        viewModel.clearOutput()
                    }
                    .disabled(viewModel.isBusy || viewModel.output.isEmpty)

                    primaryActionButton(icon: "doc.on.doc", title: String(localized: "复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.output, forType: .string)
                    }
                    .disabled(viewModel.isBusy || viewModel.output.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var logSection: some View {
        SettingSection(
            String(localized: "执行日志"),
            footer: String(format: String(localized: "日志：%d 条 · 连接：%@"), logStore.entries.count, helperAdapter.connectionState.description)
        ) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if logStore.entries.isEmpty {
                            Text(String(localized: "(No logs available)"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.75))
                                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                                .padding(10)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(logStore.entries) { entry in
                                    LogEntryRow(entry: entry)
                                        .id(entry.id)
                                }
                            }
                            .padding(10)
                        }
                    }
                    .onChange(of: logStore.entries.count) { _ in
                        guard let last = logStore.entries.last else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(height: logHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                HStack(spacing: 8) {
                    Spacer()
                    secondaryActionButton(icon: "trash", title: String(localized: "清空日志")) {
                        logStore.clear()
                    }
                    .disabled(logStore.entries.isEmpty)

                    primaryActionButton(icon: "doc.on.doc", title: String(localized: "复制日志")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logStore.exportText(), forType: .string)
                    }
                    .disabled(logStore.entries.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var connectionPulseChip: some View {
        HStack(spacing: 5) {
            PulsingCircle(color: connectionColor)
            if helperAdapter.connectionState == .connecting && viewModel.statusRefreshAttempt > 0 {
                Text("正在重试 \(viewModel.statusRefreshAttempt)/\(viewModel.statusRefreshMaxAttempts)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(connectionColor.opacity(0.9))
            } else {
                Text(connectionLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(connectionColor.opacity(0.9))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(connectionColor.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(connectionColor.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func primaryActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 12))
            }
            .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
    }

    private func secondaryActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 12))
            }
            .foregroundColor(.primary.opacity(0.85))
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: Color.secondary.opacity(0.2)))
    }

    private var installStatusColor: Color {
        switch viewModel.helperStatus {
        case .installed:  return .green
        case .needUpdate: return .orange
        case .noFound:    return .red
        }
    }

    private var installStatusIcon: String {
        switch viewModel.helperStatus {
        case .installed:  return "checkmark.circle.fill"
        case .needUpdate: return "exclamationmark.triangle.fill"
        case .noFound:    return "xmark.circle.fill"
        }
    }

    private var installStatusLabel: String {
        switch viewModel.helperStatus {
        case .installed:  return String(localized: "已启用")
        case .needUpdate: return String(localized: "状态异常")
        case .noFound:    return String(localized: "未启用")
        }
    }

    private var installStatusSubtitle: String {
        switch viewModel.helperStatus {
        case .installed:
            return String(localized: "Helper 已安装并运行中，可正常执行特权操作")
        case .needUpdate:
            return String(localized: "Helper 状态异常，建议点击\"重新启用\"修复")
        case .noFound:
            return String(localized: "Helper 未启用，无法执行需要管理员权限的操作")
        }
    }

    private var connectionColor: Color {
        switch helperAdapter.connectionState {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return .red
        }
    }

    private var connectionLabel: String {
        switch helperAdapter.connectionState {
        case .connected:    return String(localized: "运行正常")
        case .connecting:   return String(localized: "正在连接")
        case .disconnected: return String(localized: "连接断开")
        }
    }

    private var connectionSubtitle: String {
        switch helperAdapter.connectionState {
        case .connected:    return String(localized: "XPC 通道运行正常，可执行特权命令")
        case .connecting:   return String(localized: "正在建立 XPC 通道，请稍候…")
        case .disconnected: return String(localized: "连接已断开，点击右侧按钮重新连接")
        }
    }
}

private struct LogEntryRow: View {
    let entry: HelperExecutionLogStore.Entry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let time = Self.formatter.string(from: entry.date)
            Text("[\(time)] \(entry.kind.label) $ \(entry.command)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(entry.isError ? .red : .secondary)
                .textSelection(.enabled)

            if !entry.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.result)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(entry.isError ? .red : .primary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
private struct DebugCustomCommandSection: View {
    let isRunning: Bool
    let onRun: (String) -> Void

    @Binding var allowCustomCommand: Bool
    @Binding var customCommand: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(String(localized: "允许自定义命令（高风险）"), isOn: $allowCustomCommand)
                .toggleStyle(SwitchToggleStyle(tint: Color.orange))
                .controlSize(.small)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                TextField(String(localized: "输入命令，例如：whoami"), text: $customCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!allowCustomCommand || isRunning)

                Button {
                    onRun(customCommand)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal").font(.system(size: 10))
                        Text("运行").font(.system(size: 12))
                    }
                    .foregroundColor(allowCustomCommand ? .white : .primary.opacity(0.6))
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: allowCustomCommand ? Color.orange : Color.gray.opacity(0.35)))
                .disabled(isRunning || !allowCustomCommand || customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
#endif
