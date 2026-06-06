//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation
import SwiftUI

enum PackageStatus: Equatable, Codable {
    case waiting
    case downloading
    case paused
    case completed
    case failed(String)

    var description: LocalizedStringKey {
        switch self {
        case .waiting: return LocalizedStringKey("等待中...")
        case .downloading: return LocalizedStringKey("下载中...")
        case .paused: return LocalizedStringKey("已暂停")
        case .completed: return LocalizedStringKey("已完成")
        case .failed(let message): return LocalizedStringKey("下载失败: \(message)")
        }
    }
}

enum NetworkError: Error, LocalizedError {
    case noConnection
    case timeout
    case serverUnreachable(String)

    case invalidURL(String)
    case invalidRequest(String)
    case invalidResponse

    case invalidData(String)
    case parsingError(Error, String)
    case dataValidationError(String)

    case httpError(Int, String?)
    case serverError(Int)
    case clientError(Int)

    case downloadError(String, Error?)
    case downloadCancelled
    case insufficientStorage(Int64, Int64)
    case cancelled

    case fileSystemError(String, Error?)
    case fileExists(String)
    case fileNotFound(String)
    case filePermissionDenied(String)

    case applicationInfoError(String, Error?)
    case unsupportedPlatform(String)
    case incompatibleVersion(String, String)
    case installError(String)
    case productNotFound

    private var errorGroup: Int {
        switch self {
        case .noConnection, .timeout, .serverUnreachable: return 1000
        case .invalidURL, .invalidRequest, .invalidResponse: return 2000
        case .invalidData, .parsingError, .dataValidationError: return 3000
        case .httpError, .serverError, .clientError: return 4000
        case .downloadError, .downloadCancelled, .insufficientStorage, .cancelled: return 5000
        case .fileSystemError, .fileExists, .fileNotFound, .filePermissionDenied: return 6000
        case .applicationInfoError, .unsupportedPlatform, .incompatibleVersion, .installError, .productNotFound: return 7000
        }
    }

    private var errorOffset: Int {
        switch self {
        case .noConnection: return 1
        case .timeout: return 2
        case .serverUnreachable: return 3
        case .invalidURL: return 1
        case .invalidRequest: return 2
        case .invalidResponse: return 3
        case .invalidData: return 1
        case .parsingError: return 2
        case .dataValidationError: return 3
        case .httpError: return 1
        case .serverError: return 2
        case .clientError: return 3
        case .downloadError: return 1
        case .downloadCancelled: return 2
        case .insufficientStorage: return 3
        case .cancelled: return 4
        case .fileSystemError: return 1
        case .fileExists: return 2
        case .fileNotFound: return 3
        case .filePermissionDenied: return 4
        case .applicationInfoError: return 1
        case .unsupportedPlatform: return 2
        case .incompatibleVersion: return 3
        case .installError: return 4
        case .productNotFound: return 5
        }
    }

    var errorCode: Int {
        return errorGroup + errorOffset
    }

    var errorDescription: String? {
        switch self {
            case .noConnection:
                return NSLocalizedString("网络无连接", value: "Network error", comment: "Network error")
            case .timeout:
                return NSLocalizedString("请求超时，请检查网络连接后重试", value: "请求超时，请检查网络连接后重试", comment: "Network timeout")
            case .serverUnreachable(let server):
                return String(format: NSLocalizedString("无法连接到服务器: %@", value: "无法连接到服务器: %@",comment: "Server unreachable"), server)
            case .invalidURL(let url):
                return String(format: NSLocalizedString("无效的URL: %@", value: "无效的URL: %@", comment: "Invalid URL"), url)
            case .invalidRequest(let reason):
                return String(format: NSLocalizedString("无效的请求: %@", value: "无效的请求: %@", comment: "Invalid request"), reason)
            case .invalidResponse:
                return NSLocalizedString("服务器响应无效", value: "服务器响应无效", comment: "Invalid response")
            case .invalidData(let detail):
                return String(format: NSLocalizedString("数据无效: %@", value: "数据无效: %@", comment: "Invalid data"), detail)
            case .parsingError(let error, let context):
                return String(format: NSLocalizedString("解析错误: %@ - %@", value: "Parsing error: %@ - %@", comment: "Parsing error"), context, error.localizedDescription)
            case .dataValidationError(let reason):
                return String(format: NSLocalizedString("数据验证失败: %@", value: "数据验证失败: %@", comment: "Data validation error"), reason)
            case .httpError(let code, let message):
                return String(format: NSLocalizedString("HTTP错误 %d: %@", value: "HTTP错误 %d: %@", comment: "HTTP error"), code, message ?? "")
            case .serverError(let code):
                return String(format: NSLocalizedString("服务器错误: %d", value: "服务器错误: %d", comment: "Server error"), code)
            case .clientError(let code):
                return String(format: NSLocalizedString("客户端错误: %d", value: "客户端错误: %d", comment: "Client error"), code)
            case .downloadError(let message, let error):
                if let error = error {
                    return String(format: NSLocalizedString("下载错误, 错误原因: %@, %@", value: "%@: %@", comment: "Download error with cause"), message, error.localizedDescription)
                }
                return NSLocalizedString(message, value: message, comment: "Download error")
            case .downloadCancelled:
                return NSLocalizedString("下载已取消", value: "下载已取消", comment: "Download cancelled")
            case .insufficientStorage(let needed, let available):
                return String(format: NSLocalizedString("存储空间不足: 需要 %lld字节, 可用 %lld字节", value: "存储空间不足: 需要 %lld字节, 可用 %lld字节", comment: "Insufficient storage"), needed, available)
            case .fileSystemError(let operation, let error):
                if let error = error {
                    return String(format: NSLocalizedString("文件系统错误(%@): %@", value: "文件系统错误(%@): %@", comment: "File system error with cause"), operation, error.localizedDescription)
                }
                return String(format: NSLocalizedString("文件系统错误: %@", value: "文件系统错误: %@", comment: "File system error"), operation)
            case .fileExists(let path):
                return String(format: NSLocalizedString("文件已存在: %@", value: "文件已存在: %@", comment: "File exists"), path)
            case .fileNotFound(let path):
                return String(format: NSLocalizedString("文件不存在: %@", value: "文件不存在: %@", comment: "File not found"), path)
            case .filePermissionDenied(let path):
                return String(format: NSLocalizedString("文件访问权限被拒绝: %@", value: "文件访问权限被拒绝: %@", comment: "File permission denied"), path)
            case .applicationInfoError(let message, let error):
                if let error = error {
                    return String(format: NSLocalizedString("应用信息错误(%@): %@", value: "应用信息错误(%@): %@", comment: "Application info error with cause"), message, error.localizedDescription)
                }
                return String(format: NSLocalizedString("应用信息错误: %@", value: "应用信息错误: %@", comment: "Application info error"), message)
            case .unsupportedPlatform(let platform):
                return String(format: NSLocalizedString("不支持的平台: %@", value: "不支持的平台: %@", comment: "Unsupported platform"), platform)
            case .incompatibleVersion(let current, let required):
                return String(format: NSLocalizedString("版本不兼容: 当前版本 %@, 需要版本 %@", value: "版本不兼容: 当前版本 %@, 需要版本 %@", comment: "Incompatible version"), current, required)
            case .cancelled:
                return NSLocalizedString("下载已取消", value: "下载已取消", comment: "Download cancelled")
            case .installError(let message):
                return String(format: NSLocalizedString("安装错误: %@", value: "安装错误: %@", comment: "Install error"), message)
            case .productNotFound:
                return NSLocalizedString("产品未找到", value: "产品未找到", comment: "Product not found")
        }
    }
    
    var debugDescription: String {
        return "Error \(errorCode): \(errorDescription ?? "")"
    }
}

enum DownloadStatus: Equatable, Codable {
    case waiting
    case preparing(PrepareInfo)
    case downloading(DownloadInfo)
    case paused(PauseInfo)
    case completed(CompletionInfo)
    case failed(FailureInfo)
    case retrying(RetryInfo)

    struct PrepareInfo: Codable {
        let message: String
        let timestamp: Date
        let stage: PrepareStage
        
        enum PrepareStage: Codable {
            case initializing
            case creatingInstaller
            case signingApp
            case fetchingInfo
        }
    }
    
    struct DownloadInfo: Codable {
        let fileName: String
        let currentPackageIndex: Int
        let totalPackages: Int
        let startTime: Date
        let estimatedTimeRemaining: TimeInterval?
    }
    
    struct PauseInfo: Codable {
        let reason: PauseReason
        let timestamp: Date
        let resumable: Bool
        
        enum PauseReason: Codable {
            case userRequested
            case networkIssue
            case systemSleep
            case other(String)
        }
    }
    
