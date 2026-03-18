//
//  PIMXParser.swift
//  Adobe Downloader
//

import Foundation

enum PIMXCommandDescriptor {
    case moveFile(source: String, target: String)
    case copyFile(source: String, target: String)
    case blindCopy(source: String, target: String)
    case createDirectory(path: String)
    case mergeDirectory(source: String, target: String)
    case deleteFile(target: String)
    case deleteDirectory(source: String)
    case createSymlink(source: String, target: String)

    case permission(path: String, mode: String)
    case owner(path: String, uid: String, gid: String)

    case runProgram(path: String, arguments: [String], successExitCodes: [Int32])
    case registerApplication(path: String)
    case setDisplayAttributes(target: String, icon: String)
    case touch(path: String)
    case folderIcon(folderPath: String, iconPath: String)
}

struct PIMXAssetReference {
    let source: String
    let target: String
    let isDirectoryLike: Bool
}

private enum AssetCommandStyle {
    case move
    case copy
    case blindCopy
}

struct PIMXPackageInfo {
    let packageName: String
    let commands: [PIMXCommandDescriptor]
    let assetReferences: [PIMXAssetReference]
}

class PIMXParser {

    private let propertyTable: HDPIMPropertyTable

    init(propertyTable: HDPIMPropertyTable) {
        self.propertyTable = propertyTable
    }

    func parse(pimxURL: URL, extractDir: URL) throws -> PIMXPackageInfo {
        let xmlData = try Self.loadXMLData(from: pimxURL)
        return try parse(pimxURL: pimxURL, xmlData: xmlData, extractDir: extractDir)
    }

    func parse(pimxURL: URL, xmlData: Data, extractDir: URL) throws -> PIMXPackageInfo {
        let xmlDoc = try XMLDocument(data: xmlData, options: [])

        guard let root = xmlDoc.rootElement() else {
            throw PIMXError.invalidXML("PIMX 根节点不存在: \(pimxURL.path)")
        }

        let packageName = try root.nodes(forXPath: "PackageName").first?.stringValue ?? ""
        guard !packageName.isEmpty else {
            throw PIMXError.invalidXML("PIMX 缺少 PackageName")
        }

        let assetsResult = try parseAssets(root: root)
        var commands = assetsResult.commands

        commands += try parseCommands(root: root)

        return PIMXPackageInfo(
            packageName: packageName,
            commands: commands,
            assetReferences: assetsResult.assetReferences
        )
    }

