//
//  SignatureValidator.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit
import Security

class SignatureValidator {

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

    static func validateFileHash(fileURL: URL, expectedHash: String, algorithm: String = "sha256") throws -> Bool {
        let computedHash: String

        switch algorithm.lowercased() {
        case "sha256":
            computedHash = try sha256Hash(of: fileURL)
        case "sha1":
            computedHash = try sha1Hash(of: fileURL)
        case "md5":
            let data = try Data(contentsOf: fileURL)
            computedHash = md5Hash(of: data)
        default:
            computedHash = try sha256Hash(of: fileURL)
        }

        return computedHash.lowercased() == expectedHash.lowercased()
    }

    static func validateWithSegments(fileURL: URL, validationInfo: ValidationInfo) throws -> Bool {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }

        for segment in validationInfo.segments {
            let segmentIndex = segment.segmentNumber - 1
            let startOffset = Int64(segmentIndex) * validationInfo.segmentSize
            let isLastSegment = segment.segmentNumber == validationInfo.segmentCount
            let segmentSize = isLastSegment && validationInfo.lastSegmentSize > 0
                ? validationInfo.lastSegmentSize
                : validationInfo.segmentSize

            fileHandle.seek(toFileOffset: UInt64(startOffset))
            let segmentData = fileHandle.readData(ofLength: Int(segmentSize))

            guard segmentData.count == Int(segmentSize) else {
                return false
            }

            let hash = segmentHash(data: segmentData, algorithm: validationInfo.algorithm, expectedHash: segment.hash)
            if hash.lowercased() != segment.hash.lowercased() {
                return false
            }
        }

        return true
    }

    private static func segmentHash(data: Data, algorithm: String, expectedHash: String) -> String {
        switch algorithm.lowercased() {
        case "sha256", "sha-256", "type2":
            return sha256Hash(of: data)
        case "sha1", "sha-1":
            let digest = Insecure.SHA1.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        case "md5", "type1":
            return md5Hash(of: data)
        default:
            return expectedHash.count == 64 ? sha256Hash(of: data) : md5Hash(of: data)
        }
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
