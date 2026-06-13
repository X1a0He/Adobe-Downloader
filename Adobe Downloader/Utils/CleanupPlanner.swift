import Foundation
import Darwin

enum CleanupProtectedResource {
    static let protectedKeywords = [
        "adobe downloader",
        "adobe-downloader",
        "com.x1a0he.macos.adobe-downloader"
    ]

    private static var runtimeProtectedPaths: [String] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.x1a0he.macOS.Adobe-Downloader"
        let helperID = "\(bundleID).helper"
        let home = NSHomeDirectory()
        var paths = Set<String>()

        [
            Bundle.main.bundleURL.path,
            Bundle.main.executableURL?.path,
            Bundle.main.resourceURL?.path,
            "/Applications/Adobe Downloader.app",
            "/Library/LaunchDaemons/\(helperID).plist",
            "/Library/PrivilegedHelperTools/\(helperID)",
            "\(home)/Library/Preferences/\(bundleID).plist",
            "\(home)/Library/Application Support/Adobe Downloader",
            "\(home)/Library/Application Support/\(bundleID)",
            "\(home)/Library/Caches/Adobe Downloader",
            "\(home)/Library/Caches/\(bundleID)",
            "\(home)/Library/Containers/\(bundleID)",
            "\(home)/Library/Group Containers/\(bundleID)",
            UserDefaults.standard.string(forKey: "defaultDirectory")
        ].compactMap { $0 }
            .filter { !$0.isEmpty }
            .forEach {
                paths.insert(($0 as NSString).standardizingPath)
            }

