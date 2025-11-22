//
//  NavigationCustomDownloadView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2025/07/19.
//

import SwiftUI

class CustomDownloadLoadingState: ObservableObject {
    @Published var isLoading = true
    @Published var currentTask = ""
    @Published var error: String?
}

struct NavigationCustomDownloadView: View {
    @StateObject private var loadingState = CustomDownloadLoadingState()
    @State private var allPackages: [Package] = []
    @State private var dependenciesToDownload: [DependenciesToDownload] = []
    @State private var showExistingFileAlert = false
    @State private var existingFilePath: URL?
    @State private var pendingDependencies: [DependenciesToDownload] = []
    @State private var productIcon: NSImage? = nil
    
    let productId: String
    let version: String
    let onDownloadStart: ([DependenciesToDownload]) -> Void
    let onDismiss: () -> Void
    
    init(productId: String, version: String, onDownloadStart: @escaping ([DependenciesToDownload]) -> Void, onDismiss: @escaping () -> Void) {
        self.productId = productId
        self.version = version
        self.onDownloadStart = onDownloadStart
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        Group {
            if loadingState.isLoading {
                NavigationCustomDownloadLoadingView(
                    loadingState: loadingState,
                    productId: productId,
                    version: version,
                    onCancel: onDismiss
                )
            } else if loadingState.error != nil {
                VStack {
                    Text("加载失败")
                        .font(.headline)
                    Text(loadingState.error!)
                        .foregroundColor(.secondary)
                    Button("重试") {
                        loadingState.error = nil
                        loadingState.isLoading = true
                        loadPackageInfo()
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                }
                .padding()
                .navigationTitle("自定义下载")
            } else {
                NavigationCustomPackageSelectorView(
                    productId: productId,
                    version: version,
                    packages: allPackages,
                    dependenciesToDownload: dependenciesToDownload,
                    onDownloadStart: { dependencies in
                        onDownloadStart(dependencies)
                    },
                    onCancel: onDismiss,
                    onFileExists: { path, dependencies in
                        existingFilePath = path
                        pendingDependencies = dependencies
                        showExistingFileAlert = true
                    }
                )
            }
        }
        .onAppear {
            if loadingState.isLoading {
                loadPackageInfo()
            }
            loadProductIcon()
        }
        .sheet(isPresented: $showExistingFileAlert) {
            if let existingPath = existingFilePath {
                ExistingFileAlertView(
                    path: existingPath,
                    onUseExisting: {
                        showExistingFileAlert = false
                        if let existingPath = existingFilePath {
                            Task {
                                await createCompletedCustomTask(
                                    path: existingPath,
                                    dependencies: pendingDependencies
                                )
                            }
                        }
                        pendingDependencies = []
                        onDismiss()
                    },
                    onRedownload: {
                        showExistingFileAlert = false
                        startCustomDownloadProcess(dependencies: pendingDependencies)
                    },
                    onCancel: {
                        showExistingFileAlert = false
                        pendingDependencies = []
                    },
                    iconImage: productIcon
                )
            }
        }
    }
    
    private func loadPackageInfo() {
        Task {
            do {
                let (packages, dependencies) = try await fetchPackageInfo()
                await MainActor.run {
                    allPackages = packages
                    dependenciesToDownload = dependencies
                    loadingState.isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadingState.isLoading = false
                    loadingState.error = error.localizedDescription
                }
            }
        }
    }
    
    private func fetchPackageInfo() async throws -> ([Package], [DependenciesToDownload]) {
        guard let product = findProduct(id: productId, version: version) else {
            throw NetworkError.invalidData("找不到产品信息")
        }
        
        var allPackages: [Package] = []
        var dependenciesToDownload: [DependenciesToDownload] = []
        
        let firstPlatform = product.platforms.first
        let buildGuid = firstPlatform?.languageSet.first?.buildGuid ?? ""
        
        var dependencyInfos: [DependenciesToDownload] = []
        dependencyInfos.append(DependenciesToDownload(sapCode: product.id, version: product.version, buildGuid: buildGuid))
        
        let dependencies = firstPlatform?.languageSet.first?.dependencies
        if let dependencies = dependencies {
            for dependency in dependencies {
                dependencyInfos.append(DependenciesToDownload(sapCode: dependency.sapCode, version: dependency.productVersion, buildGuid: dependency.buildGuid))
            }
        }
        
        for dependencyInfo in dependencyInfos {
            await MainActor.run {
                loadingState.currentTask = String(localized: "正在处理 \(dependencyInfo.sapCode) 的包信息...")
            }
            
            let jsonString = try await globalNetworkService.getApplicationInfo(buildGuid: dependencyInfo.buildGuid)
            dependencyInfo.applicationJson = jsonString
            
            var processedJsonString = jsonString
            if dependencyInfo.sapCode == product.id {
                if let jsonData = jsonString.data(using: .utf8),
                   var appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    
                    if var modules = appInfo["Modules"] as? [String: Any] {
                        modules["Module"] = [] as [[String: Any]]
                        appInfo["Modules"] = modules
                    }
                    
                    if let processedData = try? JSONSerialization.data(withJSONObject: appInfo, options: .prettyPrinted),
                       let processedString = String(data: processedData, encoding: .utf8) {
                        processedJsonString = processedString
                    }
                }
            }
            
            guard let jsonData = processedJsonString.data(using: .utf8),
                  let appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let packages = appInfo["Packages"] as? [String: Any],
                  let packageArray = packages["Package"] as? [[String: Any]] else {
                throw NetworkError.invalidData("无法解析产品信息")
            }
            
            for package in packageArray {
                guard let downloadURL = package["Path"] as? String, !downloadURL.isEmpty else { continue }
                
                let packageVersion: String = package["PackageVersion"] as? String ?? ""
                let fullPackageName: String
                
                if let name = package["fullPackageName"] as? String, !name.isEmpty {
                    fullPackageName = name
                } else if let name = package["PackageName"] as? String, !name.isEmpty {
                    fullPackageName = "\(name).zip"
                } else {
                    continue
                }
                
                let downloadSize: Int64
                switch package["DownloadSize"] {
                case let sizeNumber as NSNumber:
                    downloadSize = sizeNumber.int64Value
                case let sizeString as String:
                    downloadSize = Int64(sizeString) ?? 0
                default:
                    downloadSize = 0
                }
                
                let packageType = package["Type"] as? String ?? "non-core"
                let condition = package["Condition"] as? String ?? ""

                let isCore = packageType == "core"
                let targetArchitecture = StorageData.shared.downloadAppleSilicon ? "arm64" : "x64"
                let language = StorageData.shared.defaultLanguage
                let installLanguage = "[installLanguage]==\(language)"
                
                var shouldDefaultSelect = false
                var isRequired = false
                
                if dependencyInfo.sapCode == product.id {
                    if isCore {
                        shouldDefaultSelect = condition.isEmpty || 
                                            condition.contains("[OSArchitecture]==\(targetArchitecture)") ||
                                            condition.contains(installLanguage) || language == "ALL"
                        isRequired = shouldDefaultSelect
                    } else {
                        shouldDefaultSelect = condition.contains(installLanguage) || language == "ALL"
                    }
                } else {
                    shouldDefaultSelect = condition.isEmpty ||
                                        (condition.contains("[OSVersion]") && checkOSVersionCondition(condition)) ||
                                        condition.contains(installLanguage) || language == "ALL"
                }

                // Photoshop 的 SuperCafModels 包默认选中
                if fullPackageName.contains("SuperCafModels") {
                    shouldDefaultSelect = true
                }
                
                let packageObj = Package(
                    type: packageType,
                    fullPackageName: fullPackageName,
                    downloadSize: downloadSize,
                    downloadURL: downloadURL,
                    packageVersion: packageVersion,
                    condition: condition,
                    isRequired: isRequired
                )

                packageObj.isSelected = shouldDefaultSelect
                
                dependencyInfo.packages.append(packageObj)
                allPackages.append(packageObj)
            }
            
            dependenciesToDownload.append(dependencyInfo)
        }
        
        return (allPackages, dependenciesToDownload)
    }
    
