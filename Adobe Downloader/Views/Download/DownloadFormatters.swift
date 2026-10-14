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
        byteFormatter.string(fromByteCount: bytesPerSecond.isFinite && bytesPerSecond > 0 && bytesPerSecond < Double(Int64.max) ? Int64(bytesPerSecond) : 0) + "/s"
    }

    static func fileSize(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func remainingTime(total: Int64, downloaded: Int64, speed: Double) -> String {
        remainingTime(seconds: DownloadTimeEstimate.seconds(remaining: max(total - downloaded, 0), speed: speed))
    }

    static func remainingTime(seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "" }
        let rounded = seconds.rounded(.up)
        guard rounded < Double(Int.max) else { return "" }
        let remaining = Int(rounded)
        if remaining >= 3600 {
            return String(format: "%d:%02d:%02d", remaining / 3600, remaining / 60 % 60, remaining % 60)
        }
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    static func shortenedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        guard components.count > 4 else { return path }
        return "/" + components.suffix(2).joined(separator: "/")
    }
}
