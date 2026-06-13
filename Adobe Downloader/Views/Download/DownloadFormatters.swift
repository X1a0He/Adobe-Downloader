import Foundation

enum DownloadFormatters {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    static func speed(_ bytesPerSecond: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func fileSize(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func remainingTime(total: Int64, downloaded: Int64, speed: Double) -> String {
        guard speed > 0 else { return "" }
        let remainingSeconds = Int(Double(total - downloaded) / speed)
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func shortenedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        guard components.count > 4 else { return path }
        return "/" + components.suffix(2).joined(separator: "/")
    }
}
