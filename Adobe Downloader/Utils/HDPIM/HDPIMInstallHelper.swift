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
        .replacingOccurrences(of: "\r", with: "&#13;")
        .replacingOccurrences(of: "\n", with: "&#10;")
        .replacingOccurrences(of: "\t", with: "&#9;")
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
    var actualTargetPath: String? = nil

    var normalizedTargetPath: String {
        let trimmed = actualTargetPath == nil ? targetPath.trimmingCharacters(in: .whitespacesAndNewlines) : targetPath
        guard isDirectory else {
            return trimmed
        }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    var xml: String {
        xml(literalPath: nil)
    }

    func xml(literalPath: PIMXLiteralPath?) -> String {
        let tagName = isDirectory ? "DeleteDirectory" : "DeleteFile"
        let path = literalPath == nil ? normalizedTargetPath.replacingOccurrences(of: "\r", with: ":x0D") : normalizedTargetPath
        var attributes = ["target=\"\(xmlEscapedPIMXValue(path))\""]
        if let literalPath {
            attributes.append("\(PIMXLiteralPath.templateAttribute)=\"\(xmlEscapedPIMXValue(literalPath.template))\"")
            attributes.append("\(PIMXLiteralPath.relativePathAttribute)=\"\(xmlEscapedPIMXValue(literalPath.relativePath))\"")
        }
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
        #if DEBUG
        if let logHandler {
            logHandler(message)
        } else {
            print(message)
        }
        #endif
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
        commandWillExecute: ((HDPIMCommand) throws -> Void)? = nil,
        commandDidExecute: ((HDPIMCommand) -> Void)? = nil,
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
        setenv(HDPIMHeadlessInstallRunner.stagingFolderEnvironmentKey, stagingFolder, 1)

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
                throw HDPIMInstallError.packageNameMismatch(expected: appJsonName, actual: pimxName)
            }
        }

        guard packageInfo.uninstallManifest != nil else {
            throw HDPIMMaterialError.invalid("包 \(packageInfo.packageName) 缺少完整卸载清单")
        }
        let engine = HDPIMCommandEngine(propertyTable: propertyTable)
        let commands = engine.generateCommands(from: packageInfo.commands)

        let executionResult = try await engine.executeAll(
            commands: commands,
            commandWillExecute: commandWillExecute,
            commandDidExecute: commandDidExecute,
            progressHandler: progressHandler
        )

        return try persistPackageArtifacts(
            parsedPackage: parsedPackage, packageInfo: packageInfo,
            executedCommands: executionResult.executedCommands,
            deleteEntries: executionResult.deleteEntries, pimxFragments: executionResult.pimxFragments,
            sapCode: sapCode, version: version, platform: platform, amtConfigAppID: amtConfigAppID
        )
    }

    func preparePackageArtifacts(
        parsedPackage: ParsedPackage,
        validatedExtract: ExtractedPackageValidationResult,
        executedCommands: [HDPIMCommand],
        sapCode: String,
        version: String,
        platform: String,
        amtConfigAppID: String?,
        uninstallManifestOverride: [HDPIMDeleteEntry]? = nil,
        literalPathsOverride: [PIMXLiteralPath.Key: PIMXLiteralPath]? = nil
    ) throws -> InstallResult {
        let packageInfo = validatedExtract.packageInfo
        let commands = HDPIMCommandEngine(propertyTable: propertyTable).generateCommands(from: packageInfo.commands)
        return try persistPackageArtifacts(
            parsedPackage: parsedPackage, packageInfo: packageInfo,
            executedCommands: executedCommands, deleteEntries: executedCommands.flatMap { $0.getDeleteEntries() },
            pimxFragments: commands.flatMap { $0.getPimxCommandFragments() },
            sapCode: sapCode, version: version, platform: platform, amtConfigAppID: amtConfigAppID,
            uninstallManifestOverride: uninstallManifestOverride,
            literalPathsOverride: literalPathsOverride
        )
    }

    struct MaterialXML {
        let uninstall: String?
        let repair: String
    }

    func materialXML(
        packageInfo: PIMXPackageInfo,
        executedCommands: [HDPIMCommand],
        deleteEntries: [HDPIMDeleteEntry] = [],
        pimxFragments: [HDPIMPimxCommandFragment],
        uninstallManifestOverride: [HDPIMDeleteEntry]? = nil,
        literalPathsOverride: [PIMXLiteralPath.Key: PIMXLiteralPath]? = nil
    ) throws -> MaterialXML {
        let generators = try materialGenerators(
            packageInfo: packageInfo, executedCommands: executedCommands,
            deleteEntries: deleteEntries, pimxFragments: pimxFragments,
            uninstallManifestOverride: uninstallManifestOverride,
            literalPathsOverride: literalPathsOverride
        )
        return MaterialXML(uninstall: generators.uninstall.generate(),
                           repair: generators.repair.generate())
    }

    private func materialGenerators(
        packageInfo: PIMXPackageInfo,
        executedCommands: [HDPIMCommand],
        deleteEntries: [HDPIMDeleteEntry],
        pimxFragments: [HDPIMPimxCommandFragment],
        uninstallManifestOverride: [HDPIMDeleteEntry]?,
        literalPathsOverride: [PIMXLiteralPath.Key: PIMXLiteralPath]?
    ) throws -> (uninstall: UninstallPIMXGenerator, repair: UninstallPIMXGenerator, entries: [HDPIMDeleteEntry]) {
        guard let manifest = uninstallManifestOverride ?? packageInfo.uninstallManifest else {
            throw HDPIMMaterialError.invalid("包 \(packageInfo.packageName) 缺少完整卸载清单")
        }
        let entries = manifest + deleteEntries.compactMap { applyingAssetDeletionPolicy(to: $0, assets: packageInfo.assetReferences) }
        let uninstall = UninstallPIMXGenerator()
        uninstall.addReverseCommands(makeDeleteCommandFragments(
            from: entries, assetReferences: uninstallManifestOverride == nil ? packageInfo.assetReferences.filter { !$0.isPermanent } : [],
            literalPaths: literalPathsOverride ?? packageInfo.literalPaths,
            localizations: localizations(from: executedCommands)
        ))
        uninstall.addReverseCommands(pimxFragments.filter { $0.kind == .uninstall }.map(\.xml))
        let repair = UninstallPIMXGenerator()
        repair.addReverseCommands(pimxFragments.filter { $0.kind == .repair }.map(\.xml))
        return (uninstall, repair, entries)
    }

    private func persistPackageArtifacts(
        parsedPackage: ParsedPackage,
        packageInfo: PIMXPackageInfo,
        executedCommands: [HDPIMCommand],
        deleteEntries: [HDPIMDeleteEntry],
        pimxFragments: [HDPIMPimxCommandFragment],
        sapCode: String,
        version: String,
        platform: String,
        amtConfigAppID: String?,
        uninstallManifestOverride: [HDPIMDeleteEntry]? = nil,
        literalPathsOverride: [PIMXLiteralPath.Key: PIMXLiteralPath]? = nil
    ) throws -> InstallResult {
        let generators = try materialGenerators(
            packageInfo: packageInfo, executedCommands: executedCommands,
            deleteEntries: deleteEntries, pimxFragments: pimxFragments,
            uninstallManifestOverride: uninstallManifestOverride,
            literalPathsOverride: literalPathsOverride
        )
        let pimxFileName = makePIMXFileName(
            sapCode: sapCode, version: version, platform: platform, amtConfigAppID: amtConfigAppID,
            packageName: parsedPackage.packageName,
            packageVersion: parsedPackage.packageVersion.isEmpty ? version : parsedPackage.packageVersion
        )
        let root = URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers", isDirectory: true)
        let uninstallResult = try generators.uninstall.writeAndHash(
            to: root.appendingPathComponent("uninstallXml"), fileName: pimxFileName
        )
        let repairResult = try generators.repair.writeAndHash(to: root.appendingPathComponent("repairXml"), fileName: pimxFileName)
        return InstallResult(
            executedCommands: executedCommands, deleteEntries: generators.entries, pimxFragments: pimxFragments,
            uninstallPIMXPath: uninstallResult.path,
            uninstallPIMXHash: uninstallResult.sha1, uninstallPIMXHash256: uninstallResult.sha256,
            repairPIMXPath: repairResult.path, repairPIMXHash: repairResult.sha1, repairPIMXHash256: repairResult.sha256
        )
    }

    func artifactURLs(for package: PackageToInstall, amtConfigAppID: String?) -> [URL] {
        let fileName = makePIMXFileName(sapCode: package.sapCode, version: package.version,
                                      platform: package.platform, amtConfigAppID: amtConfigAppID,
                                      packageName: package.packageName,
                                      packageVersion: package.parsed.packageVersion.isEmpty ? package.version : package.parsed.packageVersion)
        return ["uninstallXml", "repairXml"].map {
            URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers").appendingPathComponent($0).appendingPathComponent(fileName)
        }
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

    private func applyingAssetDeletionPolicy(to entry: HDPIMDeleteEntry, assets: [PIMXAssetReference]) -> HDPIMDeleteEntry? {
        let actual = entry.actualTargetPath ?? propertyTable.expandPath(entry.targetPath)
        let match = assets.filter {
            let root = URL(fileURLWithPath: $0.target).path
            return actual == root || ($0.isDirectoryLike && actual.hasPrefix(root + "/"))
        }.max { $0.target.count < $1.target.count }
        guard let match else { return entry }
        guard !match.isPermanent else { return nil }
        return HDPIMDeleteEntry(
            targetPath: entry.targetPath, isDirectory: entry.isDirectory,
            isRecursiveDelete: entry.isDirectory && actual == URL(fileURLWithPath: match.target).path && match.isRecursiveDelete,
            isUserPreferences: match.isUserPreferences, actualTargetPath: entry.actualTargetPath
        )
    }

    private func localizations(from commands: [HDPIMCommand]) -> [(source: String, target: String)] {
        commands.compactMap { command in
            guard let move = command as? LocalizeFileCommand else { return nil }
            return (move.source, move.target)
        }
    }

    func makeDeleteCommandFragments(
        from deleteEntries: [HDPIMDeleteEntry],
        assetReferences: [PIMXAssetReference],
        literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath],
        localizations: [(source: String, target: String)] = []
    ) -> [String] {
        let orderedEntries = deleteEntries
            + makeSourceSideDeleteEntries(from: assetReferences)
            + makeDirectoryDeleteEntries(from: assetReferences)

        var seen: Set<String> = []
        return orderedEntries.compactMap { original in
            var entry = original
            let originalPath = original.actualTargetPath ?? propertyTable.expandPath(original.targetPath)
            var actualPath = originalPath
            for move in localizations {
                if actualPath == move.source || actualPath.hasPrefix(move.source + "/") {
                    actualPath = move.target + actualPath.dropFirst(move.source.count)
                }
            }
            if actualPath != originalPath {
                entry = HDPIMDeleteEntry(targetPath: actualPath, isDirectory: original.isDirectory,
                    isRecursiveDelete: original.isRecursiveDelete, isUserPreferences: original.isUserPreferences,
                    actualTargetPath: actualPath)
            }
            guard !entry.normalizedTargetPath.isEmpty else {
                return nil
            }
            var literalPath = entry.actualTargetPath.flatMap {
                literalPaths[PIMXLiteralPath.Key(actualTarget: $0, targetTemplate: entry.normalizedTargetPath)]
            }
            if literalPath == nil, actualPath.hasPrefix("/"), actualPath.contains("[") || actualPath.contains(":x0D") {
                let components = actualPath.split(separator: "/").map(String.init)
                if let index = components.firstIndex(where: { $0.contains("[") || $0.contains(":x0D") }), index > 0 {
                    literalPath = PIMXLiteralPath(template: "/" + components[..<index].joined(separator: "/"),
                                                 relativePath: components[index...].joined(separator: "/"))
                    entry = HDPIMDeleteEntry(targetPath: actualPath, isDirectory: entry.isDirectory,
                        isRecursiveDelete: entry.isRecursiveDelete, isUserPreferences: entry.isUserPreferences,
                        actualTargetPath: actualPath)
                }
            }
            let identity = "\(entry.isDirectory ? "D" : "F")|\(URL(fileURLWithPath: actualPath).path)"
            guard seen.insert(identity).inserted else {
                return nil
            }
            return entry.xml(literalPath: literalPath)
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
            guard !targetPath.isEmpty else {
                continue
            }

            let directoryPath = asset.isDirectoryLike
                ? normalizeDirectoryPIMXPath(targetPath)
                : normalizeDirectoryPIMXPath((targetPath as NSString).deletingLastPathComponent)
            guard !directoryPath.isEmpty else {
                continue
            }

            let root = targetRoots.first { directoryPath == $0 || directoryPath.hasPrefix($0 + "/") } ?? directoryPath
            for directory in recursiveParentDirectories(for: directoryPath, stoppingAt: root) {
                let isUserPreferences = asset.isUserPreferences
                entries.append(
                    HDPIMDeleteEntry(
                        targetPath: directory,
                        isDirectory: true,
                        isRecursiveDelete: false,
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
            guard !rawTarget.isEmpty else {
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

    static func validateExtractedPackage(
        parsedPackage: ParsedPackage,
        extractDir: URL,
        aliasPackageName: String,
        productInstallDir: String,
        propertyTable: HDPIMPropertyTable,
        skipAssetSourceValidation: Bool = false
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
        let packageInfo = try parser.parse(pimxURL: pimxURL, xmlData: pimxData, extractDir: extractDir,
                                           collectUninstallManifest: !skipAssetSourceValidation)
        guard packageInfo.packageName == parsedPackage.packageName else {
            throw HDPIMInstallError.packageNameMismatch(expected: parsedPackage.packageName, actual: packageInfo.packageName)
        }
        if !skipAssetSourceValidation {
            try validateRequiredAssetSources(packageName: parsedPackage.packageName, assetReferences: packageInfo.assetReferences)
        }

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
            .filter { !$0.isSymbolicLink }
            .map(\.source)
            .filter { !HDPIMCommandExecutor.pathExists($0) }

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