        return Array(paths)
    }

    static let dangerousPaths = [
        "/",
        "/Applications",
        "/Library",
        "/System",
        "/Users",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/tmp",
        "/private",
        "/opt",
        "/Volumes"
    ]

    static let allowedPathPrefixes = [
        "/Applications/Adobe",
        "/Applications/Utilities/Adobe",
        "/Applications/Acrobat",
        "/Applications/Maxon Cinema 4D",
        "/Library/Application Support/Adobe",
        "/Library/Application Support/Macromedia",
        "/Library/Application Support/Microsoft/Office365/User Content.localized/Startup",
        "/Library/Application Support/Mozilla/Extensions",
        "/Library/Application Support/Mozilla/NativeMessagingHosts",
        "/Library/Application Support/Uninst-",
        "/Library/Caches/*Adobe*",
        "/Library/Caches/*adobe*",
        "/Library/Caches/Acrobat*",
        "/Library/Caches/AI_*",
        "/Library/Caches/Adobe",
        "/Library/Caches/adobe",
        "/Library/Caches/com.adobe",
        "/Library/Caches/Acrobat",
        "/Library/Caches/com.apple.nsurlsessiond/Downloads/*adobe*",
        "/Library/Caches/com.crashlytics.data",
        "/Library/Application Support/regid",
        "/Library/Frameworks/Adobe",
        "/Library/Google/Chrome/NativeMessagingHosts/*adobe*",
        "/Library/InstallerSandboxes/.PKInstallSandboxManager/*/Boms/*Adobe*",
        "/Library/InstallerSandboxes/.PKInstallSandboxManager/*/Boms/*adobe*",
        "/Library/Internet Plug-Ins/Adobe",
        "/Library/Internet Plug-Ins/Flash",
        "/Library/LaunchAgents/*Adobe*",
        "/Library/LaunchAgents/*adobe*",
        "/Library/LaunchAgents/Adobe",
        "/Library/LaunchAgents/adobe",
        "/Library/LaunchAgents/com.adobe",
        "/Library/LaunchDaemons/*Adobe*",
        "/Library/LaunchDaemons/*adobe*",
        "/Library/LaunchDaemons/Adobe",
        "/Library/LaunchDaemons/adobe",
        "/Library/LaunchDaemons/com.adobe",
        "/Library/Preferences/*Adobe*",
        "/Library/Preferences/*adobe*",
        "/Library/Preferences/com.adobe",
        "/Library/Preferences/Adobe",
        "/Library/Preferences/adobe",
        "/Library/PDF Services/Save as Adobe PDF",
        "/Library/Automator/Save as Adobe PDF",
        "/Library/ScriptingAdditions/Adobe",
        "/Library/PreferencePanes/Flash",
        "/Library/PrivilegedHelperTools/*Adobe*",
        "/Library/PrivilegedHelperTools/*adobe*",
        "/Library/PrivilegedHelperTools/Adobe",
        "/Library/PrivilegedHelperTools/adobe",
        "/Library/PrivilegedHelperTools/com.adobe",
        "/Library/Logs/Adobe",
        "/Library/Logs/adobe",
        "/Library/Logs/CreativeCloud",
        "/Library/Logs/DiagnosticReports/Adobe",
        "/Library/Logs/DiagnosticReports/Creative Cloud Content Manager.node",
        "/Library/Logs/DiagnosticReports/After Effects",
        "/Library/Logs/DiagnosticReports/RemoteUpdateManager",
        "/Library/Logs/DiagnosticReports/SpeedGrade",
        "/Library/Google/Chrome/NativeMessagingHosts",
        "/Library/Application Support/Mozilla",
        "/Library/Application Support/CrashReporter/Adobe",
        "/Users/Shared/Adobe",
        "/Users/Shared/*Adobe*",
        "/Users/Shared/NGL",
        "/Users/Shared/Red Giant",
        "/Users/Shared/Plugin Loading.log",
        "/Users/Shared/*.aeroresource",
        "/private/var/db/receipts/com.adobe",
        "/private/var/db/receipts/*Adobe*",
        "/private/var/db/receipts/*adobe*",
        "/private/var/db/receipts/adobe",
        "/private/var/db/receipts/Adobe",
        "/private/var/log/acro",
        "/private/tmp/.adobe",
        "/private/tmp/adobe",
        "/private/tmp/Adobe",
        "/private/tmp/CCLBS",
        "/private/var/folders/*adobe*",
        "/private/var/folders/*Adobe*",
        "/private/var/folders/*CCLBS*",
        "/private/var/folders/*/*adobe*",
        "/private/var/folders/*/*Adobe*",
        "/private/var/folders/*/*CCLBS*",
        "/private/var/folders/*/*/*adobe*",
        "/private/var/folders/*/*/*Adobe*",
        "/private/var/folders/*/*/*CCLBS*",
        "/private/var/folders/*/*/*/.com.adobe.*",
        "/private/var/folders/*/*/*/*UXP*",
        "/private/var/folders/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*Adobe*",
        "/private/var/folders/*/*/*/*CCLBS*",
        "/private/var/folders/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*Adobe*",
        "/private/var/folders/*/*/*/*/*CCLBS*",
        "/private/var/folders/*/*/*/*/*/*adobe*",
        "/private/var/folders/*/*/*/*/*/*Adobe*",
        "/private/var/folders/*/*/*/*/*/*CCLBS*",
        "/private/var/root/Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj",
        "/private/var/root/Library/Application Support/Google/Chrome/Default/Extensions/kjchkpkjpiloipaonppkmepcbhcncedo",
        "/private/var/root/Library/Group Containers/UBF8T346G9.Office",
        "/usr/local/bin/RemoteUpdateManager"
    ]

    static let allowedUserPathPrefixes = [
        "Library/Application Scripts/Adobe",
        "Library/Application Scripts/com.adobe",
        "Library/Application Support/Adobe",
        "Library/Application Support/com.adobe",
        "Library/Application Support/Acrobat",
        "Library/Application Support/AAMUpdater",
        "Library/Application Support/Adobe-Hub-App",
        "Library/Application Support/AdobeUXP",
        "Library/Application Support/AdobeGCClient",
        "Library/Application Support/CEF",
        "Library/Application Support/CCX",
        "Library/Application Support/Creative Cloud",
        "Library/Application Support/io.branch",
        "Library/Application Support/CrashReporter/Adobe",
        "Library/Application Support/CrashReporter/Aero",
        "Library/Application Support/CrashReporter/After Effects",
        "Library/Application Support/CrashReporter/Core Sync",
        "Library/Application Support/Google/Chrome/Default/Extensions/efaidnbmnnnibpcajpcglclefindmkaj",
        "Library/Application Support/Google/Chrome/Default/Extensions/kjchkpkjpiloipaonppkmepcbhcncedo",
        "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.adobe",
        "Library/Containers/adobe",
        "Library/Containers/com.adobe",
        "Library/Containers/Adobe",
        "Library/Group Containers/Adobe",
        "Library/Group Containers/com.adobe",
        "Library/Group Containers/JQ525L2MZD.com.adobe",
        "Library/Group Containers/*.com.adobe",
        "Library/Group Containers/UBF8T346G9.Office",
        "Library/Preferences/com.adobe",
        "Library/Preferences/Adobe",
        "Library/Preferences/adobe",
        "Library/Preferences/AIRobin",
        "Library/Preferences/Lightroom",
        "Library/Preferences/Macromedia",
        "Library/Preferences/macromedia",
        "Library/Preferences/ByHost/com.adobe",
        "Library/Preferences/ByHost/adobe",
        "Library/Caches/Adobe",
        "Library/Caches/adobe",
        "Library/Caches/com.adobe",
        "Library/Caches/Acrobat",
        "Library/Caches/Aero",
        "Library/Caches/AI_",
        "Library/Caches/CSXS",
        "Library/Caches/UXPLogs",
        "Library/Caches/com.apple.nsurlsessiond/Downloads",
        "Library/Caches/com.crashlytics.data",
        "Library/Cookies/com.adobe",
        "Library/Cookies/Adobe",
        "Library/Cookies/adobe",
        "Library/HTTPStorages/Adobe",
        "Library/HTTPStorages/com.adobe",
        "Library/HTTPStorages/adobe",
        "Library/HTTPStorages/Aero",
        "Library/HTTPStorages/Creative Cloud Content Manager.node",
        "Library/Logs/Adobe",
        "Library/Logs/adobe",
        "Library/Logs/CreativeCloud",
        "Library/Logs/CSXS",
        "Library/Logs/NGL",
        "Library/Logs/NGLClient_",
        "Library/Logs/acro",
        "Library/Logs/amt",
        "Library/Logs/CoreSync",
        "Library/Logs/DiagnosticReports/Adobe",
        "Library/Logs/distNGLLog.txt",
        "Library/Logs/oobelib.log",
        "Library/Logs/PDApp",
        "Library/Logs/RemoteUpdateManager.log",
        "Library/LaunchAgents/com.adobe",
        "Library/LaunchAgents/adobe",
        "Library/Saved Application State/adobe",
        "Library/Saved Application State/com.adobe",
        "Library/Saved Application State/Adobe",
        "Library/WebKit/adobe",
        "Library/WebKit/com.adobe",
        "Library/WebKit/Adobe",
        "Library/WebKit/Databases/___IndexedDB/com.Adobe",
        "Library/Metadata/CoreSpotlight/SpotlightKnowledge",
        "Library/NGL",
        "Library/PhotoshopCrashes",
        "Documents/Adobe",
        "Creative Cloud Files",
        ".adobe"
    ]

    static func isProtectedPath(_ path: String) -> Bool {
        let rawLowered = path.lowercased()
        let normalized = (path as NSString).standardizingPath
        let lowered = normalized.lowercased()

        if protectedKeywords.map({ $0.lowercased() }).contains(where: { rawLowered.contains($0) }) {
            return true
        }

        return runtimeProtectedPaths
            .map { ($0 as NSString).standardizingPath.lowercased() }
            .contains {
                lowered == $0
                    || lowered.hasPrefix($0 + "/")
                    || rawLowered.contains($0)
            }
    }

    static func isDangerousPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return dangerousPaths.contains { normalized == $0 }
    }

    static func isAllowedAdobePath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath

        if normalized.lowercased().contains("adobe downloader") || normalized.lowercased().contains("com.x1a0he") {
            return false
        }

        for prefix in allowedPathPrefixes {
            if normalized.hasPrefix(prefix)
                || normalized.lowercased().hasPrefix(prefix.lowercased())
                || wildcardMatch(normalized, pattern: prefix) {
                return true
            }
        }

        if normalized.hasPrefix("/Users/") {
            let components = normalized.split(separator: "/")
            guard components.count > 2 else { return false }
            let relativePath = components[2...].joined(separator: "/")

            for prefix in allowedUserPathPrefixes {
                if relativePath.hasPrefix(prefix)
                    || relativePath.lowercased().hasPrefix(prefix.lowercased())
                    || wildcardMatch(relativePath, pattern: prefix) {
                    return true
                }
            }
        }

        return false
    }

    private static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else {
            return false
        }
        return fnmatch(pattern.lowercased(), value.lowercased(), 0) == 0
    }

    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !isProtectedPath(path) else { return false }
        guard !isDangerousPath(path) else { return false }
        return isAllowedAdobePath(path)
    }

    static func isProtectedCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let isDestructiveCommand = lowered.contains("rm ")
            || lowered.contains("rm -")
            || lowered.contains("/bin/rm")
            || lowered.contains("mv ")
            || lowered.contains("/bin/mv")
        return isDestructiveCommand && isProtectedPath(command)
    }
}