    private func parseAssets(root: XMLElement) throws -> (commands: [PIMXCommandDescriptor], assetReferences: [PIMXAssetReference]) {
        var commands: [PIMXCommandDescriptor] = []
        var assetReferences: [PIMXAssetReference] = []

        let assets = try root.nodes(forXPath: "Assets/Asset")
        for node in assets {
            guard let element = node as? XMLElement else { continue }
            let source = element.attribute(forName: "source")?.stringValue ?? ""
            let target = element.attribute(forName: "target")?.stringValue ?? ""
            let type = element.attribute(forName: "type")?.stringValue ?? "file"

            guard !source.isEmpty, !target.isEmpty else { continue }

            let expandedSource = propertyTable.expandPath(source)
            let expandedTarget = propertyTable.expandPath(target)

            let isDirectoryLike = isDirectoryAsset(
                element: element,
                type: type,
                rawSource: source,
                expandedSource: expandedSource
            )

            switch type.lowercased() {
            case "directory":
                appendAssetCommands(
                    source: expandedSource,
                    target: expandedTarget,
                    isDirectoryLike: true,
                    style: .move,
                    to: &commands
                )
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: expandedTarget,
                    isDirectoryLike: true
                ))
            case "symlink":
                let linkTarget = element.attribute(forName: "targetLinkPath")?.stringValue ?? source
                commands.append(.createSymlink(source: propertyTable.expandPath(linkTarget), target: expandedTarget))
            default:
                appendAssetCommands(
                    source: expandedSource,
                    target: expandedTarget,
                    isDirectoryLike: isDirectoryLike,
                    style: .move,
                    to: &commands
                )
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: expandedTarget,
                    isDirectoryLike: isDirectoryLike
                ))
            }
        }

        let blindCopies = try root.nodes(forXPath: "Assets/BlindCopy")
        for node in blindCopies {
            guard let element = node as? XMLElement else { continue }
            let source = element.attribute(forName: "source")?.stringValue ?? ""
            let target = element.attribute(forName: "target")?.stringValue ?? ""

            guard !source.isEmpty, !target.isEmpty else { continue }

            let expandedSource = propertyTable.expandPath(source)
            let expandedTarget = propertyTable.expandPath(target)
            let isDirectoryLike = expandedSource.hasSuffix("/") || isExistingDirectory(expandedSource)

            appendAssetCommands(
                source: expandedSource,
                target: expandedTarget,
                isDirectoryLike: isDirectoryLike,
                style: .blindCopy,
                to: &commands
            )
            assetReferences.append(PIMXAssetReference(
                source: expandedSource,
                target: expandedTarget,
                isDirectoryLike: isDirectoryLike
            ))
        }

        return (commands, assetReferences)
    }

    private func parseCommands(root: XMLElement) throws -> [PIMXCommandDescriptor] {
        var commands: [PIMXCommandDescriptor] = []

        guard let commandsNode = try root.nodes(forXPath: "Commands").first as? XMLElement else {
            return commands
        }

        for child in commandsNode.children ?? [] {
            guard let element = child as? XMLElement, let tagName = element.name else { continue }

            switch tagName {
            case "Permission":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                let mode = (try element.nodes(forXPath: "PermissionValue").first?.stringValue)
                    ?? element.attribute(forName: "mode")?.stringValue ?? ""
                if !path.isEmpty && !mode.isEmpty {
                    commands.append(.permission(
                        path: propertyTable.expandPath(path),
                        mode: mode
                    ))
                }

            case "Owner":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                let uid = (try element.nodes(forXPath: "User").first?.stringValue)
                    ?? element.attribute(forName: "uid")?.stringValue ?? "0"
                let gid = (try element.nodes(forXPath: "Group").first?.stringValue)
                    ?? element.attribute(forName: "gid")?.stringValue ?? "0"
                if !path.isEmpty {
                    commands.append(.owner(
                        path: propertyTable.expandPath(path),
                        uid: uid, gid: gid
                    ))
                }

            case "RunProgram":
                let programPath = (try element.nodes(forXPath: "Path").first?.stringValue) ?? ""
                var arguments: [String] = []
                let argNodes = try element.nodes(forXPath: "Arguments/Argument")
                for argNode in argNodes {
                    if let arg = argNode.stringValue {
                        arguments.append(propertyTable.expandPath(arg))
                    }
                }
                var exitCodes: [Int32] = [0]
                let exitCodeNodes = try element.nodes(forXPath: "SuccessExitCodes/ExitCode")
                if !exitCodeNodes.isEmpty {
                    exitCodes = exitCodeNodes.compactMap { Int32($0.stringValue ?? "") }
                }
                if !programPath.isEmpty {
                    commands.append(.runProgram(
                        path: propertyTable.expandPath(programPath),
                        arguments: arguments,
                        successExitCodes: exitCodes
                    ))
                }

            case "UninstallCommand":
                let programPath = (try element.nodes(forXPath: "Path").first?.stringValue) ?? ""
                var arguments: [String] = []
                let argNodes = try element.nodes(forXPath: "Arguments/Argument")
                for argNode in argNodes {
                    if let arg = argNode.stringValue {
                        arguments.append(propertyTable.expandPath(arg))
                    }
                }
                if !programPath.isEmpty {
                    commands.append(.runProgram(
                        path: propertyTable.expandPath(programPath),
                        arguments: arguments,
                        successExitCodes: [0]
                    ))
                }

            case "RegisterApplication":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                if !path.isEmpty {
                    commands.append(.registerApplication(path: propertyTable.expandPath(path)))
                }

            case "SetDisplayAttributes":
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                let icon = (try element.nodes(forXPath: "Icon").first?.stringValue)
                    ?? element.attribute(forName: "icon")?.stringValue ?? ""
                if !target.isEmpty && !icon.isEmpty {
                    commands.append(.setDisplayAttributes(
                        target: propertyTable.expandPath(target),
                        icon: propertyTable.expandPath(icon)
                    ))
                }

            case "DeleteFile":
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                if !target.isEmpty {
                    commands.append(.deleteFile(target: propertyTable.expandPath(target)))
                }

            case "DeleteDirectory":
                let source = (try element.nodes(forXPath: "Source").first?.stringValue)
                    ?? element.attribute(forName: "source")?.stringValue ?? ""
                if !source.isEmpty {
                    commands.append(.deleteDirectory(source: propertyTable.expandPath(source)))
                }

            case "Touch":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                if !path.isEmpty {
                    commands.append(.touch(path: propertyTable.expandPath(path)))
                }

            case "FolderIcon":
                let folderPath = (try element.nodes(forXPath: "FolderPath").first?.stringValue)
                    ?? element.attribute(forName: "FolderPath")?.stringValue ?? ""
                let iconPath = (try element.nodes(forXPath: "IconPath").first?.stringValue)
                    ?? element.attribute(forName: "IconPath")?.stringValue ?? ""
                if !folderPath.isEmpty && !iconPath.isEmpty {
                    commands.append(.folderIcon(
                        folderPath: propertyTable.expandPath(folderPath),
                        iconPath: propertyTable.expandPath(iconPath)
                    ))
                }

            case "Shortcut":
                if let source = element.attribute(forName: "source")?.stringValue,
                   let target = element.attribute(forName: "target")?.stringValue {
                    commands.append(.createSymlink(
                        source: propertyTable.expandPath(source),
                        target: propertyTable.expandPath(target)
                    ))
                }

            default:
                break
            }
        }

        return commands
    }

    private func isDirectoryAsset(
        element: XMLElement,
        type: String,
        rawSource: String,
        expandedSource: String
    ) -> Bool {
        if type.lowercased() == "directory" {
            return true
        }

        if boolAttribute(element.attribute(forName: "recursive")?.stringValue) {
            return true
        }

        if rawSource.hasSuffix("/") {
            return true
        }

        return isExistingDirectory(expandedSource)
    }

    private func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func appendAssetCommands(
        source: String,
        target: String,
        isDirectoryLike: Bool,
        style: AssetCommandStyle,
        to commands: inout [PIMXCommandDescriptor]
    ) {
        guard isDirectoryLike else {
            let fileTarget = resolvedFileTarget(source: source, target: target)
            commands.append(commandDescriptor(for: style, source: source, target: fileTarget))
            return
        }

        let sourceURL = URL(fileURLWithPath: source, isDirectory: true)
        let normalizedTarget = target.hasSuffix("/") ? String(target.dropLast()) : target
        let targetRootURL = URL(fileURLWithPath: normalizedTarget, isDirectory: true)

        var createdDirectories = Set<String>()
        func appendCreateDirectory(_ path: String) {
            guard !path.isEmpty, createdDirectories.insert(path).inserted else { return }
            commands.append(.createDirectory(path: path))
        }

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            appendCreateDirectory(targetRootURL.path)
        }

        guard let enumerator = FileManager.default.enumerator(atPath: sourceURL.path) else {
            return
        }

        for case let relativePath as String in enumerator {
            guard !relativePath.isEmpty else { continue }

            let itemURL = sourceURL.appendingPathComponent(relativePath)
            let targetURL = targetRootURL.appendingPathComponent(relativePath)
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = resourceValues?.isSymbolicLink ?? false
            let isDirectory = resourceValues?.isDirectory ?? false

            if isSymbolicLink {
                appendCreateDirectory(targetURL.deletingLastPathComponent().path)
                if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path) {
                    commands.append(.createSymlink(source: linkTarget, target: targetURL.path))
                }
                continue
            }

            if isDirectory {
                appendCreateDirectory(targetURL.path)
                continue
            }

            appendCreateDirectory(targetURL.deletingLastPathComponent().path)
            commands.append(commandDescriptor(for: style, source: itemURL.path, target: targetURL.path))
        }
    }

    private func commandDescriptor(
        for style: AssetCommandStyle,
        source: String,
        target: String
    ) -> PIMXCommandDescriptor {
        switch style {
        case .move:
            return .moveFile(source: source, target: target)
        case .copy:
            return .copyFile(source: source, target: target)
        case .blindCopy:
            return .blindCopy(source: source, target: target)
        }
    }

    private func resolvedFileTarget(source: String, target: String) -> String {
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        let targetURL = URL(fileURLWithPath: target)

        if target.hasSuffix("/") {
            return targetURL.appendingPathComponent(sourceName).path
        }

        if targetURL.pathExtension.isEmpty {
            return targetURL.appendingPathComponent(sourceName).path
        }

        return target
    }

    private func boolAttribute(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "true" || normalized == "1" || normalized == "yes"
    }

    static func loadXMLData(from pimxURL: URL, writeBackIfNeeded: Bool = true) throws -> Data {
        var xmlData = try Data(contentsOf: pimxURL)
        let firstChunk = String(data: xmlData.prefix(200), encoding: .utf8) ?? ""

        if !firstChunk.contains("<") {
            do {
                let decompressed = try HDPIMNativeLZMA2.decompress(data: xmlData)
                guard !decompressed.isEmpty else {
                    throw PIMXError.invalidXML("PIMX 解压结果为空: \(pimxURL.path)")
                }
                xmlData = decompressed
                if writeBackIfNeeded {
                    try xmlData.write(to: pimxURL)
                }
            } catch let error as PIMXError {
                throw error
            } catch {
                throw PIMXError.invalidXML("PIMX 解压失败: \(error.localizedDescription)")
            }
        }

        let normalizedChunk = String(data: xmlData.prefix(200), encoding: .utf8) ?? ""
        if !normalizedChunk.contains("<") {
            throw PIMXError.invalidXML("PIMX 不是有效的 XML: \(pimxURL.path)")
        }

        return xmlData
    }
}

enum PIMXError: Error, LocalizedError {
    case invalidXML(String)
    case pimxNotFound(String)
    case packageNameMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidXML(let msg): return "PIMX 解析错误: \(msg)"
        case .pimxNotFound(let path): return "PIMX 文件不存在: \(path)"
        case .packageNameMismatch(let expected, let actual):
            return "包名不匹配: 期望 \(expected), PIMX 中为 \(actual)"
        }
    }
}
