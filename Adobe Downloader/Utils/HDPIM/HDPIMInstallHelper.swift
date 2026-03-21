//
//  HDPIMInstallHelper.swift
//  Adobe Downloader
//
//

import Foundation

private func xmlEscapedPIMXValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

enum HDPIMPimxFragmentKind {
    case uninstall
    case repair
}

struct HDPIMDeleteEntry {
    let targetPath: String
    let isDirectory: Bool
    let isRecursiveDelete: Bool
    let isUserPreferences: Bool

    var normalizedTargetPath: String {
        let trimmed = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDirectory else {
            return trimmed
        }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    var xml: String {
        let tagName = isDirectory ? "DeleteDirectory" : "DeleteFile"
        var attributes = ["target=\"\(xmlEscapedPIMXValue(normalizedTargetPath))\""]
        if isDirectory && isRecursiveDelete {
            attributes.append("isRecursiveDelete=\"true\"")
        }
        if isUserPreferences {
            attributes.append("isUserPreferences=\"true\"")
        }
        return "<\(tagName) \(attributes.joined(separator: " "))></\(tagName)>"
    }
}

struct HDPIMPimxCommandFragment {
    let xml: String
    let kind: HDPIMPimxFragmentKind
}

class HDPIMInstallHelper {

    private let propertyTable: HDPIMPropertyTable
    var logHandler: ((String) -> Void)?

    private func log(_ message: String) {
        if let logHandler {
            logHandler(message)
        } else {
            print(message)
        }
    }

    init(propertyTable: HDPIMPropertyTable) {
        self.propertyTable = propertyTable
    }

    struct InstallResult {
        let executedCommands: [HDPIMCommand]
        let deleteEntries: [HDPIMDeleteEntry]
        let pimxFragments: [HDPIMPimxCommandFragment]
        let uninstallPIMXPath: URL?
        let uninstallPIMXHash: String?
        let uninstallPIMXHash256: String?
        let repairPIMXPath: URL?
        let repairPIMXHash: String?
        let repairPIMXHash256: String?
    }

    struct ExtractedPackageValidationResult {
        let pimxURL: URL
        let pimxData: Data
        let packageInfo: PIMXPackageInfo
        let stagingFolder: String
    }

