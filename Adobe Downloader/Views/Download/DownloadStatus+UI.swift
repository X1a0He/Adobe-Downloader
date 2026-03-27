import SwiftUI

extension DownloadStatus {
    var badgeColor: Color {
        switch self {
        case .downloading: return .blue
        case .preparing:   return .purple.opacity(0.8)
        case .completed:   return .green.opacity(0.8)
        case .failed:      return .red.opacity(0.8)
        case .paused:      return .orange.opacity(0.8)
        case .waiting:     return .gray.opacity(0.8)
        case .retrying:    return .yellow.opacity(0.8)
        }
    }

    var statusIcon: String {
        switch self {
        case .downloading: return "arrow.down.circle.fill"
        case .preparing:   return "gear.circle.fill"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "xmark.circle.fill"
        case .paused:      return "pause.circle.fill"
        case .waiting:     return "clock.circle.fill"
        case .retrying:    return "arrow.clockwise.circle.fill"
        }
    }

    var progressBarColor: Color {
        switch self {
        case .downloading: return .blue
        case .paused:      return .orange
        default:           return .blue
        }
    }
}

enum TaskAction {
    case pause
    case resume
    case cancel
    case retry
    case remove
    case install

    var needsConfirmation: Bool {
        switch self {
        case .cancel, .remove: return true
        default: return false
        }
    }

    var confirmTitle: String {
        switch self {
        case .cancel: return String(localized: "确认取消")
        case .remove: return String(localized: "确认删除")
        default: return ""
        }
    }

    func confirmMessage(for taskName: String) -> String {
        switch self {
        case .cancel: return String(localized: "确定要取消\(taskName)的下载吗？")
        case .remove: return String(localized: "确定要删除任务\(taskName)吗？")
        default: return ""
        }
    }

    var buttonLabel: String {
        switch self {
        case .pause:   return String(localized: "暂停")
        case .resume:  return String(localized: "继续")
        case .cancel:  return String(localized: "取消")
        case .retry:   return String(localized: "重试")
        case .remove:  return String(localized: "移除")
        case .install: return String(localized: "安装")
        }
    }

    var buttonIcon: String {
        switch self {
        case .pause:   return "pause.fill"
        case .resume:  return "play.fill"
        case .cancel:  return "xmark"
        case .retry:   return "arrow.clockwise"
        case .remove:  return "trash"
        case .install: return "tray.and.arrow.down"
        }
    }

    var buttonColor: Color {
        switch self {
        case .pause:   return .orange
        case .resume:  return .blue
        case .cancel:  return .red
        case .retry:   return .blue
        case .remove:  return .red
        case .install: return .green
        }
    }
}