    private func createCompletedCustomTask(path: URL, dependencies: [DependenciesToDownload]) async {
        let existingTask = globalNetworkManager.downloadTasks.first { task in
            return task.productId == productId &&
                   task.productVersion == version &&
                   task.language == StorageData.shared.defaultLanguage &&
                   task.directory == path
        }
        
        if existingTask != nil {
            return
        }
        
        let platform = globalProducts.first(where: { $0.id == productId && $0.version == version })?.platforms.first?.id ?? "unknown"

        let task = NewDownloadTask(
            productId: productId,
            productVersion: version,
            language: StorageData.shared.defaultLanguage,
            displayName: findProduct(id: productId)?.displayName ?? productId,
            directory: path,
            dependenciesToDownload: dependencies,
            retryCount: 0,
            createAt: Date(),
            totalProgress: 1.0,
            platform: platform
        )

        task.dependenciesToDownload = dependencies

        let totalSize = dependencies.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }
        task.totalSize = totalSize
        task.totalDownloadedSize = totalSize
        task.totalProgress = 1.0

        for dependency in dependencies {
            for package in dependency.packages where package.isSelected {
                package.downloaded = true
                package.progress = 1.0
                package.downloadedSize = package.downloadSize
                package.status = .completed
            }
        }

        task.setStatus(DownloadStatus.completed(DownloadStatus.CompletionInfo(
            timestamp: Date(),
            totalTime: 0,
            totalSize: totalSize
        )))