    struct CompletionInfo: Codable {
        let timestamp: Date
        let totalTime: TimeInterval
        let totalSize: Int64
    }
    
    struct FailureInfo: Codable {
        let message: String
        let error: Error?
        let timestamp: Date
        let recoverable: Bool
        
        enum CodingKeys: CodingKey {
            case message
            case timestamp
            case recoverable
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(recoverable, forKey: .recoverable)
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(String.self, forKey: .message)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            recoverable = try container.decode(Bool.self, forKey: .recoverable)
            error = nil
        }
        
        init(message: String, error: Error?, timestamp: Date, recoverable: Bool) {
            self.message = message
            self.error = error
            self.timestamp = timestamp
            self.recoverable = recoverable
        }
    }
    
    struct RetryInfo: Codable {
        let attempt: Int
        let maxAttempts: Int
        let reason: String
        let nextRetryDate: Date
    }
    
    private enum CodingKeys: String, CodingKey {
        case type
        case info
    }
    
    private enum StatusType: String, Codable {
        case waiting
        case preparing
        case downloading
        case paused
        case completed
        case failed
        case retrying
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .waiting:
            try container.encode(StatusType.waiting, forKey: .type)
        case .preparing(let info):
            try container.encode(StatusType.preparing, forKey: .type)
            try container.encode(info, forKey: .info)
        case .downloading(let info):
            try container.encode(StatusType.downloading, forKey: .type)
            try container.encode(info, forKey: .info)
        case .paused(let info):
            try container.encode(StatusType.paused, forKey: .type)
            try container.encode(info, forKey: .info)
        case .completed(let info):
            try container.encode(StatusType.completed, forKey: .type)
            try container.encode(info, forKey: .info)
        case .failed(let info):
            try container.encode(StatusType.failed, forKey: .type)
            try container.encode(info, forKey: .info)
        case .retrying(let info):
            try container.encode(StatusType.retrying, forKey: .type)
            try container.encode(info, forKey: .info)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)
        
        switch type {
        case .waiting:
            self = .waiting
        case .preparing:
            let info = try container.decode(PrepareInfo.self, forKey: .info)
            self = .preparing(info)
        case .downloading:
            let info = try container.decode(DownloadInfo.self, forKey: .info)
            self = .downloading(info)
        case .paused:
            let info = try container.decode(PauseInfo.self, forKey: .info)
            self = .paused(info)
        case .completed:
            let info = try container.decode(CompletionInfo.self, forKey: .info)
            self = .completed(info)
        case .failed:
            let info = try container.decode(FailureInfo.self, forKey: .info)
            self = .failed(info)
        case .retrying:
            let info = try container.decode(RetryInfo.self, forKey: .info)
            self = .retrying(info)
        }
    }
    
    var description: String {
        switch self {
        case .waiting:
            return NSLocalizedString("等待中", value: "等待中", comment: "Download status waiting")
        case .preparing(let info):
            return String(format: NSLocalizedString("准备中: %@", value: "准备中: %@", comment: "Download status preparing"), info.message)
        case .downloading(let info):
            return String(format: NSLocalizedString("正在下载 %@ (%d/%d)", value: "正在下载 %@ (%d/%d)", comment: "Download status downloading"),
                        info.fileName, info.currentPackageIndex + 1, info.totalPackages)
        case .paused(let info):
            switch info.reason {
            case .userRequested:
                return NSLocalizedString("已暂停", value: "已暂停", comment: "Download status paused")
            case .networkIssue:
                return NSLocalizedString("网络中断", value: "网络中断", comment: "Download status network paused")
            case .systemSleep:
                return NSLocalizedString("系统休眠", value: "系统休眠", comment: "Download status system sleep")
            case .other(let reason):
                return String(format: NSLocalizedString("已暂停: %@", value: "已暂停: %@", comment: "Download status paused with reason"), reason)
            }
        case .completed(let info):
            return String(format: NSLocalizedString("已完成 (用时: %@)", value: "已完成 (用时: %@)", comment: "Download status completed"),
                        info.totalTime.formatDuration())
        case .failed(let info):
            return String(format: NSLocalizedString("失败: %@", value: "失败: %@", comment: "Download status failed"),
                        info.message)
        case .retrying(let info):
            return String(format: NSLocalizedString("重试中 (%d/%d)", value: "重试中 (%d/%d)", comment: "Download status retrying"),
                        info.attempt, info.maxAttempts)
        }
    }
    
    var sortOrder: Int {
        switch self {
        case .downloading: return 0
        case .preparing: return 1
        case .waiting: return 2
        case .paused: return 3
        case .retrying: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }
    
    var isActive: Bool {
        switch self {
        case .downloading, .preparing, .waiting, .retrying:
            return true
        default:
            return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed:
            return true
        default:
            return false
        }
    }
    
    var canRetry: Bool {
        if case .failed(let info) = self {
            return info.recoverable
        }
        return false
    }
    
    var canPause: Bool {
        switch self {
        case .downloading, .preparing, .waiting:
            return true
        default:
            return false
        }
    }
    
    var canResume: Bool {
        if case .paused(let info) = self {
            return info.resumable
        }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
    
    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

extension DownloadStatus.PrepareInfo: Equatable {}
extension DownloadStatus.PrepareInfo.PrepareStage: Equatable {}
extension DownloadStatus.PauseInfo.PauseReason: Equatable {}
extension DownloadStatus.DownloadInfo: Equatable {}
extension DownloadStatus.PauseInfo: Equatable {}
extension DownloadStatus.CompletionInfo: Equatable {}
extension DownloadStatus.RetryInfo: Equatable {}

extension DownloadStatus.FailureInfo: Equatable {
    static func == (lhs: DownloadStatus.FailureInfo, rhs: DownloadStatus.FailureInfo) -> Bool {
        return lhs.message == rhs.message &&
               lhs.timestamp == rhs.timestamp &&
               lhs.recoverable == rhs.recoverable
    }
}

enum LoadingState: Equatable {
    case idle
    case loading
    case failed(Error)
    case success
    
    static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.success, .success):
            return true
        case let (.failed(lError), .failed(rError)):
            return lError.localizedDescription == rError.localizedDescription
        default:
            return false
        }
    }
}

