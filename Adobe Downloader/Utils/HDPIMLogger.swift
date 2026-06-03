import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var prefix: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LogCategory: String {
    case network = "Network"
    case download = "Download"
    case install = "Install"
    case extraction = "Extraction"
    case validation = "Validation"
    case system = "System"
    case general = "General"
}

class HDPIMLogger {
    static let shared = HDPIMLogger()

    private var currentLevel: LogLevel = .info
    private let dateFormatter: DateFormatter
    private let logQueue = DispatchQueue(label: "com.hdpim.logger", qos: .utility)
    private var logFileURL: URL?

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        setupLogFile()
    }

    func setLevel(_ level: LogLevel) {
        currentLevel = level
    }

    private func setupLogFile() {
        guard let logsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let logDir = logsDir.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let fileName = "hdpim_\(dateFormatter.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")).log"
        logFileURL = logDir.appendingPathComponent(fileName)

        cleanOldLogs(in: logDir)
    }

    private func cleanOldLogs(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let sortedFiles = files.filter { $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        if sortedFiles.count > 10 {
            sortedFiles.dropFirst(10).forEach { try? FileManager.default.removeItem(at: $0.0) }
        }
    }

    private func log(_ level: LogLevel, _ message: String, category: LogCategory, file: String, function: String, line: Int) {
        guard level >= currentLevel else { return }

        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "\(timestamp) \(level.prefix) [\(category.rawValue)] [\(fileName):\(line)] \(function) - \(message)"

        logQueue.async { [weak self] in
            print(logMessage)
            self?.writeToFile(logMessage)
        }
    }

    private func writeToFile(_ message: String) {
        guard let url = logFileURL else { return }
        let data = (message + "\n").data(using: .utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data ?? Data())
                handle.closeFile()
            }
        } else {
            try? data?.write(to: url)
        }
    }

    func debug(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, message, category: category, file: file, function: function, line: line)
    }

    func info(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, message, category: category, file: file, function: function, line: line)
    }

    func warning(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, message, category: category, file: file, function: function, line: line)
    }

    func error(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, message, category: category, file: file, function: function, line: line)
    }
}
