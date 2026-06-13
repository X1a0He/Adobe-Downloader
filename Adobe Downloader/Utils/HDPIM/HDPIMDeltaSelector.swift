import Foundation

enum DeltaSelection {
    case delta(DeltaPackageInfo, URL)
    case fullPackage
    case skip
}

final class HDPIMDeltaSelector {

    static let shared = HDPIMDeltaSelector()
    private init() {}

    func selectDeltaPackage(
        parsedPackage: ParsedPackage,
        installedPackageVersion: String,
        sapCode: String,
        codexVersion: String,
        processorFamily: HDPIMProcessorFamily
    ) async -> DeltaSelection {
        guard !parsedPackage.deltaPackages.isEmpty else {
            return .fullPackage
        }

        let failedVersions = HDPIMDatabase.shared.getDeltaFailVersions(
            sapCode: sapCode,
            version: codexVersion,
            processorFamily: processorFamily
        )

        if failedVersions.contains(installedPackageVersion) {
            print("[DeltaSelector] previous delta attempt failed with version - \(installedPackageVersion)")
            return .fullPackage
        }

        guard let matching = parsedPackage.deltaPackages.first(where: {
            $0.basePackageVersion == installedPackageVersion
        }) else {
            return .fullPackage
        }

        guard !matching.metadataFilePath.isEmpty else {
            print("[DeltaSelector] diffJsonMissingInAppJson for \(parsedPackage.fullPackageName)")
            return .fullPackage
        }

        do {
            let diffJsonURL = try await fetchAndValidateDiffJson(
                metadataPath: matching.metadataFilePath,
                sapCode: sapCode
            )
            return .delta(matching, diffJsonURL)
        } catch {
            print("[DeltaSelector] diffJsonDownloadFailure: \(error.localizedDescription)")
            return .fullPackage
        }
    }

    func markDeltaFailed(sapCode: String, codexVersion: String, processorFamily: HDPIMProcessorFamily, failedVersion: String) {
        HDPIMDatabase.shared.addDeltaFailVersion(
            sapCode: sapCode,
            version: codexVersion,
            processorFamily: processorFamily,
            failedVersion: failedVersion
        )
    }

    private func fetchAndValidateDiffJson(metadataPath: String, sapCode: String) async throws -> URL {
        let cdnBase = globalCdn.hasSuffix("/") ? String(globalCdn.dropLast()) : globalCdn
        let cleanPath = metadataPath.hasPrefix("/") ? metadataPath : "/\(metadataPath)"
        let urlString = cdnBase + cleanPath

        guard let url = URL(string: urlString) else {
            throw DeltaSelectorError.invalidURL(urlString)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdobeDelta_\(sapCode)_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destURL = tempDir.appendingPathComponent("diff.json")

        let communicator = PDMHttpCommunicator()
        let headers = NetworkConstants.downloadHeaders.map { ($0.key, $0.value) }

        let response = communicator.sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString,
            method: "GET",
            headers: headers,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 60
        ))

        guard response.isSuccess, !response.data.isEmpty else {
            throw DeltaSelectorError.downloadFailed("HTTP \(response.statusCode)")
        }

        try response.data.write(to: destURL)
        return destURL
    }
}

enum DeltaSelectorError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid diff.json URL: \(url)"
        case .downloadFailed(let reason): return "Failed to download diff.json: \(reason)"
        case .hashMismatch: return "diff.json hash validation failed"
        }
    }
}
