//
//  CleanConfigView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

struct CleanConfigView: View {
    @State private var showConfirmation = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var chipInfo: String = ""
    @State private var helperStatus: PrivilegedHelperAdapter.HelperStatus = .noFound

    private func getChipInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        let chipName = String(cString: machine)

        if chipName.contains("Apple") {
            return chipName
        } else {
            return chipName.components(separatedBy: "@")[0].trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            BeautifulGroupBox(label: {
                Text("重置程序")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("重置程序") {
                            showConfirmation = true
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: .red.opacity(0.8)))
                        .foregroundColor(.white)

                        Button("修复 Helper") {
                            runFixHelperScript()
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: .blue.opacity(0.8)))
                        .foregroundColor(.white)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            BeautifulGroupBox(label: {
                Text("系统信息")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .foregroundColor(.blue)
                            .imageScale(.medium)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.blue.opacity(0.1)).frame(width: 28, height: 28))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                                .fontWeight(.medium)

                            Text("\(chipInfo.isEmpty ? "加载中..." : chipInfo)")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                        }
                        Spacer()
                    }
                }
            }
        }
        .alert("确认重置程序", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                cleanConfig()
            }
        } message: {
            Text("这将清空所有配置并结束应用程序，确定要继续吗？")
        }
        .alert("操作结果", isPresented: $showAlert) {
            Button("确定") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            chipInfo = getChipInfo()
        }
        .task {
            PrivilegedHelperAdapter.shared.getHelperStatus { status in
                helperStatus = status
            }
        }
    }

    private func cleanConfig() {
        do {
            let downloadsURL = try FileManager.default.url(for: .downloadsDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: false)
            let scriptURL = downloadsURL.appendingPathComponent("clean-config.sh")

            guard let scriptPath = Bundle.main.path(forResource: "clean-config", ofType: "sh"),
                  let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
                throw NSError(domain: "ScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取脚本文件"])
            }

            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)

            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: scriptURL.path)

            if helperStatus == .installed {
                PrivilegedHelperAdapter.shared.executeCommand("open -a Terminal \(scriptURL.path)") { output in
                    if output.starts(with: "Error") {
                        alertMessage = String(localized: "清空配置失败: \(output)")
                        showAlert = true
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            exit(0)
                        }
                    }
                }
            } else {
                let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                NSWorkspace.shared.open([scriptURL],
                                        withApplicationAt: terminalURL,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        alertMessage = "打开终端失败: \(error.localizedDescription)"
                        showAlert = true
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        exit(0)
                    }
                }
            }

        } catch {
            alertMessage = String(localized: "清空配置失败: \(error.localizedDescription)")
            showAlert = true
        }
    }

    private func runFixHelperScript() {
        do {
            let downloadsURL = try FileManager.default.url(for: .downloadsDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: false)
            let scriptURL = downloadsURL.appendingPathComponent("fix-helper.sh")

            guard let scriptPath = Bundle.main.path(forResource: "fix-helper", ofType: "sh"),
                  let scriptContent = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
                throw NSError(domain: "ScriptError",
                              code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取修复脚本文件"])
            }

            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path)

            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([scriptURL],
                                    withApplicationAt: terminalURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    alertMessage = "打开终端失败: \(error.localizedDescription)"
                    showAlert = true
                    return
                }
            }
        } catch {
            alertMessage = String(localized: "修复 Helper 失败: \(error.localizedDescription)")
            showAlert = true
        }
    }
}

struct CleanupLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let command: String
    let status: LogStatus
    let message: String

    enum LogStatus {
        case running
        case success
        case error
        case cancelled
    }

    static func getCleanupDescription(for command: String) -> String {
        if command.contains("Library/Logs") || command.contains("DiagnosticReports") {
            if command.contains("Adobe Creative Cloud") {
                return String(localized: "正在清理 Creative Cloud 日志文件...")
            } else if command.contains("CrashReporter") {
                return String(localized: "正在清理崩溃报告日志...")
            } else {
                return String(localized: "正在清理应用程序日志文件...")
            }
        } else if command.contains("Library/Caches") {
            return String(localized: "正在清理缓存文件...")
        } else if command.contains("Library/Preferences") {
            return String(localized: "正在清理偏好设置文件...")
        } else if command.contains("Applications") {
            if command.contains("Creative Cloud") {
                return String(localized: "正在清理 Creative Cloud 应用...")
            } else {
                return String(localized: "正在清理 Adobe 应用程序...")
            }
        } else if command.contains("LaunchAgents") || command.contains("LaunchDaemons") {
            return String(localized: "正在清理启动项服务...")
        } else if command.contains("security") {
            return String(localized: "正在清理钥匙串数据...")
        } else if command.contains("AdobeGenuineClient") || command.contains("AdobeGCClient") {
            return String(localized: "正在清理正版验证服务...")
        } else if command.contains("hosts") {
            return String(localized: "正在清理 hosts 文件...")
        } else if command.contains("kill") {
            return String(localized: "正在停止 Adobe 相关进程...")
        } else if command.contains("receipts") {
            return String(localized: "正在清理安装记录...")
        } else {
            return String(localized: "正在清理其他文件...")
        }
    }
}