    func installPackage(
        parsedPackage: ParsedPackage,
        extractDir: URL,
        sapCode: String,
        version: String,
        platform: String,
        amtConfigAppID: String?,
        installDir: String,
        aliasPackageName: String,
        productInstallDir: String,
        validatedExtract: ExtractedPackageValidationResult? = nil,
        progressHandler: ((Int, Int, String) -> Void)? = nil
    ) async throws -> InstallResult {

        log("[HDPIM InstallHelper] 开始安装包: \(parsedPackage.packageName)")
        log("[HDPIM InstallHelper] 解压目录: \(extractDir.path)")
        log("[HDPIM InstallHelper] AliasPackageName: \(aliasPackageName)")
        log("[HDPIM InstallHelper] 产品安装目录 (InstallDir): \(productInstallDir)")

        guard FileManager.default.fileExists(atPath: extractDir.path) else {
            throw HDPIMInstallError.extractionFailed("解压目录不存在: \(extractDir.path)")
        }

        propertyTable.setMediaFolder(extractDir.path)

        propertyTable.setSourceFolder(extractDir.path)

        let stagingFolder = extractDir.appendingPathComponent(aliasPackageName).path
        propertyTable.setStagingFolder(stagingFolder)
        log("[HDPIM InstallHelper] StagingFolder: \(stagingFolder)")

        propertyTable.setProductInstallDir(productInstallDir)
        log("[HDPIM InstallHelper] InstallDir (产品特定): \(productInstallDir)")

        let validationResult: ExtractedPackageValidationResult
        do {
            if let validatedExtract {
                validationResult = validatedExtract
            } else {
                validationResult = try Self.validateExtractedPackage(
                    parsedPackage: parsedPackage,
                    extractDir: extractDir,
                    aliasPackageName: aliasPackageName,
                    productInstallDir: productInstallDir,
                    propertyTable: propertyTable
                )
            }
        } catch {
            log("[HDPIM InstallHelper] PIMX 解析失败: \(error.localizedDescription)")
            throw error
        }

        let pimxURL = validationResult.pimxURL
        let pimxData = validationResult.pimxData
        let packageInfo = validationResult.packageInfo

        log("[HDPIM InstallHelper] 找到 PIMX: \(pimxURL.path)")
        log("[HDPIM InstallHelper] PIMX 文件大小: \(pimxData.count) 字节")
        if pimxData.count < 10 {
            log("[HDPIM InstallHelper] PIMX 文件内容(hex): \(pimxData.map { String(format: "%02x", $0) }.joined(separator: " "))")
            throw HDPIMInstallError.pimxNotFound("PIMX 文件为空或过小: \(pimxURL.path) (\(pimxData.count) bytes)")
        }
        let firstBytes = String(data: pimxData.prefix(200), encoding: .utf8) ?? ""
        log("[HDPIM InstallHelper] PIMX 开头: \(firstBytes.prefix(100))...")
        log("[HDPIM InstallHelper] StagingFolder 校验通过: \(validationResult.stagingFolder)")
        log("[HDPIM InstallHelper] PIMX 解析成功: \(packageInfo.commands.count) 条命令")

        if !parsedPackage.packageName.isEmpty && !packageInfo.packageName.isEmpty {
            let appJsonName = parsedPackage.packageName
            let pimxName = packageInfo.packageName
            if appJsonName != pimxName {
                print("Warning: 包名不完全匹配 - Application.json: '\(appJsonName)', PIMX: '\(pimxName)'")
            }
        }

        let engine = HDPIMCommandEngine(propertyTable: propertyTable)
        let commands = engine.generateCommands(from: packageInfo.commands)

        let executionResult = try await engine.executeAll(
            commands: commands,
            progressHandler: progressHandler
        )

        var uninstallPath: URL?
        var sha1Hash: String?
        var sha256Hash: String?
        var repairPath: URL?
        var repairSha1Hash: String?
        var repairSha256Hash: String?

        let pimxFileName = makePIMXFileName(
            sapCode: sapCode,
            version: version,
            platform: platform,
            amtConfigAppID: amtConfigAppID,
            packageName: parsedPackage.packageName,
            packageVersion: parsedPackage.packageVersion.isEmpty ? version : parsedPackage.packageVersion
        )
        let uninstallFragments = executionResult.pimxFragments
            .filter { $0.kind == .uninstall }
            .map(\.xml)
        let repairFragments = executionResult.pimxFragments
            .filter { $0.kind == .repair }
            .map(\.xml)
        let deleteFragments = makeDeleteCommandFragments(
            from: executionResult.deleteEntries,
            assetReferences: packageInfo.assetReferences
        )

        if !deleteFragments.isEmpty || !uninstallFragments.isEmpty {
            let uninstallGenerator = UninstallPIMXGenerator()
            uninstallGenerator.addReverseCommands(deleteFragments)
            uninstallGenerator.addReverseCommands(uninstallFragments)

            let uninstallDir = URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers/uninstallXml")

            let result = try uninstallGenerator.writeAndHash(
                to: uninstallDir,
                fileName: pimxFileName
            )
            uninstallPath = result.path
            sha1Hash = result.sha1
            sha256Hash = result.sha256
        }

        let repairDir = URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers/repairXml")
        let repairGenerator = UninstallPIMXGenerator()
        repairGenerator.addReverseCommands(repairFragments)
        let repairResult = try repairGenerator.writeAndHash(
            to: repairDir,
            fileName: pimxFileName
        )
        repairPath = repairResult.path
        repairSha1Hash = repairResult.sha1
        repairSha256Hash = repairResult.sha256

        return InstallResult(
            executedCommands: executionResult.executedCommands,
            deleteEntries: executionResult.deleteEntries,
            pimxFragments: executionResult.pimxFragments,
            uninstallPIMXPath: uninstallPath,
            uninstallPIMXHash: sha1Hash,
            uninstallPIMXHash256: sha256Hash,
            repairPIMXPath: repairPath,
            repairPIMXHash: repairSha1Hash,
            repairPIMXHash256: repairSha256Hash
        )
    }

    private func makePIMXFileName(
        sapCode: String,
        version: String,
        platform: String,
        amtConfigAppID: String?,
        packageName: String,
        packageVersion: String
    ) -> String {
        let normalizedVersion = version.replacingOccurrences(of: ".", with: "_")
        let appGuid = makeAPPGUIDPrefix(
            sapCode: sapCode,
            version: normalizedVersion,
            platform: platform,
            amtConfigAppID: amtConfigAppID
        )
        return "\(appGuid)_\(packageName)_\(packageVersion).pimx"
    }

