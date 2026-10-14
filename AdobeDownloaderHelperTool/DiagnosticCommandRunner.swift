import Foundation
import Darwin

/// 启动与取消共用锁，取消已生效的任务不能再创建子进程。
final class DiagnosticCommandCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func launchIfActive(_ launch: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try launch()
        return true
    }
}

/// 每个诊断连接只拥有自己的命令；断开连接时取消，不能影响安装进程。
final class DiagnosticCommandController {
    private let lock = NSLock()
    private var identifier: UUID?
    private let cancellation = DiagnosticCommandCancellation()
    private var disconnected = false

    func start(id: UUID, command: String, timeout: Double, reply: @escaping (HelperOperationResult) -> Void) {
        lock.lock()
        guard identifier == nil, !disconnected else {
            lock.unlock()
            reply(.failure("诊断连接不可用或已有命令正在执行"))
            return
        }
        identifier = id
        lock.unlock()
        guard timeout.isFinite, (1...120).contains(timeout),
              !command.utf8.contains(0), command.utf8.count <= 16_384 else {
            reply(.failure("诊断命令或超时时间无效"))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            reply(DiagnosticCommandRunner.run(command: command, timeout: timeout, cancellation: self.cancellation))
        }
    }

    func cancel(id: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if id == nil { disconnected = true }
        if id == nil || identifier == id { cancellation.cancel() }
    }
}

enum DiagnosticCommandRunner {
    private static let outputLimit = 128 * 1024

    static func run(command: String, timeout: Double, cancellation: DiagnosticCommandCancellation = DiagnosticCommandCancellation()) -> HelperOperationResult {
        let started = ProcessInfo.processInfo.systemUptime
        var output = Data()
        var errors = Data()
        var truncated = false
        var timedOut = false
        var cancelled = false
        var exitCode: Int32?
        var failure: String?
        do {
            if cancellation.isCancelled { throw CancellationError() }
            let stdout = try makePipe()
            defer { close(stdout.read); close(stdout.write) }
            let stderr = try makePipe()
            defer { close(stderr.read); close(stderr.write) }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try check(posix_spawn_file_actions_adddup2(&actions, stdout.write, STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, stderr.write, STDERR_FILENO))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            var mask = sigset_t()
            sigemptyset(&mask)
            try check(posix_spawnattr_setsigmask(&attributes, &mask))
            var defaults = sigset_t()
            sigemptyset(&defaults)
            sigaddset(&defaults, SIGTERM)
            sigaddset(&defaults, SIGINT)
            sigaddset(&defaults, SIGPIPE)
            try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
            try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
            let strings = ["/bin/sh", "-c", command].map { strdup($0) }
            let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
            defer { (strings + environment).forEach { free($0) } }
            var argv = strings + [nil]
            var envp = environment + [nil]
            var pid: pid_t = 0
            guard try cancellation.launchIfActive({
                try check(posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, &envp))
            }) else { throw CancellationError() }

            // 持续排空两个管道，保留上限不影响消费，避免大量输出阻塞子进程。
            var status: Int32 = 0
            var stopped = false
            while true {
                drain(stdout.read, into: &output, truncated: &truncated)
                drain(stderr.read, into: &errors, truncated: &truncated)
                if !stopped {
                    cancelled = cancellation.isCancelled
                    timedOut = !cancelled && ProcessInfo.processInfo.systemUptime - started >= timeout
                    if cancelled || timedOut {
                        // 在 waitpid 回收 PID 前终止整个组，避免误伤复用的 PID。
                        kill(-pid, SIGKILL)
                        stopped = true
                    }
                }
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { break }
                if waited < 0 && errno != EINTR { throw posixError() }
                Thread.sleep(forTimeInterval: 0.01)
            }
            // 子进程已退出；只读当前缓冲，不等待后台后代关闭输出端。
            let outputPending = drain(stdout.read, into: &output, truncated: &truncated, limit: 256 * 1024)
            let errorPending = drain(stderr.read, into: &errors, truncated: &truncated, limit: 256 * 1024)
            truncated = truncated || outputPending || errorPending
            let signal = status & 0x7f
            exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        } catch is CancellationError {
            cancelled = true
        } catch {
            failure = error.localizedDescription
        }
        let stdout = String(decoding: output, as: UTF8.self)
        let stderr = [String(decoding: errors, as: UTF8.self), failure ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return HelperOperationResult(
            success: exitCode == 0 && !timedOut && !cancelled && failure == nil,
            output: [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n"),
            exitCode: exitCode,
            diagnostic: HelperDiagnosticResult(standardOutput: stdout, standardError: stderr,
                duration: ProcessInfo.processInfo.systemUptime - started,
                timedOut: timedOut, cancelled: cancelled, outputTruncated: truncated)
        )
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw posixError() }
        guard fcntl(fds[0], F_SETFD, FD_CLOEXEC) >= 0,
              fcntl(fds[1], F_SETFD, FD_CLOEXEC) >= 0,
              fcntl(fds[0], F_SETFL, O_NONBLOCK) >= 0 else {
            let error = posixError()
            close(fds[0]); close(fds[1])
            throw error
        }
        return (fds[0], fds[1])
    }

    @discardableResult
    private static func drain(_ fd: Int32, into data: inout Data, truncated: inout Bool, limit: Int = 64 * 1024) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var consumed = 0
        while consumed < limit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            let retained = min(count, outputLimit - data.count)
            data.append(contentsOf: buffer.prefix(retained))
            truncated = truncated || retained < count
            consumed += count
        }
        return true
    }

    private static func check(_ status: Int32) throws {
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