struct CleanupUserContext {
    let userName: String
    let userHome: String
    let userUID: Int
    let loginKeychain: String
    let userContexts: [CleanupUserContext]

    static func current() -> CleanupUserContext {
        let home = NSHomeDirectory()
        return CleanupUserContext(
            userName: NSUserName(),
            userHome: home,
            userUID: Int(getuid()),
            loginKeychain: "\(home)/Library/Keychains/login.keychain-db",
            userContexts: []
        )
    }

    static func allCleanupUsers() -> [CleanupUserContext] {
        let currentUser = current()
        var contexts = [currentUser]
        contexts.append(contentsOf: localUserContexts().filter { $0.userHome != currentUser.userHome })
        return contexts
    }

    private static func localUserContexts() -> [CleanupUserContext] {
        do {
            let users = try FileManager.default.contentsOfDirectory(
                atPath: "/Users"
            )
            return users.compactMap { userName in
                guard !["Shared", "Guest"].contains(userName) else { return nil }
                let home = "/Users/\(userName)"
                guard FileManager.default.fileExists(atPath: home),
                      !CleanupProtectedResource.isProtectedPath(home) else {
                    return nil
                }
                return CleanupUserContext(
                    userName: userName,
                    userHome: home,
                    userUID: uid(for: userName),
                    loginKeychain: "\(home)/Library/Keychains/login.keychain-db",
                    userContexts: []
                )
            }
        } catch {
            return []
        }
    }

