import Foundation

struct HDPIMFileChange: Codable {
    enum Kind: String, Codable { case contents, metadata }
    let path: String
    let kind: Kind

    static func from(_ descriptors: [PIMXCommandDescriptor]) throws -> [HDPIMFileChange] {
        var changes: [HDPIMFileChange] = []
        for descriptor in descriptors {
            switch descriptor {
            case .moveFile(_, let target, _), .copyFile(_, let target, _), .blindCopy(_, let target, _),
                 .createSymlink(_, let target, _), .deleteFile(let target, _):
                changes.append(.init(path: target, kind: .contents))
            case .mergeDirectory(let source, let target, _):
                changes.append(.init(path: target, kind: .metadata))
                let sourceRoot = URL(fileURLWithPath: source).standardizedFileURL
                guard let items = FileManager.default.enumerator(at: sourceRoot,
                                                                 includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                    throw HDPIMMaterialError.invalid("无法预检目录：\(source)")
                }
                for case let item as URL in items {
                    let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let relative = String(item.path.dropFirst(sourceRoot.path.count + 1))
                    let destination = URL(fileURLWithPath: target).appendingPathComponent(relative).path
                    changes.append(.init(path: destination, kind: values.isDirectory == true && values.isSymbolicLink != true ? .metadata : .contents))
                }
            case .createDirectory(let path, _), .permission(let path, _), .owner(let path, _, _),
                 .registerApplication(let path), .touch(let path):
                changes.append(.init(path: path, kind: .metadata))
            case .deleteDirectory(let path, let recursive, _):
                changes.append(.init(path: path, kind: recursive ? .contents : .metadata))
            case .setDisplayAttributes(let target, _), .folderIcon(let target, _):
                changes.append(.init(path: target, kind: .metadata))
                changes.append(.init(path: URL(fileURLWithPath: target).appendingPathComponent("Icon\r").path, kind: .contents))
            case .unlockPath(let path, _):
                changes.append(.init(path: path, kind: .metadata))
            case .localizeFile(let source, let target):
                changes.append(contentsOf: [.init(path: source, kind: .contents), .init(path: target, kind: .contents)])
            case .macAlias(_, let path, _):
                changes.append(.init(path: path, kind: .contents))
            case .runProgram(let execution, _, _):
                if let execution { try validate(execution.path) }
            }
        }
        for change in changes { try validate(change.path) }
        return changes
    }

    static func from(_ commands: [DeltaCommand]) throws -> [HDPIMFileChange] {
        var changes: [HDPIMFileChange] = []
        for command in commands {
            switch command.type {
            case .exists:
                break
            case .patchFile(_, let target), .copyFile(_, let target), .moveFile(_, let target),
                 .createSymlink(_, let target), .deletePath(let target):
                changes.append(.init(path: target, kind: .contents))
            case .createDirectory(let path), .updatePermission(let path, _):
                changes.append(.init(path: path, kind: .metadata))
            case .renameLocalized(let destination, let localeMap):
                changes.append(.init(path: destination, kind: .contents))
                let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
                for name in localeMap.values {
                    guard HDPIMPackageMaterial.isLeafName(name) else {
                        throw HDPIMMaterialError.invalid("非法本地化目录名：\(name)")
                    }
                    changes.append(.init(path: parent.appendingPathComponent(name).path, kind: .contents))
                }
            }
        }
        for change in changes { try validate(change.path) }
        return changes
    }

    static func validate(_ path: String) throws {
        // 此处消费已解析路径，也包括从归档枚举出的字面文件名。
        guard path.hasPrefix("/"), !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path != "/" else {
            throw HDPIMMaterialError.invalid("未正确解析的安装路径：\(path)")
        }
    }
}
