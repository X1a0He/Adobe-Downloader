//
//  HDPIMInstallHelper.swift
//  Adobe Downloader
//
//

import Foundation

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
        let reverseXMLs: [String]
        let uninstallPIMXPath: URL?
        let uninstallPIMXHash: String?
        let uninstallPIMXHash256: String?
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

        let (executed, reverseXMLs) = try await engine.executeAll(
            commands: commands,
            progressHandler: progressHandler
        )

        var uninstallPath: URL?
        var sha1Hash: String?
        var sha256Hash: String?

        if !reverseXMLs.isEmpty {
            let generator = UninstallPIMXGenerator()
            generator.addReverseCommands(reverseXMLs)

            let uninstallDir = URL(fileURLWithPath: "/Library/Application Support/Adobe/Installers/uninstallXml")

            let result = try generator.writeAndHash(
                to: uninstallDir,
                packageName: parsedPackage.packageName
            )
            uninstallPath = result.path
            sha1Hash = result.sha1
            sha256Hash = result.sha256
        }

        return InstallResult(
            executedCommands: executed,
            reverseXMLs: reverseXMLs,
            uninstallPIMXPath: uninstallPath,
            uninstallPIMXHash: sha1Hash,
            uninstallPIMXHash256: sha256Hash
        )
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
