import Foundation
import Darwin
import cminizip

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
                        chunkHandler: { advanceProgress(UInt64($0)) }
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

            progressHandler?(1.0)

            return HDPIMMiniZipExtractionSummary(
                restoredSymlinkCount: restoredSymlinkCount,
                restoredPermissionCount: restoredPermissionCount
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
            pos_in_zip_directory: ZPOS64_T(entry.position),
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
        chunkHandler: ((Int) -> Void)? = nil
    ) throws {
        if shouldApplyLZMA2(to: entry, compressionType: compressionType) {
            try extractLZMA2EntryStreaming(
                in: archive,
                to: outputURL.path,
                path: entry.normalizedPath,
                chunkHandler: chunkHandler
            )
            return
        }

        try extractCurrentEntry(
            in: archive,
            to: outputURL.path,
            path: entry.normalizedPath,
            chunkHandler: chunkHandler
        )
    }

    func extractCurrentEntry(
        in archive: unzFile,
        to fullPath: String,
        path: String,
        chunkHandler: ((Int) -> Void)? = nil
    ) throws {
        guard unzOpenCurrentFile(archive) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        guard fileManager.createFile(atPath: fullPath, contents: nil) else {
            throw HDPIMMiniZipError.writeFailed(fullPath)
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fullPath))
        defer {
            try? handle.close()
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }
            try handle.write(contentsOf: buffer.prefix(Int(readBytes)))
            chunkHandler?(Int(readBytes))
        }

        let closeStatus = unzCloseCurrentFile(archive)
        shouldClose = false
        guard closeStatus == UNZ_OK else {
            throw HDPIMMiniZipError.closeCurrentFileFailed(path)
        }
    }

    private func extractLZMA2EntryStreaming(
        in archive: unzFile,
        to fullPath: String,
        path: String,
        chunkHandler: ((Int) -> Void)? = nil
    ) throws {
        guard unzOpenCurrentFile(archive) == UNZ_OK else {
            throw HDPIMMiniZipError.openCurrentFileFailed(path)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = unzCloseCurrentFile(archive)
            }
        }

        guard fileManager.createFile(atPath: fullPath, contents: nil) else {
            throw HDPIMMiniZipError.writeFailed(fullPath)
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fullPath))
        defer {
            try? handle.close()
        }

        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var isDecoderInitialized = false
        var decoder: HDPIMNativeLZMA2StreamDecoder?

        while true {
            let readBytes = unzReadCurrentFile(archive, &buffer, UInt32(bufferSize))
            if readBytes < 0 {
                throw HDPIMMiniZipError.readFailed(path)
            }
            if readBytes == 0 {
                break
            }

            var chunk = Data(buffer.prefix(Int(readBytes)))
            if !isDecoderInitialized {
                guard let dictionaryByte = chunk.first else {
                    throw HDPIMMiniZipError.readFailed(path)
                }
                decoder = try HDPIMNativeLZMA2StreamDecoder(dictionaryByte: dictionaryByte)
                chunk.removeFirst()
                isDecoderInitialized = true
            }

            guard let decoder else {
                throw HDPIMMiniZipError.readFailed(path)
            }

            if !chunk.isEmpty {
                let decodedData = try decoder.process(chunk: chunk, finish: false)
                if !decodedData.isEmpty {
                    try handle.write(contentsOf: decodedData)
                    chunkHandler?(decodedData.count)
                }
            }
        }

        if let decoder {
            let tailData = try decoder.process(chunk: Data(), finish: true)
            if !tailData.isEmpty {
                try handle.write(contentsOf: tailData)
                chunkHandler?(tailData.count)
            }
        }

        let closeStatus = unzCloseCurrentFile(archive)
        shouldClose = false
        guard closeStatus == UNZ_OK else {
            throw HDPIMMiniZipError.closeCurrentFileFailed(path)
        }
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
        chunkHandler: ((Int) -> Void)? = nil
    ) throws -> Bool {
        try owner.goToEntry(entry, in: archive)
        try owner.createParentDirectoryIfNeeded(for: outputURL)
        try owner.writeRegularEntry(
            entry,
            archive: archive,
            outputURL: outputURL,
            compressionType: compressionType,
            chunkHandler: chunkHandler
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
}
