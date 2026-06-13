import Foundation
import Darwin

enum HDPIMZipEntryType {
    case directory
    case regularFile
    case symbolicLink
}

struct HDPIMZipEntryRecord {
    let path: String
    let normalizedPath: String
    let type: HDPIMZipEntryType
    let compressionMethod: UInt16
    let permissions: UInt16
    let externalAttributes: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc: UInt32
    let position: UInt64
    let fileNumber: UInt64

    var unixMode: UInt32 {
        (externalAttributes >> 16) & 0xFFFF
    }
}

struct HDPIMSymlinkRecord {
    let linkPath: String
    let linkTarget: String
    let permissions: UInt16
    let externalAttributes: UInt32
}

enum HDPIMMiniZipError: Error, LocalizedError {
    case openFailed(String)
    case invalidEntry(String)
    case invalidEntryPath(String)
    case openCurrentFileFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case closeCurrentFileFailed(String)
    case sizeMismatch(String, UInt64, UInt64)
    case crcMismatch(String, UInt32, UInt32)
    case invalidSymlinkTarget(String)
    case brokenSymlink(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "无法打开 ZIP 文件: \(path)"
        case .invalidEntry(let path):
            return "ZIP 条目无效: \(path)"
        case .invalidEntryPath(let path):
            return "ZIP 条目路径非法: \(path)"
        case .openCurrentFileFailed(let path):
            return "无法打开 ZIP 条目: \(path)"
        case .readFailed(let path):
            return "读取 ZIP 条目失败: \(path)"
        case .writeFailed(let path):
            return "写入解压文件失败: \(path)"
        case .closeCurrentFileFailed(let path):
            return "关闭 ZIP 条目失败: \(path)"
        case .sizeMismatch(let path, let expected, let actual):
            return "ZIP 条目大小不匹配: \(path), expected=\(expected), actual=\(actual)"
        case .crcMismatch(let path, let expected, let actual):
            return String(format: "ZIP 条目 CRC 不匹配: %@, expected=%08x, actual=%08x", path, expected, actual)
        case .invalidSymlinkTarget(let path):
            return "符号链接目标无效: \(path)"
        case .brokenSymlink(let path):
            return "符号链接目标不存在: \(path)"
        case .cancelled:
            return "解压已取消"
        }
    }
}

struct HDPIMMiniZipExtractionSummary {
    let restoredSymlinkCount: Int
    let restoredPermissionCount: Int
    let restoredMetadataCount: Int
}

final class HDPIMMiniZipExtractor {
    private let fileManager = FileManager.default

    func makeSession(zipURL: URL) throws -> HDPIMMiniZipArchiveSession {
        try HDPIMMiniZipArchiveSession(owner: self, zipURL: zipURL)
    }

    func listEntries(
        zipURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) throws -> [HDPIMZipEntryRecord] {
        guard let archive = unzOpen64(zipURL.path) else {
            throw HDPIMMiniZipError.openFailed(zipURL.path)
        }

        defer {
            unzClose(archive)
        }

        var globalInfo = unz_global_info64()
        let globalInfoStatus = unzGetGlobalInfo64(archive, &globalInfo)
        let totalEntries = globalInfoStatus == UNZ_OK ? max(Int(globalInfo.number_entry), 1) : 1
        var entries: [HDPIMZipEntryRecord] = []
        var status = unzGoToFirstFile(archive)

        while status == UNZ_OK {
            entries.append(try currentEntryRecord(in: archive))
            progressHandler?(Double(entries.count) / Double(totalEntries))
            status = unzGoToNextFile(archive)
        }

        guard status == UNZ_END_OF_LIST_OF_FILE else {
            throw HDPIMMiniZipError.readFailed(zipURL.path)
        }

        return entries
    }

    func readEntryData(zipURL: URL, entryPath: String) throws -> Data {
        let entries = try listEntries(zipURL: zipURL)
        guard let entry = entries.first(where: { $0.normalizedPath == normalizedEntryPath(entryPath) }) else {
            throw HDPIMMiniZipError.invalidEntry(entryPath)
        }

        return try withArchive(zipURL: zipURL) { archive in
            try goToEntry(entry, in: archive)
            return try readCurrentEntryData(in: archive, path: entry.normalizedPath)
        }
    }

