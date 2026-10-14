import Foundation
import os.log

final class HelperService: NSObject {
    private let listener: NSXPCListener
    private var connections: Set<NSXPCConnection> = []
    private let connectionsLock = NSLock()
    private let logger = Logger(subsystem: "com.x1a0he.macOS.Adobe-Downloader.helper", category: "Service")

    override init() {
        listener = NSXPCListener(machServiceName: "com.x1a0he.macOS.Adobe-Downloader.helper")
        super.init()
        listener.delegate = self
    }

    func run() {
        logger.notice("Helper 服务启动")
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Helper is running")
        listener.resume()
        RunLoop.current.run()
    }
}

extension HelperService: NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        logger.notice("收到 XPC 连接请求")

        guard SecurityValidator.validateClientConnection(connection) else {
            logger.error("客户端验证失败")
            return false
        }

        let interface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedInterface = interface
        let service = HelperServiceImpl()
        connection.exportedObject = service

        connection.invalidationHandler = { [weak self, weak connection] in
            service.diagnostics.cancel()
            self?.logger.notice("XPC 连接断开")
            if let connection { self?.removeConnection(connection) }
        }

        connection.interruptionHandler = { [weak self, weak connection] in
            service.diagnostics.cancel()
            self?.logger.error("XPC 连接中断")
            if let connection { self?.removeConnection(connection) }
        }

        connectionsLock.lock()
        connections.insert(connection)
        let count = connections.count
        connectionsLock.unlock()
        connection.resume()

        logger.notice("XPC 连接已建立，活动连接数: \(count)")
        return true
    }

    private func removeConnection(_ connection: NSXPCConnection) {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        connections.remove(connection)
    }
}

private final class HelperServiceImpl: NSObject, HelperXPCProtocol {
    let diagnostics = DiagnosticCommandController()
    private let operationLock = NSLock()
    private var clientOperationID: UUID?

    private func rememberOperation(_ id: UUID) {
        operationLock.lock(); defer { operationLock.unlock() }
        clientOperationID = id
    }

    private func operationIDForClient() -> UUID? {
        operationLock.lock(); defer { operationLock.unlock() }
        return clientOperationID
    }

    private let logger = Logger(subsystem: "com.x1a0he.macOS.Adobe-Downloader.helper", category: "ServiceImpl")

    func executeOperation(_ operationData: Data, withReply reply: @escaping (Data) -> Void) {
        guard let operation = try? JSONDecoder().decode(HelperOperation.self, from: operationData) else {
            let result = HelperOperationResult.failure("无法解析操作")
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            reply(data)
            return
        }

        logger.notice("执行操作: \(operation.description)")

        let result: HelperOperationResult
        switch operation {
        case .runDiagnostic(let id, let command, let timeout):
            diagnostics.start(id: id, command: command, timeout: timeout) { result in
                reply((try? JSONEncoder().encode(result)) ?? Data())
            }
            return

        case .cancelDiagnostic(let id):
            diagnostics.cancel(id: id)
            result = .success("Cancellation requested")

        case .hdpimInstall(let productDir, let userHome, let executablePath):
            do {
                let id = try ProcessManager.shared.startHDPIMInstall(
                    productDir: productDir,
                    userHome: userHome,
                    executablePath: executablePath
                )
                rememberOperation(id)
                result = .success("Started", operationID: id)
            } catch {
                result = .failure("启动失败: \(error.localizedDescription)")
            }

        case .hdpimUninstall(let request, let userHome, let executablePath):
            do {
                let id = try ProcessManager.shared.startHDPIMUninstall(
                    request: request,
                    userHome: userHome,
                    executablePath: executablePath
                )
                rememberOperation(id)
                result = .success("Started", operationID: id)
            } catch {
                result = .failure("启动失败: \(error.localizedDescription)")
            }

        case .hdpimProgress(let id):
            let progress = ProcessManager.shared.getProgress(operationID: id)
            let data = (try? JSONEncoder().encode(progress)) ?? Data()
            result = .success(String(decoding: data, as: UTF8.self))

        case .cancelHDPIMOperation(let id):
            ProcessManager.shared.cancel(operationID: id)
            result = .success("Cancelled")

        case .cancelOperation:
            ProcessManager.shared.cancel(operationID: operationIDForClient())
            result = .success("Cancelled")

        default:
            result = OperationExecutor.execute(operation)
        }

        let data = (try? JSONEncoder().encode(result)) ?? Data()
        reply(data)
    }

    func executeInstallation(_ operationData: Data, withReply reply: @escaping (Data) -> Void) {
        executeOperation(operationData, withReply: reply)
    }

    func getInstallationProgress(withReply reply: @escaping (Data) -> Void) {
        let progress = ProcessManager.shared.getProgress(operationID: operationIDForClient())
        let data = (try? JSONEncoder().encode(progress)) ?? Data()
        reply(data)
    }

    func cancelCurrentOperation(withReply reply: @escaping (Bool) -> Void) {
        ProcessManager.shared.cancel(operationID: operationIDForClient())
        reply(true)
    }

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        reply(version)
    }
}