    private static func uid(for userName: String) -> Int {
        if let passwd = getpwnam(userName) {
            return Int(passwd.pointee.pw_uid)
        }
        return 0
    }

    var allUsersContext: CleanupUserContext {
        CleanupUserContext(
            userName: userName,
            userHome: userHome,
            userUID: userUID,
            loginKeychain: loginKeychain,
            userContexts: Self.allCleanupUsers()
        )
    }

    func expand(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{USER_HOME}", with: userHome)
            .replacingOccurrences(of: "{USER_UID}", with: "\(userUID)")
            .replacingOccurrences(of: "{LOGIN_KEYCHAIN}", with: loginKeychain)
            .replacingOccurrences(of: "{USER_NAME}", with: userName)
    }

    func expandedForAllUsers(_ template: String) -> [String] {
        guard template.contains("{ALL_USER_") else {
            return [expand(template)]
        }

        let contexts = userContexts.isEmpty ? [self] : userContexts
        return contexts.map {
            template
                .replacingOccurrences(of: "{ALL_USER_HOME}", with: $0.userHome)
                .replacingOccurrences(of: "{ALL_USER_UID}", with: "\($0.userUID)")
                .replacingOccurrences(of: "{ALL_USER_NAME}", with: $0.userName)
                .replacingOccurrences(of: "{ALL_USER_LOGIN_KEYCHAIN}", with: $0.loginKeychain)
        }
    }
}

