//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/11/18.
//

import SwiftUI

struct TipsSheetView: View {
    @ObservedObject private var storage = StorageData.shared
    @EnvironmentObject private var networkManager: NetworkManager
    @Binding var showTipsSheet: Bool
    @Binding var showLanguagePicker: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Adobe Downloader 已为你默认设定如下值")
                .font(.headline)

            VStack(spacing: 12) {
                HStack {
                    Toggle("使用默认语言", isOn: Binding(
                        get: { storage.useDefaultLanguage },
                        set: { storage.useDefaultLanguage = $0 }
                    ))
                    .padding(.leading, 5)
                    Spacer()
                    Text(getLanguageName(code: storage.defaultLanguage))
                        .foregroundColor(.secondary)
                    Button("选择") {
                        showLanguagePicker = true
                    }
                    .padding(.trailing, 5)
                }

                Divider()

                HStack {
                    Toggle("使用默认目录", isOn: Binding(
                        get: { storage.useDefaultDirectory },
                        set: { storage.useDefaultDirectory = $0 }
                    ))
                    .padding(.leading, 5)
                    Spacer()
                    Text(formatPath(storage.defaultDirectory))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("选择") {
                        selectDirectory()
                    }
                    .padding(.trailing, 5)
                }

                Divider()

                HStack {
                    Toggle("重新下载时需要确认", isOn: Binding(
                        get: { storage.confirmRedownload },
                        set: { 
                            storage.confirmRedownload = $0
                            NotificationCenter.default.post(name: .storageDidChange, object: nil)
                        }
                    ))
                    .padding(.leading, 5)
                    Spacer()
                }

                Divider()

                HStack {
                    Toggle("下载 Apple Silicon 架构", isOn: Binding(
                        get: { storage.downloadAppleSilicon },
                        set: { newValue in
                            storage.downloadAppleSilicon = newValue
                            Task {
                                await networkManager.fetchProducts()
                            }
                        }
                    ))
                    .disabled(networkManager.isFetchingProducts)
                    .padding(.leading, 5)
                    Spacer()
                    Text("当前架构: \(AppStatics.cpuArchitecture)")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Text("你可以在设置中随时更改以上选项")
                .font(.headline)

            Button("确定") {
                showTipsSheet = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 500)
    }
    
    private func formatPath(_ path: String) -> String {
        if path.isEmpty { return String(localized: "未设置") }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择默认下载目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK {
            storage.defaultDirectory = panel.url?.path ?? "Downloads"
            storage.useDefaultDirectory = true
        }
    }
    
    private func getLanguageName(code: String) -> String {
        AppStatics.supportedLanguages.first { $0.code == code }?.name ?? code
    }
} 
