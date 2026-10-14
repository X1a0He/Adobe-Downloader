import Foundation

enum HDPIMPackageExecutionMode {
    case full(HDPIMInstalledPackageSnapshot?)
    case databaseOnly(HDPIMInstalledPackageSnapshot)
    case delta(HDPIMInstalledPackageSnapshot, DeltaPackageInfo)

    var requiresExtraction: Bool {
        if case .databaseOnly = self { return false }
        return true
    }
}

struct HDPIMPlannedPackage {
    let package: PackageToInstall
    let material: HDPIMPackageMaterial
    let mode: HDPIMPackageExecutionMode
    let fullFallbackReason: String?
}

enum HDPIMInstallPlanner {
    static func plan(
        package: PackageToInstall,
        installedPackages: [HDPIMInstalledPackageSnapshot],
        failedDeltaVersions: Set<String>,
        forceFullInstall: Bool
    ) throws -> HDPIMPlannedPackage {
        let material = try HDPIMPackageMaterial.resolve(package.parsed, compressionType: package.compressionType)
        let normalizedPackage = package.selecting(material)
        let targetVersion = package.parsed.packageVersion.isEmpty ? package.version : package.parsed.packageVersion
        let same = installedPackages.first { $0.packageVersion == targetVersion }
        let requiresFileInstallation = forceFullInstall || same?.canReuseInstallation == false
        if !requiresFileInstallation, let same {
            return HDPIMPlannedPackage(package: normalizedPackage, material: material,
                                       mode: .databaseOnly(same), fullFallbackReason: nil)
        }
        if material.kind == .full {
            return HDPIMPlannedPackage(package: normalizedPackage, material: material,
                                       mode: .full(installedPackages.first), fullFallbackReason: nil)
        }
        guard let delta = material.delta else {
            throw HDPIMMaterialError.invalid("\(package.packageName) 缺少已选差分信息")
        }
        let base = installedPackages.first { $0.packageVersion == delta.basePackageVersion }
        if let base, base.canReuseInstallation, !requiresFileInstallation, !failedDeltaVersions.contains(base.packageVersion) {
            return HDPIMPlannedPackage(package: normalizedPackage, material: material,
                                       mode: .delta(base, delta), fullFallbackReason: nil)
        }
        let reason = requiresFileInstallation || base?.canReuseInstallation == false ? "当前安装需要完整修复" :
            (base == nil ? "未找到有效的 BasePackageVersion=\(delta.basePackageVersion)" : "此旧版本存在差分失败记录")
        let full = try material.selectingFull()
        return HDPIMPlannedPackage(package: package.selecting(full), material: full,
                                   mode: .full(installedPackages.first), fullFallbackReason: reason)
    }
}

extension PackageToInstall {
    func selecting(_ material: HDPIMPackageMaterial) -> PackageToInstall {
        var selected = material.selected.applying(to: parsed)
        selected.material = material
        return PackageToInstall(sapCode: sapCode, version: version, platform: platform,
                                packageName: packageName, parsed: selected, applicationInfo: applicationInfo,
                                zipPath: sapDir.appendingPathComponent(material.selected.fileName), sapDir: sapDir,
                                compressionType: material.selected.compressionType, aliasPackageName: aliasPackageName,
                                productInstallDir: productInstallDir)
    }
}

enum HDPIMInstallMaterialPreparer {
    static func diffJSON(for plan: HDPIMPlannedPackage, extracted: HDPIMExtractionResult,
                         allowNetwork: Bool) async throws -> URL {
        guard let delta = plan.material.delta else {
            throw HDPIMMaterialError.invalid("缺少已选差分材料")
        }
        let expectedName = URL(fileURLWithPath: delta.metadataFilePath).lastPathComponent
        let exact = extracted.diffJSONURLs.filter { $0.lastPathComponent == expectedName }
        if exact.count == 1, let url = exact.first { return url }
        let generic = extracted.diffJSONURLs.filter { $0.lastPathComponent == "diff.json" }
        if exact.isEmpty, generic.count == 1, let url = generic.first { return url }
        guard exact.isEmpty, generic.isEmpty else {
            throw HDPIMMaterialError.invalid("差分元数据不唯一：\(plan.package.packageName)")
        }
        let sibling = plan.package.sapDir.appendingPathComponent(expectedName)
        if HDPIMPackageMaterial.isLeafName(expectedName), FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        guard allowNetwork else {
            throw HDPIMMaterialError.unavailable("离线安装缺少差分元数据：\(expectedName)")
        }
        let url = try plan.material.resolvedDownloadURL(for: delta.metadataFilePath)
        let token = PDMTransferCancellation()
        let operation = HDPIMOperationContext.cancellation
        let registration = operation?.register { token.cancel() }
        defer { if let registration { operation?.unregister(registration) } }
        let response = try await PDMHttpCommunicator(cancellation: token).sendRequest(PDMHTTPRequestConfig(
            url: url.absoluteString, method: "GET", headers: NetworkConstants.downloadHeaders.map { ($0.key, $0.value) },
            useCookie: false, autoRedirect: true, validateSSL: true, timeoutSeconds: 60
        ))
        try HDPIMOperationContext.checkCancellation()
        guard response.isSuccess, !response.data.isEmpty else {
            throw HDPIMMaterialError.unavailable("差分元数据请求失败：HTTP \(response.statusCode)")
        }
        _ = try JSONSerialization.jsonObject(with: response.data)
        let destination = extracted.extractRoot.appendingPathComponent("downloaded-diff.json")
        try response.data.write(to: destination, options: .atomic)
        return destination
    }

