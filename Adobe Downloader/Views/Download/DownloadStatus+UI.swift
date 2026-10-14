import SwiftUI

extension DownloadStatus.PrepareInfo.PrepareStage {
    var title: String {
        switch self {
        case .initializing:      return AppLocalized("初始化")
        case .creatingInstaller: return AppLocalized("创建安装器")
        case .signingApp:        return AppLocalized("签名应用")
        case .fetchingInfo:      return AppLocalized("获取清单")
        }
    }
}

extension DownloadStatus.PauseInfo.PauseReason {
    var localizedText: String {
        switch self {
        case .userRequested: return AppLocalized("用户暂停")
        case .networkIssue:  return AppLocalized("网络中断")
        case .systemSleep:   return AppLocalized("系统休眠")
        case .other(let reason):
            if reason.isEmpty { return AppLocalized("其他原因") }
            return reason
        }
    }
}

extension DownloadStatus {
    var compactDescription: String {
        switch self {
        case .waiting:
            return AppLocalized("等待中")
        case .preparing(let info):
            return AppLocalized("准备中 · \(info.stage.title)")
        case .downloading:
            return AppLocalized("下载中")
        case .paused(let info):
            return info.reason.localizedText
        case .completed:
            return AppLocalized("已完成")
        case .failed:
            return AppLocalized("失败")
        case .retrying(let info):
            return AppLocalized("重试 \(info.attempt)/\(info.maxAttempts)")
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
        case .cancel: return AppLocalized("确认取消")
        case .remove: return AppLocalized("确认删除")
        default: return ""
        }
    }

    func confirmMessage(for taskName: String) -> String {
        switch self {
        case .cancel: return AppLocalized("确定要取消\(taskName)的下载吗？")
        case .remove: return AppLocalized("确定要删除任务\(taskName)吗？")
        default: return ""
        }
    }

    var buttonLabel: String {
        switch self {
        case .pause:   return AppLocalized("暂停")
        case .resume:  return AppLocalized("继续")
        case .cancel:  return AppLocalized("取消")
        case .retry:   return AppLocalized("重试")
        case .remove:  return AppLocalized("移除")
        case .install: return AppLocalized("安装")
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