private extension TimeInterval {
    func formatDuration() -> String {
        let hours = Int(self / 3600)
        let minutes = Int((self.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = Int(self.truncatingRemainder(dividingBy: 60))
        return String(format: NSLocalizedString("%02d:%02d:%02d", comment: ""), hours, minutes, seconds)
    }
} 

enum CleanupOption: String, CaseIterable, Identifiable {
    case adobeApps = "Adobe 应用程序"
    case adobeCreativeCloud = "Adobe Creative Cloud"
    case adobeUserData = "Adobe 用户数据"
    case adobePreferences = "Adobe 偏好设置"
    case adobeCaches = "Adobe 缓存文件"
    case adobeLicenses = "Adobe 许可文件"
    case adobeLogs = "Adobe 日志文件"
    case adobeServices = "Adobe 服务"
    case adobeKeychain = "Adobe 钥匙串"
    case adobeGenuineService = "Adobe 正版验证服务"
    case adobeHosts = "Adobe Hosts"
    case c4dRedGiant = "C4D / Red Giant"

    var id: String { self.rawValue }

    var localizedName: String {
        switch self {
        case .adobeApps:
            return String(localized: "Adobe 应用程序")
        case .adobeCreativeCloud:
            return String(localized: "Adobe Creative Cloud")
        case .adobeUserData:
            return String(localized: "Adobe 用户数据")
        case .adobePreferences:
            return String(localized: "Adobe 偏好设置")
        case .adobeCaches:
            return String(localized: "Adobe 缓存文件")
        case .adobeLicenses:
            return String(localized: "Adobe 许可文件")
        case .adobeLogs:
            return String(localized: "Adobe 日志文件")
        case .adobeServices:
            return String(localized: "Adobe 服务")
        case .adobeKeychain:
            return String(localized: "Adobe 钥匙串")
        case .adobeGenuineService:
            return String(localized: "Adobe 正版验证服务")
        case .adobeHosts:
            return String(localized: "Adobe Hosts")
        case .c4dRedGiant:
            return String(localized: "C4D / Red Giant")
        }
    }

    static var executionOrder: [CleanupOption] {
        [
            .adobeServices,
            .adobeApps,
            .adobeCreativeCloud,
            .adobeUserData,
            .adobePreferences,
            .adobeCaches,
            .adobeLicenses,
            .adobeLogs,
            .adobeGenuineService,
            .adobeKeychain,
            .adobeHosts,
            .c4dRedGiant
        ]
    }

    static var defaultSelectedOptions: [CleanupOption] {
        allCases.filter { $0 != .c4dRedGiant }
    }

    var cleanupTargets: [CleanupTarget] {
        switch self {
        case .adobeApps:
            return [
                .glob(self, "/Applications/Adobe*", "Adobe 应用程序"),
                .glob(self, "/Applications/Utilities/Adobe*", "Adobe 实用工具"),
                .path(self, "/Applications/Adobe Creative Cloud", "Creative Cloud 应用"),
                .path(self, "/Applications/Utilities/Adobe Creative Cloud", "Creative Cloud 工具"),
                .path(self, "/Applications/Utilities/Adobe Creative Cloud Experience", "Creative Cloud Experience"),
                .path(self, "/Applications/Utilities/Adobe Installers/Uninstall Adobe Creative Cloud", "Creative Cloud 卸载器"),
                .path(self, "/Applications/Utilities/Adobe Sync", "Adobe Sync"),
                .path(self, "/Applications/Utilities/Adobe Genuine Service", "Adobe Genuine Service"),
                .glob(self, "/Applications/Acrobat*", "Acrobat 应用程序"),
                .glob(self, "/Applications/*Adobe*", "Adobe 应用程序"),
                .glob(self, "/Applications/Utilities/*Adobe*", "Adobe 实用工具"),
                .glob(self, "/Applications/Utilities/*Creative Cloud*", "Creative Cloud 实用工具")
            ] + Self.systemPathTargets(for: self)
        case .adobeCreativeCloud:
            return [
                .glob(self, "/Library/Application Support/Adobe*", "系统 Adobe Application Support"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/ADBox", "ADBox"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/ADS", "ADS"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/AppsPanel", "AppsPanel"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/CEF", "CEF"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/Core", "Core"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/CoreExt", "CoreExt"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/DEBox", "DEBox"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/ElevationManager", "ElevationManager"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/FilesPanel", "FilesPanel"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/FontsPanel", "FontsPanel"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/HEX", "HEX"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/LCC", "LCC"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/NHEX", "NHEX"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/Notifications", "Notifications"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/pim.db", "pim.db"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents", "RemoteComponents"),
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/TCC", "TCC"),
                .path(self, "/Library/Application Support/Adobe/ARMNext", "ARMNext"),
                .path(self, "/Library/Application Support/Adobe/ARMDC/Application", "ARMDC"),
                .path(self, "/Library/Application Support/Adobe/PII/com.adobe.pii.prefs", "PII prefs"),
                .glob(self, "/Library/Application Support/Adobe/ACPLocal*", "ACPLocal"),
                .path(self, "/Library/Application Support/regid.1986-12.com.adobe", "Adobe regid"),
                .glob(self, "/Library/Internet Plug-Ins/AdobePDF*", "Adobe PDF 插件"),
                .path(self, "/Library/Internet Plug-Ins/AdobeAAMDetect.plugin", "AdobeAAMDetect"),
                .glob(self, "/Library/PDF Services/Save as Adobe PDF*", "Save as Adobe PDF"),
                .path(self, "/Library/ScriptingAdditions/Adobe Unit Types.osax", "Adobe Unit Types"),
                .path(self, "/Library/Automator/Save as Adobe PDF.action", "Save as Adobe PDF action"),
                .glob(self, "/Library/Frameworks/Adobe*", "Adobe Frameworks"),
                .glob(self, "/Library/PreferencePanes/Flash*", "Flash PreferencePanes"),
                .glob(self, "/Library/Internet Plug-Ins/Flash*", "Flash Plug-Ins"),
                .glob(self, "/Library/Application Support/Macromedia*", "Macromedia Application Support"),
                .path(self, "/usr/local/bin/RemoteUpdateManager", "RemoteUpdateManager"),
                .path(self, "{USER_HOME}/Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj", "Acrobat Chrome 扩展"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/Google/Chrome/*/Extensions/efaidnbmnnnibpcajpcglclefindmkaj", "Acrobat Chrome 多配置扩展"),
                .path(self, "{USER_HOME}/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint/SaveAsAdobePDF.ppam", "Office SaveAsAdobePDF 插件"),
                .path(self, "{USER_HOME}/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/linkCreation.dotm", "Office Adobe PDF 插件"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/*/*Adobe*", "Office Adobe PDF 插件"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/*/linkCreation.dotm", "Office linkCreation 插件")
            ]
        case .adobeUserData:
            return [
                .path(self, "{USER_HOME}/.adobe", ".adobe"),
                .path(self, "{ALL_USER_HOME}/.adobe", "多用户 .adobe"),
                .glob(self, "{USER_HOME}/Creative Cloud Files*", "Creative Cloud Files"),
                .glob(self, "{ALL_USER_HOME}/Creative Cloud Files*", "多用户 Creative Cloud Files"),
                .glob(self, "{USER_HOME}/Library/Application Scripts/*Adobe*", "Adobe Application Scripts"),
                .glob(self, "{USER_HOME}/Library/Application Scripts/*com.adobe*", "com.adobe Application Scripts"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Scripts/*Adobe*", "多用户 Adobe Application Scripts"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Scripts/*com.adobe*", "多用户 com.adobe Application Scripts"),
                .path(self, "{USER_HOME}/Library/Application Scripts/Adobe-Hub-App", "Adobe Hub App Scripts"),
                .glob(self, "{USER_HOME}/Library/Application Support/Adobe*", "Adobe Application Support"),
                .glob(self, "{USER_HOME}/Library/Application Support/com.adobe*", "com.adobe Application Support"),
                .glob(self, "{USER_HOME}/Library/Application Support/Acrobat*", "Acrobat Application Support"),
                .path(self, "{USER_HOME}/Library/Application Support/AAMUpdater", "AAMUpdater"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe-Hub-App", "Adobe Hub App"),
                .glob(self, "{USER_HOME}/Library/Application Support/AdobeUXP*", "AdobeUXP"),
                .glob(self, "{USER_HOME}/Library/Application Support/AdobeGC*", "AdobeGC 用户数据"),
                .glob(self, "{USER_HOME}/Library/Application Support/Creative Cloud*", "Creative Cloud 用户数据"),
                .glob(self, "{USER_HOME}/Library/Application Support/CCX*", "CCX 用户数据"),
                .glob(self, "{USER_HOME}/Library/Application Support/CEF*", "CEF 用户数据"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/Adobe*", "多用户 Adobe Application Support"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/com.adobe*", "多用户 com.adobe Application Support"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/Acrobat*", "多用户 Acrobat Application Support"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/AAMUpdater*", "多用户 AAMUpdater"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/AdobeUXP*", "多用户 AdobeUXP"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/AdobeGC*", "多用户 AdobeGC 用户数据"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/Creative Cloud*", "多用户 Creative Cloud 用户数据"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/CCX*", "多用户 CCX 用户数据"),
                .glob(self, "{ALL_USER_HOME}/Library/Application Support/CEF*", "多用户 CEF 用户数据"),
                .path(self, "{USER_HOME}/Library/Application Support/io.branch", "Adobe branch data"),
                .glob(self, "{USER_HOME}/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.adobe*", "Adobe Recent Documents"),
                .glob(self, "{USER_HOME}/Library/Containers/*adobe*", "Adobe Containers"),
                .glob(self, "{USER_HOME}/Library/Containers/com.adobe*", "com.adobe Containers"),
                .glob(self, "{ALL_USER_HOME}/Library/Containers/*adobe*", "多用户 Adobe Containers"),
                .glob(self, "{ALL_USER_HOME}/Library/Containers/com.adobe*", "多用户 com.adobe Containers"),
                .glob(self, "{USER_HOME}/Library/Group Containers/*Adobe*", "Adobe Group Containers"),
                .glob(self, "{USER_HOME}/Library/Group Containers/*com.adobe*", "com.adobe Group Containers"),
                .glob(self, "{USER_HOME}/Library/Group Containers/JQ525L2MZD.com.adobe*", "Adobe NGL Group Container"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/*Adobe*", "多用户 Adobe Group Containers"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/*com.adobe*", "多用户 com.adobe Group Containers"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/JQ525L2MZD.com.adobe*", "多用户 Adobe NGL Group Container"),
                .path(self, "{USER_HOME}/Library/Group Containers/Adobe-Hub-App", "Adobe Hub App Group Container"),
                .glob(self, "{USER_HOME}/Library/WebKit/*adobe*", "Adobe WebKit"),
                .glob(self, "{USER_HOME}/Library/WebKit/com.adobe*", "com.adobe WebKit"),
                .glob(self, "{USER_HOME}/Library/WebKit/Databases/___IndexedDB/com.Adobe*", "Adobe IndexedDB"),
                .glob(self, "{ALL_USER_HOME}/Library/WebKit/*adobe*", "多用户 Adobe WebKit"),
                .glob(self, "{ALL_USER_HOME}/Library/WebKit/com.adobe*", "多用户 com.adobe WebKit"),
                .glob(self, "{ALL_USER_HOME}/Library/WebKit/Databases/___IndexedDB/com.Adobe*", "多用户 Adobe IndexedDB"),
                .path(self, "{USER_HOME}/Library/NGL", "NGL"),
                .path(self, "{ALL_USER_HOME}/Library/NGL", "多用户 NGL"),
                .path(self, "{USER_HOME}/Library/PhotoshopCrashes", "Photoshop Crashes"),
                .path(self, "{USER_HOME}/Documents/Adobe", "Adobe Documents"),
                .path(self, "{ALL_USER_HOME}/Documents/Adobe", "多用户 Adobe Documents"),
                .glob(self, "{ALL_USER_HOME}/Library/Metadata/CoreSpotlight/*adobe*", "Adobe CoreSpotlight 元数据", recursive: true, maxDepth: 6),
                .glob(self, "/Users/Shared/Adobe*", "Shared Adobe"),
                .path(self, "/Users/Shared/NGL", "Shared NGL")
            ]
        case .adobePreferences:
            return [
                .glob(self, "/Library/Preferences/com.adobe*", "系统 Adobe 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/com.adobe*", "用户 com.adobe 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/Adobe*", "用户 Adobe 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/com.adobe*", "多用户 com.adobe 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/Adobe*", "多用户 Adobe 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/*Lightroom*", "Lightroom 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/*Lightroom*", "多用户 Lightroom 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/ByHost/com.adobe*", "ByHost Adobe 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/ByHost/com.adobe*", "多用户 ByHost Adobe 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/adobe.com*", "adobe.com 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/AIRobin*", "AIRobin 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Preferences/Macromedia*", "Macromedia 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/adobe.com*", "多用户 adobe.com 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/AIRobin*", "多用户 AIRobin 偏好设置"),
                .glob(self, "{ALL_USER_HOME}/Library/Preferences/Macromedia*", "多用户 Macromedia 偏好设置"),
                .glob(self, "{USER_HOME}/Library/Saved Application State/com.adobe*", "Adobe Saved State"),
                .glob(self, "{USER_HOME}/Library/Saved Application State/*adobe*", "Adobe Saved State"),
                .glob(self, "{ALL_USER_HOME}/Library/Saved Application State/com.adobe*", "多用户 Adobe Saved State"),
                .glob(self, "{ALL_USER_HOME}/Library/Saved Application State/*adobe*", "多用户 Adobe Saved State")
            ] + Self.userPathTargets(for: self)
        case .adobeCaches:
            return [
                .glob(self, "{USER_HOME}/Library/Caches/Adobe*", "Adobe 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/adobe*", "adobe 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/com.adobe*", "com.adobe 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/Adobe*", "多用户 Adobe 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/adobe*", "多用户 adobe 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/com.adobe*", "多用户 com.adobe 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/Acrobat*", "Acrobat 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/AI_*", "Illustrator 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/Acrobat*", "多用户 Acrobat 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/AI_*", "多用户 Illustrator 缓存"),
                .path(self, "{USER_HOME}/Library/Caches/CSXS", "CSXS 缓存"),
                .path(self, "{USER_HOME}/Library/Caches/UXPLogs", "UXPLogs 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/com.crashlytics.data/com.adobe*", "Adobe Crashlytics 缓存"),
                .glob(self, "{USER_HOME}/Library/Caches/com.apple.nsurlsessiond/Downloads/*adobe*", "Adobe nsurlsessiond 缓存"),
                .glob(self, "{ALL_USER_HOME}/Library/Caches/com.apple.nsurlsessiond/Downloads/*adobe*", "多用户 Adobe nsurlsessiond 缓存"),
                .glob(self, "/Library/Caches/*Adobe*", "系统 Adobe 缓存"),
                .glob(self, "/Library/Caches/*adobe*", "系统 adobe 缓存"),
                .glob(self, "/Library/Caches/Acrobat*", "系统 Acrobat 缓存"),
                .glob(self, "/Library/Caches/AI_*", "系统 Illustrator 缓存"),
                .glob(self, "/Library/Caches/com.apple.nsurlsessiond/Downloads/*adobe*", "系统 Adobe nsurlsessiond 缓存"),
                .path(self, "/Library/Caches/com.crashlytics.data", "系统 Crashlytics 缓存"),
                .glob(self, "{USER_HOME}/Library/Cookies/com.adobe*", "Adobe Cookies"),
                .glob(self, "{USER_HOME}/Library/Cookies/*adobe*", "Adobe Cookies"),
                .glob(self, "{ALL_USER_HOME}/Library/Cookies/com.adobe*", "多用户 Adobe Cookies"),
                .glob(self, "{ALL_USER_HOME}/Library/Cookies/*adobe*", "多用户 Adobe Cookies"),
                .glob(self, "{USER_HOME}/Library/HTTPStorages/*Adobe*", "Adobe HTTPStorages"),
                .glob(self, "{USER_HOME}/Library/HTTPStorages/com.adobe*", "com.adobe HTTPStorages"),
                .glob(self, "{USER_HOME}/Library/HTTPStorages/*adobe*", "adobe HTTPStorages"),
                .glob(self, "{ALL_USER_HOME}/Library/HTTPStorages/*Adobe*", "多用户 Adobe HTTPStorages"),
                .glob(self, "{ALL_USER_HOME}/Library/HTTPStorages/com.adobe*", "多用户 com.adobe HTTPStorages"),
                .glob(self, "{ALL_USER_HOME}/Library/HTTPStorages/*adobe*", "多用户 adobe HTTPStorages"),
                .path(self, "{USER_HOME}/Library/HTTPStorages/Creative Cloud Content Manager.node", "Creative Cloud HTTPStorage"),
                .glob(self, "/private/tmp/*adobe*", "Adobe 临时文件"),
                .glob(self, "/private/tmp/*Adobe*", "Adobe 临时文件"),
                .glob(self, "/private/tmp/.adobe*", "隐藏 Adobe 临时文件"),
                .glob(self, "/private/tmp/*CCLBS*", "CCLBS 临时文件"),
                .glob(self, "/private/var/folders/*adobe*", "Adobe var 临时文件", recursive: true, maxDepth: 10),
                .glob(self, "/private/var/folders/*Adobe*", "Adobe var 临时文件", recursive: true, maxDepth: 10),
                .glob(self, "/private/var/folders/*CCLBS*", "CCLBS var 临时文件", recursive: true, maxDepth: 10)
            ]
        case .adobeLicenses:
            return [
                .path(self, "/Library/Application Support/Adobe/Adobe PCD", "Adobe PCD"),
                .path(self, "/Library/Application Support/Adobe/SLCache", "SLCache"),
                .path(self, "/Library/Application Support/Adobe/SLStore", "SLStore"),
                .path(self, "/Library/Application Support/Adobe/OOBE", "系统 OOBE"),
                .path(self, "/Library/Application Support/Adobe/IMS", "系统 IMS"),
                .path(self, "/Library/Application Support/Adobe/OperatingConfigs", "OperatingConfigs"),
                .path(self, "/Library/Application Support/Adobe/Activation", "Activation"),
                .path(self, "/Library/Application Support/Adobe/AdobeGCClient", "AdobeGCClient"),
                .glob(self, "/Library/Application Support/Adobe/AdobeGC*", "AdobeGC"),
                .glob(self, "/Library/Application Support/Adobe/Adobe Desktop Common/AdobeGenuine*", "Adobe Genuine"),
                .path(self, "/Library/Application Support/regid.1986-12.com.adobe", "Adobe regid"),
                .path(self, "/Users/Shared/Adobe/SLCache", "Shared SLCache"),
                .path(self, "/Users/Shared/Adobe/SLStore", "Shared SLStore"),
                .path(self, "/Users/Shared/Adobe/OOBE", "Shared OOBE"),
                .path(self, "/Users/Shared/Adobe/IMS", "Shared IMS"),
                .path(self, "/Users/Shared/Adobe/NGL", "Shared Adobe NGL"),
                .path(self, "/Users/Shared/NGL", "Shared NGL"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe/OOBE", "用户 OOBE"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe/IMS", "用户 IMS"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe/SLCache", "用户 SLCache"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe/SLStore", "用户 SLStore"),
                .path(self, "{USER_HOME}/Library/Application Support/Adobe/OperatingConfigs", "用户 OperatingConfigs"),
                .path(self, "{USER_HOME}/Library/NGL", "用户 NGL"),
                .glob(self, "{USER_HOME}/Library/Group Containers/JQ525L2MZD.com.adobe.NGL*", "用户 NGL Group Container"),
                .path(self, "{ALL_USER_HOME}/Library/Application Support/Adobe/OOBE", "多用户 OOBE"),
                .path(self, "{ALL_USER_HOME}/Library/Application Support/Adobe/IMS", "多用户 IMS"),
                .path(self, "{ALL_USER_HOME}/Library/Application Support/Adobe/SLCache", "多用户 SLCache"),
                .path(self, "{ALL_USER_HOME}/Library/Application Support/Adobe/SLStore", "多用户 SLStore"),
                .path(self, "{ALL_USER_HOME}/Library/Application Support/Adobe/OperatingConfigs", "多用户 OperatingConfigs"),
                .path(self, "{ALL_USER_HOME}/Library/NGL", "多用户 NGL"),
                .glob(self, "{ALL_USER_HOME}/Library/Group Containers/JQ525L2MZD.com.adobe.NGL*", "多用户 NGL Group Container"),
                .glob(self, "/private/var/db/receipts/com.adobe*", "Adobe Receipts"),
                .glob(self, "/private/var/db/receipts/*Photoshop*", "Photoshop Receipts"),
                .glob(self, "/private/var/db/receipts/*CreativeCloud*", "CreativeCloud Receipts"),
                .glob(self, "/private/var/db/receipts/*CCXP*", "CCXP Receipts"),
                .glob(self, "/private/var/db/receipts/*mygreatcompany*", "mygreatcompany Receipts"),
                .glob(self, "/private/var/db/receipts/*AntiCC*", "AntiCC Receipts"),
                .glob(self, "/private/var/db/receipts/*.RiD.*", "RiD Receipts"),
                .glob(self, "/private/var/db/receipts/*.CCRuntime.*", "CCRuntime Receipts"),
                .shell(self, "/bin/sh -c '/usr/sbin/pkgutil --pkgs | /usr/bin/grep -i \"adobe\\|photoshop\\|illustrator\\|creativecloud\\|acrobat\\|ccx\\|coresync\\|ngl\\|agm\\|ags\" | /usr/bin/grep -vi \"adobe downloader\\|adobe-downloader\\|com.x1a0he\" | while IFS= read -r pkg; do /usr/sbin/pkgutil --forget \"$pkg\" >/dev/null 2>&1 || true; done'", "注销 Adobe 安装收据", kind: .shell)
            ]
        case .adobeLogs:
            return [
                .glob(self, "{USER_HOME}/Library/Logs/Adobe*", "Adobe 日志"),
                .glob(self, "{USER_HOME}/Library/Logs/adobe*", "adobe 日志"),
                .glob(self, "{ALL_USER_HOME}/Library/Logs/Adobe*", "多用户 Adobe 日志"),
                .glob(self, "{ALL_USER_HOME}/Library/Logs/adobe*", "多用户 adobe 日志"),
                .path(self, "{USER_HOME}/Library/Logs/Adobe Creative Cloud Cleaner Tool.log", "Creative Cloud Cleaner 日志"),
                .path(self, "{USER_HOME}/Library/Logs/CreativeCloud", "CreativeCloud 日志"),
                .path(self, "{ALL_USER_HOME}/Library/Logs/CreativeCloud", "多用户 CreativeCloud 日志"),
                .path(self, "/Library/Logs/CreativeCloud", "系统 CreativeCloud 日志"),
                .path(self, "{USER_HOME}/Library/Logs/CSXS", "CSXS 日志"),
                .path(self, "{USER_HOME}/Library/Logs/amt3.log", "amt3.log"),
                .path(self, "{USER_HOME}/Library/Logs/CoreSyncInstall.log", "CoreSyncInstall.log"),
                .glob(self, "{USER_HOME}/Library/Logs/CrashReporter/*Adobe*", "Adobe CrashReporter"),
                .glob(self, "{ALL_USER_HOME}/Library/Logs/CrashReporter/*Adobe*", "多用户 Adobe CrashReporter"),
                .path(self, "{USER_HOME}/Library/Logs/acroLicLog.log", "acroLicLog.log"),
                .path(self, "{USER_HOME}/Library/Logs/acroNGLLog.txt", "acroNGLLog.txt"),
                .glob(self, "{USER_HOME}/Library/Logs/DiagnosticReports/*Adobe*", "Adobe DiagnosticReports"),
                .glob(self, "{ALL_USER_HOME}/Library/Logs/DiagnosticReports/*Adobe*", "多用户 Adobe DiagnosticReports"),
                .path(self, "{USER_HOME}/Library/Logs/distNGLLog.txt", "distNGLLog.txt"),
                .glob(self, "{USER_HOME}/Library/Logs/NGL*", "NGL 日志"),
                .glob(self, "{ALL_USER_HOME}/Library/Logs/NGL*", "多用户 NGL 日志"),
                .path(self, "{USER_HOME}/Library/Logs/oobelib.log", "oobelib.log"),
                .glob(self, "{USER_HOME}/Library/Logs/PDApp*", "PDApp 日志"),
                .glob(self, "/Library/Logs/adobe*", "系统 adobe 日志"),
                .glob(self, "/Library/Logs/Adobe*", "系统 Adobe 日志"),
                .glob(self, "/Library/Logs/DiagnosticReports/*Adobe*", "系统 Adobe DiagnosticReports"),
                .glob(self, "/Library/Application Support/CrashReporter/*Adobe*", "系统 Adobe CrashReporter"),
                .glob(self, "{USER_HOME}/Library/Application Support/CrashReporter/*Adobe*", "用户 Adobe CrashReporter"),
                .shell(self, "/bin/sh -c '/usr/bin/find /Applications /Library \"{ALL_USER_HOME}/Library\" /Users/Shared -maxdepth 4 \\( -iname \"*adobe*\" -o -iname \"*creative cloud*\" -o -iname \"*acrobat*\" -o -iname \"*ngl*\" -o -iname \"*ccx*\" \\) 2>/dev/null | /usr/bin/grep -vi \"Adobe Downloader\\|Adobe-Downloader\\|com.x1a0he\" | /usr/bin/head -n 80 || true'", "扫描 Adobe 残留", kind: .shell)
            ]
        case .adobeServices:
            return Self.safeAdobeProcessNames.map {
                .shell(self, "/usr/bin/killall -9 \"\($0)\" 2>/dev/null || true", "终止 \($0)", kind: .process)
            } + [
                .shell(self, "/bin/ps axo pid,command | /usr/bin/grep -i 'Adobe' | /usr/bin/grep -v 'Adobe Downloader' | /usr/bin/grep -v 'Adobe-Downloader.helper' | /usr/bin/grep -v grep | /usr/bin/awk '{print $1}' | /usr/bin/xargs /bin/kill -9 2>/dev/null || true", "终止 Adobe 相关进程", kind: .process),
                .shell(self, "/bin/ps axo pid,command | /usr/bin/grep -i 'node' | /usr/bin/grep -iE 'Adobe|Creative Cloud|com\\.adobe' | /usr/bin/grep -v 'Adobe Downloader' | /usr/bin/grep -v grep | /usr/bin/awk '{print $1}' | /usr/bin/xargs /bin/kill -9 2>/dev/null || true", "终止 Adobe node 进程", kind: .process),
                .shell(self, "/bin/launchctl bootout gui/{USER_UID} /Library/LaunchAgents/com.adobe.* 2>/dev/null || true", "卸载系统 Adobe LaunchAgent", kind: .launchctl),
                .shell(self, "/bin/launchctl bootout gui/{USER_UID} {USER_HOME}/Library/LaunchAgents/com.adobe.* 2>/dev/null || true", "卸载用户 Adobe LaunchAgent", kind: .launchctl),
                .shell(self, "/bin/launchctl bootout system /Library/LaunchDaemons/com.adobe.* 2>/dev/null || true", "卸载 Adobe LaunchDaemon", kind: .launchctl),
                .shell(self, "/bin/launchctl bootout system /Library/LaunchDaemons/*adobe* 2>/dev/null || true", "卸载通配 Adobe LaunchDaemon", kind: .launchctl),
                .shell(self, "/bin/launchctl bootout gui/{ALL_USER_UID} {ALL_USER_HOME}/Library/LaunchAgents/*adobe* 2>/dev/null || true", "卸载多用户通配 Adobe LaunchAgent", kind: .launchctl),
                .shell(self, "/bin/launchctl remove com.adobe.AdobeCreativeCloud 2>/dev/null || true", "移除 Creative Cloud 服务", kind: .launchctl),
                .shell(self, "/bin/launchctl remove com.adobe.AdobeGenuineService.plist 2>/dev/null || true", "移除 Genuine Service", kind: .launchctl),
                .shell(self, "/bin/sh -c '/bin/launchctl print system 2>/dev/null | /usr/bin/grep -io \"com\\.adobe[^ ]*\" | /usr/bin/sort -u | while IFS= read -r label; do /bin/launchctl bootout system \"$label\" >/dev/null 2>&1 || /bin/launchctl remove \"$label\" >/dev/null 2>&1 || true; done'", "动态卸载系统 Adobe 服务", kind: .launchctl),
                .shell(self, "/bin/sh -c '/bin/launchctl print gui/{ALL_USER_UID} 2>/dev/null | /usr/bin/grep -io \"com\\.adobe[^ ]*\" | /usr/bin/sort -u | while IFS= read -r label; do /bin/launchctl bootout gui/{ALL_USER_UID} \"$label\" >/dev/null 2>&1 || /bin/launchctl remove \"$label\" >/dev/null 2>&1 || true; done'", "动态卸载用户 Adobe 服务", kind: .launchctl),
                .glob(self, "/Library/LaunchAgents/com.adobe.*", "系统 Adobe LaunchAgents"),
                .glob(self, "/Library/LaunchAgents/*adobe*", "系统通配 Adobe LaunchAgents"),
                .glob(self, "/Library/LaunchDaemons/com.adobe.*", "Adobe LaunchDaemons"),
                .glob(self, "/Library/LaunchDaemons/*adobe*", "通配 Adobe LaunchDaemons"),
                .glob(self, "{USER_HOME}/Library/LaunchAgents/com.adobe.*", "用户 Adobe LaunchAgents"),
                .glob(self, "{ALL_USER_HOME}/Library/LaunchAgents/com.adobe.*", "多用户 Adobe LaunchAgents"),
                .glob(self, "{ALL_USER_HOME}/Library/LaunchAgents/*adobe*", "多用户通配 Adobe LaunchAgents"),
                .glob(self, "/Library/LaunchAgents/com.adobe.ARMDCHelper*", "ARMDCHelper LaunchAgent"),
                .path(self, "/Library/LaunchAgents/com.adobe.AdobeCreativeCloud.plist", "Creative Cloud LaunchAgent"),
                .path(self, "/Library/LaunchAgents/com.adobe.ccxprocess.plist", "CCXProcess LaunchAgent")
            ]
        case .adobeKeychain:
            return [
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe App Info"), "Adobe App Info", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe App Prefetched Info"), "Adobe App Prefetched Info", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe User"), "Adobe User", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe Profile Info"), "Adobe Profile Info", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe User Info"), "Adobe User Info", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe User OS Info"), "Adobe User OS Info", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe Proxy Username"), "Adobe Proxy Username", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe Proxy Password"), "Adobe Proxy Password", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-l", value: "Adobe.APS"), "Adobe APS", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "internet-password", matchFlag: "-s", value: "services.acrobat.com"), "Acrobat Services", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "certificate", matchFlag: "-c", value: "Adobe Content Certificate"), "Adobe Content Certificate", kind: .keychain),
                .shell(self, Self.userKeychainDeleteCommand(itemClass: "certificate", matchFlag: "-c", value: "Adobe Intermediate CA"), "Adobe Intermediate CA", kind: .keychain),
                .shell(self, Self.dynamicKeychainDeleteCommand(keychain: "{ALL_USER_LOGIN_KEYCHAIN}", userUID: "{ALL_USER_UID}", itemClass: "generic-password"), "动态删除用户 Adobe 密码项", kind: .keychain),
                .shell(self, Self.dynamicKeychainDeleteCommand(keychain: "{ALL_USER_LOGIN_KEYCHAIN}", userUID: "{ALL_USER_UID}", itemClass: "certificate"), "动态删除用户 Adobe 证书", kind: .keychain),
                .shell(self, Self.systemKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe App Info"), "系统 Adobe App Info", kind: .keychain),
                .shell(self, Self.systemKeychainDeleteCommand(itemClass: "generic-password", matchFlag: "-s", value: "Adobe User"), "系统 Adobe User", kind: .keychain),
                .shell(self, Self.systemKeychainDeleteCommand(itemClass: "certificate", matchFlag: "-c", value: "Adobe Content Certificate"), "系统 Adobe Content Certificate", kind: .keychain),
                .shell(self, Self.dynamicKeychainDeleteCommand(keychain: "/Library/Keychains/System.keychain", itemClass: "generic-password"), "动态删除系统 Adobe 密码项", kind: .keychain),
                .shell(self, Self.dynamicKeychainDeleteCommand(keychain: "/Library/Keychains/System.keychain", itemClass: "certificate"), "动态删除系统 Adobe 证书", kind: .keychain)
            ]
        case .adobeGenuineService:
            return [
                .path(self, "/Library/Application Support/Adobe/Adobe Desktop Common/AdobeGenuineClient", "AdobeGenuineClient"),
                .path(self, "/Library/Application Support/Adobe/AdobeGCClient", "AdobeGCClient"),
                .path(self, "/Library/Preferences/com.adobe.AdobeGenuineService.plist", "Adobe Genuine Service plist"),
                .path(self, "/Applications/Utilities/Adobe Creative Cloud/Utils/AdobeGenuineValidator", "AdobeGenuineValidator"),
                .path(self, "/Applications/Utilities/Adobe Genuine Service", "Adobe Genuine Service"),
                .glob(self, "/Library/PrivilegedHelperTools/com.adobe.acc*", "Adobe ACC Helper"),
                .glob(self, "/Library/PrivilegedHelperTools/com.adobe*", "Adobe Privileged Helper"),
                .glob(self, "/Library/Application Support/Adobe/AdobeGC*", "AdobeGC"),
                .glob(self, "/Library/Application Support/Adobe/Adobe Desktop Common/AdobeGenuine*", "Adobe Genuine Client")
            ]
        case .adobeHosts:
            return [
                .shell(self, "/bin/sh -c '/usr/bin/grep -vi \"adobe\" /etc/hosts | /usr/bin/grep -vi \"hstatic.io\" > /etc/hosts.adobe-downloader.tmp && /bin/mv /etc/hosts.adobe-downloader.tmp /etc/hosts'", "清理 hosts Adobe 条目", kind: .hosts)
          ]
        case .c4dRedGiant:
            return Self.safeC4DProcessNames.map {
                .shell(self, "/usr/bin/killall -9 \"\($0)\" 2>/dev/null || true", "终止 \($0)", kind: .process)
            } + Self.c4dPathTargets(for: self)
        }
    }

    private static let unsafeProcessNames = [
        "node",
        "Commandline"
    ]

    private static var safeAdobeProcessNames: [String] {
        adobeProcessNames.filter { !unsafeProcessNames.contains($0) }
    }

    private static var safeC4DProcessNames: [String] {
        c4dProcessNames.filter { !unsafeProcessNames.contains($0) }
    }

    private static let adobeProcessNames = [
        "Creative Cloud Uninstaller",
        "Adobe Creative Cloud Cleaner Tool",
        "Adobe Desktop Service",
        "AdobeIPCBroker",
        "Core Sync Helper",
        "Core Sync",
        "ACCFinderSync",
        "Creative Cloud",
        "Creative Cloud Content Manager.node",
        "Creative Cloud Libraries Synchronizer",
        "Creative Cloud Helper",
        "Creative Cloud UI Helper",
        "Creative Cloud UI Helper (GPU)",
        "Creative Cloud UI Helper (Renderer)",
        "CCXProcess",
        "CCLibrary",
        "Adobe Content",
        "Adobe Content Synchronizer",
        "node",
        "armsvc",
        "AGSService",
        "AGMService",
        "AdobeCRDaemon",
        "AcroCEF",
        "Adobe CEF Helper",
        "Adobe CEF Helper (GPU)",
        "Adobe CEF Helper (Renderer)",
        "AdobeExtensionsService",
        "AdobeResourceSynchronizer",
        "AdobeGCClient",
        "Adobe Installer",
        "com.adobe",
        "com.adobe.acc.installer.v2",
        "com.adobe.ARMDC.Communicator",
        "com.adobe.ARMDC.SMJobBlessHelper",
        "Adobe Acrobat Synchronizer",
        "Adobe FormsCentral",
        "Adobe Genuine Software Monitor Service",
        "Acrobat Uninstaller",
        "Acrobat",
        "Acrobat Reader",
        "Acrobat Pro DC",
        "AdobeAcrobat",
        "Adobe Reader",
        "Distiller",
        "After Effects",
        "After Effects (Beta)",
        "TeamProjectsLocalHub",
        "Adobe AIR",
        "Animate",
        "Adobe Animate 2024",
        "Adobe Animate 2023",
        "Animate CC",
        "Audition",
        "Adobe Audition 2025",
        "Adobe Audition 2024",
        "Adobe Audition CC",
        "Adobe Audition (Beta)",
        "Adobe Bridge",
        "Adobe Bridge 2026",
        "Adobe Bridge 2025",
        "Adobe Bridge 2024",
        "Adobe Bridge CC",
        "Adobe Bridge CS6",
        "Adobe Bridge (Beta)",
        "Character Animator",
        "Character Animator (Beta)",
        "Device Central",
        "Dimension",
        "Adobe Dimension",
        "Dreamweaver",
        "Dreamweaver CC",
        "Edge Animate",
        "Edge Inspect",
        "Edge Reflow",
        "Edge Code",
        "Encore",
        "Extension Manager",
        "Fireworks",
        "Flash",
        "Flash CC",
        "Flash Player",
        "FrameMaker",
        "Fuse",
        "GoLive",
        "ImageReady",
        "AIRobin",
        "Illustrator",
        "Illustrator CC",
        "Adobe Illustrator",
        "InCopy",
        "Adobe InCopy 2026",
        "Adobe InCopy 2025",
        "Adobe InCopy 2024",
        "InDesign",
        "Adobe InDesign 2026",
        "Adobe InDesign 2025",
        "Adobe InDesign 2024",
        "InDesign CC",
        "Adobe InDesign 2026 (Beta)",
        "Adobe InDesign 2025 (Beta)",
        "Adobe InDesign 2024 (Beta)",
        "Lightroom",
        "Adobe Lightroom Classic",
        "Adobe Lightroom",
        "LiveMotion",
        "Media Encoder",
        "Adobe Media Encoder 2025",
        "Adobe Media Encoder 2024",
        "Adobe Media Encoder CC",
        "Adobe Media Encoder CS6",
        "Adobe Media Encoder (Beta)",
        "Muse",
        "Adobe Muse CC",
        "PageMill",
        "Photoshop",
        "Adobe Photoshop 2026",
        "Adobe Photoshop 2025",
        "Adobe Photoshop 2024",
        "Photoshop CC",
        "Prelude",
        "Prelude CC",
        "Premiere",
        "Adobe Premiere Pro 2025",
        "Adobe Premiere Pro 2024",
        "Premiere Pro CC",
        "Premiere Pro",
        "Adobe Premiere Pro (Beta)",
        "Premiere Rush",
        "Adobe Premiere Rush",
        "SpeedGrade",
        "SpeedGrade CC",
        "Substance 3D",
        "Adobe Substance 3D Designer",
        "Adobe Substance 3D Painter",
        "Adobe Substance 3D Sampler",
        "Adobe Substance 3D Stager",
        "Version Cue",
        "Adobe UXP Developer Tools",
        "Adobe XD",
        "AdobeCrashReport",
        "crashpad_handler",
        "Adobe Crash",
        "Adobe Crash Processor",
        "Adobe Crash Reporter",
        "Adobe Crash Handler"
    ]

    private static let systemPathTemplates = [
        "/Library/Application Support/Adobe*",
        "/Library/Application Support/CrashReporter/Adobe*",
        "/Library/Application Support/Macromedia*",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Excel/AcrobatExcelAddin.xlam",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Excel/~\\$*batExcelAddin.xlam",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Powerpoint/SaveAsAdobePDF.ppam",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Powerpoint/~\\$*AsAdobePDF.ppam",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Word/linkCreation.dotm",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup/Word/~\\$*Creation.dotm",
        "/Library/Application Support/Mozilla/Extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}",
        "/Library/Application Support/Mozilla/NativeMessagingHosts/.DC",
        "/Library/Application Support/Mozilla/NativeMessagingHosts/*adobe*",
        "/Library/Application Support/regid*adobe*",
        "/Library/Application Support/Uninst-*.log",
        "/Library/Automator/Save as Adobe PDF.action",
        "/Library/Caches/*adobe*",
        "/Library/Frameworks/Adobe*",
        "/Library/Google/Chrome/NativeMessagingHosts/*adobe*",
        "/Library/InstallerSandboxes/.PKInstallSandboxManager/*/Boms/*adobe*",
        "/Library/Internet Plug-Ins/Adobe*",
        "/Library/Internet Plug-Ins/Flash*",
        "/Library/Internet Plug-Ins/flash*",
        "/Library/LaunchAgents/*adobe*",
        "/Library/LaunchDaemons/*adobe*",
        "/Library/Logs/Adobe*",
        "/Library/Logs/adobe*",
        "/Library/Logs/CreativeCloud",
        "/Library/Logs/DiagnosticReports/Adobe*",
        "/Library/Logs/DiagnosticReports/Creative Cloud Content Manager.node*",
        "/Library/Logs/DiagnosticReports/After Effects*",
        "/Library/Logs/DiagnosticReports/RemoteUpdateManager*",
        "/Library/Logs/DiagnosticReports/SpeedGrade*",
        "/Library/PDF Services/Save as Adobe PDF.app",
        "/Library/PreferencePanes/Flash*",
        "/Library/Preferences/*Adobe*",
        "/Library/Preferences/*adobe*",
        "/Library/PrivilegedHelperTools/*adobe*",
        "/Library/ScriptingAdditions/Adobe*",
        "/private/tmp/*adobe*",
        "/private/tmp/*/*Adobe*",
        "/private/tmp/*/*adobe*",
        "/private/var/db/receipts/*adobe*",
        "/private/var/folders/*adobe*",
        "/private/var/folders/*/*adobe*",
        "/private/var/folders/*/*/*adobe*",
        "/private/var/folders/*/*/*/*Adobe*",
        "/private/var/folders/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/.com.adobe.*",
        "/private/var/folders/*/*/*/*UXP*",
        "/private/var/folders/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*/*/*/*/*adobe*",
        "/private/var/log/acro*",
        "/Users/Shared/Adobe*",
        "/Users/Shared/NGL",
        "/Users/Shared/Plugin Loading.log",
        "/Users/Shared/*.aeroresource",
        "/Users/*/Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj",
        "/Users/*/Library/Application Support/Google/Chrome/Default/Extensions/kjchkpkjpiloipaonppkmepcbhcncedo",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Excel/SaveAsAdobePDF.xlam",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Excel/~\\$*AsAdobePDF.xlam",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint/SaveAsAdobePDF.ppam",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint/~\\$*AsAdobePDF.ppam",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/linkCreation.dotm",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/~\\$*Creation.dotm",
        "/Users/*/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg",
        "/private/var/root/Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj",
        "/private/var/root/Library/Application Support/Google/Chrome/Default/Extensions/kjchkpkjpiloipaonppkmepcbhcncedo",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Excel/SaveAsAdobePDF.xlam",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Excel/~\\$*AsAdobePDF.xlam",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint/SaveAsAdobePDF.ppam",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/PowerPoint/~\\$*AsAdobePDF.ppam",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/linkCreation.dotm",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/~\\$*Creation.dotm",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg",
        "/usr/local/bin/RemoteUpdateManager",
        "/Applications/Utilities/Adobe*",
        "/Applications/Adobe*"
    ]

    private static let userPathTemplates = [
        "/.adobe*",
        "/Library/Application Scripts/*Adobe*",
        "/Library/Application Scripts/*adobe*",
        "/Library/Application Scripts/com.microsoft.*/AcrobatUtils.scpt",
        "/Library/Application Support/*Adobe*",
        "/Library/Application Support/*adobe*",
        "/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/*adobe*",
        "/Library/Application Support/CrashReporter/*Adobe*",
        "/Library/Application Support/CrashReporter/Aero*",
        "/Library/Application Support/CrashReporter/After Effects*",
        "/Library/Application Support/CrashReporter/Core Sync*",
        "/Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj",
        "/Library/Application Support/Google/Chrome/Default/Extensions/kjchkpkjpiloipaonppkmepcbhcncedo",
        "/Library/Application Support/io.branch",
        "/Library/Caches/Acrobat*",
        "/Library/Caches/*Adobe*",
        "/Library/Caches/*adobe*",
        "/Library/Caches/Aero*",
        "/Library/Caches/AI_*",
        "/Library/Caches/com.apple.nsurlsessiond/Downloads/*adobe*",
        "/Library/Caches/com.crashlytics.data",
        "/Library/Caches/CSXS",
        "/Library/Caches/UXPLogs",
        "/Library/Containers/*adobe*",
        "/Library/Containers/*/*/*/*/*Adobe*",
        "/Library/Cookies/*adobe*",
        "/Library/Group Containers/*Adobe*",
        "/Library/Group Containers/*adobe*",
        "/Library/HTTPStorages/*Adobe*",
        "/Library/HTTPStorages/*adobe*",
        "/Library/HTTPStorages/Aero",
        "/Library/LaunchAgents/*adobe*",
        "/Library/Logs/acro*",
        "/Library/Logs/*Adobe*",
        "/Library/Logs/amt*.log",
        "/Library/Logs/CoreSync*",
        "/Library/Logs/CreativeCloud",
        "/Library/Logs/CSXS",
        "/Library/Logs/DiagnosticReports/Adobe*",
        "/Library/Logs/distNGLLog.txt",
        "/Library/Logs/NGL",
        "/Library/Logs/NGLClient_*",
        "/Library/Logs/oobelib.log",
        "/Library/Logs/PDApp.log",
        "/Library/Logs/RemoteUpdateManager.log",
        "/Library/Metadata/CoreSpotlight/SpotlightKnowledge/*/*/*/*/*/*adobe*",
        "/Library/NGL",
        "/Library/PhotoshopCrashes*",
        "/Library/Preferences/*Adobe*",
        "/Library/Preferences/*adobe*",
        "/Library/Preferences/AIRobin*",
        "/Library/Preferences/ByHost/*adobe*",
        "/Library/Preferences/*Lightroom*",
        "/Library/Preferences/*Macromedia*",
        "/Library/Preferences/*macromedia*",
        "/Library/Saved Application State/*adobe*",
        "/Library/WebKit/*adobe*"
    ]

    private static let c4dProcessNames = [
        "c4d",
        "c4dpy",
        "Cinema 4D",
        "Cinema 4D Team Render Client",
        "Cinema 4D Team Render Server",
        "Commandline"
    ]

    private static let c4dPathTemplates = [
        "/Library/Application Support/Red Giant",
        "/Library/LaunchDaemons/com.redgiant.service.plist",
        "/Users/*/Library/Application Support/CrashReporter/c4d*",
        "/Users/*/Library/Application Support/CrashReporter/Cinema 4D*",
        "/Users/*/Library/Application Support/Maxon",
        "/Users/*/Library/Application Support/Red Giant",
        "/Users/*/Library/Caches/net.maxon.cinema4d*",
        "/Users/*/Library/HTTPStorages/net.maxon.cinema4d*",
        "/Users/*/Library/Preferences/Maxon",
        "/Users/*/Library/Preferences/net.maxon.cinema4d*",
        "/Users/*/Library/Saved Application State/net.maxon.cinema4d*",
        "/Users/Shared/Red Giant",
        "/Applications/Maxon Cinema 4D*"
    ]

    private static func systemPathTargets(for option: CleanupOption) -> [CleanupTarget] {
        systemPathTemplates.map {
            createPathTarget(option, template: $0, title: "系统级路径")
        }
    }

    private static func userPathTargets(for option: CleanupOption) -> [CleanupTarget] {
        userPathTemplates.map {
            createPathTarget(option, template: $0, title: "用户级路径", userScoped: true)
        }
    }

    private static func c4dPathTargets(for option: CleanupOption) -> [CleanupTarget] {
        c4dPathTemplates.map {
            createPathTarget(option, template: $0, title: "C4D / Red Giant 路径")
        }
    }

    private static func userKeychainDeleteCommand(
        itemClass: String,
        matchFlag: String,
        value: String
    ) -> String {
        "/bin/launchctl asuser {USER_UID} " + keychainDeleteCommand(
            keychain: "{LOGIN_KEYCHAIN}",
            itemClass: itemClass,
            matchFlag: matchFlag,
            value: value
        )
    }

    private static func systemKeychainDeleteCommand(
        itemClass: String,
        matchFlag: String,
        value: String
    ) -> String {
        keychainDeleteCommand(
            keychain: "/Library/Keychains/System.keychain",
            itemClass: itemClass,
            matchFlag: matchFlag,
            value: value
        )
    }

    private static func keychainDeleteCommand(
        keychain: String,
        itemClass: String,
        matchFlag: String,
        value: String
    ) -> String {
        "/bin/sh -c 'if /usr/bin/security delete-\(itemClass) \(matchFlag) \"\(value)\" \"\(keychain)\" >/dev/null 2>&1; then /bin/echo \"deleted=1\"; else /bin/echo \"deleted=0\"; fi'"
    }

    private static func dynamicKeychainDeleteCommand(
        keychain: String,
        userUID: String? = nil,
        itemClass: String
    ) -> String {
        let attr = itemClass == "certificate" ? "alis" : "svce"
        let deleteCommand = itemClass == "certificate"
            ? "/usr/bin/security delete-certificate -c \"$item\" \"\(keychain)\""
            : "/usr/bin/security delete-generic-password -s \"$item\" \"\(keychain)\""
        let shell = "/bin/sh -c '/usr/bin/security dump-keychain \"\(keychain)\" 2>/dev/null | /usr/bin/grep -i \"Adobe App Info\\|Adobe App Prefetched Info\\|Adobe User\\|Adobe Profile\\|Adobe Proxy\\|Adobe Package\\|Adobe Content\\|Adobe Intermediate\\|Adobe Lightroom\\|Creative Cloud\\|com.adobe\\|NGL\\|IMS\\|SLCache\\|SLStore\" | /usr/bin/grep -vi \"Adobe Downloader\\|Adobe-Downloader\\|com.x1a0he\" | /usr/bin/grep -i \"\(attr)\" | /usr/bin/awk -F \"=\" \"{print \\\\$2}\" | /usr/bin/cut -d \"\\\"\" -f2 | /usr/bin/sort -u | while IFS= read -r item; do if \(deleteCommand) >/dev/null 2>&1; then /bin/echo deleted; fi; done | /usr/bin/wc -l | /usr/bin/awk \"{print \\\"deleted=\\\" \\\\$1}\"'"

        if let userUID {
            return "/bin/launchctl asuser \(userUID) \(shell)"
        }
        return shell
    }

    private static func createPathTarget(
        _ option: CleanupOption,
        template: String,
        title: String,
        userScoped: Bool = false
    ) -> CleanupTarget {
        let resolvedTemplate = normalizePathTemplate(template, userScoped: userScoped)
        let description = "\(title): \(template)"
        if hasWildcardPattern(resolvedTemplate) {
            return .glob(option, resolvedTemplate, description)
        }
        return .path(option, resolvedTemplate, description)
    }

    private static func normalizePathTemplate(_ template: String, userScoped: Bool) -> String {
        let normalized = template.replacingOccurrences(of: "\\$", with: "$")
        if normalized.hasPrefix("/Users/*") {
            return "{ALL_USER_HOME}" + normalized.dropFirst("/Users/*".count)
        }
        if userScoped, normalized.hasPrefix("/") {
            return "{ALL_USER_HOME}" + normalized
        }
        return normalized
    }

    private static func hasWildcardPattern(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    var description: String {
        switch self {
        case .adobeApps:
            return String(localized: "删除所有已安装的 Adobe 应用程序（不包括 Adobe Downloader）")
        case .adobeCreativeCloud:
            return String(localized: "删除 Adobe Creative Cloud 应用程序及其组件")
        case .adobeUserData:
            return String(localized: "删除当前用户目录中的 Adobe 支持数据、容器、WebKit 和共享数据")
        case .adobePreferences:
            return String(localized: "删除 Adobe 应用程序的偏好设置文件（不包括 Adobe Downloader）")
        case .adobeCaches:
            return String(localized: "删除 Adobe 应用程序的缓存文件（不包括 Adobe Downloader）")
        case .adobeLicenses:
            return String(localized: "删除 Adobe 许可和激活相关文件")
        case .adobeLogs:
            return String(localized: "删除 Adobe 应用程序的日志文件（不包括 Adobe Downloader）")
        case .adobeServices:
            return String(localized: "停止并删除 Adobe 相关服务")
        case .adobeKeychain:
            return String(localized: "删除钥匙串中的 Adobe 相关条目")
        case .adobeGenuineService:
            return String(localized: "删除 Adobe 正版验证服务及其组件")
        case .adobeHosts:
            return String(localized: "清理 hosts 文件中的 Adobe 相关条目")
        case .c4dRedGiant:
            return String(localized: "停止并删除 Cinema 4D、Maxon 和 Red Giant 相关残留")
        }
    }
}

private extension CleanupTarget {
    static func path(
        _ option: CleanupOption,
        _ template: String,
        _ description: String
    ) -> CleanupTarget {
        CleanupTarget(option: option, kind: .removePath, template: template, description: description)
    }

    static func glob(
        _ option: CleanupOption,
        _ template: String,
        _ description: String,
        recursive: Bool = false,
        maxDepth: Int = 4
    ) -> CleanupTarget {
        CleanupTarget(
            option: option,
            kind: .removeGlob,
            template: template,
            description: description,
            recursive: recursive,
            maxDepth: maxDepth
        )
    }

    static func shell(
        _ option: CleanupOption,
        _ template: String,
        _ description: String,
        kind: CleanupActionKind = .shell
    ) -> CleanupTarget {
        CleanupTarget(option: option, kind: kind, template: template, description: description)
    }
}