enum CleanupActionKind {
    case removePath
    case removeGlob
    case shell
    case hosts
    case keychain
    case process
    case launchctl
}

struct CleanupTarget {
    let option: CleanupOption
    let kind: CleanupActionKind
    let template: String
    let description: String
    let recursive: Bool
    let maxDepth: Int

    init(
        option: CleanupOption,
        kind: CleanupActionKind,
        template: String,
        description: String,
        recursive: Bool = false,
        maxDepth: Int = 4
    ) {
        self.option = option
        self.kind = kind
        self.template = template
        self.description = description
        self.recursive = recursive
        self.maxDepth = maxDepth
    }
}

struct CleanupPlanItem: Identifiable {
    let id = UUID()
    let option: CleanupOption
    let kind: CleanupActionKind
    let title: String
    let template: String
    let resolvedTarget: String
    let command: String
    let estimatedBytes: Int64
    let shouldRunWhenMissing: Bool

    var debugSummary: String {
        [
            "\(title) | [Cleanup][Plan] category=\(option.localizedName)",
            "kind=\(kind)",
            "template=\(template)",
            "target=\(resolvedTarget)",
            "command=\(command)"
        ].joined(separator: " ")
    }
}

struct CleanupPlanProgress {
    let completedOptions: Int
    let totalOptions: Int
    let currentOptionName: String
    let completedTargets: Int
    let totalTargets: Int

    var fraction: Double {
        guard totalOptions > 0 else { return 0 }
        let optionBase = Double(completedOptions) / Double(totalOptions)
        guard totalTargets > 0 else { return optionBase }
        let targetFraction = Double(completedTargets) / Double(totalTargets)
        return min(0.98, optionBase + targetFraction / Double(totalOptions))
    }

    var message: String {
        if completedOptions >= totalOptions {
            return "清理计划生成完成"
        }
        return "正在分析 \(currentOptionName) \(completedTargets)/\(totalTargets)"
    }
}

struct CleanupPlan {
    let context: CleanupUserContext
    let options: Set<CleanupOption>
    let items: [CleanupPlanItem]
    let estimatedBytes: Int64
    let freeSpaceBefore: Int64
}

final class CleanupPlanner {
    private let fileManager = FileManager.default

    func makePlan(
        for options: Set<CleanupOption>,
        context: CleanupUserContext = .current(),
        progress: ((CleanupPlanProgress) -> Void)? = nil
    ) -> CleanupPlan {
        let context = context.allUsersContext
        let orderedOptions = CleanupOption.executionOrder.filter { options.contains($0) }
        var items: [CleanupPlanItem] = []

        for (optionIndex, option) in orderedOptions.enumerated() {
            let targets = option.cleanupTargets
            progress?(CleanupPlanProgress(
                completedOptions: optionIndex,
                totalOptions: orderedOptions.count,
                currentOptionName: option.localizedName,
                completedTargets: 0,
                totalTargets: targets.count
            ))

            items.append(contentsOf: makeItems(
                for: option,
                targets: targets,
                context: context,
                optionIndex: optionIndex,
                totalOptions: orderedOptions.count,
                progress: progress
            ))

            progress?(CleanupPlanProgress(
                completedOptions: optionIndex + 1,
                totalOptions: orderedOptions.count,
                currentOptionName: option.localizedName,
                completedTargets: targets.count,
                totalTargets: targets.count
            ))
        }

        items = deduplicatedItems(items)

        let estimatedBytes = items.reduce(Int64(0)) { $0 + $1.estimatedBytes }

        progress?(CleanupPlanProgress(
            completedOptions: orderedOptions.count,
            totalOptions: orderedOptions.count,
            currentOptionName: "",
            completedTargets: 0,
            totalTargets: 0
        ))

        return CleanupPlan(
            context: context,
            options: options,
            items: items,
            estimatedBytes: estimatedBytes,
            freeSpaceBefore: currentFreeSpace()
        )
    }

