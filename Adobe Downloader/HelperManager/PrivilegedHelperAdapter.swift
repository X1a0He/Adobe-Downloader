//
//  PrivilegedHelperAdapter.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/07/20.
//

import Foundation
import AppKit
import Combine

@objcMembers
class PrivilegedHelperAdapter: NSObject, ObservableObject {
    
    static let shared = PrivilegedHelperAdapter()
    static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"
    
    @Published var connectionState: ConnectionState = .disconnected

    private let daemonManager: SMAppServiceDaemonHelperManager
    var connectionSuccessBlock: (() -> Void)?

    enum HelperStatus {
        case installed
        case noFound
        case needUpdate
    }
    
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
        self.daemonManager = SMAppServiceDaemonHelperManager.shared
        super.init()

        daemonManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] daemonState in
                self?.connectionState = self?.convertConnectionState(daemonState) ?? .disconnected
            }
            .store(in: &cancellables)

        daemonManager.connectionSuccessBlock = { [weak self] in
            self?.connectionSuccessBlock?()
        }
    }
    
    private var cancellables = Set<AnyCancellable>()

    func checkInstall() {
        daemonManager.checkInstall()
    }
    
    func getHelperStatus(callback: @escaping ((HelperStatus) -> Void)) {
        daemonManager.getHelperStatus { status in
            callback(self.convertHelperStatus(status))
        }
    }
    
    static var getHelperStatus: Bool {
        return SMAppServiceDaemonHelperManager.getHelperStatus
    }

    func executeCommand(_ command: String, completion: @escaping (String) -> Void) {
        daemonManager.executeCommand(command, completion: completion)
    }
    
    func executeInstallation(_ command: String, progress: @escaping (String) -> Void) async throws {
        try await daemonManager.executeInstallation(command, progress: progress)
    }
    
    func reconnectHelper(completion: @escaping (Bool, String) -> Void) {
        daemonManager.reconnectHelper(completion: completion)
    }
    
    func reinstallHelper(completion: @escaping (Bool, String) -> Void) {
        daemonManager.reinstallHelper(completion: completion)
    }
    
    func removeInstallHelper(completion: ((Bool) -> Void)? = nil) {
        daemonManager.removeInstallHelper(completion: completion)
    }
    
    func forceReinstallHelper() {
        daemonManager.forceCleanAndReinstallHelper { success, message in
            print("Helper重新安装结果: \(success ? "成功" : "失败") - \(message)")
        }
    }
    
    func disconnectHelper() {
        daemonManager.disconnectHelper()
    }
    
    func uninstallHelperViaTerminal(completion: @escaping (Bool, String) -> Void) {
        daemonManager.uninstallHelperViaTerminal(completion: completion)
    }
    
    public func getHelperProxy() throws -> HelperToolProtocol {
        return try daemonManager.getHelperProxy()
    }
    
    private func convertConnectionState(_ daemonState: SMAppServiceDaemonHelperManager.ConnectionState) -> ConnectionState {
        switch daemonState {
        case .connected:
            return .connected
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        }
    }
    
    private func convertHelperStatus(_ daemonStatus: SMAppServiceDaemonHelperManager.HelperStatus) -> HelperStatus {
        switch daemonStatus {
        case .installed:
            return .installed
        case .noFound:
            return .noFound
        case .needUpdate:
            return .needUpdate
        }
    }
}
