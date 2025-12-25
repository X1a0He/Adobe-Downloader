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
            return "whoami（检查是否 root）"
        case .id:
            return "id（用户/组信息）"
        case .swVers:
            return "sw_vers（系统版本）"
        case .launchctlPrint:
            return "launchctl print system/...（服务状态）"
        case .listAdobeSupport:
            return "ls /Library/Application Support/Adobe"
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
        statusRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<maxAttempts {
                if Task.isCancelled { return }

                let status = await withCheckedContinuation { continuation in
                    PrivilegedHelperAdapter.shared.getHelperStatus { value in
                        continuation.resume(returning: value)
                    }
                }

                if PrivilegedHelperAdapter.shared.connectionState == .connected {
                    self.helperStatus = .installed
                    return
                }

                self.helperStatus = status
                if status == .installed { return }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
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
        BeautifulGroupBox(label: {
            Text("Helper 游乐场")
        }) {
            VStack(alignment: .leading, spacing: 10) {
                helperStatusSection

                Text("用于快速验证 Helper 是否正常、是否为 root，以及查看命令输出。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Picker("预置命令", selection: $viewModel.selectedPreset) {
                        ForEach(HelperPlaygroundPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 340, alignment: .leading)

                    Button {
                        viewModel.runCommand(viewModel.selectedPreset.command)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                            Text("运行")
                                .font(.system(size: 13))
                        }
                        .frame(minWidth: 80)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                    .foregroundColor(.white)
                    .disabled(viewModel.isBusy)

                    Spacer()

                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                            Text("打开登录项")
                                .font(.system(size: 13))
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                    .foregroundColor(.primary)
                    .disabled(viewModel.isBusy)
                }

#if DEBUG
                DebugCustomCommandSection(
                    isRunning: viewModel.isBusy,
                    onRun: viewModel.runCommand,
                    allowCustomCommand: $viewModel.allowCustomCommand,
                    customCommand: $viewModel.customCommand
                )
#endif

                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        Text(viewModel.output.isEmpty ? "（输出会显示在这里）" : viewModel.output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(viewModel.output.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(height: outputHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                    )

                    if viewModel.isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(8)
                    }
                }

                HStack {
                    Button("清空输出") {
                        viewModel.clearOutput()
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                    .foregroundColor(.primary)
                    .disabled(viewModel.isBusy || viewModel.output.isEmpty)

                    Button("复制输出") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.output, forType: .string)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                    .foregroundColor(.primary)
                    .disabled(viewModel.isBusy || viewModel.output.isEmpty)
                }

                Divider()
                    .opacity(0.6)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Helper 执行日志")
                            .font(.system(size: 14, weight: .medium))

                        Spacer()

                        Button("清空日志") {
                            logStore.clear()
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                        .foregroundColor(.primary)
                        .disabled(logStore.entries.isEmpty)

                        Button("复制日志") {
                            let text = logStore.exportText()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                        .foregroundColor(.primary)
                        .disabled(logStore.entries.isEmpty)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            if logStore.entries.isEmpty {
                                Text("（暂无日志）")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(logStore.entries) { entry in
                                        LogEntryRow(entry: entry)
                                            .id(entry.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
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
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                    )

                    HStack {
                        Text("日志：\(logStore.entries.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("连接：\(helperAdapter.connectionState.description)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("启用状态: ")
                    .font(.system(size: 14, weight: .medium))

                Group {
                    switch viewModel.helperStatus {
                    case .installed:
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                            Text("已启用")
                                .font(.system(size: 14))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    case .needUpdate:
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))
                            Text("状态异常（建议修复）")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    case .noFound:
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                            Text("未启用")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Spacer()

                if viewModel.isReinstallingHelper {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 5)
                }

                Button(action: {
                    viewModel.reinstallHelper()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                        Text("重新启用")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
                .disabled(viewModel.isBusy)
                .help("注销并重新注册后台服务（修复不同步/更新）")

                Button(action: {
                    viewModel.recreateConnection()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                            .font(.system(size: 12))
                        Text("重新创建连接")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                .foregroundColor(.primary)
                .disabled(viewModel.isBusy)
                .help("重新创建到 Helper 的 XPC 连接")
            }

            if viewModel.helperStatus != .installed {
                Text(viewModel.helperStatus == .needUpdate ? "Helper 状态异常，可能无法执行需要管理员权限的操作" : "Helper 未启用将导致无法执行需要管理员权限的操作")
                    .font(.caption)
                    .foregroundColor(viewModel.helperStatus == .needUpdate ? .orange : .red)
            }

            Divider()
                .opacity(0.6)
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
        Toggle("允许自定义命令（仅 Debug，高风险）", isOn: $allowCustomCommand)
            .toggleStyle(SwitchToggleStyle(tint: Color.orange))
            .controlSize(.small)

        HStack(spacing: 10) {
            TextField("输入命令，例如：whoami", text: $customCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .disabled(!allowCustomCommand || isRunning)

            Button {
                onRun(customCommand)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                    Text("运行")
                        .font(.system(size: 13))
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(BeautifulButtonStyle(baseColor: allowCustomCommand ? Color.orange.opacity(0.85) : Color.gray.opacity(0.35)))
            .foregroundColor(allowCustomCommand ? .white : .primary)
            .disabled(isRunning || !allowCustomCommand || customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
#endif