    func currentFreeSpace() -> Int64 {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return capacity
    }

    func releasedSpace(from plan: CleanupPlan) -> Int64 {
        max(currentFreeSpace() - plan.freeSpaceBefore, 0)
    }

    private func makeItems(for option: CleanupOption, context: CleanupUserContext) -> [CleanupPlanItem] {
        makeItems(
            for: option,
            targets: option.cleanupTargets,
            context: context,
            optionIndex: 0,
            totalOptions: 1,
            progress: nil
        )
    }

    private func deduplicatedItems(_ items: [CleanupPlanItem]) -> [CleanupPlanItem] {
        var seenCommands = Set<String>()
        var keptRemovalPaths: [String] = []
        var result: [CleanupPlanItem] = []

        for item in items {
            guard seenCommands.insert(item.command).inserted else {
                continue
            }

            if isRemovalKind(item.kind),
               keptRemovalPaths.contains(where: { isPath($0, sameOrAncestorOf: item.resolvedTarget) }) {
                continue
            }

            result.append(item)

            if isRemovalKind(item.kind), !hasWildcard(item.resolvedTarget) {
                keptRemovalPaths.append(item.resolvedTarget)
            }
        }

        return result
    }

    private func isRemovalKind(_ kind: CleanupActionKind) -> Bool {
        kind == .removePath || kind == .removeGlob
    }

    private func isPath(_ parent: String, sameOrAncestorOf child: String) -> Bool {
        let normalizedParent = normalizedPath(parent)
        let normalizedChild = normalizedPath(child)
        return normalizedChild == normalizedParent || normalizedChild.hasPrefix(normalizedParent + "/")
    }

    private func removalCommand(for path: String) -> String {
        if let userName = userContextName(for: path), shouldRemoveAsUser(path) {
            return "/usr/bin/sudo -u \(shellQuoted(userName)) /bin/rm -rf -- \(shellQuoted(path))"
        }

        return "/bin/rm -rf -- \(shellQuoted(path))"
    }

    private func shouldRemoveAsUser(_ path: String) -> Bool {
        guard let relativePath = userRelativePath(for: path) else {
            return false
        }

        return relativePath.hasPrefix("Library/Containers/")
            || relativePath.hasPrefix("Library/Group Containers/")
            || relativePath.hasPrefix("Documents/")
    }

    private func userContextName(for path: String) -> String? {
        let normalized = normalizedPath(path)
        let components = normalized.split(separator: "/").map(String.init)

        if components.count >= 2, components[0] == "Users" {
            return components[1]
        }

        if normalized.hasPrefix(NSHomeDirectory() + "/") {
            return NSUserName()
        }

        return nil
    }

    private func userRelativePath(for path: String) -> String? {
        let normalized = normalizedPath(path)
        let components = normalized.split(separator: "/").map(String.init)

        if components.count > 2, components[0] == "Users" {
            return components.dropFirst(2).joined(separator: "/")
        }

        let home = normalizedPath(NSHomeDirectory())
        guard normalized.hasPrefix(home + "/") else {
            return nil
        }

        return String(normalized.dropFirst(home.count + 1))
    }

