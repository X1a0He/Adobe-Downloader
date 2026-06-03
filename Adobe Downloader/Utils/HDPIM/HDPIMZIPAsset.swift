//
//  HDPIMZIPAsset.swift
//  Adobe Downloader
//
//  Based on IDA analysis of ZIPAsset::extract
//

import Foundation

class HDPIMZIPAsset {
    private let sourcePath: String
    private let targetPath: String
    private var isExtracted: Bool = false

    init(sourcePath: String, targetPath: String) {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
    }

    func extract() -> Bool {
        guard !isExtracted else { return true }

        do {
            try FileManager.default.createDirectory(
                atPath: targetPath,
                withIntermediateDirectories: true
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", sourcePath, "-d", targetPath]

            try process.run()
            process.waitUntilExit()

            isExtracted = process.terminationStatus == 0
            return isExtracted
        } catch {
            return false
        }
    }

    func extractWithRetry(maxRetries: Int = 3) -> Bool {
        for attempt in 1...maxRetries {
            if extract() {
                return true
            }
            if attempt < maxRetries {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return false
    }
}
