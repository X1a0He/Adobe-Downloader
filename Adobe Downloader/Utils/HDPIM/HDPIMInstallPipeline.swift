//
//  HDPIMInstallPipeline.swift
//  Adobe Downloader
//

import Foundation

class HDPIMInstallPipeline {

    private var isCancelled = false
    private var backupManager: HDPIMBackupManager?
    private var allExecutedCommands: [HDPIMCommand] = []
    private var temporaryExtractDirectories: [URL] = []

    private var logHandler: ((String) -> Void)?

    private struct ValidatedExtractPackage {
        let extractionResult: HDPIMExtractionResult
        let extractDir: URL
        let validation: HDPIMInstallHelper.ExtractedPackageValidationResult
    }

    private final class ExtractionProgressState {
        var lastReportedStep = -1
    }

    private final class CommandProgressState {
        var lastReportedStep = -1
        var lastReportedStatus: String?
    }

    private func log(_ message: String) {
        if let logHandler {
            logHandler(message)
        } else {
            print(message)
        }
    }

    func install(
        productDir: URL,
        progressHandler: @escaping (Double, String) -> Void,
        logHandler: ((String) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws {
        isCancelled = false
        self.logHandler = logHandler
        temporaryExtractDirectories.removeAll()
        defer { cleanupTemporaryExtractDirectories() }

        progressHandler(0.0, "正在解析 driver.xml...")
        let (productInfo, requestInfo): (ProductInfoFromDriver, [String: String])
        do {
            (productInfo, requestInfo) = try parseDriverXML(at: productDir)
            log("[HDPIM Pipeline] driver.xml 解析成功: sapCode=\(productInfo.sapCode), deps=\(productInfo.dependencies.count)")
        } catch {
            log("[HDPIM Pipeline] driver.xml 解析失败: \(error)")
            throw error
        }

        let propertyTable = HDPIMPropertyTable()

        propertyTable.setupSystemDirectories()

        let installDir = requestInfo["InstallDir"] ?? "/Applications"
        propertyTable.setInstallDir(installDir)
        propertyTable.mergeFromRequestInfo(requestInfo)

        progressHandler(0.05, "正在收集包信息...")
        let packagesToInstall = try collectPackages(
            productDir: productDir,
            productInfo: productInfo,
            propertyTable: propertyTable
        )

        guard !packagesToInstall.isEmpty else {
            progressHandler(1.0, "没有需要安装的包")
            return
        }

        log("[HDPIM Pipeline] 收集到 \(packagesToInstall.count) 个包: \(packagesToInstall.map { $0.packageName })")

        try HDPIMDatabase.shared.open()
        defer { HDPIMDatabase.shared.close() }

        progressHandler(0.1, "正在备份现有文件...")
        let backup = HDPIMBackupManager()
        self.backupManager = backup

        let installDirs = collectInstallDirectories(
            packages: packagesToInstall,
            installDir: installDir,
            sapCode: productInfo.sapCode
        )
        if !installDirs.isEmpty {
            log("[HDPIM Pipeline] 需要备份 \(installDirs.count) 个目录: \(installDirs.map(\.path))")
            try await backup.backupDirectories(
                installDirs,
                progressHandler: { index, total, dir in
                    progressHandler(0.1, "正在备份现有文件 (\(index + 1)/\(total)): \(dir.lastPathComponent)")
                },
                logHandler: log
            )
        }

        let totalPackages = packagesToInstall.count
        var installedCount = 0

        do {
            for (index, pkg) in packagesToInstall.enumerated() {
                if isCancelled || (cancellationCheck?() ?? false) {
                    throw HDPIMInstallError.cancelled
                }

                let packageProgress = Double(index) / Double(totalPackages)
                let baseProgress = 0.15 + packageProgress * 0.8  // 15%~95%

                log("[HDPIM Pipeline] 开始解压 (\(index+1)/\(totalPackages)): \(pkg.packageName) (\(pkg.zipPath.lastPathComponent))")
                let zipSize = (try? FileManager.default.attributesOfItem(atPath: pkg.zipPath.path)[.size] as? Int64) ?? 0
                log("[HDPIM Pipeline] ZIP 大小: \(ByteCountFormatter.string(fromByteCount: zipSize, countStyle: .file))")
                if pkg.compressionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zip-lzma2" {
                    log("[HDPIM Pipeline] 解压后端: native-liblzma + 3 worker")
                } else {
                    log("[HDPIM Pipeline] 解压后端: cminizip + 3 worker")
                }
                progressHandler(baseProgress, "正在解压 \(pkg.packageName) (\(index+1)/\(totalPackages))...")
                let extractedPackage: ValidatedExtractPackage
                do {
                    let extractionState = ExtractionProgressState()
                    extractedPackage = try await extractPackage(
                        pkg: pkg,
                        propertyTable: propertyTable,
                        progressHandler: { extractProgress in
                            let clampedProgress = min(max(extractProgress, 0), 1)
                            let mappedProgress = baseProgress + clampedProgress * 0.02
                            let percent = Int(clampedProgress * 100)
                            let coarseStep = percent / 2
                            guard coarseStep != extractionState.lastReportedStep || percent == 100 else {
                                return
                            }
                            extractionState.lastReportedStep = coarseStep
                            progressHandler(
                                mappedProgress,
                                "正在解压 \(pkg.packageName) (\(index+1)/\(totalPackages))... \(percent)%"
                            )
                        }
                    )
                    let extractDir = extractedPackage.extractDir
                    log("[HDPIM Pipeline] 解压完成: \(pkg.packageName) → \(extractDir.path)")
                    log("[HDPIM Pipeline] PIMX 校验通过: \(extractedPackage.validation.pimxURL.path)")
                    log("[HDPIM Pipeline] 解压恢复统计: symlink=\(extractedPackage.extractionResult.restoredSymlinkCount), permissions=\(extractedPackage.extractionResult.restoredPermissionCount), retries=\(extractedPackage.extractionResult.usedRetryCount)")
                    if !extractedPackage.extractionResult.diffJSONURLs.isEmpty {
                        log("[HDPIM Pipeline] 发现 diff.json: \(extractedPackage.extractionResult.diffJSONURLs.map(\.lastPathComponent))")
                    }
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: extractDir.path) {
                        log("[HDPIM Pipeline] 解压内容 (\(contents.count) 项): \(contents.prefix(20))")
                    }
                } catch {
                    log("[HDPIM Pipeline] 解压失败 \(pkg.packageName): \(error)")
                    throw HDPIMInstallError.extractionFailed("\(pkg.packageName): \(error.localizedDescription)")
                }

                progressHandler(baseProgress + 0.02, "正在安装 \(pkg.packageName)...")
                let helper = HDPIMInstallHelper(propertyTable: propertyTable)
                helper.logHandler = logHandler
                let commandState = CommandProgressState()

                let result = try await helper.installPackage(
                    parsedPackage: pkg.parsed,
                    extractDir: extractedPackage.extractDir,
                    sapCode: pkg.sapCode,
                    version: pkg.version,
                    installDir: installDir,
                    aliasPackageName: pkg.aliasPackageName,
                    productInstallDir: pkg.productInstallDir,
                    validatedExtract: extractedPackage.validation,
                    progressHandler: { cmdIndex, cmdTotal, cmdName in
                        let normalizedTotal = max(cmdTotal, 1)
                        let ratio = Double(cmdIndex + 1) / Double(normalizedTotal)
                        let cmdProgress = baseProgress + 0.02 + ratio * 0.06
                        let percent = Int(ratio * 100)
                        let coarseStep = percent / 2

                        let status: String
                        if cmdName.contains("正在处理:") {
                            status = "[\(pkg.packageName)] \(cmdName)"
                        } else {
                            status = "正在安装 \(pkg.packageName)... \(percent)%"
                        }

                        guard commandState.lastReportedStatus != status
                                || commandState.lastReportedStep != coarseStep
                                || cmdName.contains("正在处理:")
                                || percent == 100 else {
                            return
                        }

                        commandState.lastReportedStatus = status
                        commandState.lastReportedStep = coarseStep
                        progressHandler(cmdProgress, status)
                    }
                )

                allExecutedCommands.append(contentsOf: result.executedCommands)

                try HDPIMDatabase.shared.recordInstall(HDPIMInstallRecord(
                    sapCode: pkg.sapCode,
                    codexVersion: pkg.version,
                    platform: pkg.platform,
                    packageName: pkg.packageName,
                    packageVersion: pkg.parsed.packageVersion,
                    installPath: installDir,
                    uninstallPIMXPath: result.uninstallPIMXPath?.path,
                    uninstallPIMXHash: result.uninstallPIMXHash256,
                    installTimestamp: Date()
                ))

                installedCount += 1
            }

            progressHandler(0.95, "正在清理临时文件...")
            try await backup.cleanup()

            progressHandler(1.0, "安装完成")

        } catch {
            let errorDetail = "[\(packagesToInstall[min(installedCount, packagesToInstall.count - 1)].packageName)] \(error.localizedDescription)"
            progressHandler(0.0, "安装失败: \(errorDetail)，正在回滚...")

            await HDPIMRollbackHelper.rollback(
                executedCommands: allExecutedCommands,
                backupManager: backup
            )

            if let sapCode = packagesToInstall.first?.sapCode,
               let version = packagesToInstall.first?.version {
                try? HDPIMDatabase.shared.removeInstallation(sapCode: sapCode, version: version)
            }

            throw error
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func parseDriverXML(at productDir: URL) throws -> (ProductInfoFromDriver, [String: String]) {
        let driverPath = productDir.appendingPathComponent("driver.xml")

        guard FileManager.default.fileExists(atPath: driverPath.path) else {
            throw HDPIMInstallError.pimxNotFound("driver.xml 不存在: \(driverPath.path)")
        }

        let xmlData = try Data(contentsOf: driverPath)
        let xmlDoc = try XMLDocument(data: xmlData, options: [])

        let sapCode = try xmlDoc.nodes(forXPath: "//ProductInfo/SapCode").first?.stringValue
            ?? xmlDoc.nodes(forXPath: "//ProductInfo/SAPCode").first?.stringValue ?? ""
        let codexVersion = try xmlDoc.nodes(forXPath: "//ProductInfo/CodexVersion").first?.stringValue ?? ""
        let platform = try xmlDoc.nodes(forXPath: "//ProductInfo/Platform").first?.stringValue ?? ""
        let buildGuid = try xmlDoc.nodes(forXPath: "//ProductInfo/BuildGuid").first?.stringValue ?? ""

        var dependencies: [(sapCode: String, platform: String, buildGuid: String)] = []
        let depNodes = try xmlDoc.nodes(forXPath: "//ProductInfo/Dependencies/Dependency")
        for node in depNodes {
            guard let element = node as? XMLElement else { continue }
            let depSapCode = try element.nodes(forXPath: "SapCode").first?.stringValue
                ?? element.nodes(forXPath: "SAPCode").first?.stringValue ?? ""
            let depPlatform = try element.nodes(forXPath: "Platform").first?.stringValue ?? ""
            let depBuildGuid = try element.nodes(forXPath: "BuildGuid").first?.stringValue ?? ""
            if !depSapCode.isEmpty {
                dependencies.append((sapCode: depSapCode, platform: depPlatform, buildGuid: depBuildGuid))
            }
        }

        var requestInfo: [String: String] = [:]
        let requestNodes = try xmlDoc.nodes(forXPath: "//RequestInfo/*")
        for node in requestNodes {
            if let name = node.name, let value = node.stringValue {
                requestInfo[name] = value
            }
        }

        let productInfo = ProductInfoFromDriver(
            sapCode: sapCode,
            codexVersion: codexVersion,
            platform: platform,
            buildGuid: buildGuid,
            dependencies: dependencies
        )

        return (productInfo, requestInfo)
    }

    private func collectPackages(
        productDir: URL,
        productInfo: ProductInfoFromDriver,
        propertyTable: HDPIMPropertyTable
    ) throws -> [PackageToInstall] {
        var packages: [PackageToInstall] = []

        var sapCodes = [(sapCode: productInfo.sapCode, platform: productInfo.platform)]
        for dep in productInfo.dependencies {
            sapCodes.append((sapCode: dep.sapCode, platform: dep.platform))
        }

        for (sapCode, platform) in sapCodes {
            let sapDir = productDir.appendingPathComponent(sapCode)
            let appJsonPath = sapDir.appendingPathComponent("application.json")

            guard FileManager.default.fileExists(atPath: appJsonPath.path),
                  let jsonString = try? String(contentsOf: appJsonPath, encoding: .utf8),
                  let appInfo = try? ApplicationJSONParser.parse(jsonString: jsonString) else {
                continue
            }

            let productInstallDir: String
            if !appInfo.installDir.isEmpty {
                productInstallDir = propertyTable.expandPath(appInfo.installDir)
                log("[HDPIM Pipeline] 产品 \(sapCode) InstallDir: \(appInfo.installDir) → \(productInstallDir)")
            } else {
                productInstallDir = propertyTable.getProperty("INSTALLDIR") ?? "/Applications"
                log("[HDPIM Pipeline] 产品 \(sapCode) 无 InstallDir，使用默认: \(productInstallDir)")
            }

            for parsedPkg in appInfo.packages where !parsedPkg.path.isEmpty {
                let zipPath = sapDir.appendingPathComponent(parsedPkg.fullPackageName)
                guard FileManager.default.fileExists(atPath: zipPath.path) else { continue }

                let aliasName = parsedPkg.aliasPackageName.isEmpty
                    ? parsedPkg.packageName
                    : parsedPkg.aliasPackageName

                packages.append(PackageToInstall(
                    sapCode: sapCode,
                    version: productInfo.codexVersion,
                    platform: platform,
                    packageName: parsedPkg.packageName,
                    parsed: parsedPkg,
                    zipPath: zipPath,
                    sapDir: sapDir,
                    compressionType: appInfo.compressionType,
                    aliasPackageName: aliasName,
                    productInstallDir: productInstallDir
                ))
            }
        }

        return packages
    }

    private func extractPackage(
        pkg: PackageToInstall,
        propertyTable: HDPIMPropertyTable,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ValidatedExtractPackage {
        let extractDir = try makeExtractLocation(installDir: pkg.productInstallDir)
        temporaryExtractDirectories.append(extractDir)

        let extractionResult = try await extractPackageAssets(
            pkg: pkg,
            to: extractDir,
            progressHandler: progressHandler
        )
        guard !extractionResult.pimxURLs.isEmpty else {
            throw HDPIMInstallError.pimxNotFound("包 \(pkg.packageName) 解压后未找到 .pimx")
        }
        let validation = try HDPIMInstallHelper.validateExtractedPackage(
            parsedPackage: pkg.parsed,
            extractDir: extractDir,
            aliasPackageName: pkg.aliasPackageName,
            productInstallDir: pkg.productInstallDir,
            propertyTable: propertyTable
        )

        return ValidatedExtractPackage(
            extractionResult: extractionResult,
            extractDir: extractDir,
            validation: validation
        )
    }

    private func extractPackageAssets(
        pkg: PackageToInstall,
        to destination: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> HDPIMExtractionResult {
        let coordinator = HDPIMExtractionCoordinator()
        let result = try await coordinator.extract(
            request: HDPIMExtractionRequest(
                sourceURL: pkg.zipPath,
                destinationURL: destination,
                compressionType: pkg.compressionType,
                packageName: pkg.packageName,
                validationURL: pkg.parsed.validationURLType2,
                isDMG: pkg.parsed.type.lowercased() == "dmg",
                allowOverlap: false
            ),
            progressHandler: progressHandler,
            retryHandler: { [weak self] attempt, maxRetryCount, error in
                self?.log("[HDPIM Pipeline] 解压重试 \(attempt)/\(maxRetryCount): \(pkg.packageName), reason=\(error.localizedDescription)")
            },
            cancellationCheck: { [weak self] in
                self?.isCancelled ?? false
            }
        )

        if result.usedRetryCount > 0 {
            log("[HDPIM Pipeline] 解压重试完成: \(pkg.packageName), retries=\(result.usedRetryCount)")
        }

        return result
    }

    private func makeExtractLocation(installDir: String) throws -> URL {
        let fileManager = FileManager.default
        let installURL = URL(fileURLWithPath: installDir, isDirectory: true)

        for baseURL in try extractLocationCandidates(for: installURL) {
            let primaryURL = baseURL
                .appendingPathComponent(".adobeTemp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fileManager.createDirectory(at: primaryURL, withIntermediateDirectories: true)
                return primaryURL
            } catch {
                continue
            }
        }

        let fallbackURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        log("[HDPIM Pipeline] 无法在目标卷创建 .adobeTemp，回退到系统临时目录: \(fallbackURL.path)")
        try fileManager.createDirectory(at: fallbackURL, withIntermediateDirectories: true)
        return fallbackURL
    }

    private func extractLocationCandidates(for installURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let volumeRootURL = try resolveVolumeRoot(for: installURL)
        var candidates: [URL] = []

        let dataVolumeURL = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if volumeRootURL.path == "/" && fileManager.fileExists(atPath: dataVolumeURL.path) {
            candidates.append(dataVolumeURL)
        }

        candidates.append(volumeRootURL)

        var seen: Set<String> = []
        return candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func resolveVolumeRoot(for url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let existingURL = nearestExistingAncestor(for: standardizedURL)

        if let volumeURL = try existingURL.resourceValues(forKeys: [.volumeURLKey]).volume {
            return volumeURL.standardizedFileURL
        }

        let path = existingURL.path
        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                return URL(fileURLWithPath: "/Volumes/\(components[1])", isDirectory: true)
            }
        }

        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    private func nearestExistingAncestor(for url: URL) -> URL {
        let fileManager = FileManager.default
        var cursor = url

        while !fileManager.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path.isEmpty {
                return URL(fileURLWithPath: "/", isDirectory: true)
            }
            cursor = parent
        }

        return cursor
    }

    private func cleanupTemporaryExtractDirectories() {
        let fileManager = FileManager.default
        for directory in temporaryExtractDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryExtractDirectories.removeAll()
    }

    private func collectInstallDirectories(
        packages: [PackageToInstall],
        installDir: String,
        sapCode: String
    ) -> [URL] {
        let fileManager = FileManager.default
        var seen: Set<String> = []

        return packages.compactMap { package in
            let path = URL(fileURLWithPath: package.productInstallDir, isDirectory: true)
                .standardizedFileURL
                .path
            guard seen.insert(path).inserted else {
                return nil
            }
            guard fileManager.fileExists(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}

struct ProductInfoFromDriver {
    let sapCode: String
    let codexVersion: String
    let platform: String
    let buildGuid: String
    let dependencies: [(sapCode: String, platform: String, buildGuid: String)]
}

struct PackageToInstall {
    let sapCode: String
    let version: String
    let platform: String
    let packageName: String
    let parsed: ParsedPackage
    let zipPath: URL
    let sapDir: URL
    let compressionType: String
    let aliasPackageName: String
    let productInstallDir: String
}
