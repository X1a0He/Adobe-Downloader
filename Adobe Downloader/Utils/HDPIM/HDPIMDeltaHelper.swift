import Foundation

enum DeltaHelperError: Error, LocalizedError {
    case initFailed(String)
    case commandGenerationFailed(String)
    case executionFailed(String)
    case dbUpdateFailed(String)

    var errorDescription: String? {
        switch self {
        case .initFailed(let s): return "Delta init failed: \(s)"
        case .commandGenerationFailed(let s): return "Delta command generation failed: \(s)"
        case .executionFailed(let s): return "Delta execution failed: \(s)"
        case .dbUpdateFailed(let s): return "Delta DB update failed: \(s)"
        }
    }
}

final class HDPIMDeltaHelper {

    private let commandEngine = HDPIMDeltaCommandEngine()

    struct Prepared {
        let commands: [DeltaCommand]
        let packageName: String
        let uninstallManifest: [HDPIMDeleteEntry]
        let literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath]
    }

    func prepare(diffJsonURL: URL, package: PackageToInstall, propertyTable: HDPIMPropertyTable,
                 extractDir: URL) async throws -> Prepared {
        commandEngine.propertyTable = propertyTable.cloned()
        let plan = try commandEngine.generatePlan(from: diffJsonURL, installDir: package.productInstallDir,
                                                 extractDir: extractDir.path)
        let prepared = try await commandEngine.preparePatches(plan.commands, in: extractDir.appendingPathComponent("prepared-patches"))
        return Prepared(commands: prepared, packageName: package.packageName,
                        uninstallManifest: plan.uninstallManifest, literalPaths: plan.literalPaths)
    }

    func execute(_ prepared: Prepared, progressHandler: ((Double, String) -> Void)? = nil) async throws {
        try HDPIMOperationContext.checkCancellation()
        try commandEngine.validateBeforeExecution(prepared.commands)
        try await commandEngine.executeCommands(prepared.commands) { fraction in
            progressHandler?(fraction, "正在增量更新 \(prepared.packageName)... \(Int(fraction * 100))%")
        }
        progressHandler?(1, "增量文件处理完成：\(prepared.packageName)")
    }

    func execute(
        sapCode: String,
        codexVersion: String,
        platform: String,
        installDir: String,
        extractDir: String,
        deltaInfo: DeltaPackageInfo,
        diffJsonURL: URL,
        packageName: String,
        packageVersion: String,
        progressHandler: ((Double, String) -> Void)? = nil,
        databaseAlreadyOpen: Bool = false,
        parentPropertyTable: HDPIMPropertyTable? = nil
    ) async throws {
        progressHandler?(0.0, "Preparing delta update for \(packageName)...")

        guard FileManager.default.fileExists(atPath: extractDir) else {
            throw DeltaHelperError.initFailed("Extract directory not found: \(extractDir)")
        }

        progressHandler?(0.1, "Generating delta commands...")

        let propertyTable = parentPropertyTable?.cloned() ?? HDPIMPropertyTable()
        if parentPropertyTable == nil { propertyTable.setupSystemDirectories() }
        propertyTable.setInstallDir(installDir)
        propertyTable.setProductInstallDir(installDir)
        propertyTable.setSourceFolder(extractDir)
        propertyTable.setMediaFolder(extractDir)
        commandEngine.propertyTable = propertyTable

        let commands: [DeltaCommand]
        do {
            commands = try commandEngine.generateCommands(
                from: diffJsonURL,
                installDir: installDir,
                extractDir: extractDir
            )
            try commandEngine.validateBeforeExecution(commands)
        } catch {
            markFailed(sapCode: sapCode, codexVersion: codexVersion, platform: platform, packageVersion: packageVersion)
            throw DeltaHelperError.commandGenerationFailed(error.localizedDescription)
        }

        guard !commands.isEmpty else {
            progressHandler?(1.0, "No delta commands to execute")
            return
        }

        progressHandler?(0.2, "Executing \(commands.count) delta commands...")

        do {
            try await commandEngine.executeCommands(commands) { fraction in
                let overall = 0.2 + fraction * 0.7
                progressHandler?(overall, "Patching files... \(Int(fraction * 100))%")
            }
        } catch {
            markFailed(sapCode: sapCode, codexVersion: codexVersion, platform: platform, packageVersion: packageVersion)
            throw DeltaHelperError.executionFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "Delta update complete for \(packageName)")
    }

    private func markFailed(sapCode: String, codexVersion: String, platform: String, packageVersion: String) {
        let processorFamily = HDPIMProcessorFamily.from(platform: platform)
        HDPIMDeltaSelector.shared.markDeltaFailed(
            sapCode: sapCode,
            codexVersion: codexVersion,
            processorFamily: processorFamily,
            failedVersion: packageVersion
        )
    }

}
