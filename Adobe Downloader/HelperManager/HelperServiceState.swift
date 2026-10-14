import Foundation

/// 系统只提供 requiresApproval，不能可靠区分首次等待授权和用户后来关闭后台项目。
enum HelperServiceState: Equatable {
    case checking
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case invalidBundle
    case invalidSignature
    case registrationFailed
    case connectionFailed
    case legacyDetected

    static var noFound: Self { .notRegistered }
    static var installed: Self { .enabled }

    var title: String {
        switch self {
        case .checking: return AppLocalized("正在检查")
        case .notRegistered: return AppLocalized("尚未注册")
        case .requiresApproval: return AppLocalized("等待后台运行授权")
        case .enabled: return AppLocalized("已连接")
        case .notFound: return AppLocalized("系统未找到服务")
        case .invalidBundle: return AppLocalized("Helper 文件或路径异常")
        case .invalidSignature: return AppLocalized("签名校验失败")
        case .registrationFailed: return AppLocalized("注册失败")
        case .connectionFailed: return AppLocalized("已授权，连接失败")
        case .legacyDetected: return AppLocalized("需要迁移旧版 Helper")
        }
    }

    var guidance: String {
        switch self {
        case .checking: return AppLocalized("正在读取系统授权状态并检查连接。")
        case .notRegistered: return AppLocalized("点击启用 Helper，向系统注册安装所需的后台服务。")
        case .requiresApproval: return Self.approvalGuidance
        case .enabled: return AppLocalized("Helper 已通过连接检查，可以执行安装和卸载操作。")
        case .notFound, .invalidBundle:
            return AppLocalized("应用内的 Helper 或服务配置不可用。请重新下载完整的 Adobe Downloader；不要单独移动 Helper。")
        case .invalidSignature:
            return AppLocalized("系统无法验证 App 或 Helper 的签名。请使用完整且签名有效的发布版本；打开后台开关不能修复签名问题。")
        case .registrationFailed:
            return AppLocalized("系统未能完成注册，后台列表中可能不会出现条目。请复制诊断信息，按具体错误处理后重试。")
        case .connectionFailed:
            return AppLocalized("后台运行已获授权，但 Helper 没有正常响应。请先重新连接；仍失败时可重新注册服务。")
        case .legacyDetected:
            return AppLocalized("检测到旧版系统服务。迁移会停止旧服务并备份旧文件，然后注册当前 App 内的 Helper。")
        }
    }

    static var approvalGuidance: String {
        AppLocalized("打开系统设置 → 通用 → 登录项与扩展，在“允许在后台运行”或“后台 App 活动”中允许 Adobe Downloader。这里不是上方的“登录时打开”列表；返回 App 后会自动检查。")
    }
}