    private func makeAPPGUIDPrefix(
        sapCode: String,
        version: String,
        platform: String,
        amtConfigAppID: String?
    ) -> String {
        let uppercasedAppID = amtConfigAppID?.uppercased() ?? ""
        if uppercasedAppID.contains("-32-") {
            return "\(sapCode)_\(version)_32"
        }
        if uppercasedAppID.contains("-64-") {
            return "\(sapCode)_\(version)"
        }

        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedPlatform == "OSX" || normalizedPlatform == "OSX10" {
            return "\(sapCode)_\(version)_32"
        }
        if normalizedPlatform == "WINARM64" {
            return "\(sapCode)_\(version)_arm64"
        }
        return "\(sapCode)_\(version)"
    }

    private func makeDeleteCommandFragments(
        from deleteEntries: [HDPIMDeleteEntry],
        assetReferences: [PIMXAssetReference]
    ) -> [String] {
        let orderedEntries = deleteEntries
            .filter { !shouldSkipDeleteEntry($0.normalizedTargetPath) }
            + makeSourceSideDeleteEntries(from: assetReferences)
            + makeDirectoryDeleteEntries(from: assetReferences)

        var seen: Set<String> = []
        return orderedEntries.compactMap { entry in
            guard !entry.normalizedTargetPath.isEmpty else {
                return nil
            }
            let key = "\(entry.isDirectory ? "D" : "F")|\(entry.normalizedTargetPath)|\(entry.isRecursiveDelete)|\(entry.isUserPreferences)"
            guard seen.insert(key).inserted else {
                return nil
            }
            return entry.xml
        }
    }

    private func makeSourceSideDeleteEntries(from assetReferences: [PIMXAssetReference]) -> [HDPIMDeleteEntry] {
        var entries: [HDPIMDeleteEntry] = []

        for asset in assetReferences {
            let sourcePath = asset.sourceTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRelativePIMXPath(sourcePath) else {
                continue
            }

            if sourcePath.localizedCaseInsensitiveContains("CustomHook"),
               !asset.isDirectoryLike {
                entries.append(
                    HDPIMDeleteEntry(
                        targetPath: sourcePath,
                        isDirectory: false,
                        isRecursiveDelete: false,
                        isUserPreferences: false
                    )
                )
            }

            for directory in recursiveParentDirectories(for: sourcePath) {
                entries.append(
                    HDPIMDeleteEntry(
                        targetPath: directory,
                        isDirectory: true,
                        isRecursiveDelete: false,
                        isUserPreferences: false
                    )
                )
            }
        }

        return entries
    }

    private func makeDirectoryDeleteEntries(from assetReferences: [PIMXAssetReference]) -> [HDPIMDeleteEntry] {
        let targetRoots = makeTargetRoots(from: assetReferences)
        var entries: [HDPIMDeleteEntry] = []

        for asset in assetReferences {
            let targetPath = asset.targetTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetPath.isEmpty, !shouldSkipDeleteEntry(targetPath) else {
                continue
            }

            let directoryPath = asset.isDirectoryLike
                ? normalizeDirectoryPIMXPath(targetPath)
                : normalizeDirectoryPIMXPath((targetPath as NSString).deletingLastPathComponent)
            guard !directoryPath.isEmpty else {
                continue
            }

            let root = targetRoots.first { directoryPath.hasPrefix($0) } ?? directoryPath
            for directory in recursiveParentDirectories(for: directoryPath, stoppingAt: root) {
                let isUserPreferences = directory.lowercased().hasPrefix("[userpreferences]/")
                    || directory.lowercased().hasPrefix("[usercommon]/")
                entries.append(
                    HDPIMDeleteEntry(
                        targetPath: directory,
                        isDirectory: true,
                        isRecursiveDelete: isUserPreferences,
                        isUserPreferences: isUserPreferences
                    )
                )
            }
        }

        return entries
    }

    private func makeTargetRoots(from assetReferences: [PIMXAssetReference]) -> [String] {
        var seen: Set<String> = []
        var roots: [String] = []

        for asset in assetReferences {
            let rawTarget = asset.targetTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTarget.isEmpty, !shouldSkipDeleteEntry(rawTarget) else {
                continue
            }

            let root = asset.isDirectoryLike
                ? normalizeDirectoryPIMXPath(rawTarget)
                : normalizeDirectoryPIMXPath((rawTarget as NSString).deletingLastPathComponent)
            guard !root.isEmpty, seen.insert(root).inserted else {
                continue
            }
            roots.append(root)
        }

        return roots.sorted { $0.count > $1.count }
    }