        await MainActor.run {
            globalNetworkManager.downloadTasks.append(task)
            globalNetworkManager.updateDockBadge()
            globalNetworkManager.objectWillChange.send()
        }

        await globalNetworkManager.saveTask(task)
    }
    
    private func startCustomDownloadProcess(dependencies: [DependenciesToDownload]) {
        Task {
            let destinationURL: URL
            do {
                destinationURL = try await getDestinationURL(
                    productId: productId,
                    version: version,
                    language: StorageData.shared.defaultLanguage
                )
            } catch {
                await MainActor.run { onDismiss() }
                return
            }
            
            do {
                try await globalNetworkManager.startCustomDownload(
                    productId: productId,
                    selectedVersion: version,
                    language: StorageData.shared.defaultLanguage,
                    destinationURL: destinationURL,
                    customDependencies: dependencies
                )
            } catch {
                print("自定义下载失败: \(error.localizedDescription)")
            }

            await MainActor.run {
                onDismiss()
            }
        }
    }
    
    private func getDestinationURL(productId: String, version: String, language: String) async throws -> URL {
        let platform = globalProducts.first(where: { $0.id == productId && $0.version == version })?.platforms.first?.id ?? "unknown"
        let installerName = productId == "APRO"
            ? "Adobe Downloader \(productId)_\(version)_\(platform).dmg"
            : "Adobe Downloader \(productId)_\(version)-\(language)-\(platform)"

        if StorageData.shared.useDefaultDirectory && !StorageData.shared.defaultDirectory.isEmpty {
            return URL(fileURLWithPath: StorageData.shared.defaultDirectory)
                .appendingPathComponent(installerName)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "选择保存位置"
                panel.canCreateDirectories = true
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                
                if let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    panel.directoryURL = downloadsDir
                }
                
                let result = panel.runModal()
                if result == .OK, let selectedURL = panel.url {
                    continuation.resume(returning: selectedURL.appendingPathComponent(installerName))
                } else {
                    continuation.resume(throwing: NetworkError.cancelled)
                }
            }
        }
    }
    
    private func loadProductIcon() {
        guard let product = findProduct(id: productId),
              let icon = product.getBestIcon(),
              let iconURL = URL(string: icon.value) else {
            return
        }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: iconURL)
                if let image = NSImage(data: data) {
                    await MainActor.run {
                        productIcon = image
                    }
                }
            } catch {
                print("加载产品图标失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func checkOSVersionCondition(_ condition: String) -> Bool {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let currentVersion = Double("\(osVersion.majorVersion).\(osVersion.minorVersion)") ?? 0.0
        
        let versionPattern = #"\[OSVersion\](>=|<=|<|>|==)([\d.]+)"#
        guard let regex = try? NSRegularExpression(pattern: versionPattern) else { return false }
        
        let nsRange = NSRange(condition.startIndex..<condition.endIndex, in: condition)
        let matches = regex.matches(in: condition, range: nsRange)
        
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let operatorRange = Range(match.range(at: 1), in: condition),
                  let versionRange = Range(match.range(at: 2), in: condition),
                  let requiredVersion = Double(condition[versionRange]) else { continue }
            
            let operatorSymbol = String(condition[operatorRange])
            if !compareVersions(current: currentVersion, required: requiredVersion, operator: operatorSymbol) {
                return false
            }
        }
        
        return !matches.isEmpty
    }
    
    private func compareVersions(current: Double, required: Double, operator: String) -> Bool {
        switch `operator` {
        case ">=":
            return current >= required
        case "<=":
            return current <= required
        case ">":
            return current > required
        case "<":
            return current < required
        case "==":
            return current == required
        default:
            return false
        }
    }
}

