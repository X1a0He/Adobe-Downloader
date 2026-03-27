import SwiftUI

struct BeautifulSearchField: View {
    @Binding var text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
            
            TextField("搜索应用", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 13))
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

struct FlatToggleStyle: ToggleStyle {
    var onColor: Color = .blue
    var offColor: Color = .gray.opacity(0.3)
    var thumbColor: Color = .white
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isOn ? onColor : offColor)
                    .frame(width: 50, height: 29)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(configuration.isOn ? onColor.opacity(0.2) : offColor.opacity(0.6), lineWidth: 1)
                    )
                
                Circle()
                    .fill(thumbColor)
                    .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
                    .frame(width: 24, height: 24)
                    .offset(x: configuration.isOn ? 11 : -11)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: configuration.isOn)
            }
            .onTapGesture {
                withAnimation {
                    configuration.isOn.toggle()
                }
            }
        }
    }
}

struct FlatSegmentedPickerStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 1)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
            )
    }
}

struct ToolbarView: ToolbarContent {
    @Binding var currentApiVersion: String
    @Binding var showDownloadManager: Bool
    let isRefreshing: Bool
    let downloadTasksCount: Int
    let onRefresh: () -> Void
    let openSettings: () -> Void
    
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 8) {
                Picker("API", selection: $currentApiVersion) {
                    Text("v4").tag("4")
                    Text("v5").tag("5")
                    Text("v6").tag("6")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 126)
            }
            .help("切换 API 版本")
            .disabled(isRefreshing)
        }
        
        ToolbarItem(placement: .principal) {
            ToolbarTitleView()
        }
        
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showDownloadManager.toggle() }) {
                ToolbarDownloadButtonLabel(downloadTasksCount: downloadTasksCount)
            }
            .help(downloadTasksCount > 0 ? "打开下载管理（\(downloadTasksCount) 个任务）" : "打开下载管理")
            
            Button(action: onRefresh) {
                ToolbarRefreshButtonLabel(isRefreshing: isRefreshing)
            }
            .help(isRefreshing ? "正在刷新产品列表" : "刷新产品列表")
            .disabled(isRefreshing)
            
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .help("打开设置")
        }
    }
}

private struct ToolbarTitleView: View {
    var body: some View {
        Text("Adobe Downloader")
            .font(.headline)
            .lineLimit(1)
            .frame(minWidth: 180, maxWidth: 260)
    }
}

private struct ToolbarRefreshButtonLabel: View {
    let isRefreshing: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("刷新中")
            } else {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
    }
}

private struct ToolbarDownloadButtonLabel: View {
    let downloadTasksCount: Int
    
    var body: some View {
        HStack(spacing: 6) {
            Label("下载管理", systemImage: downloadTasksCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .foregroundStyle(downloadTasksCount > 0 ? Color.accentColor : Color.primary)

            if downloadTasksCount > 0 {
                Text(downloadTasksCount.formatted())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
