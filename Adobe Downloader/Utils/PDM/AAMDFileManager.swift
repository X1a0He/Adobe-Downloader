import Foundation

struct AAMDResumeSnapshot {
    let fileSize: Int64
    let segmentSize: Int64
    let downloadedBytes: Int64
    let isComplete: Bool
    let segmentCount: Int
    let downloadMode: PDMDownloadMode
}

final class AAMDFileManager {

    static let headerString = "Adobe_Download_001"
    static let headerSize = headerString.utf8.count
    static let segmentEntrySize = 21
    static let headerKeyValueDelimiter = "{|}"

    private let aamdURL: URL
    private let downloadFileURL: URL
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    private var writeFailed = false

    init(downloadFileURL: URL, metadataDirectory: URL? = nil) {
        self.downloadFileURL = downloadFileURL
        let adjacentURL = URL(fileURLWithPath: downloadFileURL.path + ".aamd")
        if let metadataDirectory {
            let metadataURL = metadataDirectory.appendingPathComponent(downloadFileURL.lastPathComponent + ".aamd")
            let metadataSize = (try? FileManager.default.attributesOfItem(atPath: metadataURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let adjacentSize = (try? FileManager.default.attributesOfItem(atPath: adjacentURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            aamdURL = metadataSize == 0 && adjacentSize > 0 ? adjacentURL : metadataURL
        } else {
            aamdURL = adjacentURL
        }
    }

    func exists() -> Bool {
        fileManager.fileExists(atPath: aamdURL.path)
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try preserveExistingFiles(includeDownload: false)
        } catch {
            writeFailed = true
        }
    }

    @discardableResult
    func preserveExistingDownload() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return try preserveExistingFiles(includeDownload: true)
    }

    private func preserveExistingFiles(includeDownload: Bool) throws -> URL? {
        let sources = (includeDownload
            ? [downloadFileURL, aamdURL, DownloadArtifactStore.receiptURL(for: downloadFileURL)]
            : [aamdURL])
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return nil }
        let directory = downloadFileURL.deletingLastPathComponent()
            .appendingPathComponent(".download-backups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            for source in sources {
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            for (source, destination) in moved.reversed() where !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: destination, to: source)
            }
            print("[PDM] 下载材料备份未完成，恢复目录: \(directory.path)")
            throw error
        }
        writeFailed = false
        print("[PDM] 已保留旧下载材料: \(directory.path)")
        return directory
    }

    @discardableResult
    func writeMetaInfo() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            _ = try preserveExistingFiles(includeDownload: false)
            try fileManager.createDirectory(at: aamdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.headerString.utf8).write(to: aamdURL, options: .atomic)
            writeFailed = false
            return true
        } catch {
            writeFailed = true
            return false
        }
    }

    @discardableResult
    func writeHeaders(_ headers: [String: String], segmentTableSpan: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard segmentTableSpan >= 0,
              segmentTableSpan < (Int.max - Self.headerSize) / Self.segmentEntrySize - 1 else { return false }
        do {
            var data = try Data(contentsOf: aamdURL)
            let offset = headersOffset(segmentTableSpan: segmentTableSpan)
            if data.count < offset {
                data.append(Data(repeating: 0, count: offset - data.count))
            } else {
                data = Data(data.prefix(offset))
            }
            data.append(Data(constructHeadersXML(headers).utf8))
            try data.write(to: aamdURL, options: .atomic)
            return true
        } catch {
            writeFailed = true
            return false
        }
    }

    @discardableResult
    func updateSegmentData(segment: Int, bytesDownloaded: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard segment >= 0, bytesDownloaded >= 0,
              segment < (Int.max - Self.headerSize) / Self.segmentEntrySize else { return false }
        do {
            let handle = try FileHandle(forWritingTo: aamdURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(segmentOffset(segment)))
            let entry = String(format: "%20lld\n", bytesDownloaded)
            try handle.write(contentsOf: Data(entry.utf8))
            return true
        } catch {
            writeFailed = true
            return false
        }
    }

    @discardableResult
    func synchronize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            let handle = try FileHandle(forWritingTo: aamdURL)
            defer { try? handle.close() }
            try handle.synchronize()
            return !writeFailed
        } catch {
            writeFailed = true
            return false
        }
    }

    func validateAAMDFile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: aamdURL) else { return false }
        return hasValidHeader(data)
    }

    func readHeaders() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: aamdURL), hasValidHeader(data) else { return nil }
        return decodedHeaders(data)?.headers
    }

    func resumeSnapshot() -> AAMDResumeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !writeFailed,
              let data = try? Data(contentsOf: aamdURL), hasValidHeader(data),
              let decoded = decodedHeaders(data) else { return nil }
        let headers = decoded.headers
        guard let fileSize = headers["FILE_SIZE"].flatMap(Int64.init), fileSize > 0,
              let segmentSize = headers["SEGMENT_SIZE"].flatMap(Int64.init), segmentSize > 0,
              headers["NO_Of_BYTES_TO_DOWNLOAD"].flatMap(Int64.init) == fileSize,
              headers["DOWNLOAD_START_ADDRESS"].flatMap(Int64.init) == 0,
              headers["ETAG"] != nil,
              let serverPath = headers["SERVER_PATH"], !serverPath.isEmpty,
              let attributes = try? fileManager.attributesOfItem(atPath: downloadFileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == fileSize else { return nil }

        let mode: PDMDownloadMode
        if let modeString = headers["DOWNLOAD_MODE"] {
            guard let parsed = Self.parseDownloadMode(modeString) else { return nil }
            mode = parsed
        } else {
            mode = decoded.offset == Self.headerSize + Self.segmentEntrySize
                ? .singleStream : .multiStream(maxSegments: 1)
        }
        let expectedCount = mode.isSingleStream ? 1 : Int((fileSize - 1) / segmentSize + 1)
        let segmentCount: Int
        if let countString = headers["SEGMENT_COUNT"] {
            guard let count = Int(countString), count == expectedCount else { return nil }
            segmentCount = count
        } else {
            segmentCount = expectedCount
        }
        guard segmentCount > 0,
              segmentCount <= (decoded.offset - Self.headerSize) / Self.segmentEntrySize else { return nil }

        var total: Int64 = 0
        for index in 0..<segmentCount {
            let start = mode.isSingleStream ? 0 : Int64(index) * segmentSize
            let length = mode.isSingleStream ? fileSize : min(segmentSize, fileSize - start)
            guard let count = segmentBytes(index, data: data), count >= 0, count <= length else { return nil }
            total += count
        }
        return AAMDResumeSnapshot(
            fileSize: fileSize,
            segmentSize: segmentSize,
            downloadedBytes: total,
            isComplete: total == fileSize,
            segmentCount: segmentCount,
            downloadMode: mode
        )
    }

    func getBytesDownloadedForSegment(_ segment: Int) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: aamdURL) else { return 0 }
        return segmentBytes(segment, data: data) ?? 0
    }

    func getTotalBytesDownloaded(segmentCount: Int) -> Int64 {
        guard let snapshot = resumeSnapshot(), snapshot.segmentCount == segmentCount else { return 0 }
        return snapshot.downloadedBytes
    }

    func validateHeaders(
        remoteETag: String,
        remoteFileSize: Int64,
        remoteURL: String,
        segmentSize: Int64
    ) -> Bool {
        guard let stored = readHeaders(), resumeSnapshot() != nil else { return false }
        return stored["ETAG"] == remoteETag
            && stored["SERVER_PATH"] == remoteURL
            && stored["FILE_SIZE"].flatMap(Int64.init) == remoteFileSize
            && stored["SEGMENT_SIZE"].flatMap(Int64.init) == segmentSize
            && stored["NO_Of_BYTES_TO_DOWNLOAD"].flatMap(Int64.init) == remoteFileSize
            && stored["DOWNLOAD_START_ADDRESS"].flatMap(Int64.init) == 0
    }

    static func parseDownloadMode(_ value: String) -> PDMDownloadMode? {
        if value == "singleStream" { return .singleStream }
        let prefix = "multiStream(maxSegments: "
        guard value.hasPrefix(prefix), value.hasSuffix(")"),
              let count = Int(value.dropFirst(prefix.count).dropLast()), count > 0 else { return nil }
        return .multiStream(maxSegments: count)
    }

    private func hasValidHeader(_ data: Data) -> Bool {
        data.starts(with: Data(Self.headerString.utf8))
    }

    private func segmentBytes(_ segment: Int, data: Data) -> Int64? {
        guard segment >= 0, segment < (Int.max - Self.headerSize) / Self.segmentEntrySize else { return nil }
        let offset = segmentOffset(segment)
        let end = offset + Self.segmentEntrySize
        guard end <= data.count else { return nil }
        let entry = data[offset..<end]
        if entry.allSatisfy({ $0 == 0 }) { return 0 }
        guard let value = String(data: entry, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(trimmed)
    }

    private func segmentOffset(_ segment: Int) -> Int {
        Self.headerSize + segment * Self.segmentEntrySize
    }

    private func headersOffset(segmentTableSpan: Int) -> Int {
        Self.headerSize + (segmentTableSpan + 1) * Self.segmentEntrySize
    }

    private func constructHeadersXML(_ headers: [String: String]) -> String {
        var xml = "<headers>\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            xml += "@START@\(key)\(Self.headerKeyValueDelimiter)\(value)@END@\n"
        }
        xml += "</headers>\n"
        return xml
    }

    private func decodedHeaders(_ data: Data) -> (headers: [String: String], offset: Int)? {
        guard let start = data.range(of: Data("<headers>".utf8)),
              let end = data.range(of: Data("</headers>".utf8)), start.upperBound <= end.lowerBound,
              start.lowerBound >= Self.headerSize,
              let content = String(data: data[start.upperBound..<end.lowerBound], encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("@START@"), value.hasSuffix("@END@") else { return nil }
            let entry = value.dropFirst(7).dropLast(5)
            guard let delimiter = entry.range(of: Self.headerKeyValueDelimiter) else { return nil }
            let key = String(entry[..<delimiter.lowerBound])
            guard !key.isEmpty, result[key] == nil else { return nil }
            result[key] = String(entry[delimiter.upperBound...])
        }
        return (result, start.lowerBound)
    }
}