    private func makeItems(
        for option: CleanupOption,
        targets: [CleanupTarget],
        context: CleanupUserContext,
        optionIndex: Int,
        totalOptions: Int,
        progress: ((CleanupPlanProgress) -> Void)?
    ) -> [CleanupPlanItem] {
        targets.enumerated().flatMap { targetIndex, target -> [CleanupPlanItem] in
            progress?(CleanupPlanProgress(
                completedOptions: optionIndex,
                totalOptions: totalOptions,
                currentOptionName: option.localizedName,
                completedTargets: targetIndex,
                totalTargets: targets.count
            ))

            let items: [CleanupPlanItem]
            switch target.kind {
            case .removePath:
                items = makeRemovePathItems(target: target, context: context)
            case .removeGlob:
                items = makeRemoveGlobItems(target: target, context: context)
            case .shell, .hosts, .keychain, .process, .launchctl:
                items = makeShellItems(target: target, context: context)
            }

            progress?(CleanupPlanProgress(
                completedOptions: optionIndex,
                totalOptions: totalOptions,
                currentOptionName: option.localizedName,
                completedTargets: targetIndex + 1,
                totalTargets: targets.count
            ))
            return items
        }
    }

    private func makeRemovePathItems(target: CleanupTarget, context: CleanupUserContext) -> [CleanupPlanItem] {
        context.expandedForAllUsers(target.template).compactMap { expanded in
            let path = normalizedPath(expanded)
            guard !path.isEmpty,
                  CleanupProtectedResource.isSafePath(path),
                  fileManager.fileExists(atPath: path) else {
                return nil
            }

            return CleanupPlanItem(
                option: target.option,
                kind: .removePath,
                title: target.description,
                template: target.template,
                resolvedTarget: path,
                command: removalCommand(for: path),
                estimatedBytes: estimatedSize(of: path),
                shouldRunWhenMissing: false
            )
        }
    }

