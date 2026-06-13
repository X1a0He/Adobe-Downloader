//
//  PDMValidationManager.swift
//  Adobe Downloader
//

import Foundation
import CryptoKit

final class PDMValidationManager {

    private let communicator: PDMHttpCommunicator

    init(communicator: PDMHttpCommunicator) {
        self.communicator = communicator
    }

    func fetchValidationInfo(
        from validationURL: String,
        headers: [(String, String)]
    ) -> ValidationInfo? {
        guard !validationURL.isEmpty else { return nil }

        let config = PDMHTTPRequestConfig(
            url: validationURL,
            method: "GET",
            headers: headers,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 60
        )

        let response = communicator.sendRequest(config)

        guard response.isSuccess, !response.data.isEmpty else {
            return nil
        }

        guard let xmlString = String(data: response.data, encoding: .utf8) else {
            return nil
        }

        return ValidationInfo.parse(from: xmlString)
    }

    func validateSegment(
        data: Data,
        expectedHash: String,
        algorithm: String
    ) -> Bool {
        guard !expectedHash.isEmpty else { return true }

        let computedHash: String

        let normalizedAlgorithm = algorithm.lowercased()

        switch normalizedAlgorithm {
        case "sha256", "sha-256", "type2":
            let digest = SHA256.hash(data: data)
            computedHash = digest.map { String(format: "%02x", $0) }.joined()
        case "sha1", "sha-1":
            let digest = Insecure.SHA1.hash(data: data)
            computedHash = digest.map { String(format: "%02x", $0) }.joined()
        case "md5", "type1":
            let digest = Insecure.MD5.hash(data: data)
            computedHash = digest.map { String(format: "%02x", $0) }.joined()
        default:
            if expectedHash.count == 64 {
                let digest = SHA256.hash(data: data)
                computedHash = digest.map { String(format: "%02x", $0) }.joined()
            } else {
                let digest = Insecure.MD5.hash(data: data)
                computedHash = digest.map { String(format: "%02x", $0) }.joined()
            }
        }

        return computedHash.lowercased() == expectedHash.lowercased()
    }

    func validateFile(
        at fileURL: URL,
        validationInfo: ValidationInfo,
        totalSize: Int64
    ) throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize == totalSize else {
            return false
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        for segment in validationInfo.segments {
            let segmentIndex = segment.segmentNumber - 1
            let segmentSize: Int64
            if segment.segmentNumber == validationInfo.segmentCount {
                segmentSize = validationInfo.lastSegmentSize > 0
                    ? validationInfo.lastSegmentSize
                    : (totalSize - Int64(segmentIndex) * validationInfo.segmentSize)
            } else {
                segmentSize = validationInfo.segmentSize
            }

            let offset = Int64(segmentIndex) * validationInfo.segmentSize
            try fileHandle.seek(toOffset: UInt64(offset))
            guard let segmentData = try fileHandle.read(upToCount: Int(segmentSize)) else {
                return false
            }

            if !validateSegment(
                data: segmentData,
                expectedHash: segment.hash,
                algorithm: validationInfo.algorithm
            ) {
                throw PDMDownloadError.segmentValidationFailed(segmentIndex)
            }
        }

        return true
    }

    func getRemoteFileSize(
        url: String,
        headers: [(String, String)]
    ) -> Int64 {
        let config = PDMHTTPRequestConfig(
            url: url,
            method: "HEAD",
            headers: headers,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 30
        )

        let response = communicator.sendRequest(config)

        if response.isSuccess {
            return response.contentLength
        }
        return 0
    }

    func getETag(
        url: String,
        headers: [(String, String)]
    ) -> String? {
        let config = PDMHTTPRequestConfig(
            url: url,
            method: "HEAD",
            headers: headers,
            useCookie: true,
            autoRedirect: true,
            validateSSL: true,
            timeoutSeconds: 30
        )

        let response = communicator.sendRequest(config)
        return response.etag
    }
}
