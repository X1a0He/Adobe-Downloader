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
        databaseAlreadyOpen: Bool = false
    ) async throws {
        progressHandler?(0.0, "Preparing delta update for \(packageName)...")

        guard FileManager.default.fileExists(atPath: extractDir) else {
            throw DeltaHelperError.initFailed("Extract directory not found: \(extractDir)")
        }

        progressHandler?(0.1, "Generating delta commands...")

        let propertyTable = HDPIMPropertyTable()
        propertyTable.setupSystemDirectories()
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

        progressHandler?(0.9, "Updating database...")

        let processorFamily = HDPIMProcessorFamily.from(platform: platform)
        do {
            let shouldCloseDatabase: Bool
            if databaseAlreadyOpen {
                shouldCloseDatabase = false
            } else {
                try HDPIMDatabase.shared.open()
                shouldCloseDatabase = true
            }
            defer {
                if shouldCloseDatabase {
                    HDPIMDatabase.shared.close()
                }
            }

            HDPIMDatabase.shared.setProductMeta(
                sapCode: sapCode,
                version: codexVersion,
                processorFamily: processorFamily,
                key: "autoPatchUpdate",
                value: "true"
            )
        } catch {
            throw DeltaHelperError.dbUpdateFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "Delta update complete for \(packageName)")

        cleanupDiffJson(diffJsonURL)
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

    private func cleanupDiffJson(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }
}
