//
//  LogEntryView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

struct LogEntryView: View {
    @StorageValue(\.interfaceLanguage) private var interfaceLanguage
    let log: CleanupLog
    @State private var showCopyButton = false
    
    private var statusIconName: String {
        statusIcon(for: log.status)
    }
    
    private var statusColorValue: Color {
        statusColor(for: log.status)
    }
    
    private var timeFormatted: String {
        timeString(from: log.timestamp)
    }
    
    private var displayText: String {
        #if DEBUG
        return log.command
        #else
        return CleanupLog.getCleanupDescription(for: log.command)
        #endif
    }
    
    private var errorDisplayText: String? {
        if log.status == .error && !log.message.isEmpty {
            return truncatedErrorMessage(log.message)
        }
        return nil
    }

    var body: some View {
        let _ = interfaceLanguage
        HStack {
            Image(systemName: statusIconName)
                .foregroundColor(statusColorValue)

            Text(timeFormatted)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let errorText = errorDisplayText {
                HStack(spacing: 4) {
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button(action: {
                        copyToClipboard(log.message)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(AppLocalized("复制完整错误信息"))
                }
            } else {
                Text(log.message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func truncatedErrorMessage(_ message: String) -> String {
        if message.hasPrefix("执行失败：") {
            let errorMessage = String(message.dropFirst(5))
            if errorMessage.count > 30 {
                return "执行失败：" + errorMessage.prefix(30) + "..."
            }
        }
        return message
    }

    private func copyToClipboard(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }

    private func statusIcon(for status: CleanupLog.LogStatus) -> String {
        switch status {
        case .running:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    private func statusColor(for status: CleanupLog.LogStatus) -> Color {
        switch status {
        case .running:
            return .blue
        case .success:
            return .green
        case .error:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
