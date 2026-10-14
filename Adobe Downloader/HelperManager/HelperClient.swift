import Foundation

final class HelperClient {
    private static let machServiceName = "com.x1a0he.macOS.Adobe-Downloader.helper"

    private var connection: NSXPCConnection?
    private let queue = DispatchQueue(label: "com.helper.client")

    private var connectionID: UUID?

    func connect() throws -> NSXPCConnection {
        try queue.sync { try connectOnQueue() }
    }

    /// 前台状态检查使用独立连接，探测超时不影响正在执行安装或清理的业务连接。
    func checkConnection() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let probeConnection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
                probeConnection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
                probeConnection.resume()
                defer { probeConnection.invalidate() }
                do {
                    try self.verifyConnection(probeConnection)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connectOnQueue() throws -> NSXPCConnection {
        if let existing = connection { return existing }
        let newConnection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        let id = UUID()
        let invalidate: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                // 旧连接的迟到回调不能清除新连接。
                guard self.connectionID == id else { return }
                self.connection?.invalidate()
                self.connection = nil
                self.connectionID = nil
            }
        }
        newConnection.invalidationHandler = invalidate
        newConnection.interruptionHandler = invalidate
        newConnection.resume()
        do {
            try verifyConnection(newConnection)
        } catch {
            newConnection.invalidate()
            throw error
        }
        connection = newConnection
        connectionID = id
        return newConnection
    }

    func disconnect() {
        queue.async {
            self.connection?.invalidate()
            self.connection = nil
            self.connectionID = nil
        }
    }

    func execute(
        _ operation: HelperOperation,
        completion: @escaping (Result<HelperOperationResult, HelperError>) -> Void
    ) {
        do {
            let conn = try connect()
            guard let proxy = conn.remoteObjectProxy as? HelperXPCProtocol else {
                throw HelperError.proxyCreationFailed
            }

            let operationData = try JSONEncoder().encode(operation)

            proxy.executeOperation(operationData) { resultData in
                guard let result = try? JSONDecoder().decode(
                    HelperOperationResult.self,
                    from: resultData
                ) else {
                    completion(.failure(.operationFailed("解析结果失败")))
                    return
                }

                if result.success {
                    completion(.success(result))
                } else {
                    completion(.failure(.operationFailed(result.output)))
                }
            }
        } catch let error as HelperError {
            completion(.failure(error))
        } catch {
            completion(.failure(.operationFailed(error.localizedDescription)))
        }
    }

    func executeInstallation(
        _ operation: HelperOperation,
        progress: @escaping (String) -> Void
    ) async throws {
        try HDPIMOperationContext.checkCancellation()
        let conn = try connect()
        guard let proxy = conn.remoteObjectProxy as? HelperXPCProtocol else {
            throw HelperError.proxyCreationFailed
        }

        let operationData = try JSONEncoder().encode(operation)

        let operationID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UUID?, Error>) in
            proxy.executeInstallation(operationData) { resultData in
                guard let result = try? JSONDecoder().decode(
                    HelperOperationResult.self,
                    from: resultData
                ) else {
                    continuation.resume(throwing: HelperError.operationFailed("解析结果失败"))
                    return
                }

                if result.success {
                    continuation.resume(returning: result.operationID)
                } else {
                    continuation.resume(throwing: HelperError.installationFailed(result.output))
                }
            }
        }

        let progressRequest = try operationID.map {
            try JSONEncoder().encode(HelperOperation.hdpimProgress(operationID: $0))
        }
        var cancellationSent = false
        var terminalOutput = ""
        var committed = false
        while true {
            if !cancellationSent && (Task.isCancelled || HDPIMOperationContext.cancellation?.isCancelled == true) {
                // 等启动确认后再取消，避免取消请求先于新进程登记；继续排空进度直到恢复结束。
                let cancel = operationID.map { HelperOperation.cancelHDPIMOperation(operationID: $0) } ?? .cancelOperation
                let cancelData = try JSONEncoder().encode(cancel)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    proxy.executeOperation(cancelData) { data in
                        guard let result = try? JSONDecoder().decode(HelperOperationResult.self, from: data), result.success else {
                            continuation.resume(throwing: HelperError.operationFailed("发送安装取消请求失败"))
                            return
                        }
                        continuation.resume()
                    }
                }
                cancellationSent = true
            }
            let progressData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if let progressRequest {
                    proxy.executeOperation(progressRequest) { data in
                        guard let result = try? JSONDecoder().decode(HelperOperationResult.self, from: data), result.success else {
                            continuation.resume(throwing: HelperError.operationFailed("获取安装进度失败"))
                            return
                        }
                        continuation.resume(returning: Data(result.output.utf8))
                    }
                    return
                }
                proxy.getInstallationProgress { data in
                    continuation.resume(returning: data)
                }
            }

            guard let installProgress = try? JSONDecoder().decode(
                HDPIMInstallProgress.self,
                from: progressData
            ) else {
                throw HelperError.operationFailed("解析进度失败")
            }

            if !installProgress.output.isEmpty {
                terminalOutput += installProgress.output
                while let newline = terminalOutput.firstIndex(of: "\n") {
                    let line = String(terminalOutput[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                    terminalOutput.removeSubrange(...newline)
                    if line == "RESULT|SUCCESS" { committed = true }
                }
                progress(installProgress.output)
            }

            if installProgress.isComplete {
                if let exitCode = installProgress.exitCode, exitCode != 0 {
                    throw HelperError.processExecutionFailed(
                        exitCode: exitCode,
                        output: installProgress.output
                    )
                }
                if cancellationSent && !committed { throw CancellationError() }
                break
            }

            // 调用方取消后仍需等待 Helper 收尾，不能让 Task.sleep 提前结束轮询。
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                    continuation.resume()
                }
            }
        }
    }

    private func verifyConnection(_ connection: NSXPCConnection) throws {
        let reply = ConnectionProbe()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.finish(.failure(error))
        }) as? HelperXPCProtocol else {
            throw HelperError.proxyCreationFailed
        }
        let data = try JSONEncoder().encode(HelperOperation.executeShell(command: "whoami"))
        proxy.executeOperation(data) { resultData in
            do {
                let result = try JSONDecoder().decode(HelperOperationResult.self, from: resultData)
                guard result.success,
                      result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "root" else {
                    reply.finish(.failure(HelperError.operationFailed(result.output)))
                    return
                }
                reply.finish(.success(()))
            } catch {
                reply.finish(.failure(error))
            }
        }
        try reply.wait()
    }
}

/// XPC 失败、正常回复与超时只接受第一个结果；迟到回复不再改变已结束的检查。
private final class ConnectionProbe {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws {
        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            finish(.failure(HelperError.connectionTimeout))
        }
        lock.lock()
        let value = result
        lock.unlock()
        try value?.get()
    }
}
