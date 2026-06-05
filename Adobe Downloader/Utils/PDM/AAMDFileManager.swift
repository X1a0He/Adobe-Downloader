import Foundation

final class AAMDFileManager {

    static let headerString = "Adobe_Download_001"
    static let headerSize = 18
    static let segmentEntrySize = 21
    static let headerKeyValueDelimiter = "{|}"

    private let aamdURL: URL
    private let fileManager = FileManager.default

    init(downloadFileURL: URL) {
        aamdURL = URL(fileURLWithPath: downloadFileURL.path + ".aamd")
    }

    func exists() -> Bool {
        fileManager.fileExists(atPath: aamdURL.path)
    }

    func remove() {
        guard fileManager.fileExists(atPath: aamdURL.path),
              let handle = try? FileHandle(forWritingTo: aamdURL) else {
            return
        }
        defer { try? handle.close() }
        handle.truncateFile(atOffset: 0)
    }

    func writeMetaInfo() {
        let header = "\(AAMDFileManager.headerString)\n"
        guard let data = header.data(using: .utf8) else { return }

        if fileManager.fileExists(atPath: aamdURL.path),
           let handle = try? FileHandle(forWritingTo: aamdURL) {
            defer { try? handle.close() }
            handle.truncateFile(atOffset: 0)
            handle.write(data)
            return
        }

        fileManager.createFile(atPath: aamdURL.path, contents: data)
    }

    func writeHeaders(_ headers: [String: String], segmentTableSpan: Int) {
        guard let handle = try? FileHandle(forWritingTo: aamdURL) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: UInt64(headersOffset(segmentTableSpan: segmentTableSpan)))

        let xml = constructHeadersXML(headers)
        if let data = xml.data(using: .utf8) {
            handle.write(data)
        }
    }

    func updateSegmentData(segment: Int, bytesDownloaded: Int64) {
        guard let handle = try? FileHandle(forWritingTo: aamdURL) else { return }
        defer { try? handle.close() }

        let offset = UInt64(segmentOffset(segment))
        handle.seek(toFileOffset: offset)

        let entry = String(format: "%20lu\n", bytesDownloaded)
        if let data = entry.data(using: .utf8) {
            handle.write(data)
        }
    }

    func validateAAMDFile() -> Bool {
        guard let data = try? Data(contentsOf: aamdURL) else { return false }
        guard data.count >= AAMDFileManager.headerSize else { return false }

        let headerData = data[0..<AAMDFileManager.headerSize]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return false }

        return headerStr.trimmingCharacters(in: .newlines) == AAMDFileManager.headerString
    }

    func readHeaders() -> [String: String]? {
        guard let data = try? Data(contentsOf: aamdURL),
              let content = String(data: data, encoding: .utf8) else { return nil }

        guard let startRange = content.range(of: "<headers>"),
              let endRange = content.range(of: "</headers>") else { return nil }

        let xmlContent = String(content[startRange.upperBound..<endRange.lowerBound])
        return parseHeadersXML(xmlContent)
    }

    func getBytesDownloadedForSegment(_ segment: Int) -> Int64 {
        guard let data = try? Data(contentsOf: aamdURL) else { return 0 }

        let offset = segmentOffset(segment)
        let end = offset + AAMDFileManager.segmentEntrySize

        guard end <= data.count else { return 0 }

        let segmentData = data[offset..<end]
        guard let str = String(data: segmentData, encoding: .utf8) else { return 0 }

        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(trimmed) ?? 0
    }

    func getTotalBytesDownloaded(segmentCount: Int) -> Int64 {
        var total: Int64 = 0
        for i in 0..<segmentCount {
            total += getBytesDownloadedForSegment(i)
        }
        return total
    }

    func validateHeaders(
        remoteETag: String,
        remoteFileSize: Int64,
        remoteURL: String,
        segmentSize: Int64
    ) -> Bool {
        guard let stored = readHeaders() else { return false }

        if let storedETag = stored["ETAG"], !storedETag.isEmpty, !remoteETag.isEmpty {
            if storedETag != remoteETag { return false }
        }

        if let storedSize = stored["FILE_SIZE"], let size = Int64(storedSize) {
            if size != remoteFileSize { return false }
        }

        if let storedURL = stored["SERVER_PATH"], !storedURL.isEmpty {
            if storedURL != remoteURL { return false }
        }

        if let storedSegSize = stored["SEGMENT_SIZE"], let segSize = Int64(storedSegSize) {
            if segSize != segmentSize { return false }
        }

        if let storedBytesToDownload = stored["NO_Of_BYTES_TO_DOWNLOAD"],
           let bytesToDownload = Int64(storedBytesToDownload) {
            if bytesToDownload != remoteFileSize { return false }
        }

        return true
    }

    private func segmentOffset(_ segment: Int) -> Int {
        AAMDFileManager.headerSize + segment * AAMDFileManager.segmentEntrySize
    }

    private func headersOffset(segmentTableSpan: Int) -> Int {
        AAMDFileManager.headerSize + (max(segmentTableSpan, 0) + 1) * AAMDFileManager.segmentEntrySize
    }

    private func constructHeadersXML(_ headers: [String: String]) -> String {
        var xml = "<headers>\n"
        for (key, value) in headers {
            xml += "@START@\(key)\(AAMDFileManager.headerKeyValueDelimiter)\(value)@END@\n"
        }
        xml += "</headers>\n"
        return xml
    }

    private func parseHeadersXML(_ xml: String) -> [String: String] {
        var result: [String: String] = [:]
        var remaining = xml

        while let startRange = remaining.range(of: "@START@") {
            remaining = String(remaining[startRange.upperBound...])

            guard let endRange = remaining.range(of: "@END@") else { break }
            let entry = String(remaining[remaining.startIndex..<endRange.lowerBound])

            if let delimRange = entry.range(of: AAMDFileManager.headerKeyValueDelimiter) {
                let key = String(entry[entry.startIndex..<delimRange.lowerBound])
                let value = String(entry[delimRange.upperBound...])
                result[key] = value
            }

            remaining = String(remaining[endRange.upperBound...])
        }

        return result
    }
}
