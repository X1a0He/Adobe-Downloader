import Foundation
import CryptoKit

/// 下载完成记录绑定材料身份和内容；文件长度、UI 进度与断点计数都不能代替它。
enum DownloadArtifactStore {
    struct Identity: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let source: String
        let hashKey: String

        init(name: String, version: String = "", source: String = "", hashKey: String = "") {
            self.name = name
            self.version = version
            self.source = source
            self.hashKey = hashKey
        }

        func matches(_ expected: Identity) -> Bool {
            name == expected.name
                && (expected.version.isEmpty || version == expected.version)
                && (expected.source.isEmpty || source == expected.source)
                && (expected.hashKey.isEmpty || hashKey == expected.hashKey)
        }
    }

    enum Inspection {
        case verified(Int64)
        case incomplete(Int64)
        case unverified
        case missing

        var verifiedSize: Int64? {
            if case .verified(let size) = self { return size }
            return nil
        }

        var downloadedBytes: Int64 {
            switch self {
            case .verified(let size), .incomplete(let size): return size
            default: return 0
            }
        }
    }

    struct IntegrityError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct FileStamp: Codable, Equatable {
        let size: Int64
        let modified: Date
        let fileNumber: UInt64
        let device: UInt64
    }

    private struct Receipt: Codable {
        let schemaVersion: Int
        let identity: Identity
        let stamp: FileStamp
        let sha256: String
        let verification: String
    }

    static func identity(for package: Package) -> Identity {
        Identity(name: package.fullPackageName, version: package.packageVersion,
                 source: package.manifestURL.isEmpty ? package.downloadURL : package.manifestURL,
                 hashKey: package.packageHashKey)
    }

    static func specialMetadataDirectory(for task: NewDownloadTask) -> URL {
        specialMetadataDirectory(productId: task.productId, version: task.productVersion,
                                 language: task.language, platform: task.platform, directory: task.directory)
    }

    static func specialMetadataDirectory(productId: String, version: String, language: String, platform: String, directory: URL) -> URL {
        let seed = [productId, version, language, platform, directory.standardizedFileURL.path].joined(separator: "|")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Adobe Downloader/PDM/\(productId)/\(String(hash, radix: 16))/Metadata", isDirectory: true)
    }

    static func receiptURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("download-complete.json")
    }

    static func inspect(
        fileURL: URL, identity: Identity? = nil, expectedSize: Int64 = 0,
        metadataDirectory: URL? = nil
    ) -> Inspection {
        guard let stamp = try? fileStamp(fileURL) else { return .missing }
        if let pending = pendingDownload(fileURL: fileURL, metadataDirectory: metadataDirectory) {
            return pending
        }
        guard expectedSize <= 0 || stamp.size == expectedSize,
              let receipt = readReceipt(fileURL), receipt.schemaVersion == 1,
              identity.map({ receipt.identity.matches($0) }) ?? true,
              receipt.stamp == stamp else { return .unverified }
        return .verified(stamp.size)
    }

    /// 强复核允许复制后的安装源使用原记录，但始终重新计算内容摘要。
    @discardableResult
    static func verify(
        fileURL: URL, identity: Identity? = nil, expectedSize: Int64 = 0,
        metadataDirectory: URL? = nil, validationInfo: ValidationInfo? = nil,
        allowLegacy: Bool = true, cancellationCheck: (() -> Bool)? = nil
    ) throws -> Int64 {
        try checkCancellation(cancellationCheck)
        let before = try fileStamp(fileURL)
        try requireSize(before.size, expected: expectedSize, fileURL: fileURL)
        if pendingDownload(fileURL: fileURL, metadataDirectory: metadataDirectory) != nil {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 尚未下载完整或断点记录无效，请继续下载后再安装")
        }
        if let receipt = try matchingReceipt(fileURL, identity: identity, size: before.size) {
            guard try sha256(fileURL, cancellationCheck: cancellationCheck) == receipt.sha256 else {
                throw IntegrityError(message: "\(fileURL.lastPathComponent) 内容与已完成记录不一致，请重新校验或下载")
            }
        } else if let validationInfo {
            let validator = PDMValidationManager(communicator: PDMHttpCommunicator())
            guard try validator.validateFile(at: fileURL, validationInfo: validationInfo, totalSize: before.size) else {
                throw IntegrityError(message: "材料摘要或长度校验失败：\(fileURL.lastPathComponent)")
            }
        } else if allowLegacy && fileURL.pathExtension.lowercased() == "zip" {
            try validateZIP(fileURL, contents: true, cancellationCheck: cancellationCheck)
        } else {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 缺少有效的下载完成证明，请恢复下载以重新核对材料")
        }
        guard try fileStamp(fileURL) == before else {
            throw IntegrityError(message: "校验期间文件发生变化：\(fileURL.lastPathComponent)")
        }
        return before.size
    }

    /// 仅由完整下载成功或 verify 成功的调用方提交；提交先于界面完成与断点清理。
    static func recordCompletion(
        fileURL: URL, identity: Identity, expectedSize: Int64 = 0,
        metadataDirectory: URL? = nil, validationInfo: ValidationInfo? = nil,
        cancellationCheck: (() -> Bool)? = nil
    ) throws {
        try checkCancellation(cancellationCheck)
        let before = try fileStamp(fileURL)
        try requireSize(before.size, expected: expectedSize, fileURL: fileURL)
        guard pendingDownload(fileURL: fileURL, metadataDirectory: metadataDirectory) == nil else {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 的分片尚未完成，不能提交下载完成状态")
        }
        let existingReceipt = try matchingReceipt(fileURL, identity: identity, size: before.size)
        if let existingReceipt, existingReceipt.identity != identity {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 的完成记录身份不同，不能重新标记为当前材料")
        }
        if let validationInfo {
            let validator = PDMValidationManager(communicator: PDMHttpCommunicator())
            guard try validator.validateFile(at: fileURL, validationInfo: validationInfo, totalSize: before.size) else {
                throw IntegrityError(message: "材料摘要或长度校验失败：\(fileURL.lastPathComponent)")
            }
        }
        if existingReceipt == nil && fileURL.pathExtension.lowercased() == "zip" {
            // 首次认证没有官方摘要的 ZIP 时，中央目录存在不足以证明正文完整。
            try validateZIP(fileURL, contents: validationInfo == nil, cancellationCheck: cancellationCheck)
        }
        let digest = try sha256(fileURL, cancellationCheck: cancellationCheck)
        if let existingReceipt, existingReceipt.sha256 != digest {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 内容与已完成记录不一致，不能重新签发完成记录")
        }
        guard try fileStamp(fileURL) == before else {
            throw IntegrityError(message: "记录完成状态时文件发生变化：\(fileURL.lastPathComponent)")
        }
        try checkCancellation(cancellationCheck)
        if let existingReceipt, existingReceipt.stamp == before, existingReceipt.identity == identity {
            return
        }
        let verification = existingReceipt?.verification
            ?? (validationInfo != nil ? "vendor-segments" : (fileURL.pathExtension.lowercased() == "zip" ? "zip-crc-sha256" : "verified-download"))
        let receipt = Receipt(schemaVersion: 1, identity: identity, stamp: before, sha256: digest, verification: verification)
        let data = try JSONEncoder().encode(receipt)
        if existingReceipt != nil {
            try preserveReceipt(fileURL)
        }
        try data.write(to: receiptURL(for: fileURL), options: .atomic)
    }

    /// 旧 ZIP 只在全部条目校验后迁移；未知材料保留文件和断点，不推断完成。
    static func restore(
        fileURL: URL, identity: Identity, expectedSize: Int64,
        metadataDirectory: URL? = nil, allowLegacy: Bool
    ) -> Inspection {
        let current = inspect(fileURL: fileURL, identity: identity, expectedSize: expectedSize,
                              metadataDirectory: metadataDirectory)
        switch current {
        case .verified, .incomplete, .missing: return current
        case .unverified: break
        }
        guard (try? verify(fileURL: fileURL, identity: identity, expectedSize: expectedSize,
                           metadataDirectory: metadataDirectory, allowLegacy: allowLegacy)) != nil else {
            return .unverified
        }
        do {
            try recordCompletion(fileURL: fileURL, identity: identity, expectedSize: expectedSize,
                                 metadataDirectory: metadataDirectory)
            return inspect(fileURL: fileURL, identity: identity, expectedSize: expectedSize,
                           metadataDirectory: metadataDirectory)
        } catch {
            return .unverified
        }
    }

    static func preserveForRetry(_ fileURL: URL) throws {
        let manager = FileManager.default
        let paths = [fileURL, URL(fileURLWithPath: fileURL.path + ".aamd"), receiptURL(for: fileURL)]
            .filter { manager.fileExists(atPath: $0.path) }
        guard !paths.isEmpty else { return }
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".download-recovery-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        for path in paths {
            try manager.moveItem(at: path, to: backup.appendingPathComponent(path.lastPathComponent))
        }
    }

    private static func pendingDownload(fileURL: URL, metadataDirectory: URL?) -> Inspection? {
        var directories: [URL?] = [metadataDirectory]
        if metadataDirectory != nil { directories.append(nil) }
        for directory in directories {
            let sidecar = directory?.appendingPathComponent(fileURL.lastPathComponent + ".aamd")
                ?? URL(fileURLWithPath: fileURL.path + ".aamd")
            guard let data = try? Data(contentsOf: sidecar), !data.isEmpty else { continue }
            let manager = AAMDFileManager(downloadFileURL: fileURL, metadataDirectory: directory)
            guard let snapshot = manager.resumeSnapshot() else { return .unverified }
            if !snapshot.isComplete { return .incomplete(snapshot.downloadedBytes) }
        }
        return nil
    }

    /// 明确存在的冲突或损坏记录不能降级为旧文件认证，必须先归档旧材料再重新下载。
    private static func matchingReceipt(_ fileURL: URL, identity: Identity?, size: Int64) throws -> Receipt? {
        let receiptPath = receiptURL(for: fileURL)
        guard FileManager.default.fileExists(atPath: receiptPath.path) else { return nil }
        guard let receipt = readReceipt(fileURL), receipt.schemaVersion == 1,
              identity.map({ receipt.identity.matches($0) }) ?? true,
              receipt.stamp.size == size,
              receipt.sha256.count == 64,
              receipt.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 的完成记录损坏、版本不受支持或材料身份冲突，请保留旧材料后重新下载")
        }
        return receipt
    }

    private static func preserveReceipt(_ fileURL: URL) throws {
        let receiptPath = receiptURL(for: fileURL)
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".download-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: receiptPath, to: backup.appendingPathComponent(receiptPath.lastPathComponent))
    }

    private static func readReceipt(_ fileURL: URL) -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL(for: fileURL)) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private static func fileStamp(_ url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else {
            throw IntegrityError(message: "下载材料不是普通文件：\(url.lastPathComponent)")
        }
        return FileStamp(size: size, modified: modified,
                         fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                         device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private static func requireSize(_ actual: Int64, expected: Int64, fileURL: URL) throws {
        guard actual > 0, expected <= 0 || actual == expected else {
            throw IntegrityError(message: "\(fileURL.lastPathComponent) 大小不一致，期望 \(expected)，实际 \(actual)")
        }
    }

    private final class CancellationContext {
        let check: (() -> Bool)?
        init(_ check: (() -> Bool)?) { self.check = check }
    }

    private static func checkCancellation(_ check: (() -> Bool)?) throws {
        if Task.isCancelled || check?() == true { throw CancellationError() }
    }

    private static func sha256(_ url: URL, cancellationCheck: (() -> Bool)?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try checkCancellation(cancellationCheck)
            let hasData = try autoreleasepool {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                guard !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !hasData { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateZIP(_ url: URL, contents: Bool, cancellationCheck: (() -> Bool)?) throws {
        let context = Unmanaged.passRetained(CancellationContext(cancellationCheck))
        defer { context.release() }
        let result = HDPIMValidateZipArchiveWithCancellation(url.path, contents ? 1 : 0, { pointer in
            guard let pointer else { return Task.isCancelled }
            let value = Unmanaged<CancellationContext>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || value.check?() == true
        }, context.toOpaque())
        if result == -1000 { throw CancellationError() }
        guard result == 0 else {
            throw IntegrityError(message: "\(url.lastPathComponent) ZIP 完整性校验失败（\(result)），请继续下载或重新获取该包")
        }
    }
}