    /// 仅为已确认的差分回退补齐材料；原始下载缺失或损坏仍交回下载管理处理。
    static func prepareFullFallback(
        _ plan: HDPIMPlannedPackage,
        allowNetwork: Bool,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        guard plan.fullFallbackReason != nil, plan.mode.requiresExtraction else { return }
        try HDPIMOperationContext.checkCancellation()
        let package = plan.package
        let payload = plan.material.selected
        let identity = DownloadArtifactStore.Identity(name: payload.fileName, version: package.parsed.packageVersion,
                                                      hashKey: payload.hashKey)
        if FileManager.default.fileExists(atPath: package.zipPath.path) {
            progress(0, "正在校验全量材料：\(package.packageName)")
            _ = try DownloadArtifactStore.verify(fileURL: package.zipPath, identity: identity,
                                                 expectedSize: payload.downloadSize,
                                                 cancellationCheck: { HDPIMOperationContext.cancellation?.isCancelled == true })
            progress(1, "全量材料已就绪：\(package.packageName)")
            return
        }
        guard allowNetwork else {
            throw HDPIMMaterialError.unavailable("离线安装缺少 \(payload.fileName)，请先补齐全量材料")
        }
        let url = try plan.material.resolvedDownloadURL(for: payload.path)
        let validationURLs = try payload.validationURLs.map { try plan.material.resolvedDownloadURL(for: $0).absoluteString }
        guard !validationURLs.isEmpty || !payload.hashKey.isEmpty else {
            throw HDPIMMaterialError.unavailable("\(payload.fileName) 缺少完整性校验来源")
        }
        progress(0, "正在连接全量材料下载：\(package.packageName)")
        let task = Task {
            await PDMDownloadEngine.shared.downloadFile(
                packageId: "install-full-\(UUID().uuidString)", url: url, destinationURL: package.zipPath,
                headers: NetworkConstants.downloadHeaders, expectedTotalSize: payload.downloadSize,
                validationURLs: validationURLs, artifactIdentity: identity,
                progressHandler: { current, total, _, phase in
                    let fraction = total > 0 ? min(max(Double(current) / Double(total), 0), 1) : 0
                    let message: String
                    switch phase {
                    case .waiting: message = "正在等待全量材料下载：\(package.packageName)"
                    case .transferring: message = "正在补齐全量材料：\(package.packageName) \(Int(fraction * 100))%"
                    case .validating: message = "正在校验全量材料：\(package.packageName)"
                    }
                    progress(fraction, message)
                }
            )
        }
        let cancellation = HDPIMOperationContext.cancellation
        let registration = cancellation?.register { task.cancel() }
        defer { if let registration { cancellation?.unregister(registration) } }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        try HDPIMOperationContext.checkCancellation()
        switch result {
        case .completed:
            progress(1, "正在校验全量材料：\(package.packageName)")
            _ = try DownloadArtifactStore.verify(fileURL: package.zipPath, identity: identity,
                                                 expectedSize: payload.downloadSize,
                                                 cancellationCheck: { cancellation?.isCancelled == true })
            progress(1, "全量材料已就绪：\(package.packageName)")
        case .cancelled, .paused:
            throw CancellationError()
        case .error(let error):
            throw HDPIMMaterialError.unavailable("\(payload.fileName)：\(error.localizedDescription)")
        }
    }
}

final class HDPIMPreparationProgress {
    private let lock = NSLock()
    private var fractions: [Double]
    private var lastStep = -1
    private var lastStatus: String?
    private let handler: (Double, String) -> Void

    init(count: Int, handler: @escaping (Double, String) -> Void) {
        fractions = [Double](repeating: 0, count: count)
        self.handler = handler
    }

    func update(index: Int, fraction: Double, name: String, status: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        fractions[index] = max(fractions[index], min(max(fraction, 0), 1))
        let progress = fractions.reduce(0, +) / Double(max(fractions.count, 1))
        let step = Int(progress * 100)
        let message = status ?? "正在解压并预检 \(name)... \(step)%"
        guard step != lastStep || message != lastStatus else { return }
        lastStep = step
        lastStatus = message
        handler(0.1 + progress * 0.44, message)
    }
}
