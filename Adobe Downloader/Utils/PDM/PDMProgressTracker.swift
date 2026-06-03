//
//  PDMProgressTracker.swift
//  Adobe Downloader
//

import Foundation

actor PDMProgressTracker {

    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var initialBytes: Int64 = 0

    private var lastReportTime: Date = .distantPast
    private var lastSpeedSampleTime: Date = .distantPast
    private var lastSpeedSampleBytes: Int64 = 0
    private var currentSpeed: Double = 0

    private let reportInterval = NetworkConstants.progressUpdateInterval

    typealias ProgressCallback = (Int64, Int64, Double) -> Void
    private var callback: ProgressCallback?

    func configure(totalBytes: Int64, callback: ProgressCallback?, initialBytes: Int64 = 0) {
        self.totalBytes = totalBytes
        self.callback = callback
        self.downloadedBytes = initialBytes
        self.initialBytes = initialBytes
        let now = Date()
        self.lastReportTime = now
        self.lastSpeedSampleTime = now
        self.lastSpeedSampleBytes = initialBytes
        self.currentSpeed = 0
    }

    func addDownloadedBytes(_ bytes: Int64) {
        downloadedBytes += bytes
        reportIfNeeded()
    }

    var currentDownloadedBytes: Int64 {
        downloadedBytes
    }

    var currentTotalBytes: Int64 {
        totalBytes
    }

    private func reportIfNeeded() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReportTime)
        guard elapsed >= reportInterval else { return }

        let speedElapsed = now.timeIntervalSince(lastSpeedSampleTime)
        let bytesDiff = downloadedBytes - lastSpeedSampleBytes
        if speedElapsed > 0, bytesDiff >= 0 {
            currentSpeed = Double(bytesDiff) / speedElapsed
        }

        lastReportTime = now
        lastSpeedSampleTime = now
        lastSpeedSampleBytes = downloadedBytes
        callback?(downloadedBytes, totalBytes, currentSpeed)
    }

    func forceReport() {
        callback?(downloadedBytes, totalBytes, currentSpeed)
    }

    func reset() {
        downloadedBytes = 0
        initialBytes = 0
        currentSpeed = 0
        let now = Date()
        lastReportTime = now
        lastSpeedSampleTime = now
        lastSpeedSampleBytes = 0
    }
}
