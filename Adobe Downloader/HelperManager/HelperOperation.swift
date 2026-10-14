import Foundation

enum HelperOperation: Codable, Equatable {
    case installPackage(packagePath: String, targetPath: String)
    case uninstallPath(path: String)
    case copyFile(source: String, destination: String)
    case setPermissions(path: String, mode: Int)
    case executeShell(command: String)
    case runDiagnostic(id: UUID, command: String, timeout: Double)
    case cancelDiagnostic(id: UUID)
    case hdpimInstall(productDir: String, userHome: String, executablePath: String?)
    case hdpimUninstall(request: HDPIMUninstallHelperRequest, userHome: String, executablePath: String?)
    case triggerTCCPrompt
    case cancelOperation
    case hdpimProgress(operationID: UUID)
    case cancelHDPIMOperation(operationID: UUID)
    case getVersion

    var requiresValidation: Bool {
        switch self {
        case .installPackage, .uninstallPath, .copyFile, .setPermissions:
            return true
        case .executeShell, .runDiagnostic, .cancelDiagnostic, .hdpimInstall, .hdpimUninstall, .triggerTCCPrompt, .cancelOperation, .hdpimProgress, .cancelHDPIMOperation, .getVersion:
            return false
        }
    }

    var description: String {
        switch self {
        case .installPackage(let path, _):
            return "Install package: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .uninstallPath(let path):
            return "Uninstall: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .copyFile(let source, _):
            return "Copy file: \(URL(fileURLWithPath: source).lastPathComponent)"
        case .setPermissions(let path, let mode):
            return "Set permissions \(String(mode, radix: 8)): \(URL(fileURLWithPath: path).lastPathComponent)"
        case .executeShell(let command):
            return "Execute: \(command.prefix(50))..."
        case .runDiagnostic(let id, _, _):
            return "Run diagnostic: \(id)"
        case .cancelDiagnostic(let id):
            return "Cancel diagnostic: \(id)"
        case .hdpimInstall(let productDir, _, _):
            return "HDPIM install: \(URL(fileURLWithPath: productDir).lastPathComponent)"
        case .hdpimUninstall(let request, _, _):
            return "HDPIM uninstall: \(request.description)"
        case .triggerTCCPrompt:
            return "Trigger TCC"
        case .cancelOperation:
            return "Cancel operation"
        case .hdpimProgress(let id):
            return "HDPIM progress: \(id)"
        case .cancelHDPIMOperation(let id):
            return "Cancel HDPIM operation: \(id)"
        case .getVersion:
            return "Get version"
        }
    }
}

struct HDPIMUninstallHelperRequest: Codable, Equatable {
    enum Target: String, Codable {
        case product
        case module
        case packages
    }

    struct PackageKey: Codable, Equatable {
        let packageName: String
        let packageVersion: String
    }

    let sapCode: String
    let version: String
    let processorFamily: String
    let target: Target
    let moduleIds: [String]
    let packageKeys: [PackageKey]
    var preservingUserPreferences: Bool? = nil

    var description: String {
        switch target {
        case .product:
            return "\(sapCode) \(version) \(processorFamily)"
        case .module:
            return "\(sapCode) \(version) modules=\(moduleIds.joined(separator: ","))"
        case .packages:
            let packages = packageKeys
                .map { "\($0.packageName)@\($0.packageVersion)" }
                .joined(separator: ",")
            return "\(sapCode) \(version) packages=\(packages)"
        }
    }
}

struct HelperOperationResult: Codable {
    let success: Bool
    let output: String
    let exitCode: Int32?
    var operationID: UUID? = nil
    var diagnostic: HelperDiagnosticResult? = nil

    static func success(_ output: String = "", operationID: UUID? = nil) -> HelperOperationResult {
        HelperOperationResult(success: true, output: output, exitCode: 0, operationID: operationID)
    }

    static func failure(_ error: String, exitCode: Int32? = nil) -> HelperOperationResult {
        HelperOperationResult(success: false, output: error, exitCode: exitCode)
    }
}

struct HDPIMInstallProgress: Codable {
    let output: String
    let isComplete: Bool
    let exitCode: Int32?
}

/// 可选结果字段兼容旧 Helper；诊断客户端要求该字段存在，避免误判旧协议回复。
struct HelperDiagnosticResult: Codable, Equatable {
    let standardOutput: String
    let standardError: String
    let duration: TimeInterval
    let timedOut: Bool
    let cancelled: Bool
    let outputTruncated: Bool
}
