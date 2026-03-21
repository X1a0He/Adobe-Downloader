import Foundation

actor PDMProgressTracker {

    private var downloadedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var segmentsCompleted: Int = 0
    private var segmentsTotal: Int = 0

    private var startTime: Date = Date()
    private var lastReportTime: Date = .distantPast
    private var currentSpeed: Double = 0

    private let reportInterval: TimeInterval = 0.3

    typealias ProgressCallback = (Double, Int64, Int64, Double) -> Void
    private var callback: ProgressCallback?

    func configure(totalBytes: Int64, segmentsTotal: Int, callback: ProgressCallback?) {
        self.totalBytes = totalBytes
        self.segmentsTotal = segmentsTotal
        self.callback = callback
        self.downloadedBytes = 0
        self.segmentsCompleted = 0
        self.startTime = Date()
        self.lastReportTime = Date()
        self.currentSpeed = 0
    }

    func addDownloadedBytes(_ bytes: Int64) {
        downloadedBytes += bytes
        updateSpeedAndReport()
    }

    func setDownloadedBytes(_ bytes: Int64) {
        downloadedBytes = bytes
        updateSpeedAndReport()
    }

    func markSegmentComplete() {
        segmentsCompleted += 1
    }

    func getProgress() -> PDMProgress {
        PDMProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            speed: currentSpeed,
            segmentsCompleted: segmentsCompleted,
            segmentsTotal: segmentsTotal
        )
    }

    private func updateSpeedAndReport() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReportTime)

        guard elapsed >= reportInterval else { return }

        let totalElapsed = now.timeIntervalSince(startTime)
        if totalElapsed > 0 {
            currentSpeed = Double(downloadedBytes) / totalElapsed
        }

        lastReportTime = now

        let fraction = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
        callback?(fraction, downloadedBytes, totalBytes, currentSpeed)
    }

    func reset() {
        downloadedBytes = 0
        segmentsCompleted = 0
        currentSpeed = 0
        startTime = Date()
        lastReportTime = Date()
    }
}
