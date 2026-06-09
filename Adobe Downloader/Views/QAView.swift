//
//  QAView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

struct QAView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    QAItem(
                        question: String(localized: "为什么需要安装 Helper？"),
                        answer: String(localized: "Helper 是一个具有管理员权限的辅助工具，用于执行需要管理员权限的操作，如修改系统文件等。没有 Helper 将无法正常使用软件的某些功能。")
                    )

                    QAItem(
                        question: String(localized: "为什么有时候下载会失败？"),
                        answer: String(localized: "下载失败可能有多种原因：\n1. 网络连接不稳定\n2. Adobe 服务器响应超时\n3. 本地磁盘空间不足\n建议您检查网络连接并重试，如果问题持续存在，可以尝试使用代理或 VPN。")
                    )

                    QAItem(
                        question: String(localized: "如何修复安装失败的问题？"),
                        answer: String(localized: "如果安装失败，您可以尝试以下步骤：\n1. 确保已正确启用并连接 Helper\n2. 检查磁盘剩余空间是否充足\n3. 尝试重新下载并安装\n如果问题仍然存在，可以尝试重新启用 Helper。")
                    )

                    QAItem(
                        question: String(localized: "Helper 无法安装或显示未安装怎么办？"),
                        answer: String(localized: "请按以下步骤处理：\n1. 在 Helper 设置中点击「重新启用」\n2. 前往系统设置 → 登录项与扩展\n3. 找到 Adobe Downloader.app 并打开开关\n4. 重启 Adobe Downloader\n5. 再次点击「重新启用」或「重新连接」")
                    )

                    QAItem(
                        question: String(localized: "为什么需要 IPCBox 和 HDBox？"),
                        answer: String(localized: "X1a0He CC 会下载 IPCBox 和 HDBox 组件，因为部分官方安装功能需要 HDBox，Photoshop 相关安装流程需要 IPCBox。未启用 Helper 时无法下载这些组件。")
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
