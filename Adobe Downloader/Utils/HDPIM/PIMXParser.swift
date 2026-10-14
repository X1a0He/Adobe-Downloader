//
//  PIMXParser.swift
//  Adobe Downloader
//

import Foundation
import Darwin

enum PIMXCommandDescriptor {
    case moveFile(source: String, target: String, pimxTarget: String)
    case copyFile(source: String, target: String, pimxTarget: String)
    case blindCopy(source: String, target: String, pimxTarget: String)
    case createDirectory(path: String, pimxPath: String)
    case mergeDirectory(source: String, target: String, pimxTarget: String)
    case deleteFile(target: String, isUserPreferences: Bool = false)
    case deleteDirectory(source: String, isRecursiveDelete: Bool, isUserPreferences: Bool)
    case createSymlink(source: String, target: String, pimxTarget: String)

    case unlockPath(path: String, active: Bool)
    case localizeFile(source: String, target: String)
    case macAlias(target: String, path: String, isPermanent: Bool)

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
    var isRecursiveDelete: Bool = false
    var isUserPreferences: Bool = false
    var isSymbolicLink: Bool = false
    var isPermanent: Bool = false
}

private enum AssetCommandStyle {
    case move
    case copy
    case blindCopy
}

/// 应用生成的卸载材料保留模板根与枚举名称，避免把字面 [Locale] 等重新解释为属性。
struct PIMXLiteralPath {
    struct Key: Hashable {
        let actualTarget: String
        let targetTemplate: String

        init(actualTarget: String, targetTemplate: String) {
            self.actualTarget = actualTarget
            self.targetTemplate = targetTemplate.hasSuffix("/") ? String(targetTemplate.dropLast()) : targetTemplate
        }
    }

    static let templateAttribute = "adobeDownloaderPathTemplate"
    static let relativePathAttribute = "adobeDownloaderLiteralPath"

    let template: String
    let relativePath: String

    var targetPath: String {
        (template as NSString).appendingPathComponent(relativePath)
    }

    func matches(_ path: String) -> Bool {
        path == targetPath || path == targetPath + "/"
    }

    func resolve(using propertyTable: HDPIMPropertyTable) throws -> String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PIMXError.invalidXML("卸载材料的字面相对路径无效")
        }
        let root = try propertyTable.expandPathForInstallation(template)
        try HDPIMFileChange.validate(root)
        let resolved = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relativePath).path
        try HDPIMFileChange.validate(resolved)
        return resolved
    }
}

