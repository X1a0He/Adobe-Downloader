import SwiftUI

extension DownloadStatus.PrepareInfo.PrepareStage {
    var title: String {
        switch self {
        case .initializing:      return String(localized: "初始化")
        case .creatingInstaller: return String(localized: "创建安装器")
        case .signingApp:        return String(localized: "签名应用")
        case .fetchingInfo:      return String(localized: "获取清单")
        case .validatingSetup:   return String(localized: "验证设置")
        }
    }
}

extension DownloadStatus.PauseInfo.PauseReason {
    var localizedText: String {
        switch self {
        case .userRequested: return String(localized: "用户暂停")
        case .networkIssue:  return String(localized: "网络中断")
        case .systemSleep:   return String(localized: "系统休眠")
        case .other(let reason):
            if reason.isEmpty { return String(localized: "其他原因") }
            return reason
        }
    }
}

extension DownloadStatus {
    var compactDescription: String {
        switch self {
        case .waiting:
            return String(localized: "等待中")
        case .preparing(let info):
            return String(localized: "准备中 · \(info.stage.title)")
        case .downloading:
            return String(localized: "下载中")
        case .paused(let info):
            return info.reason.localizedText
        case .completed:
            return String(localized: "已完成")
        case .failed:
            return String(localized: "失败")
        case .retrying(let info):
            return String(localized: "重试 \(info.attempt)/\(info.maxAttempts)")
        }
    }

    var pauseReasonText: String? {
        if case .paused(let info) = self {
            return info.reason.localizedText
        }
        return nil
    }

    var isActiveBroad: Bool {
        switch self {
        case .downloading, .preparing, .waiting, .retrying: return true
        default: return false
        }
    }
}

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
