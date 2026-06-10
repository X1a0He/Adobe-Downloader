//
//  InstallManager.swift
//  Adobe Downloader
//

import Foundation
import Darwin
import AppKit

actor InstallManager {
    final class InstallOutputState {
        var pending = ""
        var latestProgress = 0.0
        var lastStructuredError: String?
        var lastLoggedProgressStatus: String?
    }

    private struct PreparedInstallSource {
        let url: URL
        let cleanupURL: URL?
    }

    private struct AcrobatPIMXInstallCandidate {
        let pimxURL: URL
        let stagingURL: URL
        let propertyTable: HDPIMPropertyTable
        let packageInfo: PIMXPackageInfo
        let score: Int
    }

    enum InstallError: Error, LocalizedError {
        case installationFailed(String)
        case cancelled
        case permissionDenied
        case installationFailedWithDetails(String, String)
        case installerOpened(String)

        var errorDescription: String? {
            switch self {
            case .installationFailed(let message): return message
            case .cancelled: return String(localized: "安装已取消")
            case .permissionDenied: return String(localized: "权限被拒绝")
            case .installationFailedWithDetails(let message, _): return message
            case .installerOpened(let message): return message
            }
        }
    }

    private var isInstalling = false

    private static var shouldEmitDetailedInstallLogs: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func emitDetailedInstallLog(_ message: String, logHandler: ((String) -> Void)?) {
        guard shouldEmitDetailedInstallLogs else {
            return
        }
        logHandler?(message)
    }

    func install(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        let sourceURL = resolvedInstallSourceURL(for: appPath)
        let preparedSource = try await prepareInstallSource(
            at: sourceURL,
            progressHandler: progressHandler,
            logHandler: logHandler
        )
        defer {
            if let cleanupURL = preparedSource.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        if !FileManager.default.fileExists(atPath: preparedSource.url.appendingPathComponent("driver.xml").path),
           try await installAcrobatSourceIfPossible(
            preparedSource.url,
            progressHandler: progressHandler,
            logHandler: logHandler
           ) {
            return
        }

        let driverPath = preparedSource.url.appendingPathComponent("driver.xml").path
        guard FileManager.default.fileExists(atPath: driverPath) else {
            throw InstallError.installationFailed("找不到 driver.xml 文件")
        }

        let productDir = preparedSource.url.path
        let userHome = NSHomeDirectory()
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]

        isInstalling = true
        defer { isInstalling = false }

        do {
            let outputState = InstallOutputState()

            try await HelperManager.shared.executeHDPIMInstall(
                productDir: productDir,
                userHome: userHome,
                executablePath: executablePath
            ) { output in
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
        Task {
            try? await HelperManager.shared.cancelCurrentOperation()
        }
        isInstalling = false
    }

    func getInstallCommand(for driverPath: String) -> String {
        return "HDPIM Engine (内置安装引擎，无需外部命令)"
    }

    func retry(
        at appPath: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)? = nil
    ) async throws {
        cancel()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await install(at: appPath, progressHandler: progressHandler, logHandler: logHandler)
    }

    static func consumeHelperOutput(
        _ output: String,
        state: InstallOutputState,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?,
        failureStatusPrefix: String = "安装失败",
        includeUnstructuredOutput: Bool = true
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
                        emitDetailedInstallLog(status, logHandler: logHandler)
                    }
                    Task { @MainActor in
                        progressHandler(progress, status)
                    }
                }
                continue
            }

            if line.hasPrefix("LOG|") {
                let message = String(line.dropFirst(4))
                if shouldEmitDetailedInstallLogs {
                    logHandler?(message)
                    Task { @MainActor in
                        progressHandler(state.latestProgress, message)
                    }
                }
                continue
            }

            if line.hasPrefix("ERROR|") {
                let message = String(line.dropFirst(6))
                state.lastStructuredError = message
                logHandler?(message)
                Task { @MainActor in
                    progressHandler(state.latestProgress, "\(failureStatusPrefix): \(message)")
                }
                continue
            }

            if line.hasPrefix("RESULT|") {
                continue
            }

            if line.hasPrefix("Exit Code:") {
                continue
            }

            guard includeUnstructuredOutput else {
                continue
            }

            emitDetailedInstallLog(line, logHandler: logHandler)
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
        Self.emitDetailedInstallLog("[HDPIM Install] 安装源位于受保护目录，正在复制到临时安装目录: \(appPath.path)", logHandler: logHandler)

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

        Self.emitDetailedInstallLog("[HDPIM Install] 临时安装目录准备完成: \(stagedURL.path)", logHandler: logHandler)
        return PreparedInstallSource(url: stagedURL, cleanupURL: stageRoot)
    }

    private func resolvedInstallSourceURL(for appPath: URL) -> URL {
        if FileManager.default.fileExists(atPath: appPath.path) {
            return appPath
        }

        return extractedAcrobatSourceURL(for: appPath) ?? appPath
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

    private func installAcrobatSourceIfPossible(
        _ sourceURL: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) async throws -> Bool {
        do {
            if sourceURL.pathExtension.lowercased() == "dmg" {
                try await installAcrobatDMG(
                    sourceURL,
                    progressHandler: progressHandler,
                    logHandler: logHandler
                )
                return true
            }

            if let extractedURL = extractedAcrobatSourceURL(for: sourceURL) {
                try await installAcrobatDirectory(
                    extractedURL,
                    progressHandler: progressHandler,
                    logHandler: logHandler
                )
                return true
            }

            try await installAcrobatDirectory(
                sourceURL,
                progressHandler: progressHandler,
                logHandler: logHandler
            )
            return true
        } catch AcrobatInstallSourceError.notAcrobatSource {
            return false
        }
    }

    private func extractedAcrobatSourceURL(for sourceURL: URL) -> URL? {
        guard sourceURL.pathExtension.lowercased() == "dmg" else {
            return nil
        }

        let extractedURL = sourceURL.deletingPathExtension()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: extractedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return extractedURL
    }

    private func installAcrobatDMG(
        _ dmgURL: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) async throws {
        guard FileManager.default.fileExists(atPath: dmgURL.path) else {
            throw AcrobatInstallSourceError.notAcrobatSource
        }

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdobeDownloader-Acrobat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        defer {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", mountPoint.path, "-quiet"]
            try? process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: mountPoint)
        }

        Task { @MainActor in
            progressHandler(0.05, "正在挂载 Acrobat 安装镜像...")
        }
        Self.emitDetailedInstallLog("[Acrobat Install] 挂载 DMG: \(dmgURL.path)", logHandler: logHandler)

        let attachOutput = try await runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-mountpoint", mountPoint.path, "-noverify", "-noautoopen", "-nobrowse", "-noautofsck", "-readonly", "-quiet"]
        )
        guard attachOutput.exitCode == 0 else {
            throw InstallError.installationFailed(attachOutput.output)
        }

        try await installAcrobatDirectory(
            mountPoint,
            progressHandler: progressHandler,
            logHandler: logHandler
        )
    }

    private func installAcrobatDirectory(
        _ directoryURL: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AcrobatInstallSourceError.notAcrobatSource
        }

        if try await installAcrobatWithPIMXIfPossible(
            directoryURL,
            progressHandler: progressHandler,
            logHandler: logHandler
        ) {
            return
        }

        if let packageURL = firstInstallerPackage(in: directoryURL) {
            Task { @MainActor in
                progressHandler(0.2, "正在安装 Acrobat 安装包...")
            }
            Self.emitDetailedInstallLog("[Acrobat Install] 使用 pkg 安装: \(packageURL.path)", logHandler: logHandler)
            try await HelperManager.shared.installPackage(at: packageURL.path, target: "/")
            Task { @MainActor in
                progressHandler(1.0, "安装完成")
            }
            return
        }

        if let appURL = firstInstallerApplication(in: directoryURL) {
            Task { @MainActor in
                progressHandler(0.8, "已打开 Acrobat 安装器，请按提示完成安装")
            }
            Self.emitDetailedInstallLog("[Acrobat Install] 打开 app 安装器: \(appURL.path)", logHandler: logHandler)
            _ = await MainActor.run {
                NSWorkspace.shared.open(appURL)
            }
            throw InstallError.installerOpened("已打开 Acrobat 安装器，请按提示完成安装")
        }

        throw AcrobatInstallSourceError.notAcrobatSource
    }

    private func installAcrobatWithPIMXIfPossible(
        _ directoryURL: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)?
    ) async throws -> Bool {
        let candidates = acrobatPIMXInstallCandidates(in: directoryURL, logHandler: logHandler)
            .sorted { $0.score > $1.score }
        guard let candidate = candidates.first else {
            return false
        }

        let commands = HDPIMCommandEngine(propertyTable: candidate.propertyTable)
            .generateCommands(from: candidate.packageInfo.commands)
        guard !commands.isEmpty else {
            return false
        }

        Task { @MainActor in
            progressHandler(0.12, "正在执行 Acrobat 自动安装脚本...")
        }
        Self.emitDetailedInstallLog("[Acrobat Install] 使用 PIMX 自动安装: \(candidate.pimxURL.path)", logHandler: logHandler)
        Self.emitDetailedInstallLog("[Acrobat Install] StagingFolder: \(candidate.stagingURL.path)", logHandler: logHandler)

        let oldStagingFolder = currentEnvironmentValue(HDPIMHeadlessInstallRunner.stagingFolderEnvironmentKey)
        let oldUserHome = currentEnvironmentValue(HDPIMHeadlessInstallRunner.userHomeEnvironmentKey)
        setEnvironmentValue(HDPIMHeadlessInstallRunner.stagingFolderEnvironmentKey, candidate.stagingURL.path)
        setEnvironmentValue(HDPIMHeadlessInstallRunner.userHomeEnvironmentKey, NSHomeDirectory())
        defer {
            setEnvironmentValue(HDPIMHeadlessInstallRunner.stagingFolderEnvironmentKey, oldStagingFolder)
            setEnvironmentValue(HDPIMHeadlessInstallRunner.userHomeEnvironmentKey, oldUserHome)
        }

        let engine = HDPIMCommandEngine(propertyTable: candidate.propertyTable)
        do {
            _ = try await engine.executeAll(commands: commands) { index, total, commandName in
                let normalizedTotal = max(total, 1)
                let ratio = Double(index + 1) / Double(normalizedTotal)
                let progress = 0.12 + ratio * 0.83
                let percent = Int(ratio * 100)
                let status = commandName.contains("正在处理:")
                    ? "[Acrobat] \(commandName)"
                    : "正在自动安装 Acrobat... \(percent)%"
                Task { @MainActor in
                    progressHandler(progress, status)
                }
            }
        } catch {
            throw InstallError.installationFailedWithDetails(
                "Acrobat 自动安装失败: \(error.localizedDescription)",
                "PIMX: \(candidate.pimxURL.path)\nStagingFolder: \(candidate.stagingURL.path)\n\(String(describing: error))"
            )
        }

        Task { @MainActor in
            progressHandler(1.0, "安装完成")
        }
        return true
    }

    private func acrobatPIMXInstallCandidates(
        in rootURL: URL,
        logHandler: ((String) -> Void)?
    ) -> [AcrobatPIMXInstallCandidate] {
        let pimxURLs = pimxCandidates(in: rootURL)
            .sorted { pimxDiscoveryScore($0, rootURL: rootURL) > pimxDiscoveryScore($1, rootURL: rootURL) }
        guard !pimxURLs.isEmpty else {
            return []
        }

        var candidates: [AcrobatPIMXInstallCandidate] = []
        for pimxURL in pimxURLs {
            do {
                let xmlData = try PIMXParser.loadXMLData(from: pimxURL, writeBackIfNeeded: false)
                let packageName = pimxPackageName(from: xmlData)
                let stagingCandidates = acrobatStagingCandidates(
                    rootURL: rootURL,
                    pimxURL: pimxURL,
                    packageName: packageName
                )

                for stagingURL in stagingCandidates {
                    let propertyTable = acrobatPIMXPropertyTable(
                        rootURL: rootURL,
                        stagingURL: stagingURL
                    )
                    let parser = PIMXParser(propertyTable: propertyTable)
                    let packageInfo = try parser.parse(
                        pimxURL: pimxURL,
                        xmlData: xmlData,
                        extractDir: rootURL
                    )

                    guard isLikelyAcrobatPIMX(
                        pimxURL: pimxURL,
                        rootURL: rootURL,
                        packageInfo: packageInfo
                    ) else {
                        Self.emitDetailedInstallLog("[Acrobat Install] 跳过非 Acrobat PIMX: \(pimxURL.path)", logHandler: logHandler)
                        break
                    }

                    let missingSources = missingRequiredAssetSources(packageInfo.assetReferences)
                    guard missingSources.isEmpty else {
                        Self.emitDetailedInstallLog(
                            "[Acrobat Install] PIMX staging 不匹配: \(pimxURL.path), staging=\(stagingURL.path), missing=\(missingSources.prefix(3).joined(separator: " | "))",
                            logHandler: logHandler
                        )
                        continue
                    }

                    let score = pimxDiscoveryScore(pimxURL, rootURL: rootURL)
                        + acrobatPackageScore(packageInfo.packageName)
                        + packageInfo.commands.count
                    candidates.append(AcrobatPIMXInstallCandidate(
                        pimxURL: pimxURL,
                        stagingURL: stagingURL,
                        propertyTable: propertyTable,
                        packageInfo: packageInfo,
                        score: score
                    ))
                    break
                }
            } catch {
                Self.emitDetailedInstallLog("[Acrobat Install] PIMX 解析失败: \(pimxURL.path), \(error.localizedDescription)", logHandler: logHandler)
            }
        }

        return candidates
    }

    private func pimxCandidates(in rootURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            let pathExtension = url.pathExtension.lowercased()
            if pathExtension == "pimx" || name == "pimx.xml" {
                candidates.append(url)
            }
        }
        return candidates
    }

    private func acrobatPIMXPropertyTable(rootURL: URL, stagingURL: URL) -> HDPIMPropertyTable {
        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
        propertyTable.setInstallDir("/Applications")
        propertyTable.setTargetDir("/Applications")
        propertyTable.setProductInstallDir("/Applications")
        propertyTable.setMediaFolder(rootURL.path)
        propertyTable.setSourceFolder(rootURL.path)
        propertyTable.setStagingFolder(stagingURL.path)
        propertyTable.setProperty("workflowType", "install")
        propertyTable.setProperty("AdobePayload", stagingURL.path)
        propertyTable.setProperty("Payload", stagingURL.path)

        let localeIdentifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        if !localeIdentifier.isEmpty {
            propertyTable.setProperty("installLanguage", localeIdentifier)
            propertyTable.setProperty("uiDisplayLanguage", localeIdentifier)
        }

        return propertyTable
    }

    private func acrobatStagingCandidates(
        rootURL: URL,
        pimxURL: URL,
        packageName: String
    ) -> [URL] {
        var candidates: [URL] = []
        func append(_ url: URL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let path = url.standardizedFileURL.path
            guard !candidates.contains(where: { $0.standardizedFileURL.path == path }) else {
                return
            }
            candidates.append(url)
        }

        let pimxParent = pimxURL.deletingLastPathComponent()
        append(rootURL)
        append(pimxParent)
        append(rootURL.appendingPathComponent("Payloads", isDirectory: true))
        append(rootURL.appendingPathComponent("payloads", isDirectory: true))
        append(rootURL.appendingPathComponent("AdobePayload", isDirectory: true))

        if !packageName.isEmpty {
            append(rootURL.appendingPathComponent(packageName, isDirectory: true))
            append(pimxParent.appendingPathComponent(packageName, isDirectory: true))
        }

        for baseURL in [rootURL, pimxParent] {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for itemURL in contents {
                let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else {
                    continue
                }
                let name = itemURL.lastPathComponent.lowercased()
                if name.contains("acrobat")
                    || name.contains("acro")
                    || name.contains("apro")
                    || (!packageName.isEmpty && name == packageName.lowercased()) {
                    append(itemURL)
                }
            }
        }

        return candidates
    }

    private func pimxPackageName(from xmlData: Data) -> String {
        guard let xmlDoc = try? XMLDocument(data: xmlData, options: []) else {
            return ""
        }
        return ((try? xmlDoc.nodes(forXPath: "//PackageName").first?.stringValue) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func missingRequiredAssetSources(_ assetReferences: [PIMXAssetReference]) -> [String] {
        assetReferences
            .map(\.source)
            .filter { !$0.isEmpty && !FileManager.default.fileExists(atPath: $0) }
    }

    private func isLikelyAcrobatPIMX(
        pimxURL: URL,
        rootURL: URL,
        packageInfo: PIMXPackageInfo
    ) -> Bool {
        let assetText = packageInfo.assetReferences
            .prefix(20)
            .flatMap { [$0.sourceTemplate, $0.targetTemplate] }
            .joined(separator: " ")
        let text = [
            rootURL.lastPathComponent,
            pimxURL.path,
            packageInfo.packageName,
            assetText
        ]
            .joined(separator: " ")
            .lowercased()

        return text.contains("acrobat")
            || text.contains("acro")
            || text.contains("apro")
            || text.contains("adobe pdf")
    }

    private func pimxDiscoveryScore(_ url: URL, rootURL: URL) -> Int {
        let path = url.path.lowercased()
        var score = 0
        if path.contains("acrobat") { score += 100 }
        if path.contains("apro") { score += 90 }
        if path.contains("acro") { score += 70 }
        if path.contains("install") { score += 40 }
        if path.contains("setup") { score += 30 }
        if path.contains("payload") { score += 20 }
        if path.contains("uninstall") { score -= 100 }
        if path.contains("repair") { score -= 40 }

        let relativeDepth = url.path
            .replacingOccurrences(of: rootURL.path, with: "")
            .split(separator: "/")
            .count
        score -= relativeDepth
        return score
    }

    private func acrobatPackageScore(_ packageName: String) -> Int {
        let name = packageName.lowercased()
        var score = 0
        if name.contains("acrobat") { score += 100 }
        if name.contains("apro") { score += 90 }
        if name.contains("acro") { score += 70 }
        if name.contains("install") { score += 30 }
        if name.contains("uninstall") { score -= 100 }
        return score
    }

    private func currentEnvironmentValue(_ key: String) -> String? {
        guard let value = getenv(key) else {
            return nil
        }
        return String(cString: value)
    }

    private func setEnvironmentValue(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    private func firstInstallerPackage(in rootURL: URL) -> URL? {
        installerCandidates(in: rootURL, extensions: ["pkg"])
            .sorted { installerScore($0) > installerScore($1) }
            .first
    }

    private func firstInstallerApplication(in rootURL: URL) -> URL? {
        installerCandidates(in: rootURL, extensions: ["app"])
            .sorted { installerScore($0) > installerScore($1) }
            .first
    }

    private func installerCandidates(in rootURL: URL, extensions: Set<String>) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let pathExtension = url.pathExtension.lowercased()
            guard extensions.contains(pathExtension) else {
                continue
            }

            if pathExtension == "app" || pathExtension == "pkg" {
                enumerator.skipDescendants()
            }

            candidates.append(url)
        }
        return candidates
    }

    private func installerScore(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        var score = 0
        if name.contains("acrobat") { score += 40 }
        if name.contains("install") { score += 30 }
        if name.contains("setup") { score += 20 }
        if name.contains("adobe") { score += 10 }
        return score
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> (exitCode: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private enum AcrobatInstallSourceError: Error {
        case notAcrobatSource
    }
}
