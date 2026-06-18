//
//  SignatureValidator.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit
import Security

class SignatureValidator {
    private static let hashBufferSize = 1024 * 1024

    static func sha256Hash(of fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB

        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hash(of fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        var hasher = Insecure.SHA1()
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

    static func md5Hash(of data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hash(of fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        var hasher = Insecure.MD5()
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

    static func segmentHash(
        fileHandle: FileHandle,
        offset: Int64,
        size: Int64,
        algorithm: String,
        expectedHash: String
    ) throws -> (hash: String, bytesRead: Int64) {
        let normalizedAlgorithm = algorithm.lowercased()

        switch normalizedAlgorithm {
        case "sha256", "sha-256", "type2":
            var hasher = SHA256()
            return try hashRange(fileHandle: fileHandle, offset: offset, size: size, hasher: &hasher)
        case "sha1", "sha-1":
            var hasher = Insecure.SHA1()
            return try hashRange(fileHandle: fileHandle, offset: offset, size: size, hasher: &hasher)
        case "md5", "type1":
            var hasher = Insecure.MD5()
            return try hashRange(fileHandle: fileHandle, offset: offset, size: size, hasher: &hasher)
        default:
            if expectedHash.count == 64 {
                var hasher = SHA256()
                return try hashRange(fileHandle: fileHandle, offset: offset, size: size, hasher: &hasher)
            }
            var hasher = Insecure.MD5()
            return try hashRange(fileHandle: fileHandle, offset: offset, size: size, hasher: &hasher)
        }
    }

    private static func hashRange<H: HashFunction>(
        fileHandle: FileHandle,
        offset: Int64,
        size: Int64,
        hasher: inout H
    ) throws -> (hash: String, bytesRead: Int64) {
        try fileHandle.seek(toOffset: UInt64(offset))

        var remaining = size
        var bytesRead: Int64 = 0

        while autoreleasepool(invoking: { () -> Bool in
            guard remaining > 0 else { return false }
            let readLength = Int(min(Int64(hashBufferSize), remaining))
            let data = fileHandle.readData(ofLength: readLength)
            if data.isEmpty { return false }
            hasher.update(data: data)
            let count = Int64(data.count)
            bytesRead += count
            remaining -= count
            return true
        }) {}

        let digest = hasher.finalize()
        return (digest.map { String(format: "%02x", $0) }.joined(), bytesRead)
    }

    static func validateFileHash(fileURL: URL, expectedHash: String, algorithm: String = "sha256") throws -> Bool {
        let computedHash: String

        switch algorithm.lowercased() {
        case "sha256":
            computedHash = try sha256Hash(of: fileURL)
        case "sha1":
            computedHash = try sha1Hash(of: fileURL)
        case "md5":
            computedHash = try md5Hash(of: fileURL)
        default:
            computedHash = try sha256Hash(of: fileURL)
        }

        return computedHash.lowercased() == expectedHash.lowercased()
    }

    static func validateWithSegments(fileURL: URL, validationInfo: ValidationInfo) throws -> Bool {
        try firstMismatchedSegment(fileURL: fileURL, validationInfo: validationInfo) == nil
    }

    static func firstMismatchedSegment(fileURL: URL, validationInfo: ValidationInfo) throws -> Int? {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        for segment in validationInfo.segments {
            let segmentIndex = segment.segmentNumber - 1
            let startOffset = Int64(segmentIndex) * validationInfo.segmentSize
            let isLastSegment = segment.segmentNumber == validationInfo.segmentCount
            let segmentSize = isLastSegment && validationInfo.lastSegmentSize > 0
                ? validationInfo.lastSegmentSize
                : validationInfo.segmentSize

            let result = try segmentHash(
                fileHandle: fileHandle,
                offset: startOffset,
                size: segmentSize,
                algorithm: validationInfo.algorithm,
                expectedHash: segment.hash
            )

            guard result.bytesRead == segmentSize else {
                return segment.segmentNumber
            }

            if result.hash.lowercased() != segment.hash.lowercased() {
                return segment.segmentNumber
            }
        }

        return nil
    }

    static func verifyRSASignature(data: Data, signature: Data, publicKeyPEM: String) -> Bool {
        guard let publicKey = createSecKey(from: publicKeyPEM) else {
            return false
        }

        var error: Unmanaged<CFError>?
        let result = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            &error
        )

        return result
    }

    private static func createSecKey(from pem: String) -> SecKey? {
        let cleanPEM = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard let keyData = Data(base64Encoded: cleanPEM) else {
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]

        return SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil)
    }

    static func verifyCodeSignature(at path: URL) -> Bool {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(path as CFURL, [], &staticCode)

        guard status == errSecSuccess, let code = staticCode else {
            return false
        }

        let validateStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)
        return validateStatus == errSecSuccess
    }

    static func validateCacheData(_ data: Data, expectedHash: String) -> Bool {
        let hash = sha256Hash(of: data)
        return hash.lowercased() == expectedHash.lowercased()
    }
}

extension NewDownloadUtils {

    func loadApplicationJsonFromESD(esdDirectory: URL) throws -> String {
        let jsonPath = esdDirectory.appendingPathComponent("Application.json")

        guard FileManager.default.fileExists(atPath: jsonPath.path) else {
            throw NetworkError.invalidData("Could not find 'Application.json' file inside ESD directory: \(esdDirectory.path)")
        }

        let content = try String(contentsOf: jsonPath, encoding: .utf8)

        guard !content.isEmpty else {
            throw NetworkError.invalidData("Application.json is empty in ESD directory")
        }

        return content
    }

    func loadAndParseApplicationJsonFromESD(esdDirectory: URL) throws -> ApplicationInfo {
        let jsonString = try loadApplicationJsonFromESD(esdDirectory: esdDirectory)
        return try ApplicationJSONParser.parse(jsonString: jsonString)
    }
}
