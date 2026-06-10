//
//  PIMXParser.swift
//  Adobe Downloader
//

import Foundation

enum PIMXCommandDescriptor {
    case moveFile(source: String, target: String, pimxTarget: String)
    case copyFile(source: String, target: String, pimxTarget: String)
    case blindCopy(source: String, target: String, pimxTarget: String)
    case createDirectory(path: String, pimxPath: String)
    case mergeDirectory(source: String, target: String, pimxTarget: String)
    case deleteFile(target: String)
    case deleteDirectory(source: String, isRecursiveDelete: Bool, isUserPreferences: Bool)
    case createSymlink(source: String, target: String, pimxTarget: String)

    case permission(path: String, mode: String)
    case owner(path: String, uid: String, gid: String)

    case runProgram(
        execution: PIMXProgramInvocation?,
        repair: PIMXProgramInvocation?,
        uninstall: PIMXProgramInvocation?
    )
    case registerApplication(path: String)
    case setDisplayAttributes(target: String, icon: String)
    case touch(path: String)
    case folderIcon(folderPath: String, iconPath: String)
}

struct PIMXProgramInvocation {
    let path: String
    let arguments: [String]
    let successExitCodes: [Int32]
    let hasExplicitSuccessExitCodes: Bool
    let pimxPath: String
    let pimxArguments: [String]
    let runInUserMode: Bool
}

struct PIMXAssetReference {
    let source: String
    let target: String
    let sourceTemplate: String
    let targetTemplate: String
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

    func parseUninstallCommands(pimxURL: URL) throws -> [PIMXCommandDescriptor] {
        let xmlData = try Self.loadXMLData(from: pimxURL)
        let xmlDoc = try XMLDocument(data: xmlData, options: [])

        guard let root = xmlDoc.rootElement() else {
            throw PIMXError.invalidXML("PIMX 根节点不存在: \(pimxURL.path)")
        }

        return try parseCommands(root: root).compactMap(uninstallCommand)
    }

