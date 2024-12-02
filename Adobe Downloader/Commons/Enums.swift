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

    private var errorGroup: Int {
        switch self {
        case .noConnection, .timeout, .serverUnreachable: return 1000
        case .invalidURL, .invalidRequest, .invalidResponse: return 2000
        case .invalidData, .parsingError, .dataValidationError: return 3000
        case .httpError, .serverError, .clientError: return 4000
        case .downloadError, .downloadCancelled, .insufficientStorage, .cancelled: return 5000
        case .fileSystemError, .fileExists, .fileNotFound, .filePermissionDenied: return 6000
        case .applicationInfoError, .unsupportedPlatform, .incompatibleVersion, .installError: return 7000
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
            case validatingSetup
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
        if self < 60 {
            return String(format: "%.0f", self) + String(localized: "秒")
        } else if self < 3600 {
            let minutes = Int(self / 60)
            let remainingSeconds = Int(self.truncatingRemainder(dividingBy: 60))
            return "\(minutes)" + String(localized: "分") + "\(remainingSeconds)" + String(localized: "秒")
        } else {
            let hours = Int(self / 3600)
            let minutes = Int((self.truncatingRemainder(dividingBy: 3600)) / 60)
            let remainingSeconds = Int(self.truncatingRemainder(dividingBy: 60))
            return "\(hours)" + String(localized: "小时") + "\(minutes)" + String(localized: "分") + "\(remainingSeconds)" + String(localized: "秒")
        }
    }
} 
