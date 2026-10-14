import SwiftUI
import AppKit

struct HelperStatusSection: View {
    @ObservedObject private var manager = HelperManager.shared
    @State private var showMigrationConfirmation = false
    @State private var showRegistrationConfirmation = false
    @State private var showDiagnostics = false

    var body: some View {
        SettingSection(String(localized: "Helper 状态")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SettingsStatusChip(
                        icon: manager.isInstalled ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                        text: manager.state.title,
                        tint: manager.isInstalled ? .green : .orange
                    )
                    if manager.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(String(localized: "刷新状态")) {
                        Task { await manager.checkStatus() }
                    }
                    .disabled(manager.isBusy)
                }

                Text(manager.state.guidance)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !manager.errorDetails.isEmpty {
                    Text(manager.errorDetails)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                if !manager.migrationReport.isEmpty {
                    Text(manager.migrationReport)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack {
                    if manager.state == .legacyDetected {
                        Button(String(localized: "迁移旧版 Helper")) { showMigrationConfirmation = true }
                    } else if manager.state == .connectionFailed {
                        Button(String(localized: "重新连接")) { Task { await manager.reconnect() } }
                    } else if manager.state != .enabled && manager.state != .requiresApproval {
                        Button(String(localized: "启用 Helper")) {
                            Task { do { try await manager.install() } catch { /* 状态和错误由 Manager 发布。 */ } }
                        }
                    }
                    Button(String(localized: "打开后台项目")) { manager.openBackgroundSettings() }
                    if manager.state == .enabled || manager.state == .connectionFailed || manager.state == .registrationFailed {
                        Button(String(localized: "重新注册服务")) { showRegistrationConfirmation = true }
                    }
                }
                .disabled(manager.isBusy)

                DisclosureGroup(String(localized: "系统列表中没有 Adobe Downloader？")) {
                    Text(String(localized: "先查看上方状态：等待授权时，在后台活动区域查找 Adobe Downloader 或其开发者条目；可点信息按钮核对 App 路径。尚未注册时先点击启用；文件、签名或注册错误需先修复。手动加入“登录时打开”列表和授予完全磁盘访问都不能替代后台服务授权。"))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(String(localized: "诊断信息"), isExpanded: $showDiagnostics) {
                    Text(manager.diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(String(localized: "复制诊断信息")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manager.diagnostics, forType: .string)
                    }
                }
            }
            .padding(12)
        }
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .task { await manager.checkStatus() }
        .alert(String(localized: "迁移旧版 Helper？"), isPresented: $showMigrationConfirmation) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "备份并迁移")) {
                Task { do { try await manager.migrateLegacyHelper() } catch { /* 失败详情保留在当前页面。 */ } }
            }
        } message: {
            Text(String(localized: "请先结束正在进行的安装或清理。迁移需要管理员授权，会停止旧服务，将以下文件移存至 /Library/PrivilegedHelperTools/AdobeDownloaderHelperBackup.*，然后注册当前版本。原文件保留，可按备份路径恢复。") + "\n\n" + manager.legacyPaths.joined(separator: "\n"))
        }
        .alert(String(localized: "重新注册 Helper？"), isPresented: $showRegistrationConfirmation) {
            Button(String(localized: "取消"), role: .cancel) { }
            Button(String(localized: "重新注册")) {
                Task { do { try await manager.reinstall() } catch { /* 失败详情保留在当前页面。 */ } }
            }
        } message: {
            Text(String(localized: "重新注册会停止当前服务。请先结束正在进行的安装或清理；此操作不会替你打开系统中的后台运行开关。"))
        }
    }
}
