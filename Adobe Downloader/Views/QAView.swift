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
                        question: String(localized: "为什么需要下载 Setup 组件？"),
                        answer: String(localized: "Setup 组件是 Adobe 官方的安装程序组件，我们需要对其进行修改以实现绕过验证的功能。如果没有下载并处理 Setup 组件，将无法使用安装功能。")
                    )

                    QAItem(
                        question: String(localized: "为什么有时候下载会失败？"),
                        answer: String(localized: "下载失败可能有多种原因：\n1. 网络连接不稳定\n2. Adobe 服务器响应超时\n3. 本地磁盘空间不足\n建议您检查网络连接并重试，如果问题持续存在，可以尝试使用代理或 VPN。")
                    )

                    QAItem(
                        question: String(localized: "如何修复安装失败的问题？"),
                        answer: String(localized: "如果安装失败，您可以尝试以下步骤：\n1. 确保已正确启用并连接 Helper\n2. 确保已下载并处理 Setup 组件\n3. 检查磁盘剩余空间是否充足\n4. 尝试重新下载并安装\n如果问题仍然存在，可以尝试重新启用 Helper 和重新处理 Setup 组件。")
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
