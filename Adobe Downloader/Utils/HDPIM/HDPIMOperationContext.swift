import Foundation

/// 安装取消覆盖网络、解压和子进程；恢复阶段在独立上下文中收尾。
enum HDPIMOperationContext {
    @TaskLocal static var cancellation: HDPIMOperationCancellation?
    @TaskLocal static var isRecovering = false

    static func checkCancellation() throws {
        guard !isRecovering else { return }
        if Task.isCancelled || cancellation?.isCancelled == true {
            throw CancellationError()
        }
    }
}

final class HDPIMOperationCancellation: @unchecked Sendable {
    private let state = PDMTransferCancellation()
    private let monitor: DispatchSourceTimer?

    init(externalCheck: (() -> Bool)? = nil) {
        if let externalCheck {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            monitor = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(100))
            timer.setEventHandler { [state] in
                if externalCheck() { state.cancel() }
            }
            timer.resume()
        } else {
            monitor = nil
        }
    }

    var isCancelled: Bool { state.isCancelled }
    func cancel() { state.cancel() }
    func stopMonitoring() { monitor?.cancel() }
    func register(_ handler: @escaping () -> Void) -> UUID { state.register(handler) }
    func unregister(_ id: UUID) { state.unregister(id) }
    deinit { monitor?.cancel() }
}