    private func uninstallCommand(from descriptor: PIMXCommandDescriptor) -> PIMXCommandDescriptor? {
        switch descriptor {
        case .runProgram(_, _, let uninstall):
            if let uninstall {
                return .runProgram(execution: uninstall, repair: nil, uninstall: nil)
            }
            return nil
        default:
            return descriptor
        }
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
            if boolAttribute(element.attribute(forName: "ignoreAsset")?.stringValue) {
                continue
            }

            let expandedSource = propertyTable.expandPath(source)
            let expandedTarget = propertyTable.expandPath(target)
            let normalizedTargetTemplate = normalizePIMXPath(target, isDirectoryLike: type.lowercased() == "directory")

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
                    sourceTemplate: source,
                    targetTemplate: normalizedTargetTemplate,
                    isDirectoryLike: true,
                    style: .move,
                    to: &commands
                )
                let appTarget = wrappedDirectoryRootTarget(source: expandedSource, target: expandedTarget)
                let appTargetTemplate = wrappedDirectoryRootTarget(source: source, target: target)
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: appTarget ?? expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: normalizePIMXPath(appTargetTemplate ?? target, isDirectoryLike: true),
                    isDirectoryLike: true
                ))
            case "symlink":
                let linkTarget = element.attribute(forName: "targetLinkPath")?.stringValue ?? source
                commands.append(
                    .createSymlink(
                        source: propertyTable.expandPath(linkTarget),
                        target: expandedTarget,
                        pimxTarget: normalizePIMXPath(target, isDirectoryLike: false)
                    )
                )
            default:
                let normalizedPimxTarget = isDirectoryLike
                    ? normalizePIMXPath(target, isDirectoryLike: true)
                    : resolvedFileTarget(source: source, target: target)
                appendAssetCommands(
                    source: expandedSource,
                    target: expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: target,
                    isDirectoryLike: isDirectoryLike,
                    style: .move,
                    to: &commands
                )
                let appTarget = wrappedDirectoryRootTarget(source: expandedSource, target: expandedTarget)
                let appTargetTemplate = wrappedDirectoryRootTarget(source: source, target: target)
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: isDirectoryLike
                        ? normalizePIMXPath(appTarget ?? expandedTarget, isDirectoryLike: true)
                        : resolvedFileTarget(source: expandedSource, target: expandedTarget),
                    sourceTemplate: source,
                    targetTemplate: normalizePIMXPath(appTargetTemplate ?? normalizedPimxTarget, isDirectoryLike: isDirectoryLike),
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
            if boolAttribute(element.attribute(forName: "ignoreAsset")?.stringValue) {
                continue
            }

            let expandedSource = propertyTable.expandPath(source)
            let expandedTarget = propertyTable.expandPath(target)
            let isDirectoryLike = expandedSource.hasSuffix("/") || isExistingDirectory(expandedSource)
            let normalizedPimxTarget = isDirectoryLike
                ? normalizePIMXPath(target, isDirectoryLike: true)
                : resolvedFileTarget(source: source, target: target)

            appendAssetCommands(
                source: expandedSource,
                target: expandedTarget,
                sourceTemplate: source,
                targetTemplate: target,
                isDirectoryLike: isDirectoryLike,
                style: .blindCopy,
                to: &commands
            )
            let appTarget = wrappedDirectoryRootTarget(source: expandedSource, target: expandedTarget)
            let appTargetTemplate = wrappedDirectoryRootTarget(source: source, target: target)
            assetReferences.append(PIMXAssetReference(
                source: expandedSource,
                target: isDirectoryLike ? (appTarget ?? expandedTarget) : resolvedFileTarget(source: expandedSource, target: expandedTarget),
                sourceTemplate: source,
                targetTemplate: normalizePIMXPath(appTargetTemplate ?? normalizedPimxTarget, isDirectoryLike: isDirectoryLike),
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
                let installElement = (element.elements(forName: "InstallCommand").first)
                let uninstallElement = (element.elements(forName: "UninstallCommand").first)
                if installElement != nil || uninstallElement != nil {
                    commands.append(
                        .runProgram(
                            execution: try installElement.flatMap(parseProgramInvocation),
                            repair: try installElement.flatMap(parseProgramInvocation),
                            uninstall: try uninstallElement.flatMap(parseProgramInvocation)
                        )
                    )
                    continue
                }

                if let directInvocation = try parseProgramInvocation(from: element) {
                    commands.append(.runProgram(execution: directInvocation, repair: nil, uninstall: nil))
                }

            case "UninstallCommand":
                if let uninstallInvocation = try parseProgramInvocation(from: element) {
                    commands.append(.runProgram(execution: nil, repair: nil, uninstall: uninstallInvocation))
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
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                let path = source.isEmpty ? target : source
                if !path.isEmpty {
                    let isRecursiveDelete = boolAttribute(element.attribute(forName: "isRecursiveDelete")?.stringValue)
                    let isUserPreferences = boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue)
                    commands.append(.deleteDirectory(
                        source: propertyTable.expandPath(path),
                        isRecursiveDelete: isRecursiveDelete,
                        isUserPreferences: isUserPreferences
                    ))
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
                        target: propertyTable.expandPath(target),
                        pimxTarget: normalizePIMXPath(target, isDirectoryLike: false)
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
        sourceTemplate: String,
        targetTemplate: String,
        isDirectoryLike: Bool,
        style: AssetCommandStyle,
        to commands: inout [PIMXCommandDescriptor]
    ) {
        guard isDirectoryLike else {
            let fileTarget = resolvedFileTarget(source: source, target: target)
            let pimxTarget = normalizePIMXPath(
                resolvedFileTarget(source: sourceTemplate, target: targetTemplate),
                isDirectoryLike: false
            )
            commands.append(
                commandDescriptor(
                    for: style,
                    source: source,
                    target: fileTarget,
                    pimxTarget: pimxTarget
                )
            )
            return
        }

        if let appTarget = wrappedDirectoryRootTarget(source: source, target: target),
           let appPimxTarget = wrappedDirectoryRootTarget(source: sourceTemplate, target: targetTemplate) {
            commands.append(
                wrappedDirectoryCommandDescriptor(
                    for: style,
                    source: source,
                    target: appTarget,
                    pimxTarget: normalizePIMXPath(appPimxTarget, isDirectoryLike: true)
                )
            )
            return
        }

        let sourceURL = URL(fileURLWithPath: source, isDirectory: true)
        let normalizedTarget = target.hasSuffix("/") ? String(target.dropLast()) : target
        let targetRootURL = URL(fileURLWithPath: normalizedTarget, isDirectory: true)
        let normalizedTemplateTarget = normalizePIMXPath(targetTemplate, isDirectoryLike: true)

        var createdDirectories = Set<String>()
        func appendCreateDirectory(_ path: String, pimxPath: String) {
            guard !path.isEmpty, createdDirectories.insert(path).inserted else { return }
            commands.append(.createDirectory(path: path, pimxPath: normalizePIMXPath(pimxPath, isDirectoryLike: true)))
        }

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            appendCreateDirectory(targetRootURL.path, pimxPath: normalizedTemplateTarget)
        }

        guard let enumerator = FileManager.default.enumerator(atPath: sourceURL.path) else {
            return
        }

        for case let relativePath as String in enumerator {
            guard !relativePath.isEmpty else { continue }

            let itemURL = sourceURL.appendingPathComponent(relativePath)
            let targetURL = targetRootURL.appendingPathComponent(relativePath)
            let pimxTargetPath = appendPIMXPathComponent(normalizedTemplateTarget, relativePath)
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = resourceValues?.isSymbolicLink ?? false
            let isDirectory = resourceValues?.isDirectory ?? false

            if isSymbolicLink {
                appendCreateDirectory(
                    targetURL.deletingLastPathComponent().path,
                    pimxPath: deleteLastPIMXPathComponent(pimxTargetPath)
                )
                if let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path) {
                    commands.append(
                        .createSymlink(
                            source: linkTarget,
                            target: targetURL.path,
                            pimxTarget: normalizePIMXPath(pimxTargetPath, isDirectoryLike: false)
                        )
                    )
                }
                continue
            }

            if isDirectory {
                appendCreateDirectory(targetURL.path, pimxPath: pimxTargetPath)
                continue
            }

            appendCreateDirectory(
                targetURL.deletingLastPathComponent().path,
                pimxPath: deleteLastPIMXPathComponent(pimxTargetPath)
            )
            commands.append(
                commandDescriptor(
                    for: style,
                    source: itemURL.path,
                    target: targetURL.path,
                    pimxTarget: normalizePIMXPath(pimxTargetPath, isDirectoryLike: false)
                )
            )
        }
    }

    private func commandDescriptor(
        for style: AssetCommandStyle,
        source: String,
        target: String,
        pimxTarget: String
    ) -> PIMXCommandDescriptor {
        switch style {
        case .move:
            return .moveFile(source: source, target: target, pimxTarget: pimxTarget)
        case .copy:
            return .copyFile(source: source, target: target, pimxTarget: pimxTarget)
        case .blindCopy:
            return .blindCopy(source: source, target: target, pimxTarget: pimxTarget)
        }
    }

    private func resolvedFileTarget(source: String, target: String) -> String {
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        if target.hasSuffix("/") {
            return appendPIMXPathComponent(target, sourceName)
        }

        let lastComponent = (target as NSString).lastPathComponent
        if !lastComponent.contains(".") {
            return appendPIMXPathComponent(target, sourceName)
        }

        return target
    }

    private func wrappedDirectoryCommandDescriptor(
        for style: AssetCommandStyle,
        source: String,
        target: String,
        pimxTarget: String
    ) -> PIMXCommandDescriptor {
        if shouldMergeWrappedDirectory(source: source, target: target) {
            return .mergeDirectory(source: source, target: target, pimxTarget: pimxTarget)
        }
        return commandDescriptor(for: style, source: source, target: target, pimxTarget: pimxTarget)
    }

    private func shouldMergeWrappedDirectory(source: String, target: String) -> Bool {
        guard isExistingDirectory(target) else {
            return false
        }

        let sourceURL = URL(fileURLWithPath: source, isDirectory: true)
        switch sourceURL.pathExtension.lowercased() {
        case "app":
            let executableName = sourceURL.deletingPathExtension().lastPathComponent
            let executablePath = sourceURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableName)
                .path
            return !FileManager.default.fileExists(atPath: executablePath)
        case "framework":
            let executableName = sourceURL.deletingPathExtension().lastPathComponent
            let directExecutable = sourceURL.appendingPathComponent(executableName).path
            let versionedExecutable = sourceURL
                .appendingPathComponent("Versions/A", isDirectory: true)
                .appendingPathComponent(executableName)
                .path
            return !FileManager.default.fileExists(atPath: directExecutable)
                && !FileManager.default.fileExists(atPath: versionedExecutable)
        default:
            return true
        }
    }

    private func wrappedDirectoryRootTarget(source: String, target: String) -> String? {
        let wrappedExtensions = Set(["app", "framework", "bundle", "plugin", "xpc", "appex"])
        guard wrappedExtensions.contains(URL(fileURLWithPath: source).pathExtension.lowercased()) else {
            return nil
        }

        if wrappedExtensions.contains(URL(fileURLWithPath: target).pathExtension.lowercased()) {
            return normalizePIMXPath(target, isDirectoryLike: true)
        }

        return resolvedFileTarget(source: source, target: target)
    }

    private func appendPIMXPathComponent(_ base: String, _ component: String) -> String {
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !normalizedBase.isEmpty else {
            return component
        }
        return (normalizedBase as NSString).appendingPathComponent(component)
    }

    private func deleteLastPIMXPathComponent(_ path: String) -> String {
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? normalizedPath : parent
    }

    private func normalizePIMXPath(_ path: String, isDirectoryLike: Bool) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        if isDirectoryLike {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return trimmed
    }

    private func parseProgramInvocation(from element: XMLElement) throws -> PIMXProgramInvocation? {
        let pimxPath = (try element.nodes(forXPath: "Path").first?.stringValue)
            ?? element.attribute(forName: "path")?.stringValue
            ?? ""
        guard !pimxPath.isEmpty else {
            return nil
        }

        let pimxArguments = try element.nodes(forXPath: "Arguments/Argument").compactMap { $0.stringValue }
        let exitCodeNodes = try element.nodes(forXPath: "SuccessExitCodes/ExitCode")
        var successExitCodes = exitCodeNodes.compactMap {
            Int32($0.stringValue ?? "")
        }
        if successExitCodes.isEmpty {
            successExitCodes = [0]
        }

        let runInUserMode = boolAttribute(element.attribute(forName: "runInUserMode")?.stringValue)

        return PIMXProgramInvocation(
            path: propertyTable.expandPath(pimxPath),
            arguments: pimxArguments.map(propertyTable.expandPath),
            successExitCodes: successExitCodes,
            hasExplicitSuccessExitCodes: !exitCodeNodes.isEmpty,
            pimxPath: pimxPath,
            pimxArguments: pimxArguments,
            runInUserMode: runInUserMode
        )
    }

    private func boolAttribute(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "true" || normalized == "1" || normalized == "yes"
    }

    static func readPackageVersion(from pimxURL: URL) -> String {
        guard let xmlData = try? loadXMLData(from: pimxURL, writeBackIfNeeded: false),
              let xmlDoc = try? XMLDocument(data: xmlData, options: []),
              let root = xmlDoc.rootElement() else {
            return ""
        }

        let candidates = [
            "version",
            "PackageVersion",
            "Version",
            "CodexVersion",
            "ProductVersion",
            "BuildVersion",
            "BaseVersion"
        ]

        for key in candidates {
            let nodes = try? root.nodes(forXPath: key)
            if let value = nodes?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        return ""
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
