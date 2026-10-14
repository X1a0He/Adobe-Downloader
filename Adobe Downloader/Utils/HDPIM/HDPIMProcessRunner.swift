import Foundation
import Darwin

/// 子进程使用独立进程组；输出落到临时文件，避免两个管道相互等待。
enum HDPIMProcessRunner {
    static func run(executable: String, arguments: [String]) async throws -> HDPIMShellExecutionResult {
        try HDPIMOperationContext.checkCancellation()
        let cancellation = PDMTransferCancellation()
        let operation = HDPIMOperationContext.isRecovering ? nil : HDPIMOperationContext.cancellation
        let registration = operation?.register { cancellation.cancel() }
        defer { if let registration { operation?.unregister(registration) } }
        let recovering = HDPIMOperationContext.isRecovering
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try runBlocking(executable: executable,
                                                                      arguments: arguments,
                                                                      cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if !recovering { cancellation.cancel() }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], cancellation: PDMTransferCancellation
    ) throws -> HDPIMShellExecutionResult {
        if cancellation.isCancelled { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HDPIM-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        let outputFD = open(outputURL.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw posixError() }
        defer { close(outputFD) }
        let errorFD = open(errorURL.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard errorFD >= 0 else { throw posixError() }
        defer { close(errorFD) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errorFD, STDERR_FILENO))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        // Headless 入口忽略 SIGTERM/SIGINT；子进程必须恢复默认信号处理。
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        let argv = ([executable] + arguments).map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + environment).forEach { free($0) } }
        var argvPointers = argv + [nil]
        var environmentPointers = environment + [nil]
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, &attributes, &argvPointers, &environmentPointers))

        var status: Int32 = 0
        var stopRequestedAt: Date?
        while true {
            if cancellation.isCancelled {
                if stopRequestedAt == nil {
                    stopRequestedAt = Date()
                    kill(-pid, SIGTERM)
                } else if Date().timeIntervalSince(stopRequestedAt!) >= 2 {
                    kill(-pid, SIGKILL)
                }
            }
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { throw posixError() }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if cancellation.isCancelled {
            // shell 已退出时，同组中的 hook 仍可能存活。
            kill(-pid, SIGKILL)
            throw CancellationError()
        }
        let output = try [readOutput(outputURL), readOutput(errorURL)]
            .filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return HDPIMShellExecutionResult(output: output, exitCode: exitCode)
    }

    private static func readOutput(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let limit: UInt64 = 4 * 1024 * 1024
        try handle.seek(toOffset: size > limit ? size - limit : 0)
        let data = try handle.readToEnd() ?? Data()
        return (size > limit ? "[输出过长，仅保留末尾 4 MiB]\n" : "") + String(decoding: data, as: UTF8.self)
    }

    private static func check(_ status: Int32) throws {
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
