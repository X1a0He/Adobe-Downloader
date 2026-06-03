import Foundation

enum HelperOperation: Codable, Equatable {
    case installPackage(packagePath: String, targetPath: String)
    case uninstallPath(path: String)
    case copyFile(source: String, destination: String)
    case setPermissions(path: String, mode: Int)
    case executeShell(command: String)
    case hdpimInstall(productDir: String, userHome: String, executablePath: String?)
    case cancelOperation
    case getVersion

    var requiresValidation: Bool {
        switch self {
        case .installPackage, .uninstallPath, .copyFile, .setPermissions:
            return true
        case .executeShell, .hdpimInstall, .cancelOperation, .getVersion:
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
        case .hdpimInstall(let productDir, _, _):
            return "HDPIM install: \(URL(fileURLWithPath: productDir).lastPathComponent)"
        case .cancelOperation:
            return "Cancel operation"
        case .getVersion:
            return "Get version"
        }
    }
}

struct HelperOperationResult: Codable {
    let success: Bool
    let output: String
    let exitCode: Int32?

    static func success(_ output: String = "") -> HelperOperationResult {
        HelperOperationResult(success: true, output: output, exitCode: 0)
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
