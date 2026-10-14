import Foundation

/// 独立的一次性连接；超时或取消不会使安装使用的业务连接失效。
// 可变状态仅在 queue 上访问。
final class HelperDiagnosticSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.helper.diagnostic")
    private let id = UUID()
    private var connection: NSXPCConnection?
    private var completion: ((HelperOperationResult) -> Void)?
    private var deadline: DispatchWorkItem?
    private var cancelRequested = false

    deinit { connection?.invalidate() }

    func run(command: String, timeout: Double) async -> HelperOperationResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.completion = { continuation.resume(returning: $0) }
                guard !self.cancelRequested else {
                    self.finishOnQueue(HelperOperationResult(success: false, output: "", exitCode: nil,
                        diagnostic: HelperDiagnosticResult(standardOutput: "", standardError: "", duration: 0,
                            timedOut: false, cancelled: true, outputTruncated: false)))
                    return
                }
                do {
                    let data = try JSONEncoder().encode(HelperOperation.runDiagnostic(id: self.id, command: command, timeout: timeout))
                    let connection = NSXPCConnection(machServiceName: "com.x1a0he.macOS.Adobe-Downloader.helper", options: .privileged)
                    connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
                    let disconnected: () -> Void = { [weak self] in
                        self?.finish(.failure(String(localized: "诊断连接已中断；未收到命令的最终结果。")))
                    }
                    connection.invalidationHandler = disconnected
                    connection.interruptionHandler = disconnected
                    self.connection = connection
                    connection.resume()
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                        self?.finish(.failure(error.localizedDescription))
                    }) as? HelperXPCProtocol else {
                        throw HelperError.proxyCreationFailed
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.finishOnQueue(.failure(String(localized: "Helper 未在时限内返回结果，诊断连接已关闭。请检查 Helper 状态。")))
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + timeout + 5, execute: deadline)
                    proxy.executeOperation(data) { [weak self] data in
                        guard let result = try? JSONDecoder().decode(HelperOperationResult.self, from: data) else {
                            self?.finish(.failure(String(localized: "无法读取诊断结果，请更新并重新注册 Helper。")))
                            return
                        }
                        guard result.diagnostic != nil else {
                            self?.finish(.failure(String(localized: "Helper 不支持当前诊断请求，请更新并重新注册 Helper。") + "\n" + result.output))
                            return
                        }
                        self?.finish(result)
                    }
                    if self.cancelRequested { self.sendCancellation() }
                } catch {
                    self.finishOnQueue(.failure(error.localizedDescription))
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelRequested = true
            self.sendCancellation()
        }
    }

    private func sendCancellation() {
        guard let connection, completion != nil,
              let data = try? JSONEncoder().encode(HelperOperation.cancelDiagnostic(id: id)),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                  self?.finish(.failure(error.localizedDescription))
              }) as? HelperXPCProtocol else { return }
        // 这里仅确认请求送达；运行请求的最终回复才代表子进程已结束。
        proxy.executeOperation(data) { _ in }
    }

    private func finish(_ result: HelperOperationResult) {
        queue.async { self.finishOnQueue(result) }
    }

    private func finishOnQueue(_ result: HelperOperationResult) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel()
        deadline = nil
        connection?.invalidate()
        connection = nil
        completion(result)
    }
}
