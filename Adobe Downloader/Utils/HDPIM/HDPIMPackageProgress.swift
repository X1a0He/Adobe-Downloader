import Foundation

struct HDPIMPackageProgress: Codable, Identifiable {
    enum Stage: String, Codable {
        case waiting, preparing, prepared, updatingFiles, installing, registering, awaitingCompletion
    }

    static let messagePrefix = "PACKAGE|"
    let id: Int
    let name: String
    let productCode: String
    let version: String
    var stage: Stage = .waiting
    var fraction: Double = 0
    var revision: Int = 0

    static func decode(_ message: String) -> Self? {
        guard message.hasPrefix(messagePrefix),
              let data = Data(base64Encoded: String(message.dropFirst(messagePrefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.id >= 0, value.revision >= 0, value.fraction.isFinite,
              (0...1).contains(value.fraction) else { return nil }
        return value
    }
}

/// 并行准备也按包发送有序快照；界面使用 revision 丢弃迟到更新。
final class HDPIMPackageProgressReporter {
    private let lock = NSLock()
    private var packages: [HDPIMPackageProgress]
    private let handler: ((String) -> Void)?

    init(packages: [HDPIMPackageProgress], handler: ((String) -> Void)?) {
        self.packages = packages
        self.handler = handler
        for package in packages { emit(package) }
    }

    func update(index: Int, stage: HDPIMPackageProgress.Stage, fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        var value = packages[index]
        let fraction = min(max(fraction, 0), 1)
        let next = value.stage == stage ? max(value.fraction, fraction) : fraction
        guard value.stage != stage || Int(next * 100) != Int(value.fraction * 100) else { return }
        value.stage = stage
        value.fraction = next
        value.revision += 1
        packages[index] = value
        emit(value)
    }

    private func emit(_ value: HDPIMPackageProgress) {
        guard let handler, let data = try? JSONEncoder().encode(value) else { return }
        handler(HDPIMPackageProgress.messagePrefix + data.base64EncodedString())
    }
}
