import Foundation
import AppKit
import Combine

@MainActor
@objcMembers
class PrivilegedHelperAdapter: NSObject, ObservableObject {

    static let shared = PrivilegedHelperAdapter()
    nonisolated static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"

    @Published var connectionState: ConnectionState = .disconnected

    private let manager = HelperManager.shared
    var connectionSuccessBlock: (() -> Void)?

    // 兼容现有调用方，同时向界面保留完整的系统状态。
    typealias HelperStatus = HelperServiceState

    enum ConnectionState {
        case connected
        case disconnected
        case connecting

        var description: String {
            switch self {
            case .connected:
                return String(localized: "已连接")
            case .disconnected:
                return String(localized: "未连接")
            case .connecting:
                return String(localized: "正在连接")
            }
        }
    }

    override init() {
        super.init()

        manager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                let isInstalled = state == .enabled
                self?.connectionState = isInstalled ? .connected : .disconnected
                if isInstalled {
                    self?.connectionSuccessBlock?()
                }
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func checkInstall() {
        Task {
            await manager.checkStatus()
        }
    }

    func getHelperStatus(callback: @escaping ((HelperStatus) -> Void)) {
        Task {
            await manager.checkStatus()
            callback(manager.state)
        }
    }

    static var getHelperStatus: Bool {
        return HelperManager.shared.isInstalled
    }

    func executeCommand(_ command: String, completion: @escaping (String) -> Void) {
        Task {
            do {
                let result = try await manager.executeShell(command)
                completion(result)
            } catch {
                completion("Error: \(error.localizedDescription)")
            }
        }
    }

    func executeInstallation(_ command: String, progress: @escaping (String) -> Void) async throws {
        try await manager.executeHDPIMInstall(
            productDir: command,
            userHome: NSHomeDirectory(),
            progress: progress
        )
    }

    func reconnectHelper(completion: @escaping (Bool, String) -> Void) {
        Task {
            await manager.reconnect()
            completion(manager.isInstalled, manager.status)
        }
    }

    func reinstallHelper(completion: @escaping (Bool, String) -> Void) {
        Task {
            do {
                try await manager.reinstall()
                completion(manager.isInstalled, manager.status)
            } catch {
                completion(false, manager.status)
            }
        }
    }

    func removeInstallHelper(completion: ((Bool) -> Void)? = nil) {
        Task {
            do {
                try await manager.uninstall()
                completion?(true)
            } catch {
                completion?(false)
            }
        }
    }

    func forceReinstallHelper() {
        Task {
            do {
                try await manager.reinstall()
                print("Helper重新启用结果: 成功")
            } catch {
                print("Helper重新启用结果: 失败 - \(error.localizedDescription)")
            }
        }
    }

    func disconnectHelper() {
        Task {
            do {
                try await manager.uninstall()
            } catch {
                print("断开连接失败: \(error.localizedDescription)")
            }
        }
    }

    func uninstallHelperViaTerminal(completion: @escaping (Bool, String) -> Void) {
        Task {
            do {
                try await manager.uninstall()
                completion(true, "卸载成功")
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }
}