private struct NavigationCustomDownloadLoadingView: View {
    @ObservedObject var loadingState: CustomDownloadLoadingState
    
    let productId: String
    let version: String
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            VStack {
                if let product = findProduct(id: productId) {
                    HStack {
                        if let icon = product.getBestIcon() {
                            AsyncImage(url: URL(string: icon.value)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                            } placeholder: {
                                Image(systemName: "app.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        VStack(alignment: .leading) {
                            Text(product.displayName)
                                .font(.headline)
                            Text("版本 \(version)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                }
            }
            .padding()
            
            Divider()

            VStack(spacing: 15) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .frame(width: 40, height: 40)
                
                Text("正在获取包信息...")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                if !loadingState.currentTask.isEmpty {
                    Text(loadingState.currentTask)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Spacer()

            HStack {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .navigationTitle("自定义下载")
    }
}

private struct NavigationCustomPackageSelectorView: View {
    @State private var selectedPackages: Set<UUID> = []
    @State private var searchText = ""
    @State private var showCopiedAlert = false
    @State private var isDownloading = false
    @State private var requiredPackages: Set<UUID> = []
    
    let productId: String
    let version: String
    let packages: [Package]
    let dependenciesToDownload: [DependenciesToDownload]
    let onDownloadStart: ([DependenciesToDownload]) -> Void
    let onCancel: () -> Void
    let onFileExists: (URL, [DependenciesToDownload]) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择要下载的包")
                    .font(.headline)
                Spacer()

                Button(action: copyAllInfo) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text("复制全部")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue))
                .help("复制所有包信息")
                
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.2)))
            }
            .padding()
            
            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(dependenciesToDownload, id: \.sapCode) { dependency in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "cube.box.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.blue.opacity(0.8))
                                
                                Text("\(dependency.sapCode) \(dependency.version)\(dependency.sapCode != "APRO" ? " - (\(dependency.buildGuid))" : "")")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.primary.opacity(0.8))
                                    .textSelection(.enabled)
                                
                                if dependency.sapCode != "APRO" {
                                    Button(action: {
                                        copyToClipboard(dependency.buildGuid)
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(BeautifulButtonStyle(baseColor: .blue))
                                    .help("复制 buildGuid")
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)

                            ForEach(dependency.packages) { package in
                                NavigationEnhancedPackageRow(
                                    package: package,
                                    isSelected: selectedPackages.contains(package.id),
                                    onToggle: { isSelected in
                                        if !requiredPackages.contains(package.id) {
                                            if isSelected {
                                                selectedPackages.insert(package.id)
                                            } else {
                                                selectedPackages.remove(package.id)
                                            }
                                        }
                                    },
                                    onCopyPackageInfo: {
                                        copyPackageInfo(package)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
            
            Divider()

            HStack {
                Button("全选") {
                    selectAllPackages()
                }
                .font(.caption)
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.green))
                .help("选择所有包")
                
                Button("取消全选") {
                    clearAllSelection()
                }
                .font(.caption)
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.red))
                .help("取消选择所有包")
                
                Spacer()
                
                VStack(alignment: .center, spacing: 2) {
                    Text("已选择 \(selectedPackages.count) 个包")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("总大小: \(formattedTotalSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(isDownloading ? "正在下载..." : "开始下载") {
                    startCustomDownload()
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: isDownloading ? Color.gray : Color.blue))
                .disabled(selectedPackages.isEmpty || isDownloading)
            }
            .padding()
        }
        .frame(width: 800, height: 650)
        .navigationTitle("自定义下载")
        .onAppear {
            initializeSelection()
        }
        .popover(isPresented: $showCopiedAlert, arrowEdge: .trailing) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("已复制")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
    
    private var formattedTotalSize: String {
        let totalSize = selectedPackages.compactMap { id in
            packages.first { $0.id == id }?.downloadSize
        }.reduce(0, +)
        
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
    
    private func initializeSelection() {
        selectedPackages.removeAll()
        requiredPackages.removeAll()
        
        for package in packages {
            if package.isRequired || package.isSelected {
                selectedPackages.insert(package.id)
                requiredPackages.insert(package.id)
            }
        }
    }

    private func selectAllPackages() {
        selectedPackages = Set(packages.map { $0.id })
    }

    private func clearAllSelection() {
        selectedPackages = requiredPackages
    }
    
    private func startCustomDownload() {
        guard !isDownloading else { return }
        
        isDownloading = true
        
        for dependency in dependenciesToDownload {
            for package in dependency.packages {
                package.isSelected = selectedPackages.contains(package.id)
            }
        }

        let finalDependencies = dependenciesToDownload.filter { dependency in
            dependency.packages.contains { $0.isSelected }
        }

        if let existingPath = globalNetworkManager.isVersionDownloaded(
            productId: productId, 
            version: version, 
            language: StorageData.shared.defaultLanguage
        ) {
            isDownloading = false
            onFileExists(existingPath, finalDependencies)
        } else {
            onDownloadStart(finalDependencies)
            onCancel()
        }
    }
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopiedAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedAlert = false
        }
    }
    
