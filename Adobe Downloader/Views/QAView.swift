//
//  QAView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

struct QAView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    var body: some View {
        let _ = interfaceLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    QAItem(
                        question: AppLocalized("为什么需要安装 Helper？"),
                        answer: AppLocalized("Helper 是一个具有管理员权限的辅助工具，用于执行需要管理员权限的操作，如修改系统文件等。没有 Helper 将无法正常使用软件的某些功能。")
                    )

                    QAItem(
                        question: AppLocalized("为什么有时候下载会失败？"),
                        answer: AppLocalized("下载失败可能有多种原因：\n1. 网络连接不稳定\n2. Adobe 服务器响应超时\n3. 本地磁盘空间不足\n建议您检查网络连接并重试，如果问题持续存在，可以尝试使用代理或 VPN。")
                    )

                    QAItem(
                        question: AppLocalized("如何修复安装失败的问题？"),
                        answer: AppLocalized("如果安装失败，您可以尝试以下步骤：\n1. 确保已正确启用并连接 Helper\n2. 检查磁盘剩余空间是否充足\n3. 尝试重新下载并安装\n如果问题仍然存在，可以尝试重新启用 Helper。")
                    )

                    QAItem(
                        question: AppLocalized("Helper 无法安装或显示未安装怎么办？"),
                        answer: AppLocalized("请先在 Helper 设置查看具体状态。尚未注册时点击「启用 Helper」；等待授权时点击「打开后台项目」，在系统设置 → 通用 → 登录项与扩展的后台活动区域允许 Adobe Downloader。返回 App 后自动检查，无需重启。列表中没有条目时，请检查文件、签名或注册错误，并复制诊断信息。")
                    )

                    QAItem(
                        question: AppLocalized("为什么需要 IPCBox 和 HDBox？"),
                        answer: AppLocalized("X1a0He CC 会下载 IPCBox 和 HDBox 组件，因为部分官方安装功能需要 HDBox，Photoshop 相关安装流程需要 IPCBox。未启用 Helper 时无法下载这些组件。")
                    )
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QAItem: View {
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.headline)
                .foregroundColor(.primary)

            Text(answer)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
        }
    }
}
