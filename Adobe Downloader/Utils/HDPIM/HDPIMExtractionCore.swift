import Foundation

enum HDPIMExtractionConcurrency {
    static let maxConcurrentEntries = max(3, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    static let entrySemaphore = DispatchSemaphore(value: maxConcurrentEntries)
    static let dictionaryBudget = HDPIMExtractionMemoryBudget()
}

final class HDPIMExtractionMemoryBudget {
    private let condition = NSCondition()
    private let capacity = max(UInt64(64 * 1024 * 1024), min(ProcessInfo.processInfo.physicalMemory / 8, UInt64(512 * 1024 * 1024)))
    private var reserved: UInt64 = 0

    func acquire(_ bytes: UInt64, cancellationCheck: (() -> Bool)?) throws {
        condition.lock()
        defer { condition.unlock() }
        while reserved > 0 && (bytes > capacity || reserved > capacity - bytes) {
            if cancellationCheck?() == true { throw HDPIMExtractionError.cancelled }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        if cancellationCheck?() == true { throw HDPIMExtractionError.cancelled }
        reserved += bytes
    }

    func release(_ bytes: UInt64) {
        condition.lock()
        reserved -= bytes
        condition.broadcast()
        condition.unlock()
    }
}

struct HDPIMExtractionRequest {
    let sourceURL: URL
    let destinationURL: URL
    let compressionType: String
    let packageName: String
    let validationURL: String?
    let isDMG: Bool
    let allowOverlap: Bool
}

struct HDPIMExtractionResult {
    let extractRoot: URL
    let pimxURLs: [URL]
    let diffJSONURLs: [URL]
    let restoredSymlinkCount: Int
    let restoredPermissionCount: Int
    let restoredMetadataCount: Int
    let usedRetryCount: Int
}

enum HDPIMExtractionError: Error, LocalizedError {
    case cancelled
    case processFailed(String)
    case dmgAttachFailed(String)
    case dmgCopyFailed(String)
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(localized: "提取已取消")
        case .processFailed(let message):
            return message
        case .dmgAttachFailed(let message):
            return String(format: String(localized: "DMG 挂载失败: %@"), message)
        case .dmgCopyFailed(let message):
            return String(format: String(localized: "DMG 拷贝失败: %@"), message)
        case .invalidStructure(let message):
            return message
        }
    }
}

private final class HDPIMZipEntryQueue {
    private let lock = NSLock()
    private var entries: [HDPIMZipEntryRecord]
    private var index = 0
    private var stopped = false

    init(entries: [HDPIMZipEntryRecord]) {
        self.entries = entries
    }

    func next() -> HDPIMZipEntryRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, index < entries.count else {
            return nil
        }
        let entry = entries[index]
        index += 1
        return entry
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class HDPIMExtractionProgressTracker {
    private let totalWork: UInt64
    private let progressHandler: ((Double) -> Void)?
    private let lock = NSLock()
    private var completedWork: UInt64 = 0
    private var lastReportedStep = -1

    init(totalWork: UInt64, progressHandler: ((Double) -> Void)?) {
        self.totalWork = max(totalWork, 1)
        self.progressHandler = progressHandler
    }

    func advance(_ delta: UInt64) {
        guard delta > 0 else { return }

        let mappedProgress: Double
        let shouldReport: Bool

        lock.lock()
        completedWork = min(totalWork, completedWork + delta)
        let extractProgress = Double(completedWork) / Double(totalWork)
        mappedProgress = 0.08 + extractProgress * 0.92
        let step = Int(mappedProgress * 1000)
        shouldReport = step != lastReportedStep || completedWork == totalWork
        if shouldReport {
            lastReportedStep = step
        }
        lock.unlock()

        if shouldReport {
            progressHandler?(mappedProgress)
        }
    }

    func complete() {
        progressHandler?(1.0)
    }
}

final class HDPIMZipExtractor {
    private let archiveExtractor = HDPIMMiniZipExtractor()