    private func makeRemoveGlobItems(target: CleanupTarget, context: CleanupUserContext) -> [CleanupPlanItem] {
        let expanded = context.expandedForAllUsers(target.template)
        let swiftExpandedPaths = Array(Set(expanded.flatMap {
            expandGlob($0, recursive: target.recursive, maxDepth: target.maxDepth)
        }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let verifiedPaths = swiftExpandedPaths
            .map { normalizedPath($0) }
            .filter { !$0.isEmpty && fileManager.fileExists(atPath: $0) }
            .filter { CleanupProtectedResource.isSafePath($0) }

        if !verifiedPaths.isEmpty {
            return verifiedPaths.map { path in
                CleanupPlanItem(
                    option: target.option,
                    kind: .removeGlob,
                    title: target.description,
                    template: target.template,
                    resolvedTarget: path,
                    command: removalCommand(for: path),
                    estimatedBytes: estimatedSize(of: path),
                    shouldRunWhenMissing: false
                )
            }
        }

        return expanded.compactMap { templatePath in
            let basePath = extractBasePath(from: templatePath)
            guard CleanupProtectedResource.isAllowedAdobePath(basePath) else {
                return nil
            }

            let normalized = normalizedPath(templatePath)
            guard !normalized.isEmpty,
                  CleanupProtectedResource.isSafePath(normalized) || isWildcardPattern(normalized) else {
                return nil
            }

            return CleanupPlanItem(
                option: target.option,
                kind: .removeGlob,
                title: target.description,
                template: target.template,
                resolvedTarget: normalized,
                command: "/bin/rm -rf \(shellQuoted(normalized)) 2>/dev/null || true",
                estimatedBytes: 0,
                shouldRunWhenMissing: true
            )
        }
    }

    private func makeShellItems(target: CleanupTarget, context: CleanupUserContext) -> [CleanupPlanItem] {
        context.expandedForAllUsers(target.template).map { command in
            let guardedCommand = CleanupProtectedResource.isProtectedCommand(command)
                ? "/usr/bin/true"
                : command
            return CleanupPlanItem(
                option: target.option,
                kind: target.kind,
                title: target.description,
                template: target.template,
                resolvedTarget: guardedCommand,
                command: guardedCommand,
                estimatedBytes: 0,
                shouldRunWhenMissing: true
            )
        }
    }

    private func expandGlob(_ pattern: String, recursive: Bool, maxDepth: Int) -> [String] {
        let expandedPattern = (pattern as NSString).expandingTildeInPath
        guard hasWildcard(expandedPattern) else {
            return fileManager.fileExists(atPath: expandedPattern) ? [expandedPattern] : []
        }

        if recursive {
            let wildcardIndex = expandedPattern.firstIndex { $0 == "*" || $0 == "?" || $0 == "[" }
            let prefix = wildcardIndex.map { String(expandedPattern[..<$0]) } ?? expandedPattern
            let basePath = nearestDirectoryPrefix(prefix)
            let lastPatternComponent = (expandedPattern as NSString).lastPathComponent

            guard !basePath.isEmpty else { return [] }

            guard fileManager.fileExists(atPath: basePath) else {
                return []
            }

            let matches = recursiveMatches(basePath: basePath, pattern: lastPatternComponent, maxDepth: maxDepth)
            return matches
        }

        let components = (expandedPattern as NSString).pathComponents
        guard !components.isEmpty else { return [] }

        let startPath: String
        let startIndex: Int
        if components[0] == "/" {
            startPath = "/"
            startIndex = 1
        } else {
            startPath = fileManager.currentDirectoryPath
            startIndex = 0
        }

        return componentMatches(components: components, index: startIndex, currentPath: startPath)
    }

    private func nearestDirectoryPrefix(_ prefix: String) -> String {
        var normalized = prefix
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized.isEmpty {
            return "/"
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue {
            return normalized
        }

        return (normalized as NSString).deletingLastPathComponent
    }

    private func componentMatches(components: [String], index: Int, currentPath: String) -> [String] {
        guard index < components.count else {
            return fileManager.fileExists(atPath: currentPath) ? [currentPath] : []
        }

        let component = components[index]
        if hasWildcard(component) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: currentPath) else {
                return []
            }

            return contents
                .filter { wildcardMatch($0, pattern: component) }
                .flatMap { componentMatches(components: components, index: index + 1, currentPath: appendPathComponent($0, to: currentPath)) }
        }

        let nextPath = appendPathComponent(component, to: currentPath)
        guard fileManager.fileExists(atPath: nextPath) else {
            return []
        }

        return componentMatches(components: components, index: index + 1, currentPath: nextPath)
    }

    private func appendPathComponent(_ component: String, to path: String) -> String {
        if path == "/" {
            return "/" + component
        }
        return (path as NSString).appendingPathComponent(component)
    }

    private func recursiveMatches(basePath: String, pattern: String, maxDepth: Int) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: basePath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [String] = []
        let baseDepth = basePath.split(separator: "/").count

        for case let url as URL in enumerator {
            let depth = url.path.split(separator: "/").count - baseDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if wildcardMatch(url.lastPathComponent, pattern: pattern) {
                matches.append(url.path)
                enumerator.skipDescendants()
            }
        }

        return matches
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        fnmatch(pattern.lowercased(), value.lowercased(), 0) == 0
    }

    private func hasWildcard(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    private func estimatedSize(of path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return fileSize(path)
        }

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return fileSize(path)
        }

        var total = fileSize(path)
        for case let relativePath as String in enumerator {
            total += fileSize((path as NSString).appendingPathComponent(relativePath))
        }
        return total
    }

    private func fileSize(_ path: String) -> Int64 {
        let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private func isWildcardPattern(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    private func extractBasePath(from pattern: String) -> String {
        guard let wildcardIndex = pattern.firstIndex(where: { $0 == "*" || $0 == "?" || $0 == "[" }) else {
            return pattern
        }
        let prefix = String(pattern[..<wildcardIndex])
        return (prefix as NSString).deletingLastPathComponent
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
