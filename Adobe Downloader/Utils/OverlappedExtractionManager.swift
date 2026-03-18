import Foundation

enum ExtractionState {
    case idle
    case waitingForCentralDirectory
    case extracting(progress: Double)
    case completed
    case failed(Error)
}

class OverlappedExtractionManager {
    private var state: ExtractionState = .idle
    private let extractor = HDPIMOverlappedZipExtractor()
    private var isRunning = false

    var progressHandler: ((Double) -> Void)?

    func startExtraction(
        sourceURL: URL,
        destinationURL: URL,
        compressionType: String = ""
    ) async throws {
        isRunning = true
        state = .waitingForCentralDirectory
        extractor.completeDownload(totalSize: fileSize(at: sourceURL))

        do {
            state = .extracting(progress: 0)
            _ = try await extractor.startExtraction(
                request: HDPIMExtractionRequest(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    compressionType: compressionType,
                    packageName: sourceURL.deletingPathExtension().lastPathComponent,
                    validationURL: nil,
                    isDMG: false,
                    allowOverlap: true
                ),
                progressHandler: { [weak self] progress in
                    self?.updateProgress(progress)
                },
                cancellationCheck: { [weak self] in
                    !(self?.isRunning ?? false)
                }
            )
            state = .completed
        } catch {
            state = .failed(error)
            throw error
        }
    }

    func updateProgress(_ progress: Double) {
        state = .extracting(progress: progress)
        progressHandler?(progress)
    }

    func updateAvailableBytes(_ upperBound: Int64) {
        extractor.updateAvailableBytes(upperBound)
    }

    func markCentralDirectoryReady() {
        extractor.markCentralDirectoryReady()
    }

    func cancel() {
        isRunning = false
        extractor.cancel()
    }

    var currentState: ExtractionState {
        state
    }

    func extractPackages(
        _ packages: [(zipURL: URL, destinationURL: URL, compressionType: String)],
        progressHandler: ((Int, Int) -> Void)? = nil
    ) async throws {
        isRunning = true
        let total = packages.count
        let coordinator = HDPIMExtractionCoordinator()

        for (index, package) in packages.enumerated() {
            guard isRunning else {
                throw HDPIMExtractionError.cancelled
            }

            _ = try await coordinator.extract(
                request: HDPIMExtractionRequest(
                    sourceURL: package.zipURL,
                    destinationURL: package.destinationURL,
                    compressionType: package.compressionType,
                    packageName: package.zipURL.deletingPathExtension().lastPathComponent,
                    validationURL: nil,
                    isDMG: false,
                    allowOverlap: false
                ),
                cancellationCheck: { [weak self] in
                    !(self?.isRunning ?? false)
                }
            )
            progressHandler?(index + 1, total)
        }

        isRunning = false
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}

class ZIPAssetExtractor {
    static func extract(
        zipURL: URL,
        to destinationURL: URL,
        compressionType: String = "",
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        let coordinator = HDPIMExtractionCoordinator()
        _ = try await coordinator.extract(
            request: HDPIMExtractionRequest(
                sourceURL: zipURL,
                destinationURL: destinationURL,
                compressionType: compressionType,
                packageName: zipURL.deletingPathExtension().lastPathComponent,
                validationURL: nil,
                isDMG: false,
                allowOverlap: false
            ),
            progressHandler: progressHandler
        )
    }
}

class DMGAssetExtractor {
    static func extract(dmgURL: URL, to destinationURL: URL) async throws {
        let coordinator = HDPIMExtractionCoordinator()
        _ = try await coordinator.extract(
            request: HDPIMExtractionRequest(
                sourceURL: dmgURL,
                destinationURL: destinationURL,
                compressionType: "",
                packageName: dmgURL.deletingPathExtension().lastPathComponent,
                validationURL: nil,
                isDMG: true,
                allowOverlap: false
            )
        )
    }
}