    func extract(
        request: HDPIMExtractionRequest,
        progressHandler: ((Double) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> HDPIMExtractionResult {
        let entries = try archiveExtractor.listEntries(
            zipURL: request.sourceURL,
            progressHandler: { scanProgress in
                progressHandler?(scanProgress * 0.08)
            }
        )
        let summary = try extractWithWorkers(
            zipURL: request.sourceURL,
            entries: entries,
            destinationURL: request.destinationURL,
            compressionType: request.compressionType,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck
        )

        return HDPIMExtractionResult(
            extractRoot: request.destinationURL,
            pimxURLs: Self.collectArtifacts(in: request.destinationURL, matching: { $0.pathExtension.lowercased() == "pimx" }),
            diffJSONURLs: Self.collectArtifacts(in: request.destinationURL, matching: {
                $0.lastPathComponent.lowercased().hasSuffix("_diff.json") || $0.lastPathComponent.lowercased() == "diff.json"
            }),
            restoredSymlinkCount: summary.restoredSymlinkCount,
            restoredPermissionCount: summary.restoredPermissionCount,
            restoredMetadataCount: summary.restoredMetadataCount,
            usedRetryCount: 0
        )
    }

    private static func collectArtifacts(
        in rootURL: URL,
        matching predicate: (URL) -> Bool
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            guard predicate(fileURL) else {
                continue
            }
            urls.append(fileURL)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func extractWithWorkers(
        zipURL: URL,
        entries: [HDPIMZipEntryRecord],
        destinationURL: URL,
        compressionType: String,
        progressHandler: ((Double) -> Void)?,
        cancellationCheck: (() -> Bool)?
    ) throws -> HDPIMMiniZipExtractionSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let totalWork = archiveExtractor.totalProgressUnits(for: entries)
        let tracker = HDPIMExtractionProgressTracker(totalWork: totalWork, progressHandler: progressHandler)

        var pendingSymlinkEntries: [HDPIMZipEntryRecord] = []
        var pendingAppleDoubleEntries: [HDPIMZipEntryRecord] = []
        var restoredPermissionCount = 0
        let permissionLock = NSLock()
        var preparedDirectories = Set<String>()

        for entry in entries {
            try archiveExtractor.throwIfCancelled(cancellationCheck)

            if archiveExtractor.isMacOSXEntry(entry) {
                pendingAppleDoubleEntries.append(entry)
                tracker.advance(1)
                continue
            }

            let outputURL = destinationURL.appendingPathComponent(entry.normalizedPath, isDirectory: entry.type == .directory)

            switch entry.type {
            case .directory:
                if !entry.normalizedPath.isEmpty {
                    if preparedDirectories.insert(outputURL.path).inserted {
                        try archiveExtractor.createDirectoryIfNeeded(at: outputURL)
                    }
                    if try archiveExtractor.applyAttributes(entry.externalAttributes, to: outputURL.path, isSymbolicLink: false) {
                        restoredPermissionCount += 1
                    }
                }
                tracker.advance(1)
            case .symbolicLink:
                pendingSymlinkEntries.append(entry)
                let parent = outputURL.deletingLastPathComponent().path
                if !parent.isEmpty && preparedDirectories.insert(parent).inserted {
                    try archiveExtractor.createParentDirectoryIfNeeded(for: outputURL)
                }
            case .regularFile:
                let parent = outputURL.deletingLastPathComponent().path
                if !parent.isEmpty && preparedDirectories.insert(parent).inserted {
                    try archiveExtractor.createParentDirectoryIfNeeded(for: outputURL)
                }
            }
        }

        let regularEntries = entries.filter { $0.type == .regularFile && !archiveExtractor.isMacOSXEntry($0) }
            .sorted { $0.uncompressedSize > $1.uncompressedSize }
        let workerCount = min(HDPIMExtractionConcurrency.maxConcurrentEntries, regularEntries.count)

        if workerCount > 0 {
            let workQueue = HDPIMZipEntryQueue(entries: regularEntries)
            let dispatchGroup = DispatchGroup()
            let errorLock = NSLock()
            var firstError: Error?

            for _ in 0..<workerCount {
                dispatchGroup.enter()
                let queue = DispatchQueue(label: "com.adobe-downloader.hdpim.zip.worker.\(UUID().uuidString)")
                queue.async {
                    defer { dispatchGroup.leave() }
                    do {
                        let session = try self.archiveExtractor.makeSession(zipURL: zipURL)
                        let shouldStop = { workQueue.isStopped || (cancellationCheck?() ?? false) }
                        while let entry = workQueue.next() {
                            try self.archiveExtractor.throwIfCancelled(shouldStop)
                            while HDPIMExtractionConcurrency.entrySemaphore.wait(timeout: .now() + 0.1) == .timedOut {
                                try self.archiveExtractor.throwIfCancelled(shouldStop)
                            }
                            defer { HDPIMExtractionConcurrency.entrySemaphore.signal() }
                            try self.archiveExtractor.throwIfCancelled(shouldStop)
                            let outputURL = destinationURL.appendingPathComponent(entry.normalizedPath, isDirectory: false)
                            let restored: Bool
                            do {
                                restored = try session.extractRegularEntry(
                                    entry,
                                    to: outputURL,
                                    compressionType: compressionType,
                                    chunkHandler: { tracker.advance(UInt64($0)) },
                                    cancellationCheck: shouldStop
                                )
                            } catch {
                                try self.archiveExtractor.throwIfCancelled(shouldStop)
                                restored = try session.extractRegularEntry(
                                    entry,
                                    to: outputURL,
                                    compressionType: compressionType,
                                    chunkHandler: { tracker.advance(UInt64($0)) },
                                    cancellationCheck: shouldStop
                                )
                            }
                            if restored {
                                permissionLock.lock()
                                restoredPermissionCount += 1
                                permissionLock.unlock()
                            }
                        }
                    } catch {
                        errorLock.lock()
                        if firstError == nil {
                            firstError = error
                        }
                        errorLock.unlock()
                        workQueue.stop()
                    }
                }
            }

            dispatchGroup.wait()

            if let firstError {
                throw firstError
            }
        }

        let orderedSymlinkEntries = pendingSymlinkEntries.sorted { lhs, rhs in
            let lhsDepth = lhs.normalizedPath.split(separator: "/").count
            let rhsDepth = rhs.normalizedPath.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return lhs.normalizedPath.localizedStandardCompare(rhs.normalizedPath) == .orderedAscending
        }

        let symlinkSession = try archiveExtractor.makeSession(zipURL: zipURL)
        var symlinkRecords: [HDPIMSymlinkRecord] = []
        symlinkRecords.reserveCapacity(orderedSymlinkEntries.count)

        for entry in orderedSymlinkEntries {
            try archiveExtractor.throwIfCancelled(cancellationCheck)
            symlinkRecords.append(try symlinkSession.readSymlinkRecord(entry, destinationURL: destinationURL))
        }

        var restoredSymlinkCount = 0
        for record in symlinkRecords {
            try archiveExtractor.throwIfCancelled(cancellationCheck)
            try archiveExtractor.removeItemIfExists(at: record.linkPath)
            guard Darwin.symlink(record.linkTarget, record.linkPath) == 0 else {
                throw HDPIMMiniZipError.invalidSymlinkTarget(record.linkPath)
            }
            if try archiveExtractor.applyAttributes(record.externalAttributes, to: record.linkPath, isSymbolicLink: true) {
                restoredPermissionCount += 1
            }
            restoredSymlinkCount += 1
            tracker.advance(1)
        }

        for record in symlinkRecords {
            try archiveExtractor.throwIfCancelled(cancellationCheck)
            try archiveExtractor.validateSymlinkTarget(at: record.linkPath, target: record.linkTarget)
        }

        var restoredMetadataCount = 0
        if !pendingAppleDoubleEntries.isEmpty {
            let metadataSession = try archiveExtractor.makeSession(zipURL: zipURL)
            for entry in pendingAppleDoubleEntries {
                try archiveExtractor.throwIfCancelled(cancellationCheck)
                let restored = try metadataSession.restoreAppleDoubleMetadata(
                    entry,
                    destinationURL: destinationURL,
                    compressionType: compressionType,
                    cancellationCheck: cancellationCheck
                )
                if restored {
                    restoredMetadataCount += 1
                }
            }
        }

        tracker.complete()

        return HDPIMMiniZipExtractionSummary(
            restoredSymlinkCount: restoredSymlinkCount,
            restoredPermissionCount: restoredPermissionCount,
            restoredMetadataCount: restoredMetadataCount
        )
    }
}

final class HDPIMDMGExtractor {
    private let fileManager = FileManager.default

    func extract(
        request: HDPIMExtractionRequest,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws -> HDPIMExtractionResult {
        try throwIfCancelled(cancellationCheck)

        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("HDPIM-DMG-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        do {
        let attachOutput = try await HDPIMProcessRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", request.sourceURL.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"]
        )
        guard attachOutput.exitCode == 0 else {
            throw HDPIMExtractionError.dmgAttachFailed(attachOutput.output)
        }

        try throwIfCancelled(cancellationCheck)

        try fileManager.createDirectory(at: request.destinationURL, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        for item in contents {
            try throwIfCancelled(cancellationCheck)
            let destinationItem = request.destinationURL.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: destinationItem.path) {
                try fileManager.removeItem(at: destinationItem)
            }
            do {
                try fileManager.copyItem(at: item, to: destinationItem)
            } catch {
                throw HDPIMExtractionError.dmgCopyFailed(error.localizedDescription)
            }
        }

        try await detach(mountPoint)
        return HDPIMExtractionResult(
            extractRoot: request.destinationURL,
            pimxURLs: [],
            diffJSONURLs: [],
            restoredSymlinkCount: 0,
            restoredPermissionCount: 0,
            restoredMetadataCount: 0,
            usedRetryCount: 0
        )
        } catch {
            do { try await detach(mountPoint) }
            catch { throw HDPIMExtractionError.processFailed("DMG 清理失败，挂载目录保留在 \(mountPoint.path)：\(error.localizedDescription)") }
            throw error
        }
    }

    private func detach(_ mountPoint: URL) async throws {
        try await HDPIMOperationContext.$isRecovering.withValue(true) {
            let result = try await HDPIMProcessRunner.run(executable: "/usr/bin/hdiutil",
                                                        arguments: ["detach", mountPoint.path, "-quiet"])
            if result.exitCode != 0 {
                guard (try? fileManager.contentsOfDirectory(atPath: mountPoint.path).isEmpty) == true else {
                    throw HDPIMExtractionError.processFailed(result.output)
                }
            }
            if fileManager.fileExists(atPath: mountPoint.path) { try fileManager.removeItem(at: mountPoint) }
        }
    }

    private func throwIfCancelled(_ cancellationCheck: (() -> Bool)?) throws {
        if Task.isCancelled || (cancellationCheck?() ?? false) {
            throw HDPIMExtractionError.cancelled
        }
    }
}

final class HDPIMOverlappedZipExtractor {
    private let zipExtractor = HDPIMZipExtractor()
    private let stateQueue = DispatchQueue(label: "com.adobe-downloader.hdpim.overlap-state", attributes: .concurrent)
    private let workerQueues: [DispatchQueue] = [
        DispatchQueue(label: "com.adobe-downloader.hdpim.overlap.worker0"),
        DispatchQueue(label: "com.adobe-downloader.hdpim.overlap.worker1"),
        DispatchQueue(label: "com.adobe-downloader.hdpim.overlap.worker2")
    ]

