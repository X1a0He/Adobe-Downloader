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

struct HelperPlaygroundView: View {
    @Binding var showHelperAlert: Bool
    @Binding var helperAlertMessage: String
    @Binding var helperAlertSuccess: Bool

    @ObservedObject private var helperAdapter = PrivilegedHelperAdapter.shared
    @State private var selectedPreset: HelperPlaygroundPreset = .whoami
    @State private var isRunning = false
    @State private var isReinstallingHelper = false
    @State private var output = ""
    @State private var helperStatus: PrivilegedHelperAdapter.HelperStatus = .noFound
    @State private var statusRefreshTask: Task<Void, Never>?

    private let maxOutputLength = 24_000
    private let outputHeight: CGFloat = 220

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
                    Picker("预置命令", selection: $selectedPreset) {
                        ForEach(HelperPlaygroundPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 340, alignment: .leading)

                    Button {
                        runCommand(selectedPreset.command)
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
                    .disabled(isBusy)

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
                    .disabled(isBusy)
                }

#if DEBUG
                DebugCustomCommandSection(isRunning: isBusy, onRun: runCommand)
#endif

                ZStack(alignment: .topTrailing) {
                    ScrollView {
                        Text(output.isEmpty ? "（输出会显示在这里）" : output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(output.isEmpty ? .secondary : .primary)
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

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(8)
                    }
                }

                HStack {
                    Button("清空输出") {
                        output = ""
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                    .foregroundColor(.primary)
                    .disabled(isBusy || output.isEmpty)

                    Button("复制输出") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.35)))
                    .foregroundColor(.primary)
                    .disabled(isBusy || output.isEmpty)

                    Spacer()

                    Text("连接：\(helperAdapter.connectionState.description)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            refreshHelperStatusEventually()
        }
        .onChange(of: helperAdapter.connectionState) { newValue in
            if newValue == .connected {
                helperStatus = .installed
            }
        }
    }

    private var isBusy: Bool {
        isRunning || isReinstallingHelper
    }

    private var helperStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("安装状态: ")
                    .font(.system(size: 14, weight: .medium))

                Group {
                    switch helperStatus {
                    case .installed:
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                            Text("已安装 (build \(UserDefaults.standard.string(forKey: "InstalledHelperBuild") ?? "0"))")
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
                            Text("未安装")
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

                if isReinstallingHelper {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 5)
                }

                Button(action: {
                    isReinstallingHelper = true
                    PrivilegedHelperAdapter.shared.reinstallHelper { success, message in
                        DispatchQueue.main.async {
                            helperAlertSuccess = success
                            helperAlertMessage = message
                            showHelperAlert = true
                            isReinstallingHelper = false
                            if success {
                                helperStatus = .installed
                            }
                            refreshHelperStatusEventually()
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                        Text("重新安装")
                            .font(.system(size: 13))
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.8)))
                .foregroundColor(.white)
                .disabled(isBusy)
                .help("完全卸载并重新安装 Helper")

                Button(action: {
                    PrivilegedHelperAdapter.shared.reconnectHelper { success, message in
                        DispatchQueue.main.async {
                            helperAlertSuccess = success
                            helperAlertMessage = message
                            showHelperAlert = true
                            if success {
                                helperStatus = .installed
                            }
                            refreshHelperStatusEventually()
                        }
                    }
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
                .disabled(isBusy)
                .help("重新创建到 Helper 的 XPC 连接")
            }

            if helperStatus != .installed {
                Text(helperStatus == .needUpdate ? "Helper 状态异常，可能无法执行需要管理员权限的操作" : "Helper 未安装将导致无法执行需要管理员权限的操作")
                    .font(.caption)
                    .foregroundColor(helperStatus == .needUpdate ? .orange : .red)
            }

            Divider()
                .opacity(0.6)
        }
    }

    private func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isBusy else { return }
        isRunning = true

        appendOutput("$ \(trimmed)\n")

        PrivilegedHelperAdapter.shared.executeCommand(trimmed) { result in
            DispatchQueue.main.async {
                self.appendOutput("\(result)\n\n")
                self.isRunning = false
                self.refreshHelperStatusEventually()
            }
        }
    }

    private func refreshHelperStatusEventually(maxAttempts: Int = 8, delayNanoseconds: UInt64 = 250_000_000) {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { @MainActor in
            for _ in 0..<maxAttempts {
                if Task.isCancelled { return }

                let status = await withCheckedContinuation { continuation in
                    PrivilegedHelperAdapter.shared.getHelperStatus { value in
                        continuation.resume(returning: value)
                    }
                }

                if helperAdapter.connectionState == .connected {
                    helperStatus = .installed
                    return
                }

                helperStatus = status
                if status == .installed { return }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
    }

    private func appendOutput(_ text: String) {
        output.append(text)
        if output.count > maxOutputLength {
            output = String(output.suffix(maxOutputLength))
        }
    }
}

#if DEBUG
private struct DebugCustomCommandSection: View {
    let isRunning: Bool
    let onRun: (String) -> Void

    @State private var allowCustomCommand = false
    @State private var customCommand = ""

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
