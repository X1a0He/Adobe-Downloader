//
//  InstallManager.swift
//  Adobe Downloader
//

import Foundation
import Darwin

actor InstallManager {
    private final class InstallOutputState {
        var pending = ""
        var latestProgress = 0.0
        var lastStructuredError: String?
        var lastLoggedProgressStatus: String?
    }

    private struct PreparedInstallSource {
        let url: URL
        let cleanupURL: URL?
    }

    enum InstallError: Error, LocalizedError {
        case installationFailed(String)
        case cancelled
        case permissionDenied
        case installationFailedWithDetails(String, String)

        var errorDescription: String? {
            switch self {
            case .installationFailed(let message): return message
            case .cancelled: return String(localized: "安装已取消")
            case .permissionDenied: return String(localized: "权限被拒绝")
            case .installationFailedWithDetails(let message, _): return message
            }
        }
    }

    private var isInstalling = false

    func install(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        let preparedSource = try await prepareInstallSource(
            at: appPath,
            progressHandler: progressHandler,
            logHandler: logHandler
        )
        defer {
            if let cleanupURL = preparedSource.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        let driverPath = preparedSource.url.appendingPathComponent("driver.xml").path
        guard FileManager.default.fileExists(atPath: driverPath) else {
            throw InstallError.installationFailed("找不到 driver.xml 文件")
        }

        let encodedProductDir = Data(preparedSource.url.path.utf8).base64EncodedString()
        let encodedUserHome = Data(NSHomeDirectory().utf8).base64EncodedString()
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let encodedExecutablePath = Data(executablePath.utf8).base64EncodedString()
        let command = HelperSpecialCommand.hdpimInstallPrefix + encodedProductDir + "|" + encodedUserHome + "|" + encodedExecutablePath
        isInstalling = true
        defer { isInstalling = false }

        do {
            let outputState = InstallOutputState()

            try await PrivilegedHelperAdapter.shared.executeInstallation(command) { output in
                Self.consumeHelperOutput(
                    output,
                    state: outputState,
                    progressHandler: progressHandler,
                    logHandler: logHandler
                )
            }

            Self.consumeHelperOutput(
                "\n",
                state: outputState,
                progressHandler: progressHandler,
                logHandler: logHandler
            )

            if let lastStructuredError = outputState.lastStructuredError {
                throw InstallError.installationFailedWithDetails(
                    "安装失败: \(lastStructuredError)",
                    lastStructuredError
                )
            }
        } catch {
            throw InstallError.installationFailedWithDetails(
                "安装失败: \(error.localizedDescription)",
                String(describing: error)
            )
        }
    }

    func cancel() {
        guard isInstalling else { return }
        PrivilegedHelperAdapter.shared.executeCommand(HelperSpecialCommand.hdpimCancel) { _ in }
        isInstalling = false
    }

    func getInstallCommand(for driverPath: String) -> String {
        return "HDPIM Engine (内置安装引擎，无需外部命令)"
    }

    func retry(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        cancel()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await install(at: appPath, progressHandler: progressHandler)
    }

    private static func consumeHelperOutput(
        _ output: String,
        state: InstallOutputState,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) {
        state.pending.append(output.replacingOccurrences(of: "\r\n", with: "\n"))

        while let newlineRange = state.pending.range(of: "\n") {
            let line = String(state.pending[..<newlineRange.lowerBound])
            state.pending.removeSubrange(...newlineRange.lowerBound)

            guard !line.isEmpty else { continue }

            if line.hasPrefix("PROGRESS|") {
                let components = line.split(separator: "|", maxSplits: 2).map(String.init)
                if components.count == 3, let progress = Double(components[1]) {
                    state.latestProgress = progress
                    let status = components[2]
                    if state.lastLoggedProgressStatus != status {
                        state.lastLoggedProgressStatus = status
                        logHandler?(status)
                    }
                    Task { @MainActor in
                        progressHandler(progress, status)
                    }
                }
                continue
            }

            if line.hasPrefix("LOG|") {
                let message = String(line.dropFirst(4))
                logHandler?(message)
                Task { @MainActor in
                    progressHandler(state.latestProgress, message)
                }
                continue
            }

            if line.hasPrefix("ERROR|") {
                let message = String(line.dropFirst(6))
                state.lastStructuredError = message
                logHandler?(message)
                Task { @MainActor in
                    progressHandler(state.latestProgress, "安装失败: \(message)")
                }
                continue
            }

            if line.hasPrefix("RESULT|") {
                continue
            }

            if line.hasPrefix("Exit Code:") {
                continue
            }

            logHandler?(line)
        }
    }

    private func prepareInstallSource(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) async throws -> PreparedInstallSource {
        guard needsInstallStaging(for: appPath) else {
            return PreparedInstallSource(url: appPath, cleanupURL: nil)
        }

        progressHandler(0.0, "正在准备安装源...")
        logHandler?("[HDPIM Install] 安装源位于受保护目录，正在复制到临时安装目录: \(appPath.path)")

        let stageRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Adobe Downloader/InstallSources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stageRoot.appendingPathComponent(appPath.lastPathComponent, isDirectory: true)

        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        do {
            try await runLocalCopy(sourceURL: appPath, destinationURL: stagedURL)
            try sanitizeStagedInstallSource(at: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stageRoot)
            throw InstallError.installationFailed("安装源复制失败: \(error.localizedDescription)")
        }

        logHandler?("[HDPIM Install] 临时安装目录准备完成: \(stagedURL.path)")
        return PreparedInstallSource(url: stagedURL, cleanupURL: stageRoot)
    }

    private func needsInstallStaging(for url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        let home = NSHomeDirectory()
        let protectedRoots = [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents"
        ]

        return protectedRoots.contains { standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/") }
    }

    private func runLocalCopy(sourceURL: URL, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                task.arguments = [sourceURL.path, destinationURL.path]
                task.standardOutput = stdout
                task.standardError = stderr

                do {
                    try task.run()
                    task.waitUntilExit()

                    if task.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? String(data: outputData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "ditto exited with code \(task.terminationStatus)"
                        continuation.resume(throwing: InstallError.installationFailed(message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sanitizeStagedInstallSource(at rootURL: URL) throws {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        let attributesToClear = [
            "com.apple.macl",
            "com.apple.provenance",
            "com.apple.quarantine"
        ]

        func clearAttributes(at url: URL, isSymbolicLink: Bool) {
            for attribute in attributesToClear {
                url.path.withCString { pathPtr in
                    attribute.withCString { namePtr in
                        _ = removexattr(pathPtr, namePtr, isSymbolicLink ? XATTR_NOFOLLOW : 0)
                    }
                }
            }
        }

        clearAttributes(at: rootURL, isSymbolicLink: false)

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let itemURL as URL in enumerator {
            let isSymbolicLink = (try? itemURL.resourceValues(forKeys: Set(keys)).isSymbolicLink) ?? false
            clearAttributes(at: itemURL, isSymbolicLink: isSymbolicLink)
        }
    }
}