    private func recursiveParentDirectories(
        for path: String,
        stoppingAt stopPath: String? = nil
    ) -> [String] {
        var directories: [String] = []
        var cursor = normalizeDirectoryPIMXPath(path)
        let normalizedStop = stopPath.map(normalizeDirectoryPIMXPath)

        while !cursor.isEmpty {
            directories.append(cursor)
            if let normalizedStop, cursor == normalizedStop {
                break
            }

            let parent = normalizeDirectoryPIMXPath((cursor as NSString).deletingLastPathComponent)
            if parent.isEmpty || parent == cursor {
                break
            }
            cursor = parent
        }

        return directories
    }

    private func isRelativePIMXPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("[")
    }

    private func normalizeDirectoryPIMXPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private func shouldSkipDeleteEntry(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("["),
           normalized.localizedCaseInsensitiveContains("/CustomHook/") {
            return true
        }
        return false
    }

    static func validateExtractedPackage(
        parsedPackage: ParsedPackage,
        extractDir: URL,
        aliasPackageName: String,
        productInstallDir: String,
        propertyTable: HDPIMPropertyTable
    ) throws -> ExtractedPackageValidationResult {
        guard FileManager.default.fileExists(atPath: extractDir.path) else {
            throw HDPIMInstallError.extractionFailed("解压目录不存在: \(extractDir.path)")
        }

        let validationTable = propertyTable.cloned()
        validationTable.setMediaFolder(extractDir.path)
        validationTable.setSourceFolder(extractDir.path)

        let resolvedAlias = aliasPackageName.isEmpty ? parsedPackage.packageName : aliasPackageName
        let stagingFolder = extractDir.appendingPathComponent(resolvedAlias).path
        validationTable.setStagingFolder(stagingFolder)
        validationTable.setProductInstallDir(productInstallDir)

        let pimxURL = try findValidatedPIMX(
            in: extractDir,
            packageName: parsedPackage.packageName,
            aliasPackageName: resolvedAlias
        )
        let pimxData = try PIMXParser.loadXMLData(from: pimxURL)

        let parser = PIMXParser(propertyTable: validationTable)
        let packageInfo = try parser.parse(pimxURL: pimxURL, xmlData: pimxData, extractDir: extractDir)
        try validateRequiredAssetSources(packageName: parsedPackage.packageName, assetReferences: packageInfo.assetReferences)

        return ExtractedPackageValidationResult(
            pimxURL: pimxURL,
            pimxData: pimxData,
            packageInfo: packageInfo,
            stagingFolder: stagingFolder
        )
    }

    private static func validateRequiredAssetSources(
        packageName: String,
        assetReferences: [PIMXAssetReference]
    ) throws {
        let missingSources = assetReferences
            .map(\.source)
            .filter { !FileManager.default.fileExists(atPath: $0) }

        guard missingSources.isEmpty else {
            let preview = missingSources.prefix(5).joined(separator: " | ")
            throw HDPIMInstallError.extractionFailed("包 \(packageName) 的 staging 资源缺失: \(preview)")
        }
    }

    private static func findValidatedPIMX(
        in extractDir: URL,
        packageName: String,
        aliasPackageName: String
    ) throws -> URL {
        let rootMatches = pimxCandidates(in: extractDir)
        if rootMatches.count == 1, let pimxURL = rootMatches.first {
            return pimxURL
        }

        let aliasDir = extractDir.appendingPathComponent(aliasPackageName, isDirectory: true)
        let aliasMatches = pimxCandidates(in: aliasDir)
        if aliasMatches.count == 1, let pimxURL = aliasMatches.first {
            return pimxURL
        }

        if FileManager.default.fileExists(atPath: extractDir.appendingPathComponent("pimx.xml").path) {
            return extractDir.appendingPathComponent("pimx.xml")
        }

        throw HDPIMInstallError.extractionFailed(
            "包 \(packageName) 的解压目录中 .pimx 数量异常: root=\(rootMatches.count), alias=\(aliasMatches.count)"
        )
    }

    private static func pimxCandidates(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { $0.pathExtension.lowercased() == "pimx" }
    }
}
