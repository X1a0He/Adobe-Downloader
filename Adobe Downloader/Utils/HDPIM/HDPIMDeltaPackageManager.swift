import Foundation

final class HDPIMDeltaPackageManager {

    static let shared = HDPIMDeltaPackageManager()

    private let selector = HDPIMDeltaSelector.shared
    private let helper = HDPIMDeltaHelper()

    private init() {}

    func selectDeltaPackage(
        parsedPackage: ParsedPackage,
        installedVersion: String,
        sapCode: String,
        codexVersion: String,
        processorFamily: HDPIMProcessorFamily
    ) async -> DeltaSelection {
        return await selector.selectDeltaPackage(
            parsedPackage: parsedPackage,
            installedPackageVersion: installedVersion,
            sapCode: sapCode,
            codexVersion: codexVersion,
            processorFamily: processorFamily
        )
    }

    func applyDeltaPackage(
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
        try await helper.execute(
            sapCode: sapCode,
            codexVersion: codexVersion,
            platform: platform,
            installDir: installDir,
            extractDir: extractDir,
            deltaInfo: deltaInfo,
            diffJsonURL: diffJsonURL,
            packageName: packageName,
            packageVersion: packageVersion,
            progressHandler: progressHandler,
            databaseAlreadyOpen: databaseAlreadyOpen
        )
    }

    func fallbackToFullPackage(
        sapCode: String,
        codexVersion: String,
        processorFamily: HDPIMProcessorFamily,
        failedVersion: String
    ) {
        selector.markDeltaFailed(
            sapCode: sapCode,
            codexVersion: codexVersion,
            processorFamily: processorFamily,
            failedVersion: failedVersion
        )
    }
}