    func extract(
        zipURL: URL,
        entries: [HDPIMZipEntryRecord],
        to destinationURL: URL,
        compressionType: String,
        progressHandler: ((Double) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> HDPIMMiniZipExtractionSummary {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        return try withArchive(zipURL: zipURL) { archive in
            let totalWork = max(totalProgressUnits(for: entries), 1)
            var pendingSymlinks: [HDPIMSymlinkRecord] = []
            var pendingAppleDoubleEntries: [HDPIMZipEntryRecord] = []
            var restoredPermissionCount = 0
            var completedWork: UInt64 = 0

            let advanceProgress: (UInt64) -> Void = { delta in
                guard delta > 0 else { return }
                completedWork = min(totalWork, completedWork + delta)
                progressHandler?(Double(completedWork) / Double(totalWork))
            }

            var status = unzGoToFirstFile(archive)
            while status == UNZ_OK {
                try throwIfCancelled(cancellationCheck)

                let entry = try currentEntryRecord(in: archive)

                if isMacOSXEntry(entry) {
                    pendingAppleDoubleEntries.append(entry)
                    advanceProgress(1)
                    status = unzGoToNextFile(archive)
                    continue
                }

                let outputURL = destinationURL.appendingPathComponent(entry.normalizedPath, isDirectory: entry.type == .directory)

                switch entry.type {
                case .directory:
                    if !entry.normalizedPath.isEmpty {
                        try createDirectoryIfNeeded(at: outputURL)
                        if try applyAttributes(entry.externalAttributes, to: outputURL.path, isSymbolicLink: false) {
                            restoredPermissionCount += 1
                        }
                    }
                    advanceProgress(1)
                case .symbolicLink:
                    try createParentDirectoryIfNeeded(for: outputURL)
                    let targetData = try readCurrentEntryData(
                        in: archive,
                        path: entry.normalizedPath
                    )
                    let targetPath = try decodeSymlinkTarget(targetData, entryPath: entry.normalizedPath)
                    pendingSymlinks.append(HDPIMSymlinkRecord(
                        linkPath: outputURL.path,
                        linkTarget: targetPath,
                        permissions: entry.permissions,
                        externalAttributes: entry.externalAttributes
                    ))
                    advanceProgress(1)
                case .regularFile:
                    try createParentDirectoryIfNeeded(for: outputURL)
                    try writeRegularEntry(
                        entry,
                        archive: archive,
                        outputURL: outputURL,
                        compressionType: compressionType,
                        chunkHandler: { advanceProgress(UInt64($0)) },
                        cancellationCheck: cancellationCheck
                    )
                    if try applyAttributes(entry.externalAttributes, to: outputURL.path, isSymbolicLink: false) {
                        restoredPermissionCount += 1
                    }
                }

                status = unzGoToNextFile(archive)
            }

            guard status == UNZ_END_OF_LIST_OF_FILE else {
                throw HDPIMMiniZipError.readFailed(zipURL.path)
            }

            let orderedSymlinks = pendingSymlinks.sorted { lhs, rhs in
                let lhsDepth = lhs.linkPath.split(separator: "/").count
                let rhsDepth = rhs.linkPath.split(separator: "/").count
                if lhsDepth != rhsDepth {
                    return lhsDepth < rhsDepth
                }
                return lhs.linkPath.localizedStandardCompare(rhs.linkPath) == .orderedAscending
            }

            var restoredSymlinkCount = 0
            for linkRecord in orderedSymlinks {
                try throwIfCancelled(cancellationCheck)
                try removeItemIfExists(at: linkRecord.linkPath)
                guard Darwin.symlink(linkRecord.linkTarget, linkRecord.linkPath) == 0 else {
                    throw HDPIMMiniZipError.invalidSymlinkTarget(linkRecord.linkPath)
                }
                if try applyAttributes(linkRecord.externalAttributes, to: linkRecord.linkPath, isSymbolicLink: true) {
                    restoredPermissionCount += 1
                }
                restoredSymlinkCount += 1
            }

            for linkRecord in orderedSymlinks {
                try throwIfCancelled(cancellationCheck)
                try validateSymlinkTarget(at: linkRecord.linkPath, target: linkRecord.linkTarget)
            }

            var restoredMetadataCount = 0
            for appleDoubleEntry in pendingAppleDoubleEntries {
                try throwIfCancelled(cancellationCheck)
                let restored = (try? restoreAppleDoubleMetadata(
                    appleDoubleEntry,
                    archive: archive,
                    destinationURL: destinationURL,
                    compressionType: compressionType,
                    cancellationCheck: cancellationCheck
                )) ?? false
                if restored {
                    restoredMetadataCount += 1
                }
            }

            progressHandler?(1.0)

            return HDPIMMiniZipExtractionSummary(
                restoredSymlinkCount: restoredSymlinkCount,
                restoredPermissionCount: restoredPermissionCount,
                restoredMetadataCount: restoredMetadataCount
            )
        }
    }

    func withArchive<T>(zipURL: URL, _ body: (unzFile) throws -> T) throws -> T {
        guard let archive = unzOpen64(zipURL.path) else {
            throw HDPIMMiniZipError.openFailed(zipURL.path)
        }

        defer {
            unzClose(archive)
        }

        return try body(archive)
    }

    func currentEntryRecord(in archive: unzFile) throws -> HDPIMZipEntryRecord {
        var fileInfo = unz_file_info64()
        var filePos = unz64_file_pos()
        let bufferSize = 4096
        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer {
            nameBuffer.deallocate()
        }

        let infoStatus = unzGetCurrentFileInfo64(
            archive,
            &fileInfo,
            nameBuffer,
            UInt(bufferSize),
            nil,
            0,
            nil,
            0
        )
        guard infoStatus == UNZ_OK else {
            throw HDPIMMiniZipError.invalidEntry("")
        }

        let posStatus = unzGetFilePos64(archive, &filePos)
        guard posStatus == UNZ_OK else {
            throw HDPIMMiniZipError.invalidEntry(String(cString: nameBuffer))
        }

        let rawPath = String(cString: nameBuffer)
        let normalizedPath = try sanitizedPath(rawPath)
        let unixMode = (UInt32(fileInfo.external_fa) >> 16) & 0xFFFF
        let fileType = unixMode & 0xF000
        let entryType: HDPIMZipEntryType

        if rawPath.hasSuffix("/") || fileType == 0x4000 {
            entryType = .directory
        } else if fileType == 0xA000 {
            entryType = .symbolicLink
        } else {
            entryType = .regularFile
        }

        return HDPIMZipEntryRecord(
            path: rawPath,
            normalizedPath: normalizedPath,
            type: entryType,
            compressionMethod: UInt16(fileInfo.compression_method),
            permissions: UInt16(unixMode & 0x01FF),
            externalAttributes: UInt32(fileInfo.external_fa),
            compressedSize: UInt64(fileInfo.compressed_size),
            uncompressedSize: UInt64(fileInfo.uncompressed_size),
            crc: UInt32(fileInfo.crc),
            position: UInt64(filePos.pos_in_zip_directory),
            fileNumber: UInt64(filePos.num_of_file)
        )
    }

    func goToEntry(_ entry: HDPIMZipEntryRecord, in archive: unzFile) throws {
        var position = unz64_file_pos(
            pos_in_zip_directory: Int64(entry.position),
            num_of_file: ZPOS64_T(entry.fileNumber)
        )
        guard unzGoToFilePos64(archive, &position) == UNZ_OK else {
            throw HDPIMMiniZipError.invalidEntry(entry.normalizedPath)
        }
    }

    func readCurrentEntryData(
        in archive: unzFile,
        path: String,
        chunkHandler: ((Int) -> Void)? = nil
    ) throws -> Data {
        guard unzOpenCurrentFile(archive) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var data = Data()

        while true {
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }
            data.append(buffer, count: Int(readBytes))
            chunkHandler?(Int(readBytes))
        }

        let closeStatus = unzCloseCurrentFile(archive)
        shouldClose = false
        guard closeStatus == UNZ_OK else {
            throw HDPIMMiniZipError.closeCurrentFileFailed(path)
        }

        return data
    }

    func writeRegularEntry(
        _ entry: HDPIMZipEntryRecord,
        archive: unzFile,
        outputURL: URL,
        compressionType: String,
        chunkHandler: ((Int) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws {
        if shouldApplyLZMA2(to: entry, compressionType: compressionType) {
            try extractZipLZMA2EntryAutomatic(
                entry,
                in: archive,
                to: outputURL.path,
                chunkHandler: chunkHandler,
                cancellationCheck: cancellationCheck
            )
            return
        }

        let result = try extractCurrentEntry(
            in: archive,
            to: outputURL.path,
            path: entry.normalizedPath,
            chunkHandler: chunkHandler,
            cancellationCheck: cancellationCheck
        )
        try validateEntryIntegrity(
            entry,
            actualSize: result.writtenSize,
            actualCRC: result.crc
        )
    }

    @discardableResult
    func extractCurrentEntry(
        in archive: unzFile,
        to fullPath: String,
        path: String,
        chunkHandler: ((Int) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> (writtenSize: UInt64, crc: UInt32) {
        guard unzOpenCurrentFile(archive) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        let handle = try openOutputHandle(at: fullPath)
        defer {
            try? handle.close()
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var writtenSize: UInt64 = 0
        var crc: UInt32 = 0

        while true {
            try throwIfCancelled(cancellationCheck)
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }
            let data = Data(buffer.prefix(Int(readBytes)))
            try handle.write(contentsOf: data)
            writtenSize += UInt64(readBytes)
            crc = HDPIMCRC32(crc, data)
            chunkHandler?(Int(readBytes))
        }

        let closeStatus = unzCloseCurrentFile(archive)
        shouldClose = false
        guard closeStatus == UNZ_OK else {
            throw HDPIMMiniZipError.closeCurrentFileFailed(path)
        }

        return (writtenSize, crc)
    }

    private func extractZipLZMA2EntryAutomatic(
        _ entry: HDPIMZipEntryRecord,
        in archive: unzFile,
        to fullPath: String,
        chunkHandler: ((Int) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws {
        if entry.compressionMethod == 0 {
            _ = try extractStoredLZMA2Entry(
                entry,
                in: archive,
                to: fullPath,
                path: entry.normalizedPath,
                chunkHandler: chunkHandler,
                cancellationCheck: cancellationCheck
            )
            return
        }

        let decodedSize = try extractHDPIMLZMA2Entry(
            entry,
            in: archive,
            to: fullPath,
            path: entry.normalizedPath,
            cancellationCheck: cancellationCheck
        )
        chunkHandler?(Int(decodedSize))
    }

    @discardableResult
    private func extractHDPIMLZMA2Entry(
        _ entry: HDPIMZipEntryRecord,
        in archive: unzFile,
        to fullPath: String,
        path: String,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> UInt64 {
        var method: Int32 = 0
        guard unzOpenCurrentFile3(archive, &method, nil, 1, nil) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        let outputSize = try readHDPIMLZMA2OutputSize(in: archive, path: path)

        let dictionaryByte = try readHDPIMLZMA2PropertyByte(in: archive, path: path)
        let compressedBodySize = entry.compressedSize > 0 ? entry.compressedSize - 1 : 0
        let decoder = try HDPIMSevenZipLZMA2Decoder(
            propertyByte: dictionaryByte,
            expectedSize: outputSize,
            compressedBodySize: compressedBodySize
        )

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            try throwIfCancelled(cancellationCheck)
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }
            try decoder.processChunk(Data(buffer.prefix(Int(readBytes))))
        }

        let decodedSize = try decoder.finish(withExpectedSize: outputSize, writingToPath: fullPath)

        _ = unzCloseCurrentFile(archive)
        shouldClose = false

        try validateExtractedEntryFile(entry, at: fullPath, actualSize: decodedSize.uint64Value)

        return decodedSize.uint64Value
    }

    private func readHDPIMLZMA2OutputSize(in archive: unzFile, path: String) throws -> UInt64 {
        let fieldSize = 64
        var field = [UInt8](repeating: 0, count: fieldSize)
        let status = unzGetLocalExtrafield(archive, &field, UInt32(fieldSize))
        guard status == UNZ_OK else {
            throw HDPIMMiniZipError.readFailed(path)
        }

        let digits = field.prefix { byte in
            byte >= 48 && byte <= 57
        }
        guard !digits.isEmpty,
              let value = UInt64(String(decoding: digits, as: UTF8.self)) else {
            throw HDPIMMiniZipError.invalidEntry(path)
        }

        return value
    }

    private func readHDPIMLZMA2PropertyByte(in archive: unzFile, path: String) throws -> UInt8 {
        var property = [UInt8](repeating: 0, count: 1)
        let readBytes = unzReadCurrentFile(archive, &property, 1)
        guard readBytes == 1 else {
            throw HDPIMMiniZipError.readFailed(path)
        }
        return property[0]
    }

    func shouldApplyLZMA2(to entry: HDPIMZipEntryRecord, compressionType: String) -> Bool {
        guard entry.type == .regularFile else {
            return false
        }

        guard compressionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zip-lzma2" else {
            return false
        }

        return !entry.normalizedPath.lowercased().hasSuffix(".pimx")
    }

    private func extractStoredLZMA2Entry(
        _ entry: HDPIMZipEntryRecord,
        in archive: unzFile,
        to fullPath: String,
        path: String,
        chunkHandler: ((Int) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> UInt64 {
        guard unzOpenCurrentFile(archive) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        let handle = try openOutputHandle(at: fullPath)
        defer {
            try? handle.close()
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var decoder: HDPIMNativeLZMA2StreamDecoder?
        var rawSize: UInt64 = 0
        var rawCRC: UInt32 = 0
        var decodedSize: UInt64 = 0

        while true {
            try throwIfCancelled(cancellationCheck)
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }

            let data = Data(buffer.prefix(Int(readBytes)))
            rawSize += UInt64(readBytes)
            rawCRC = HDPIMCRC32(rawCRC, data)
            chunkHandler?(Int(readBytes))

            if decoder == nil {
                guard let propertyByte = data.first else {
                    throw HDPIMMiniZipError.invalidEntry(path)
                }
                decoder = try HDPIMNativeLZMA2StreamDecoder(dictionaryByte: propertyByte)
                let body = data.dropFirst()
                if !body.isEmpty {
                    let output = try decoder!.process(chunk: Data(body), finish: false)
                    try handle.write(contentsOf: output)
                    decodedSize += UInt64(output.count)
                }
            } else {
                let output = try decoder!.process(chunk: data, finish: false)
                try handle.write(contentsOf: output)
                decodedSize += UInt64(output.count)
            }
        }

        if let decoder {
            let output = try decoder.process(chunk: Data(), finish: true)
            try handle.write(contentsOf: output)
            decodedSize += UInt64(output.count)
        } else {
            throw HDPIMMiniZipError.invalidEntry(path)
        }

        let closeStatus = unzCloseCurrentFile(archive)
        shouldClose = false
        guard closeStatus == UNZ_OK else {
            throw HDPIMMiniZipError.closeCurrentFileFailed(path)
        }

        try validateEntryIntegrity(entry, actualSize: rawSize, actualCRC: rawCRC)

        return decodedSize
    }

    private func openOutputHandle(at fullPath: String) throws -> FileHandle {
        if !fileManager.fileExists(atPath: fullPath) {
            guard fileManager.createFile(atPath: fullPath, contents: nil) else {
                throw HDPIMMiniZipError.writeFailed(fullPath)
            }
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fullPath))
        try handle.truncate(atOffset: 0)
        return handle
    }

    private func validateEntryIntegrity(
        _ entry: HDPIMZipEntryRecord,
        actualSize: UInt64,
        actualCRC: UInt32
    ) throws {
        guard actualSize == entry.uncompressedSize else {
            throw HDPIMMiniZipError.sizeMismatch(entry.normalizedPath, entry.uncompressedSize, actualSize)
        }
        guard actualCRC == entry.crc else {
            throw HDPIMMiniZipError.crcMismatch(entry.normalizedPath, entry.crc, actualCRC)
        }
    }

    private func validateExtractedEntryFile(
        _ entry: HDPIMZipEntryRecord,
        at path: String,
        actualSize: UInt64
    ) throws {
        let crc = try crc32OfFile(at: path)
        try validateEntryIntegrity(entry, actualSize: actualSize, actualCRC: crc)
    }

    private func crc32OfFile(at path: String) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer {
            try? handle.close()
        }

        var crc: UInt32 = 0
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            crc = HDPIMCRC32(crc, data)
        }
        return crc
    }

    func writeData(_ data: Data, to path: String) throws {
        guard fileManager.createFile(atPath: path, contents: nil) else {
            throw HDPIMMiniZipError.writeFailed(path)
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer {
            try? handle.close()
        }
        try handle.write(contentsOf: data)
    }

    func decodeSymlinkTarget(_ data: Data, entryPath: String) throws -> String {
        guard let targetPath = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !targetPath.isEmpty else {
            throw HDPIMMiniZipError.invalidSymlinkTarget(entryPath)
        }

        return targetPath
    }

    func createDirectoryIfNeeded(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func createParentDirectoryIfNeeded(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !parent.path.isEmpty else {
            return
        }
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    func applyAttributes(_ externalAttributes: UInt32, to path: String, isSymbolicLink: Bool) throws -> Bool {
        let unixMode = (externalAttributes >> 16) & 0xFFFF
        guard unixMode > 1 else {
            return false
        }

        let permissions = mode_t(unixMode & 0x01FF)
        let result: Int32
        if isSymbolicLink || (unixMode & 0xF000) == 0xA000 {
            result = lchmod(path, permissions)
        } else {
            result = chmod(path, permissions)
        }

        return result == 0
    }

    func isMacOSXEntry(_ entry: HDPIMZipEntryRecord) -> Bool {
        entry.normalizedPath == "__MACOSX" || entry.normalizedPath.hasPrefix("__MACOSX/")
    }

    func appleDoubleTargetURL(for entry: HDPIMZipEntryRecord, destinationURL: URL) -> URL? {
        let prefix = "__MACOSX/"
        guard entry.normalizedPath.hasPrefix(prefix) else {
            return nil
        }

        let relativePath = String(entry.normalizedPath.dropFirst(prefix.count))
        var components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let appleDoubleName = components.popLast(),
              appleDoubleName.hasPrefix("._"),
              appleDoubleName.count > 2 else {
            return nil
        }

        components.append(String(appleDoubleName.dropFirst(2)))
        let realRelativePath = components.joined(separator: "/")
        guard !realRelativePath.isEmpty else {
            return nil
        }

        return destinationURL.appendingPathComponent(realRelativePath)
    }

    func makeAppleDoubleTempURL() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("adbzip.temp.\(UUID().uuidString)")
    }

    @discardableResult
    func restoreAppleDoubleMetadata(
        _ entry: HDPIMZipEntryRecord,
        archive: unzFile,
        destinationURL: URL,
        compressionType: String,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> Bool {
        guard let targetURL = appleDoubleTargetURL(for: entry, destinationURL: destinationURL),
              fileManager.fileExists(atPath: targetURL.path) else {
            return false
        }

        try goToEntry(entry, in: archive)

        let tempURL = makeAppleDoubleTempURL()
        try createParentDirectoryIfNeeded(for: tempURL)
        defer {
            try? removeItemIfExists(at: tempURL.path)
        }

        try writeRegularEntry(
            entry,
            archive: archive,
            outputURL: tempURL,
            compressionType: compressionType,
            chunkHandler: nil,
            cancellationCheck: cancellationCheck
        )

        return HDPIMUnpackAppleDouble(tempURL.path, targetURL.path, nil)
    }

    func validateSymlinkTarget(at linkPath: String, target: String) throws {
        let linkParent = URL(fileURLWithPath: linkPath).deletingLastPathComponent()
        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target)
        } else {
            targetURL = URL(fileURLWithPath: target, relativeTo: linkParent).standardizedFileURL
        }

        var info = stat()
        guard lstat(targetURL.path, &info) == 0 else {
            throw HDPIMMiniZipError.brokenSymlink("\(linkPath) -> \(target)")
        }
    }

    func removeItemIfExists(at path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            try fileManager.removeItem(atPath: path)
        }
    }

    func throwIfCancelled(_ cancellationCheck: (() -> Bool)?) throws {
        if Task.isCancelled || (cancellationCheck?() ?? false) {
            throw HDPIMMiniZipError.cancelled
        }
    }

    func sanitizedPath(_ rawPath: String) throws -> String {
        if rawPath.hasPrefix("/") {
            throw HDPIMMiniZipError.invalidEntryPath(rawPath)
        }

        let normalized = normalizedEntryPath(rawPath)
        if normalized.isEmpty {
            return normalized
        }

        if normalized.contains("../") || normalized == ".." {
            throw HDPIMMiniZipError.invalidEntryPath(rawPath)
        }

        return normalized
    }

    func totalProgressUnits(for entries: [HDPIMZipEntryRecord]) -> UInt64 {
        entries.reduce(0) { partial, entry in
            switch entry.type {
            case .regularFile:
                return partial + max(entry.uncompressedSize, 1)
            case .directory, .symbolicLink:
                return partial + 1
            }
        }
    }

    func normalizedEntryPath(_ rawPath: String) -> String {
        let normalized = rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }
}

final class HDPIMMiniZipArchiveSession {
    private let owner: HDPIMMiniZipExtractor
    private let archive: unzFile

    init(owner: HDPIMMiniZipExtractor, zipURL: URL) throws {
        guard let archive = unzOpen64(zipURL.path) else {
            throw HDPIMMiniZipError.openFailed(zipURL.path)
        }
        self.owner = owner
        self.archive = archive
    }

    deinit {
        unzClose(archive)
    }

    func extractRegularEntry(
        _ entry: HDPIMZipEntryRecord,
        to outputURL: URL,
        compressionType: String,
        chunkHandler: ((Int) -> Void)? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> Bool {
        try owner.goToEntry(entry, in: archive)
        try owner.createParentDirectoryIfNeeded(for: outputURL)
        try owner.writeRegularEntry(
            entry,
            archive: archive,
            outputURL: outputURL,
            compressionType: compressionType,
            chunkHandler: chunkHandler,
            cancellationCheck: cancellationCheck
        )
        return try owner.applyAttributes(entry.externalAttributes, to: outputURL.path, isSymbolicLink: false)
    }

    func readSymlinkRecord(
        _ entry: HDPIMZipEntryRecord,
        destinationURL: URL
    ) throws -> HDPIMSymlinkRecord {
        try owner.goToEntry(entry, in: archive)
        let outputURL = destinationURL.appendingPathComponent(entry.normalizedPath, isDirectory: false)
        try owner.createParentDirectoryIfNeeded(for: outputURL)
        let targetData = try owner.readCurrentEntryData(in: archive, path: entry.normalizedPath)
        let targetPath = try owner.decodeSymlinkTarget(targetData, entryPath: entry.normalizedPath)
        return HDPIMSymlinkRecord(
            linkPath: outputURL.path,
            linkTarget: targetPath,
            permissions: entry.permissions,
            externalAttributes: entry.externalAttributes
        )
    }

    @discardableResult
    func restoreAppleDoubleMetadata(
        _ entry: HDPIMZipEntryRecord,
        destinationURL: URL,
        compressionType: String,
        cancellationCheck: (() -> Bool)? = nil
    ) throws -> Bool {
        try owner.restoreAppleDoubleMetadata(
            entry,
            archive: archive,
            destinationURL: destinationURL,
            compressionType: compressionType,
            cancellationCheck: cancellationCheck
        )
    }
}
