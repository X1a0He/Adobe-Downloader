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

struct ToolbarView: View {
    @Binding var downloadAppleSilicon: Bool
    @Binding var currentApiVersion: String
    @Binding var searchText: String
    @Binding var showDownloadManager: Bool
    let isRefreshing: Bool
    let downloadTasksCount: Int
    let onRefresh: () -> Void
    let openSettings: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            Toggle("下载 Apple Silicon", isOn: $downloadAppleSilicon)
            .disabled(isRefreshing)
            .toggleStyle(SwitchToggleStyle(tint: Color.green))
            
            HStack(spacing: 10) {
                Text("API:")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))

                HStack(spacing: 1) {
                    ForEach(["4", "5", "6"], id: \.self) { version in
                        Button(action: { 
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentApiVersion = version 
                            }
                        }) {
                            Text("v\(version)")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 40, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(currentApiVersion == version ? 
                                              Color.blue.opacity(0.15) : 
                                              Color.clear)
                                        .animation(.easeInOut(duration: 0.2), value: currentApiVersion)
                                )
                                .foregroundColor(currentApiVersion == version ? 
                                                 Color.blue.opacity(0.9) : 
                                                 Color.secondary.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                        )
                )
            }
            .disabled(isRefreshing)
            
            HStack(spacing: 8) {
                BeautifulSearchField(text: $searchText)
                    .frame(maxWidth: 200)

                Button(action: openSettings) {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 34, height: 34)
                        
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button(action: onRefresh) {
                    ZStack {
                        Circle()
                            .fill(isRefreshing ? Color.secondary.opacity(0.05) : Color.blue.opacity(0.1))
                            .frame(width: 34, height: 34)
                        
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(isRefreshing ? .secondary.opacity(0.5) : .blue)
                    }
                }
                .disabled(isRefreshing)
                .buttonStyle(.plain)
                
                Button(action: { showDownloadManager.toggle() }) {
                    ZStack {
                        Circle()
                            .fill(downloadTasksCount > 0 ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1))
                            .frame(width: 34, height: 34)
                        
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(downloadTasksCount > 0 ? .blue : .secondary)
                    }
                    .overlay(
                        Group {
                            if downloadTasksCount > 0 {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 18, height: 18)
                                    
                                    Text("\(downloadTasksCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .offset(x: 12, y: -12)
                            }
                        }
                    )
                }
                .disabled(isRefreshing)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.clear))
    }
} 
