import Foundation

enum HelperError: LocalizedError, Codable {
    case connectionFailed
    case connectionTimeout
    case proxyCreationFailed
    case notInstalled
    case notAuthorized
    case invalidPath(String)
    case securityValidationFailed
    case operationFailed(String)
    case processExecutionFailed(exitCode: Int32, output: String)
    case installationFailed(String)
    case unsupportedOperation
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "无法连接到 Helper 服务"
        case .connectionTimeout:
            return "连接 Helper 服务超时"
        case .proxyCreationFailed:
            return "无法创建 Helper 代理对象"
        case .notInstalled:
            return "Helper 服务未安装"
        case .notAuthorized:
            return "Helper 服务未授权"
        case .invalidPath(let path):
            return "无效的路径: \(path)"
        case .securityValidationFailed:
            return "安全验证失败"
        case .operationFailed(let reason):
            return "操作失败: \(reason)"
        case .processExecutionFailed(let exitCode, let output):
            return "进程执行失败 (退出码: \(exitCode)): \(output)"
        case .installationFailed(let reason):
            return "安装失败: \(reason)"
        case .unsupportedOperation:
            return "不支持的操作"
        case .cancelled:
            return "操作已取消"
        }
    }
}