struct PIMXPackageInfo {
    let packageName: String
    let commands: [PIMXCommandDescriptor]
    let assetReferences: [PIMXAssetReference]
    let literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath]
    var uninstallManifest: [HDPIMDeleteEntry]? = nil
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

    func parse(pimxURL: URL, xmlData: Data, extractDir: URL, collectUninstallManifest: Bool = true) throws -> PIMXPackageInfo {
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
        var literalPaths = assetsResult.literalPaths
        let uninstallManifest = collectUninstallManifest
            ? try makeUninstallManifest(from: assetsResult.assetReferences, literalPaths: &literalPaths)
            : nil

        commands += try parseCommands(root: root)

        return PIMXPackageInfo(
            packageName: packageName,
            commands: commands,
            assetReferences: assetsResult.assetReferences,
            literalPaths: literalPaths,
            uninstallManifest: uninstallManifest
        )
    }

    func parseUninstallCommands(pimxURL: URL, xmlData: Data? = nil, preservingUserPreferences: Bool = false) throws -> [PIMXCommandDescriptor] {
        let descriptors = try parseStoredCommands(pimxURL: pimxURL, xmlData: xmlData).compactMap { descriptor -> PIMXCommandDescriptor? in
            if preservingUserPreferences {
                switch descriptor {
                case .deleteDirectory(_, _, true), .deleteFile(_, true): return nil
                default: break
                }
            }
            return uninstallCommand(from: descriptor)
        }
        return orderedDeletionCommands(descriptors)
    }

    func parseRepairCommands(pimxURL: URL, xmlData: Data? = nil) throws -> [PIMXCommandDescriptor] {
        try parseStoredCommands(pimxURL: pimxURL, xmlData: xmlData)
    }

    /// 完整性检查使用清单声明的类型，不补入卸载父目录，也不按当前磁盘状态重分类。
    func parseInstalledPayload(pimxURL: URL, xmlData: Data) throws -> [PIMXCommandDescriptor] {
        try parseStoredCommands(pimxURL: pimxURL, xmlData: xmlData, orderDeletions: false).filter {
            switch $0 {
            case .deleteFile(_, false), .deleteDirectory(_, _, false): return true
            default: return false
            }
        }
    }

    /// 包清单目录及文件的直接父目录，包含偏好；不使用卸载执行时按磁盘状态补齐的目录。
    func parseInstalledDirectories(pimxURL: URL, xmlData: Data) throws -> [String] {
        try parseStoredCommands(pimxURL: pimxURL, xmlData: xmlData, orderDeletions: false).compactMap {
            switch $0 {
            case .deleteDirectory(let path, _, _): return path
            case .deleteFile(let path, _): return (path as NSString).deletingLastPathComponent
            default: return nil
            }
        }
    }

    private func parseStoredCommands(pimxURL: URL, xmlData: Data?, orderDeletions: Bool = true) throws -> [PIMXCommandDescriptor] {
        let xmlData = try xmlData ?? Self.loadXMLData(from: pimxURL, writeBackIfNeeded: false)
        let xmlDoc = try XMLDocument(data: xmlData, options: [])

        guard let root = xmlDoc.rootElement() else {
            throw PIMXError.invalidXML("PIMX 根节点不存在: \(pimxURL.path)")
        }

        return try parseCommands(root: root, isStoredMaterial: true, orderDeletions: orderDeletions)
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

    private func parseAssets(root: XMLElement) throws -> (commands: [PIMXCommandDescriptor], assetReferences: [PIMXAssetReference], literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath]) {
        var commands: [PIMXCommandDescriptor] = []
        var assetReferences: [PIMXAssetReference] = []
        var literalPaths: [PIMXLiteralPath.Key: PIMXLiteralPath] = [:]

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

            let expandedSource = try propertyTable.expandPathForInstallation(source)
            let expandedTarget = try propertyTable.expandPathForInstallation(target)
            let normalizedTargetTemplate = normalizePIMXPath(target, isDirectoryLike: type.lowercased() == "directory")

            let isDirectoryLike = isDirectoryAsset(
                element: element,
                type: type,
                rawSource: source,
                expandedSource: expandedSource
            )

            switch type.lowercased() {
            case "directory":
                try appendAssetCommands(
                    source: expandedSource,
                    target: expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: normalizedTargetTemplate,
                    isDirectoryLike: true,
                    style: .move,
                    to: &commands,
                    literalPaths: &literalPaths
                )
                let appTarget = wrappedDirectoryRootTarget(source: expandedSource, target: expandedTarget)
                let appTargetTemplate = wrappedDirectoryRootTarget(source: source, target: target)
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: appTarget ?? expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: normalizePIMXPath(appTargetTemplate ?? target, isDirectoryLike: true),
                    isDirectoryLike: true,
                    isRecursiveDelete: boolAttribute(element.attribute(forName: "isRecursiveDelete")?.stringValue),
                    isUserPreferences: boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue),
                    isPermanent: boolAttribute(element.attribute(forName: "isPermanent")?.stringValue)
                ))
            case "symlink":
                let linkTarget = element.attribute(forName: "targetLinkPath")?.stringValue ?? source
                commands.append(
                    .createSymlink(
                        source: try propertyTable.expandPathForInstallation(linkTarget),
                        target: expandedTarget,
                        pimxTarget: normalizePIMXPath(target, isDirectoryLike: false)
                    )
                )
                assetReferences.append(PIMXAssetReference(
                    source: expandedSource,
                    target: expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: normalizePIMXPath(target, isDirectoryLike: false),
                    isDirectoryLike: false,
                    isUserPreferences: boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue),
                    isSymbolicLink: true,
                    isPermanent: boolAttribute(element.attribute(forName: "isPermanent")?.stringValue)
                ))
            default:
                let normalizedPimxTarget = isDirectoryLike
                    ? normalizePIMXPath(target, isDirectoryLike: true)
                    : resolvedFileTarget(source: source, target: target)
                try appendAssetCommands(
                    source: expandedSource,
                    target: expandedTarget,
                    sourceTemplate: source,
                    targetTemplate: target,
                    isDirectoryLike: isDirectoryLike,
                    style: .move,
                    to: &commands,
                    literalPaths: &literalPaths
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
                    isDirectoryLike: isDirectoryLike,
                    isRecursiveDelete: boolAttribute(element.attribute(forName: "isRecursiveDelete")?.stringValue),
                    isUserPreferences: boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue),
                    isPermanent: boolAttribute(element.attribute(forName: "isPermanent")?.stringValue)
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

            let expandedSource = try propertyTable.expandPathForInstallation(source)
            let expandedTarget = try propertyTable.expandPathForInstallation(target)
            let isDirectoryLike = expandedSource.hasSuffix("/") || isExistingDirectory(expandedSource)
            let normalizedPimxTarget = isDirectoryLike
                ? normalizePIMXPath(target, isDirectoryLike: true)
                : resolvedFileTarget(source: source, target: target)

            try appendAssetCommands(
                source: expandedSource,
                target: expandedTarget,
                sourceTemplate: source,
                targetTemplate: target,
                isDirectoryLike: isDirectoryLike,
                style: .blindCopy,
                to: &commands,
                literalPaths: &literalPaths
            )
            let appTarget = wrappedDirectoryRootTarget(source: expandedSource, target: expandedTarget)
            let appTargetTemplate = wrappedDirectoryRootTarget(source: source, target: target)
            assetReferences.append(PIMXAssetReference(
                source: expandedSource,
                target: isDirectoryLike ? (appTarget ?? expandedTarget) : resolvedFileTarget(source: expandedSource, target: expandedTarget),
                sourceTemplate: source,
                targetTemplate: normalizePIMXPath(appTargetTemplate ?? normalizedPimxTarget, isDirectoryLike: isDirectoryLike),
                isDirectoryLike: isDirectoryLike,
                isRecursiveDelete: boolAttribute(element.attribute(forName: "isRecursiveDelete")?.stringValue),
                isUserPreferences: boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue),
                isPermanent: boolAttribute(element.attribute(forName: "isPermanent")?.stringValue)
            ))
        }

        return (commands, assetReferences, literalPaths)
    }

    /// 清单来自安装源；不枚举目标目录，避免把其他包或用户新增文件登记为本包所有。
    private func makeUninstallManifest(
        from assets: [PIMXAssetReference],
        literalPaths: inout [PIMXLiteralPath.Key: PIMXLiteralPath]
    ) throws -> [HDPIMDeleteEntry] {
        var entries: [HDPIMDeleteEntry] = []
        for asset in assets where !asset.isPermanent {
            let sourceURL = URL(fileURLWithPath: asset.source)
            let targetURL = URL(fileURLWithPath: asset.target)
            let template = normalizePIMXPath(asset.targetTemplate, isDirectoryLike: asset.isDirectoryLike)

            if asset.isSymbolicLink {
                entries.append(HDPIMDeleteEntry(targetPath: template, isDirectory: false,
                    isRecursiveDelete: false, isUserPreferences: asset.isUserPreferences,
                    actualTargetPath: targetURL.path))
                continue
            }

            var sourceInfo = stat()
            guard lstat(sourceURL.path, &sourceInfo) == 0 else {
                throw PIMXError.invalidXML("无法读取卸载清单的安装源：\(sourceURL.path)")
            }
            let isDirectory = (sourceInfo.st_mode & S_IFMT) == S_IFDIR
            entries.append(HDPIMDeleteEntry(targetPath: template, isDirectory: isDirectory,
                isRecursiveDelete: isDirectory && asset.isRecursiveDelete,
                isUserPreferences: asset.isUserPreferences, actualTargetPath: targetURL.path))
            guard isDirectory else { continue }

            // 使用相对名称构建目标，避免 /tmp 与 /private/tmp 等同一目录的别名影响边界判断。
            var descendants: [(relativePath: String, isDirectory: Bool)] = []
            var pending = [""]
            while let parent = pending.popLast() {
                try HDPIMOperationContext.checkCancellation()
                let directory = parent.isEmpty ? sourceURL : sourceURL.appendingPathComponent(parent)
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                    let relativePath = parent.isEmpty ? name : parent + "/" + name
                    let item = sourceURL.appendingPathComponent(relativePath)
                    var info = stat()
                    guard lstat(item.path, &info) == 0 else {
                        throw PIMXError.invalidXML("无法读取卸载清单源条目：\(item.path)")
                    }
                    let childIsDirectory = info.st_mode & S_IFMT == S_IFDIR
                    descendants.append((relativePath, childIsDirectory))
                    if childIsDirectory { pending.append(relativePath) }
                }
            }
            for descendant in descendants.sorted(by: { $0.relativePath < $1.relativePath }) {
                let actual = targetURL.appendingPathComponent(descendant.relativePath).path
                let target = appendPIMXPathComponent(template, descendant.relativePath)
                entries.append(HDPIMDeleteEntry(targetPath: target, isDirectory: descendant.isDirectory,
                    isRecursiveDelete: false, isUserPreferences: asset.isUserPreferences,
                    actualTargetPath: actual))
                if descendant.relativePath.contains("[") || descendant.relativePath.contains(":x0D") {
                    literalPaths[PIMXLiteralPath.Key(actualTarget: actual, targetTemplate: target)] =
                        PIMXLiteralPath(template: template, relativePath: descendant.relativePath)
                }
            }
        }
        return entries
    }

    private func parseCommands(root: XMLElement, isStoredMaterial: Bool = false, orderDeletions: Bool = true) throws -> [PIMXCommandDescriptor] {
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
                        path: try propertyTable.expandPathForInstallation(path),
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
                        path: try propertyTable.expandPathForInstallation(path),
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
                            uninstall: try uninstallElement.flatMap { try parseProgramInvocation(from: $0, workflowType: "uninstall") }
                        )
                    )
                    continue
                }

                if let directInvocation = try parseProgramInvocation(from: element) {
                    commands.append(.runProgram(execution: directInvocation, repair: nil, uninstall: nil))
                }

            case "UninstallCommand":
                if let uninstallInvocation = try parseProgramInvocation(from: element, workflowType: "uninstall") {
                    commands.append(.runProgram(execution: nil, repair: nil, uninstall: uninstallInvocation))
                }

            case "RegisterApplication":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                if !path.isEmpty {
                    commands.append(.registerApplication(path: try propertyTable.expandPathForInstallation(path)))
                }

            case "SetDisplayAttributes":
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                let icon = (try element.nodes(forXPath: "Icon").first?.stringValue)
                    ?? element.attribute(forName: "icon")?.stringValue ?? ""
                if !target.isEmpty && !icon.isEmpty {
                    commands.append(.setDisplayAttributes(
                        target: try propertyTable.expandPathForInstallation(target),
                        icon: try propertyTable.expandPathForInstallation(icon)
                    ))
                }

            case "DeleteFile":
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                let resolved = try resolveDeletePath(target, element: element, isStoredMaterial: isStoredMaterial)
                if !resolved.isEmpty {
                    commands.append(.deleteFile(target: resolved, isUserPreferences: boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue)))
                }

            case "DeleteDirectory":
                let source = (try element.nodes(forXPath: "Source").first?.stringValue)
                    ?? element.attribute(forName: "source")?.stringValue ?? ""
                let target = (try element.nodes(forXPath: "Target").first?.stringValue)
                    ?? element.attribute(forName: "target")?.stringValue ?? ""
                let path = source.isEmpty ? target : source
                let resolved = try resolveDeletePath(path, element: element, isStoredMaterial: isStoredMaterial)
                if !resolved.isEmpty {
                    let isRecursiveDelete = boolAttribute(element.attribute(forName: "isRecursiveDelete")?.stringValue)
                    let isUserPreferences = boolAttribute(element.attribute(forName: "isUserPreferences")?.stringValue)
                    commands.append(.deleteDirectory(
                        source: resolved,
                        isRecursiveDelete: isRecursiveDelete,
                        isUserPreferences: isUserPreferences
                    ))
                }

            case "Touch":
                let path = (try element.nodes(forXPath: "Path").first?.stringValue)
                    ?? element.attribute(forName: "path")?.stringValue ?? ""
                if !path.isEmpty {
                    commands.append(.touch(path: try propertyTable.expandPathForInstallation(path)))
                }

            case "FolderIcon":
                let folderPath = (try element.nodes(forXPath: "FolderPath").first?.stringValue)
                    ?? element.attribute(forName: "FolderPath")?.stringValue ?? ""
                let iconPath = (try element.nodes(forXPath: "IconPath").first?.stringValue)
                    ?? element.attribute(forName: "IconPath")?.stringValue ?? ""
                if !folderPath.isEmpty && !iconPath.isEmpty {
                    commands.append(.folderIcon(
                        folderPath: try propertyTable.expandPathForInstallation(folderPath),
                        iconPath: try propertyTable.expandPathForInstallation(iconPath)
                    ))
                }

            case "UnlockPath":
                let path = try commandPath("Path", attribute: "path", element: element)
                if !path.isEmpty {
                    commands.append(.unlockPath(path: path, active: propertyTable.getProperty("workflowType") == "uninstall"))
                }

            case "LocalizeFileName":
                let source = try commandPath("Path", attribute: "path", element: element)
                if !source.isEmpty, let name = try localizedName(element) {
                    guard HDPIMPackageMaterial.isLeafName(name) else { throw PIMXError.invalidXML("本地化文件名无效") }
                    let target = URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(name).path
                    if source != target { commands.append(.localizeFile(source: source, target: target)) }
                }

            case "Shortcut":
                let target = try commandPath("Target", attribute: "source", element: element)
                let directory = try commandPath("Directory", attribute: "directory", element: element)
                let path: String
                if !directory.isEmpty {
                    let name = try localizedName(element) ?? URL(fileURLWithPath: target).lastPathComponent
                    guard HDPIMPackageMaterial.isLeafName(name) else { throw PIMXError.invalidXML("快捷入口名称无效") }
                    path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                } else {
                    path = try commandPath("", attribute: "target", element: element)
                }
                if !target.isEmpty && !path.isEmpty {
                    commands.append(.macAlias(target: target, path: path,
                                              isPermanent: boolAttribute(element.attribute(forName: "isPermanent")?.stringValue)))
                }

            default:
                break
            }
        }

        return orderDeletions ? orderedDeletionCommands(commands) : commands
    }

    private func commandPath(_ child: String, attribute: String, element: XMLElement) throws -> String {
        let value = (child.isEmpty ? nil : element.elements(forName: child).first?.stringValue)
            ?? element.attribute(forName: attribute)?.stringValue ?? ""
        return value.isEmpty ? "" : try propertyTable.expandPathForInstallation(value)
    }

    private func localizedName(_ element: XMLElement) throws -> String? {
        let language = propertyTable.getProperty("uiDisplayLanguage")
            ?? propertyTable.getProperty("InstallLang")?.split(separator: ",").first.map(String.init) ?? ""
        let nodes = try element.nodes(forXPath: "Name/Language").compactMap { $0 as? XMLElement }
        return nodes.last {
            ($0.attribute(forName: "locale")?.stringValue ?? "") == language
        }?.stringValue
    }

    /// 显式删除在普通命令之后执行，子路径先于父目录；重复目标不扩大递归权限。
    private func orderedDeletionCommands(_ descriptors: [PIMXCommandDescriptor]) -> [PIMXCommandDescriptor] {
        var regular: [PIMXCommandDescriptor] = []
        var deletes: [String: (recursive: Bool, preferences: Bool)] = [:]
        for descriptor in descriptors {
            let path: String
            let flags: (Bool, Bool)
            switch descriptor {
            case .deleteFile(let target, let preferences): path = target; flags = (false, preferences)
            case .deleteDirectory(let target, let recursive, let preferences): path = target; flags = (recursive, preferences)
            default: regular.append(descriptor); continue
            }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if let previous = deletes[normalized] {
                deletes[normalized] = (previous.recursive && flags.0, previous.preferences || flags.1)
            } else {
                deletes[normalized] = flags
            }
        }
        let removalPolicy = HDPIMRemovalPolicy.PreflightChecker()
        let explicit = deletes
        for (path, flags) in explicit {
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while !removalPolicy.isProtected(parent.path) {
                if deletes[parent.path] != nil { break }
                deletes[parent.path] = (false, flags.preferences)
                let next = parent.deletingLastPathComponent()
                if next == parent { break }
                parent = next
            }
        }
        let unlocking = regular.filter { if case .unlockPath(_, true) = $0 { return true }; return false }
        let remaining = regular.filter { if case .unlockPath(_, true) = $0 { return false }; return true }
        return unlocking + remaining + deletes.keys.filter { !removalPolicy.isProtected($0) }.sorted(by: >).map { path in
            let flags = deletes[path]!
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                return .deleteDirectory(source: path, isRecursiveDelete: flags.recursive, isUserPreferences: flags.preferences)
            }
            return .deleteFile(target: path, isUserPreferences: flags.preferences)
        }
    }

    private func resolveDeletePath(_ path: String, element: XMLElement, isStoredMaterial: Bool) throws -> String {
        let template = element.attribute(forName: PIMXLiteralPath.templateAttribute)?.stringValue
        let relativePath = element.attribute(forName: PIMXLiteralPath.relativePathAttribute)?.stringValue
        guard template != nil || relativePath != nil else {
            // 仅解码 PIMX 文件路径，不改写属性值、枚举出的字面名称或 Hook 参数。
            return try propertyTable.expandPathForInstallation(path.replacingOccurrences(of: ":x0D", with: "\r"))
        }
        guard isStoredMaterial, let template, let relativePath else {
            throw PIMXError.invalidXML("卸载材料的字面路径属性不完整或来源无效")
        }
        let literalPath = PIMXLiteralPath(template: template, relativePath: relativePath)
        guard literalPath.matches(path) else {
            throw PIMXError.invalidXML("卸载材料的字面路径与目标不一致")
        }
        return try literalPath.resolve(using: propertyTable)
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
        to commands: inout [PIMXCommandDescriptor],
        literalPaths: inout [PIMXLiteralPath.Key: PIMXLiteralPath]
    ) throws {
        var sourceInfo = stat()
        if isDirectoryLike, lstat(source, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFLNK {
            let linkTarget = wrappedDirectoryRootTarget(source: source, target: target) ?? target
            let linkTemplate = wrappedDirectoryRootTarget(source: sourceTemplate, target: targetTemplate) ?? targetTemplate
            commands.append(commandDescriptor(for: style, source: source, target: linkTarget,
                                               pimxTarget: normalizePIMXPath(linkTemplate, isDirectoryLike: false)))
            return
        }
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
            if relativePath.contains("[") {
                let key = PIMXLiteralPath.Key(actualTarget: targetURL.path, targetTemplate: pimxTargetPath)
                literalPaths[key] = PIMXLiteralPath(template: normalizedTemplateTarget, relativePath: relativePath)
            }
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = resourceValues.isSymbolicLink == true
            let isDirectory = resourceValues.isDirectory == true

            if isSymbolicLink {
                // DirectoryEnumerator 不跟随符号链接；跳过后代会误跳过同级的真实载荷。
                appendCreateDirectory(
                    targetURL.deletingLastPathComponent().path,
                    pimxPath: deleteLastPIMXPathComponent(pimxTargetPath)
                )
                let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: itemURL.path)
                commands.append(
                    .createSymlink(
                        source: linkTarget,
                        target: targetURL.path,
                        pimxTarget: normalizePIMXPath(pimxTargetPath, isDirectoryLike: false)
                    )
                )
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
        try parseProgramInvocation(from: element, workflowType: nil)
    }

    private func parseProgramInvocation(from element: XMLElement, workflowType: String?) throws -> PIMXProgramInvocation? {
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
        let context = propertyTable.cloned()
        if let workflowType { context.setProperty("workflowType", workflowType) }

        return PIMXProgramInvocation(
            path: try context.expandPathForInstallation(pimxPath),
            arguments: pimxArguments.map(context.expandString),
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
        let original = try Data(contentsOf: pimxURL)
        let xmlData = try decodeXMLData(original, sourceURL: pimxURL)
        if writeBackIfNeeded, xmlData != original { try xmlData.write(to: pimxURL) }
        return xmlData
    }

    static func decodeXMLData(_ data: Data, sourceURL pimxURL: URL) throws -> Data {
        var xmlData = data
        let firstChunk = String(data: xmlData.prefix(200), encoding: .utf8) ?? ""

        if !firstChunk.contains("<") {
            do {
                let decompressed = try HDPIMNativeLZMA2.decompress(data: xmlData)
                guard !decompressed.isEmpty else {
                    throw PIMXError.invalidXML("PIMX 解压结果为空: \(pimxURL.path)")
                }
                xmlData = decompressed
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
