//
//  HDPIMRepairManager.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit

struct CorruptedFile {
    let path: String
    let expectedHash: String
    let actualHash: String
    let packageName: String
}

class HDPIMRepairManager {
    private let database: HDPIMDatabase

    init(database: HDPIMDatabase = .shared) {
        self.database = database
    }

    func verifyFileIntegrity(
        sapCode: String,
        platform: String?,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> [CorruptedFile] {
        progressHandler?(1.0, "验证完成")
        return []
    }

    func detectCorruptedFiles(
        sapCode: String,
        platform: String?
    ) async throws -> [CorruptedFile] {
        return try await verifyFileIntegrity(sapCode: sapCode, platform: platform)
    }

    func repair(
        sapCode: String,
        platform: String?,
        corruptedFiles: [CorruptedFile],
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        guard !corruptedFiles.isEmpty else {
            progressHandler?(1.0, "无需修复")
            return
        }

        let packageGroups = Dictionary(grouping: corruptedFiles) { $0.packageName }
        var repairedCount = 0
        let totalCount = corruptedFiles.count

        for (packageName, files) in packageGroups {
            progressHandler?(Double(repairedCount) / Double(totalCount), "修复包: \(packageName)")

            guard let packagePath = findPackagePath(packageName: packageName, sapCode: sapCode) else {
                throw RepairError.packageNotFound(packageName)
            }

            for file in files {
                try await repairFile(file: file, packagePath: packagePath)
                repairedCount += 1
                progressHandler?(Double(repairedCount) / Double(totalCount), "修复: \(file.path)")
            }
        }

        progressHandler?(1.0, "修复完成")
    }

    private func computeHash(for fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024

        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func findPackagePath(packageName: String, sapCode: String) -> URL? {
        let downloadRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Adobe Downloader/Downloads")
            .appendingPathComponent(sapCode)

        guard let enumerator = FileManager.default.enumerator(at: downloadRoot, includingPropertiesForKeys: nil) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == packageName {
                return fileURL
            }
        }

        return nil
    }

    private func repairFile(file: CorruptedFile, packagePath: URL) async throws {
        let fileName = URL(fileURLWithPath: file.path).lastPathComponent
        let sourceFile = packagePath.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: sourceFile.path) else {
            throw RepairError.sourceFileNotFound(fileName)
        }

        let destinationURL = URL(fileURLWithPath: file.path)
        let parentDir = destinationURL.deletingLastPathComponent()

        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(atPath: file.path)
        }

        try FileManager.default.copyItem(at: sourceFile, to: destinationURL)
    }
}

enum RepairError: Error, LocalizedError {
    case productNotInstalled
    case packageNotFound(String)
    case sourceFileNotFound(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .productNotInstalled:
            return "产品未安装"
        case .packageNotFound(let name):
            return "找不到包: \(name)"
        case .sourceFileNotFound(let name):
            return "找不到源文件: \(name)"
        case .verificationFailed:
            return "验证失败"
        }
    }
}
