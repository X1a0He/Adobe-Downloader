//
//  Adobe Downloader
//
//  Created by X1a0He.
//

import SwiftUI

private enum AlertConstants {
    static let iconSize: CGFloat = 64
    static let warningIconSize: CGFloat = 24
    static let warningIconOffset: CGFloat = 10
    static let verticalSpacing: CGFloat = 20
    static let buttonHeight: CGFloat = 24
    static let buttonWidth: CGFloat = 260
    static let buttonFontSize: CGFloat = 14
    static let cornerRadius: CGFloat = 12
    static let shadowRadius: CGFloat = 10
}

struct ExistingFileAlertView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let path: URL
    let onUseExisting: () -> Void
    let onRedownload: () -> Void
    let onCancel: () -> Void
    let iconImage: NSImage?
    
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: AlertConstants.verticalSpacing) {
            IconSection(iconImage: iconImage)
            
            Text(AppLocalized("安装程序已存在"))
                .font(.headline)
            
            PathSection(path: path)
            ButtonSection(
                onUseExisting: onUseExisting,
                onRedownload: onRedownload,
                onCancel: onCancel
            )
        }
        .padding()
        .background(BackgroundView())
    }
}

private struct IconSection: View {
    let iconImage: NSImage?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppIcon(iconImage: iconImage)
            WarningIcon()
        }
        .padding(.bottom, 5)
    }
}

private struct AppIcon: View {
    let iconImage: NSImage?
    
    var body: some View {
        Group {
            if let iconImage = iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: AlertConstants.iconSize, height: AlertConstants.iconSize)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
                .padding(-4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                .padding(-4)
        )
    }
}

private struct WarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: AlertConstants.warningIconSize))
            .foregroundColor(.orange)
            .offset(x: AlertConstants.warningIconOffset, y: 4)
    }
}

private struct PathSection: View {
    let path: URL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(path.path)
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.blue.opacity(0.1), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        openInFinder(path)
                    }
            }
        }
    }
    
    private func openInFinder(_ path: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }
}

private struct ButtonSection: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let onUseExisting: () -> Void
    let onRedownload: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 12) {
            ActionButton(
                title: AppLocalized("使用现有程序"),
                icon: "checkmark.circle",
                color: .blue,
                action: onUseExisting
            )
            
            ActionButton(
                title: AppLocalized("重新下载"),
                icon: "arrow.down.circle",
                color: .green,
                action: onRedownload
            )
            
            ActionButton(
                title: AppLocalized("取消"),
                icon: "xmark.circle",
                color: .red,
                action: onCancel,
                isCancel: true
            )
        }
    }
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    var isCancel: Bool = false
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(minWidth: 0, maxWidth: AlertConstants.buttonWidth)
                .frame(height: AlertConstants.buttonHeight)
                .font(.system(size: AlertConstants.buttonFontSize))
                .foregroundColor(.white)
        }
        .buttonStyle(BeautifulButtonStyle(baseColor: color))
        .if(isCancel) { view in
            view.keyboardShortcut(.cancelAction)
        }
    }
}

private struct BackgroundView: View {
    var body: some View {
        Color(NSColor.windowBackgroundColor)
            .cornerRadius(AlertConstants.cornerRadius)
            .shadow(radius: AlertConstants.shadowRadius)
    }
}

extension View {
    @ViewBuilder
    fileprivate func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct ExistingFileAlertView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ExistingFileAlertView(
                path: URL(fileURLWithPath: "/Users/username/Downloads/Adobe/Adobe Downloader PHSP_25.0-en_US-macuniversal"),
                onUseExisting: {},
                onRedownload: {},
                onCancel: {},
                iconImage: NSImage(named: "PHSP")
            )
            .background(Color.black.opacity(0.3))
            .previewDisplayName("Light Mode")
            
            ExistingFileAlertView(
                path: URL(fileURLWithPath: "/Users/username/Downloads/Adobe/Adobe Downloader PHSP_25.0-en_US-macuniversal"),
                onUseExisting: {},
                onRedownload: {},
                onCancel: {},
                iconImage: NSImage(named: "PHSP")
            )
            .background(Color.black.opacity(0.3))
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")
        }
    }
}
