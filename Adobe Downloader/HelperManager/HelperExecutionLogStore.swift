//
//  HelperExecutionLogStore.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/12/23.
//

import Foundation

final class HelperExecutionLogStore: ObservableObject {
    static let shared = HelperExecutionLogStore()

    enum Kind: String {
        case command
        case output

        var label: String {
            switch self {
            case .command:
                return "CMD"
            case .output:
                return "OUT"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let kind: Kind
        let command: String
        let result: String
        let isError: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 300
    private let maxCommandLength = 600
    private let maxResultLength = 6_000

    private init() {}

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    func append(kind: Kind, command: String, result: String, isError: Bool? = nil) {
        let normalizedCommand = truncate(command, maxLength: maxCommandLength)
        let normalizedResult = truncate(result, maxLength: maxResultLength)
        let computedIsError = isError ?? normalizedResult.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("error:")

        let entry = Entry(
            id: UUID(),
            date: Date(),
            kind: kind,
            command: normalizedCommand,
            result: normalizedResult,
            isError: computedIsError
        )

        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func exportText() -> String {
        let formatter = HelperExecutionLogStore.makeDateFormatter()
        return entries.map { entry in
            let time = formatter.string(from: entry.date)
            let header = "[\(time)] \(entry.kind.label) $ \(entry.command)"
            let body = entry.result.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? header : "\(header)\n\(body)"
        }.joined(separator: "\n\n")
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let suffix = "\n…(已截断，最多 \(maxLength) 字符)"
        let allowed = max(0, maxLength - suffix.count)
        return String(text.prefix(allowed)) + suffix
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
}

