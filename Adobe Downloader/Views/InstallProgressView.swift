//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import SwiftUI

struct InstallProgressView: View {
    @EnvironmentObject private var networkManager: NetworkManager
    let productName: String
    let progress: Double
    let status: String
    let onCancel: () -> Void
    let onRetry: (() -> Void)?
    let errorDetails: String?
    
    init(productName: String, 
         progress: Double, 
         status: String,
         onCancel: @escaping () -> Void, 
         onRetry: (() -> Void)? = nil, 
         errorDetails: String? = nil) {
        self.productName = productName
        self.progress = progress
        self.status = status
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.errorDetails = errorDetails
    }
    
    private var isCompleted: Bool {
        progress >= 1.0 || status == String(localized: "安装完成")
    }
    
    private var isFailed: Bool {
        status.contains(String(localized: "安装失败"))
    }
    
    private var progressText: String {
        if isCompleted {
            return String(localized: "安装完成")
        } else {
            return "\(Int(progress * 100))%"
        }
    }
    
    private var statusIcon: String {
        if isCompleted {
            return "checkmark.circle.fill"
        } else if isFailed {
            return "xmark.circle.fill"
        } else {
            return "arrow.down.circle.fill"
        }
    }
    
    private var statusColor: Color {
        if isCompleted {
            return .green
        } else if isFailed {
            return .red
        } else {
            return .blue
        }
    }
    
    private var statusTitle: String {
        if isCompleted {
            return String(localized: "\(productName) 安装完成")
        } else if isFailed {
            return String(localized: "\(productName) 安装失败")
        } else {
            return String(localized: "正在安装 \(productName)")
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundColor(statusColor)

                Text(statusTitle)
                    .font(.headline)
            }
            .padding(.horizontal, 20)

            if !isFailed {
                ProgressSection(progress: progress, progressText: progressText)
                    .padding(.vertical, 4)
            }

            InstallLogSection(logs: networkManager.installLogs)
            if isFailed {
                ErrorSection(
                    status: status,
                    isFailed: true,
                    errorDetails: errorDetails
                )
            }

            ButtonSection(
                isCompleted: isCompleted,
                isFailed: isFailed,
                onCancel: onCancel,
                onRetry: onRetry
            )
        }
        .padding()
        .frame(minWidth: 600)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.clear))
        )
    }
}

private struct InstallLogSection: View {
    let logs: [String]
    @State private var isExpanded = true
    @State private var showCopiedAlert = false

    var body: some View {
        if !logs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: { withAnimation { isExpanded.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 12))
                                .foregroundColor(.blue.opacity(0.7))
                            Text("安装日志 (\(logs.count))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: copyLogs) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                }

                if isExpanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(index)
                                }
                            }
                            .padding(8)
                            .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(NSColor.textBackgroundColor).opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                        .onChange(of: logs.count) { _ in
                            if let last = logs.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }

                if showCopiedAlert {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("安装日志已复制到剪贴板")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs.joined(separator: "\n"), forType: .string)
        showCopiedAlert = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedAlert = false
        }
    }
}

private struct ProgressSection: View {
    let progress: Double
    let progressText: String
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                
                Text(progressText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 6)
                        .cornerRadius(3)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.blue.opacity(0.7), Color.blue]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, CGFloat(progress) * geometry.size.width), height: 6)
                        .cornerRadius(3)
                        .animation(.linear(duration: 0.3), value: progress)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 20)
    }
}

private struct ErrorSection: View {
    let status: String
    let isFailed: Bool
    let errorDetails: String?
    
    init(status: String, 
         isFailed: Bool, 
         errorDetails: String? = nil) {
        self.status = status
        self.isFailed = isFailed
        self.errorDetails = errorDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                Text("错误详情")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
            }
            .padding(.vertical, 2)
            
            Text(status)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                )
            
            if let errorDetails = errorDetails, !errorDetails.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.orange.opacity(0.7))
                            .font(.system(size: 14))
                        Text("日志详情")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary.opacity(0.8))
                    }
                    
                    ScrollView {
                        Text(errorDetails)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .frame(maxHeight: 120)
                }
            }
            
            if isFailed {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.blue.opacity(0.7))
                        .font(.system(size: 14))
                    Text("自行安装命令")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                    Spacer()
                    CommandPopover()
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

private struct CommandSection: View {
    let command: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("自行安装命令:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                
                Text(command)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ButtonSection: View {
    let isCompleted: Bool
    let isFailed: Bool
    let onCancel: () -> Void
    let onRetry: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 12) {
            if isFailed {
                if let onRetry = onRetry {
                    Button(action: onRetry) {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                }
                
                Button(action: onCancel) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .red))
            } else if isCompleted {
                Button(action: onCancel) {
                    Label("关闭", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .green))
            } else {
                Button(action: onCancel) {
                    Label("取消", systemImage: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: .red))
            }
        }
        .padding(.horizontal, 20)
    }
}

private struct CommandPopover: View {
    @EnvironmentObject private var networkManager: NetworkManager
    @State private var showPopover = false
    @State private var showCopiedAlert = false
    
    var body: some View {
        Button(action: { showPopover.toggle() }) {
            Text("查看")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.blue.opacity(0.8))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("安装命令")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: {
                        let command = networkManager.installCommand
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(command, forType: .string)
                        showCopiedAlert = true
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedAlert = false
                        }
                    }) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                }

                if showCopiedAlert {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("命令已复制到剪贴板")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .padding(6)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)
                    .transition(.opacity)
                    .animation(.easeInOut, value: showCopiedAlert)
                }

                let command = networkManager.installCommand
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(16)
            .frame(width: 450)
        }
    }
}

#Preview("安装中") {
    let networkManager = NetworkManager()
    return InstallProgressView(
        productName: "Adobe Photoshop",
        progress: 0.45,
        status: "正在安装核心组件...",
        onCancel: {},
        onRetry: nil,
        errorDetails: nil
    )
    .environmentObject(networkManager)
}

#Preview("安装失败") {
    let networkManager = NetworkManager()
    return InstallProgressView(
        productName: "Adobe Photoshop",
        progress: 0.0,
        status: "安装失败: 权限被拒绝",
        onCancel: {},
        onRetry: {},
        errorDetails: "详细错误日志"
    )
    .environmentObject(networkManager)
    .onAppear {
        networkManager.installCommand = "sudo \"/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup\" --install=1 --driverXML=\"/Users/demo/Downloads/Adobe Photoshop/driver.xml\""
    }
}

#Preview("安装完成") {
    let networkManager = NetworkManager()
    return InstallProgressView(
        productName: "Adobe Photoshop",
        progress: 1.0,
        status: "安装完成",
        onCancel: {},
        onRetry: nil,
        errorDetails: nil
    )
    .environmentObject(networkManager)
}

#Preview("在深色模式下") {
    let networkManager = NetworkManager()
    return InstallProgressView(
        productName: "Adobe Photoshop",
        progress: 0.75,
        status: "正在安装...",
        onCancel: {},
        onRetry: nil,
        errorDetails: nil
    )
    .environmentObject(networkManager)
    .preferredColorScheme(.dark)
}