    private func copyPackageInfo(_ package: Package) {
        let packageInfo = "\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)"
        copyToClipboard(packageInfo)
    }
    
    private func copyAllInfo() {
        var result = ""

        for (index, dependency) in dependenciesToDownload.enumerated() {
            let dependencyInfo: String
            if dependency.sapCode == "APRO" {
                dependencyInfo = "\(dependency.sapCode) \(dependency.version)"
            } else {
                dependencyInfo = "\(dependency.sapCode) \(dependency.version) - (\(dependency.buildGuid))"
            }
            result += dependencyInfo + "\n"

            for (pkgIndex, package) in dependency.packages.enumerated() {
                let isLastPackage = pkgIndex == dependency.packages.count - 1
                let prefix = isLastPackage ? "    └── " : "    ├── "
                result += "\(prefix)\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)\n"
            }

            if index < dependenciesToDownload.count - 1 {
                result += "\n"
            }
        }
        
        copyToClipboard(result)
    }
}

private struct NavigationEnhancedPackageRow: View {
    let package: Package
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    let onCopyPackageInfo: () -> Void

    private var isRequiredPackage: Bool {
        package.isRequired || package.isSelected
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Button(action: { 
                if !isRequiredPackage {
                    onToggle(!isSelected)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isRequiredPackage ? .secondary : .blue)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isRequiredPackage)
            .help(isRequiredPackage ? "此包为必需包，无法取消选择" : "点击切换选择状态")
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(package.fullPackageName) (\(package.packageVersion))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary.opacity(0.8))
                        .textSelection(.enabled)

                    Text(package.type)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(package.type == "core" ? Color.blue.opacity(0.1) : Color.orange.opacity(0.1))
                        )
                        .foregroundColor(package.type == "core" ? .blue : .orange)
                    
                    if isRequiredPackage {
                        Text(package.isRequired ? "必需" : "默认")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(package.isRequired ? Color.red.opacity(0.8) : Color.purple.opacity(0.8))
                            .cornerRadius(4)
                    }
                    
                    Spacer()

                    Text(package.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button(action: onCopyPackageInfo) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: .gray.opacity(0.6)))
                    .help("复制包信息")
                }
                
                #if DEBUG
                if !package.condition.isEmpty {
                    Text("条件: \(package.condition)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .textSelection(.enabled)
                }
                #endif
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .overlay(
            Rectangle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                .opacity(0.5),
            alignment: .bottom
        )
    }
}