    private var centralDirectoryReady = false
    private var cancelled = false
    private var availableUpperBound: Int64 = -1

    func startExtraction(
        request: HDPIMExtractionRequest,
        progressHandler: ((Double) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws -> HDPIMExtractionResult {
        try await waitUntilReady(cancellationCheck: cancellationCheck)
        let queue = workerQueues[0]

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try self.zipExtractor.extract(
                        request: request,
                        progressHandler: progressHandler,
                        cancellationCheck: { self.isCancelled || (cancellationCheck?() ?? false) }
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func updateAvailableBytes(_ upperBound: Int64) {
        stateQueue.async(flags: .barrier) {
            self.availableUpperBound = max(self.availableUpperBound, upperBound)
        }
    }

    func markCentralDirectoryReady() {
        stateQueue.async(flags: .barrier) {
            self.centralDirectoryReady = true
        }
    }

    func completeDownload(totalSize: Int64) {
        stateQueue.async(flags: .barrier) {
            self.availableUpperBound = max(self.availableUpperBound, totalSize - 1)
            self.centralDirectoryReady = true
        }
    }

    func cancel() {
        stateQueue.async(flags: .barrier) {
            self.cancelled = true
        }
    }

    var currentAvailableUpperBound: Int64 {
        stateQueue.sync {
            availableUpperBound
        }
    }

    private var isCancelled: Bool {
        stateQueue.sync {
            cancelled
        }
    }

    private var isCentralDirectoryReady: Bool {
        stateQueue.sync {
            centralDirectoryReady
        }
    }

    private func waitUntilReady(cancellationCheck: (() -> Bool)?) async throws {
        while !isCentralDirectoryReady {
            if isCancelled || Task.isCancelled || (cancellationCheck?() ?? false) {
                throw HDPIMExtractionError.cancelled
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

final class HDPIMExtractionCoordinator {
    private let fileManager = FileManager.default
    private let zipExtractor = HDPIMZipExtractor()
    private let dmgExtractor = HDPIMDMGExtractor()

    func extract(
        request: HDPIMExtractionRequest,
        progressHandler: ((Double) -> Void)? = nil,
        retryHandler: ((Int, Int, Error) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) async throws -> HDPIMExtractionResult {
        let totalAttempts = 4

        for attempt in 0..<totalAttempts {
            do {
                if Task.isCancelled || (cancellationCheck?() ?? false) { throw HDPIMExtractionError.cancelled }
                try cleanupExtractionRoot(request.destinationURL)
                try fileManager.createDirectory(at: request.destinationURL, withIntermediateDirectories: true)

                let baseResult: HDPIMExtractionResult
                if request.isDMG {
                    baseResult = try await dmgExtractor.extract(
                        request: request,
                        cancellationCheck: cancellationCheck
                    )
                } else {
                    baseResult = try zipExtractor.extract(
                        request: request,
                        progressHandler: progressHandler,
                        cancellationCheck: cancellationCheck
                    )
                }

                return HDPIMExtractionResult(
                    extractRoot: baseResult.extractRoot,
                    pimxURLs: baseResult.pimxURLs,
                    diffJSONURLs: baseResult.diffJSONURLs,
                    restoredSymlinkCount: baseResult.restoredSymlinkCount,
                    restoredPermissionCount: baseResult.restoredPermissionCount,
                    restoredMetadataCount: baseResult.restoredMetadataCount,
                    usedRetryCount: attempt
                )
            } catch {
                try? cleanupExtractionRoot(request.destinationURL)

                if Task.isCancelled || (cancellationCheck?() ?? false) || error is CancellationError {
                    throw HDPIMExtractionError.cancelled
                }
                if case HDPIMExtractionError.cancelled = error { throw error }
                if case HDPIMMiniZipError.cancelled = error { throw error }

                if request.isDMG || attempt == totalAttempts - 1 {
                    throw error
                }

                retryHandler?(attempt + 1, totalAttempts - 1, error)
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        throw HDPIMExtractionError.invalidStructure(String(format: String(localized: "提取失败: %@"), request.packageName))
    }

    private func cleanupExtractionRoot(_ destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
    }
}
