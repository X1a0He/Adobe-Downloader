import Foundation

enum X1a0HeCCComponents {
    static let names = ["HDBox", "IPCBox"]
    static let root = URL(fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common", isDirectory: true)

    struct Component {
        let name: String
        let version: String
        let present: Bool
        let issues: [String]
        var isComplete: Bool { issues.isEmpty }
    }

    static func inspect(at base: URL = root) -> [Component] {
        names.map { inspect(name: $0, directory: base.appendingPathComponent($0, isDirectory: true)) }
    }

    static func requireComplete(at base: URL = root) throws {
        let issues = inspect(at: base).flatMap(\.issues)
        guard issues.isEmpty else {
            throw HDPIMMaterialError.unavailable("X1a0He CC 组件不完整：" + issues.joined(separator: "；"))
        }
    }

    static func inspect(name: String, directory: URL) -> Component {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let present = manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        var issues: [String] = []
        let pimx = directory.appendingPathComponent(name + ".pimx")
        let version = PIMXParser.readPackageVersion(from: pimx)
        var required = name == "HDBox"
            ? ["Setup", "HDHelper", "HDPIM.dylib", "HDIM.dylib", "HUM.dylib",
               "Uninstaller.app/Contents/Info.plist", "Uninstaller.app/Contents/MacOS/Uninstaller"]
            : ["AdobeIPCBroker.app/Contents/Info.plist", "AdobeIPCBroker.app/Contents/MacOS/AdobeIPCBroker"]
        if let data = try? PIMXParser.loadXMLData(from: pimx, writeBackIfNeeded: false),
           let document = try? XMLDocument(data: data),
           let root = document.rootElement(), root.name == "package_installation_info",
           root.elements(forName: "name").first?.stringValue == name, !version.isEmpty {
            if let encoded = try? root.nodes(forXPath: "packages/pimaInfo/validation_info/validation_xml").first?.stringValue,
               let validationData = Data(base64Encoded: encoded),
               let validation = try? XMLDocument(data: validationData),
               let paths = try? validation.nodes(forXPath: "//File/InstallPath"), !paths.isEmpty {
                for path in paths.compactMap(\.stringValue) {
                    let relative = String(path.drop(while: { $0 == "/" }))
                    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
                    if relative.isEmpty || relative.contains("\0") || components.contains("..") || components.contains(".") {
                        issues.append("\(name) 校验清单路径无效")
                    } else {
                        required.append(relative)
                    }
                }
            } else {
                issues.append("\(name) 缺少有效的文件清单")
            }
        } else {
            issues.append("\(name) 包身份或版本信息无效")
        }
        let resolvedRoot = directory.resolvingSymlinksInPath().path
        for relative in Set(required).sorted() {
            let file = directory.appendingPathComponent(relative)
            guard file.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/"),
                  let attributes = try? manager.attributesOfItem(atPath: file.resolvingSymlinksInPath().path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
                issues.append("\(name) 缺少或损坏：\(relative)")
                continue
            }
        }
        let app = name == "HDBox" ? "Uninstaller" : "AdobeIPCBroker"
        let info = directory.appendingPathComponent("\(app).app/Contents/Info.plist")
        if let data = try? Data(contentsOf: info),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           plist["CFBundleExecutable"] as? String == app,
           manager.isExecutableFile(atPath: directory.appendingPathComponent("\(app).app/Contents/MacOS/\(app)").path) {
            // 包版本取 PIMX；AdobeIPCBroker 的 CFBundleVersion 是独立程序版本。
        } else {
            issues.append("\(name) 的 \(app).app 不可用")
        }
        return Component(name: name, version: version, present: present, issues: issues)
    }
}

actor X1a0HeCCInstaller {
    static let shared = X1a0HeCCInstaller()
    private var installing = false
    private var productLease: UUID?

    func reserveForProductInstallation() throws -> UUID {
        guard !installing, productLease == nil else {
            throw HDPIMMaterialError.unavailable("X1a0He CC 或产品安装正在进行，请等待当前操作完成")
        }
        let lease = UUID()
        productLease = lease
        return lease
    }

    func releaseProductInstallation(_ lease: UUID) {
        if productLease == lease { productLease = nil }
    }

    func install(
        force: Bool = false,
        productLease requestedLease: UUID? = nil,
        progress: @escaping (Double, String) -> Void,
        log: ((String) -> Void)? = nil,
        cancellationCheck: @escaping () -> Bool
    ) async throws {
        guard !installing, productLease == requestedLease else {
            throw HDPIMMaterialError.unavailable("X1a0He CC 或产品安装正在进行，请等待当前操作完成")
        }
        if !force && X1a0HeCCComponents.inspect().allSatisfy(\.isComplete) { return }
        installing = true
        defer { installing = false }
        let cancellation = PDMTransferCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        let monitor = Task {
            while !Task.isCancelled {
                if cancellationCheck() {
                    cancellation.cancel()
                    session.invalidateAndCancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { monitor.cancel(); session.finishTasksAndInvalidate() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("X1a0HeCC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let check = {
            if Task.isCancelled || cancellationCheck() || cancellation.isCancelled { throw CancellationError() }
        }
        var expectedVersions: [String: String] = [:]
        do {
            try check()
            progress(0, "正在修复 X1a0He CC 组件...")
            let platform = AppStatics.isAppleSilicon ? "macarm64" : "osx10"
            let catalogURL = try officialURL("https://cdn-ffc.oobesaas.adobe.com/core/v1/applications?name=CreativeCloud&platform=\(platform)")
            let catalog = try XMLDocument(data: await data(catalogURL, session: session, cancellation: cancellation))
            let cdn = try text(catalog, "//cdn/secure")
            guard let packageSet = try catalog.nodes(forXPath: "//packageSet[name='ADC']").first else {
                throw HDPIMMaterialError.invalid("官方目录缺少 ADC 包集")
            }
            for (index, name) in X1a0HeCCComponents.names.enumerated() {
                try check()
                guard let package = try packageSet.nodes(forXPath: "packages/package[name='\(name)']").first else {
                    throw HDPIMMaterialError.invalid("官方目录缺少 \(name)")
                }
                let version = try text(package, "version")
                let manifestURL = try officialURL(try text(package, "manifestUrl"), relativeTo: cdn)
                let manifest = try XMLDocument(data: await data(manifestURL, session: session, cancellation: cancellation))
                let assets = try manifest.nodes(forXPath: "//asset")
                guard assets.count == 1, let asset = assets.first,
                      let size = Int64(try text(asset, "asset_size")), size > 0 else {
                    throw HDPIMMaterialError.invalid("\(name) 下载清单无效")
                }
                let assetURL = try officialURL(try text(asset, "asset_path"), relativeTo: manifestURL.absoluteString)
                let validationPath = try (try? text(asset, "validation_urls/type2"))
                    ?? (try? text(asset, "validation_urls/type1"))
                    ?? (try text(asset, "validation_data"))
                let validationURL = try officialURL(validationPath, relativeTo: manifestURL.absoluteString)
                let validationData = try await data(validationURL, session: session, cancellation: cancellation)
                guard let validation = ValidationInfo.parse(from: String(decoding: validationData, as: UTF8.self)) else {
                    throw HDPIMMaterialError.invalid("\(name) 官方摘要无效")
                }
                let preceding = Int64(validation.segmentCount - 1).multipliedReportingOverflow(by: validation.segmentSize)
                let total = preceding.partialValue.addingReportingOverflow(validation.lastSegmentSize)
                guard !preceding.overflow, !total.overflow, total.partialValue == size else {
                    throw HDPIMMaterialError.invalid("\(name) 官方摘要覆盖长度不一致")
                }
                progress(Double(index) * 0.4 + 0.05, "正在下载 \(name) \(version)...")
                let (download, response) = try await PDMRequestScheduler.shared.withPermit(cancellation: cancellation) {
                    try await session.download(for: self.request(assetURL))
                }
                try validate(response)
                let archive = temporary.appendingPathComponent(name + ".zip")
                try FileManager.default.moveItem(at: download, to: archive)
                try check()
                let validator = PDMValidationManager(communicator: PDMHttpCommunicator())
                guard try validator.validateFile(at: archive, validationInfo: validation, totalSize: size) else {
                    throw HDPIMMaterialError.invalid("\(name) 下载内容校验失败")
                }
                let directory = temporary.appendingPathComponent(name, isDirectory: true)
                _ = try await HDPIMExtractionCoordinator().extract(
                    request: HDPIMExtractionRequest(sourceURL: archive, destinationURL: directory, compressionType: "",
                        packageName: name, validationURL: nil, isDMG: false, allowOverlap: false),
                    cancellationCheck: { cancellationCheck() || cancellation.isCancelled }
                )
                let status = X1a0HeCCComponents.inspect(name: name, directory: directory)
                guard status.isComplete, status.version == version else {
                    throw HDPIMMaterialError.invalid("\(name) 解压后身份或完整性不符：" + status.issues.joined(separator: "；"))
                }
                expectedVersions[name] = version
            }
            try check()
        } catch {
            if Task.isCancelled || cancellationCheck() || cancellation.isCancelled { throw CancellationError() }
            throw error
        }
        progress(0.85, "正在安装 X1a0He CC 组件...")
        try await publish(temporary, versions: expectedVersions, check: check, log: log)
        progress(1, "X1a0He CC 组件已就绪")
    }

    func publish(_ source: URL, at root: URL = X1a0HeCCComponents.root,
                 versions: [String: String], check: () throws -> Void,
                 log: ((String) -> Void)?,
                 execute: (String) async throws -> String = { try await HelperManager.shared.executeShell($0) }) async throws {
        let identifier = UUID().uuidString
        let stage = root.appendingPathComponent(".X1a0HeCC-stage-" + identifier)
        let recovery = root.appendingPathComponent(".X1a0HeCC-recovery-" + identifier)
        var preparation = ["set -eu", "/bin/mkdir -p \(quote(root.path))",
                           "/bin/mkdir -m 755 \(quote(stage.path))"]
        for name in X1a0HeCCComponents.names {
            let destination = stage.appendingPathComponent(name).path
            preparation.append("/usr/bin/ditto \(quote(source.appendingPathComponent(name).path)) \(quote(destination))")
        }
        preparation.append("/usr/sbin/chown -R root:wheel \(quote(stage.path))")
        _ = try await execute(preparation.joined(separator: "\n"))
        try X1a0HeCCComponents.requireComplete(at: stage)
        try check()

        // 只有两个包均完成校验才替换；失败时将新组件移入恢复目录并归还旧组件。
        var rollback = ["status=$?", "trap - EXIT", "set +e", "rollback_status=0"]
        for name in X1a0HeCCComponents.names.reversed() {
            let target = quote(root.appendingPathComponent(name).path)
            let original = quote(recovery.appendingPathComponent(name).path)
            let failed = quote(recovery.appendingPathComponent(name + "-failed").path)
            rollback.append("if [ \"$installed_\(name)\" = 1 ]; then /bin/mv \(target) \(failed) || rollback_status=1; fi")
            rollback.append("if [ \"$saved_\(name)\" = 1 ]; then /bin/mv \(original) \(target) || rollback_status=1; fi")
        }
        rollback += ["if [ \"$rollback_status\" != 0 ]; then echo \(quote("组件恢复未完成，请保留恢复目录：" + recovery.path)) >&2; fi",
                     "exit \"$status\""]
        var commit = ["set -eu", "/bin/mkdir -m 700 \(quote(recovery.path))"]
        for name in X1a0HeCCComponents.names { commit += ["saved_\(name)=0", "installed_\(name)=0"] }
        commit += ["rollback() {\n" + rollback.joined(separator: "\n") + "\n}", "trap rollback EXIT"]
        for name in X1a0HeCCComponents.names {
            let target = quote(root.appendingPathComponent(name).path)
            let original = quote(recovery.appendingPathComponent(name).path)
            commit.append("if [ -e \(target) ] || [ -L \(target) ]; then /bin/mv \(target) \(original); saved_\(name)=1; fi")
            commit += ["/bin/mv \(quote(stage.appendingPathComponent(name).path)) \(target)", "installed_\(name)=1"]
        }
        commit.append("trap - EXIT")
        _ = try await execute(commit.joined(separator: "\n"))
        do {
            try check()
            let installed = X1a0HeCCComponents.inspect(at: root)
            guard installed.allSatisfy({ $0.isComplete && versions[$0.name] == $0.version }) else {
                throw HDPIMMaterialError.invalid("X1a0He CC 安装后复核失败")
            }
            // 此检查通过即提交成功；其后的取消不再改写组件安装结果。
            try check()
        } catch {
            var restore = ["set -eu"]
            for name in X1a0HeCCComponents.names.reversed() {
                let target = quote(root.appendingPathComponent(name).path)
                let original = quote(recovery.appendingPathComponent(name).path)
                restore.append("/bin/mv \(target) \(quote(recovery.appendingPathComponent(name + "-failed").path))")
                restore.append("if [ -e \(original) ] || [ -L \(original) ]; then /bin/mv \(original) \(target); fi")
            }
            do { _ = try await execute(restore.joined(separator: "\n")) }
            catch { throw HDPIMMaterialError.unavailable("组件恢复未完成：\(error.localizedDescription)；恢复目录：\(recovery.path)") }
            throw error
        }
        log?("[X1a0He CC] 组件校验及安装完成；原组件保留于 \(recovery.path)")
    }

    private func data(_ url: URL, session: URLSession, cancellation: PDMTransferCancellation) async throws -> Data {
        let (data, response) = try await PDMRequestScheduler.shared.withPermit(cancellation: cancellation) {
            try await session.data(for: self.request(url))
        }
        try validate(response)
        return data
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let url = http.url else { throw NetworkError.invalidResponse }
        _ = try officialURL(url.absoluteString)
    }

    private func officialURL(_ value: String, relativeTo base: String? = nil) throws -> URL {
        guard let url = URL(string: value, relativeTo: base.flatMap(URL.init(string:)))?.absoluteURL,
              url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".adobe.com") || host.hasSuffix(".adobe.io"),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw HDPIMMaterialError.invalid("组件下载地址不是 Adobe HTTPS 来源")
        }
        return url
    }

    private func text(_ node: XMLNode, _ path: String) throws -> String {
        guard let value = try node.nodes(forXPath: path).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { throw HDPIMMaterialError.invalid("组件清单缺少 \(path)") }
        return value
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
