//
//  HelperExecutionLogStore.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/12/23.
//

import Foundation

@MainActor
final class HelperExecutionLogStore: ObservableObject {
    static let shared = HelperExecutionLogStore()

    enum Status {
        case running, passed, warning, failed, cancelled, timedOut, skipped

        var title: String {
            switch self {
            case .running: return AppLocalized("执行中")
            case .passed: return AppLocalized("通过")
            case .warning: return AppLocalized("需留意")
            case .failed: return AppLocalized("失败")
            case .cancelled: return AppLocalized("已取消")
            case .timedOut: return AppLocalized("已超时")
            case .skipped: return AppLocalized("已跳过")
            }
        }
    }

    struct Entry: Identifiable {
        let id: UUID
        let date: Date
        let title: String
        let command: String
        var status: Status = .running
        var detail = ""
        var result: HelperOperationResult?

        var duration: TimeInterval? { result?.diagnostic?.duration }

        var exportText: String {
            var lines = ["[\(date.formatted(date: .omitted, time: .standard))] \(title) · \(status.title)"]
            if !command.isEmpty { lines.append("$ \(command)") }
            if let duration { lines.append(String(format: AppLocalized("耗时 %.2f 秒"), duration)) }
            if let code = result?.exitCode { lines.append(String(format: AppLocalized("退出码：%d"), code)) }
            if !detail.isEmpty { lines.append(detail) }
            if let diagnostic = result?.diagnostic {
                if !diagnostic.standardOutput.isEmpty { lines.append("stdout:\n" + diagnostic.standardOutput) }
                if !diagnostic.standardError.isEmpty { lines.append("stderr:\n" + diagnostic.standardError) }
                if diagnostic.outputTruncated { lines.append(AppLocalized("输出已截断：每个输出通道最多保留前 128 KiB。")) }
            } else if let result, !result.output.isEmpty {
                lines.append(result.output)
            }
            return lines.joined(separator: "\n")
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var discardedCount = 0
    private let maxEntries = 30

    private init() {}

    @discardableResult
    func begin(title: String, command: String = "") -> UUID {
        let entry = Entry(id: UUID(), date: Date(), title: title, command: command)
        entries.append(entry)
        while entries.count > maxEntries, let index = entries.firstIndex(where: { $0.status != .running }) {
            entries.remove(at: index)
            discardedCount += 1
        }
        return entry.id
    }

    func finish(_ id: UUID, status: Status, detail: String = "", result: HelperOperationResult? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].detail = detail
        entries[index].result = result
    }

    func clear() {
        entries.removeAll { $0.status != .running }
        discardedCount = 0
    }

    func exportText() -> String {
        let notice = discardedCount > 0
            ? String(format: AppLocalized("较早的 %d 条记录已移出本次会话。"), discardedCount) + "\n\n" : ""
        return notice + entries.map(\.exportText).joined(separator: "\n\n")
    }
}
