import Foundation

/// 下载选择的持久材料身份；DeltaPackages 只是候选集合，不能代替本次选择。
struct HDPIMPackageMaterial: Codable, Equatable {
    enum Kind: String, Codable { case full, delta }

    struct Payload: Codable, Equatable {
        let fileName: String
        let path: String
        let downloadSize: Int64
        let extractSize: Int64
        let validationURLs: [String]
        let hashKey: String
        let compressionType: String

        init(package: ParsedPackage, compressionType: String) {
            fileName = package.fullPackageName
            path = package.path
            downloadSize = package.downloadSize
            extractSize = package.extractSize
            validationURLs = [package.validationURLType2, package.validationURLType1]
                .compactMap { $0 }.filter { !$0.isEmpty }
            hashKey = package.packageHashKey
            self.compressionType = compressionType
        }

        init(delta: DeltaPackageInfo) {
            fileName = Self.deltaFileName(delta)
            path = delta.path
            downloadSize = delta.downloadSize
            extractSize = delta.extractSize
            validationURLs = delta.validationURL.isEmpty ? [] : [delta.validationURL]
            hashKey = ""
            compressionType = ""
        }

        static func deltaFileName(_ delta: DeltaPackageInfo) -> String {
            if !delta.packageName.isEmpty {
                return delta.packageName.hasSuffix(".zip") ? delta.packageName : delta.packageName + ".zip"
            }
            return URL(fileURLWithPath: delta.path).lastPathComponent
        }

        func applying(to package: ParsedPackage) -> ParsedPackage {
            var result = package
            result.fullPackageName = fileName
            result.path = path
            result.downloadSize = downloadSize
            result.extractSize = extractSize
            result.packageHashKey = hashKey
            result.validationURLType2 = validationURLs.first
            result.validationURLType1 = validationURLs.dropFirst().first
            return result
        }
    }

    static let jsonKey = "AdobeDownloaderMaterial"
    let schemaVersion: Int
    let logicalPackageName: String
    let packageVersion: String
    let kind: Kind
    let selected: Payload
    let full: Payload?
    let delta: DeltaPackageInfo?
    var sourceBaseURL: String? = nil

    static func recording(
        original: ParsedPackage,
        selectedFileName: String,
        deltaBaseVersion: String,
        compressionType: String,
        sourceBaseURL: String? = nil
    ) throws -> HDPIMPackageMaterial {
        let previous = original.material == nil ? nil : try resolve(original, compressionType: compressionType)
        let full = previous?.full ?? Payload(package: original, compressionType: compressionType)
        guard previous?.kind != .delta || previous?.full != nil else {
            throw HDPIMMaterialError.invalid("旧差分清单缺少原始全量来源：\(original.packageName)")
        }
        let source = previous?.sourceBaseURL ?? sourceBaseURL
        if deltaBaseVersion.isEmpty {
            guard selectedFileName == full.fileName else {
                throw HDPIMMaterialError.invalid("全量包文件名与原始清单不一致：\(selectedFileName)")
            }
            return HDPIMPackageMaterial(schemaVersion: 1, logicalPackageName: original.packageName,
                                        packageVersion: original.packageVersion, kind: .full,
                                        selected: full, full: full, delta: nil, sourceBaseURL: source)
        }
        let matches = original.deltaPackages.filter {
            $0.basePackageVersion == deltaBaseVersion && Payload.deltaFileName($0) == selectedFileName
        }
        guard matches.count == 1, let delta = matches.first else {
            throw HDPIMMaterialError.invalid("无法唯一确定差分材料：\(selectedFileName)，BasePackageVersion=\(deltaBaseVersion)")
        }
        return HDPIMPackageMaterial(schemaVersion: 1, logicalPackageName: original.packageName,
                                    packageVersion: original.packageVersion, kind: .delta,
                                    selected: Payload(delta: delta), full: full, delta: delta, sourceBaseURL: source)
    }

    static func resolve(_ package: ParsedPackage, compressionType: String) throws -> HDPIMPackageMaterial {
        if let error = package.materialDecodingError {
            throw HDPIMMaterialError.invalid(error)
        }
        if let material = package.material {
            try material.validate(against: package)
            return material
        }

        let matches = package.deltaPackages.filter {
            Payload.deltaFileName($0) == package.fullPackageName
                && sameResourcePath($0.path, package.path)
        }
        if matches.count == 1, let delta = matches.first {
            // 旧版本写入差分节点时覆盖了全量 Path/Size；无法从名称推造全量地址。
            return HDPIMPackageMaterial(schemaVersion: 1, logicalPackageName: package.packageName,
                                        packageVersion: package.packageVersion, kind: .delta,
                                        selected: Payload(delta: delta), full: nil, delta: delta)
        }
        guard matches.isEmpty,
              !package.fullPackageName.lowercased().contains("_delta"),
              !package.deltaPackages.contains(where: {
                  Payload.deltaFileName($0) == package.fullPackageName || sameResourcePath($0.path, package.path)
              }) else {
            throw HDPIMMaterialError.invalid("差分材料与候选身份不一致：\(package.fullPackageName)")
        }
        let full = Payload(package: package, compressionType: compressionType)
        let material = HDPIMPackageMaterial(schemaVersion: 1, logicalPackageName: package.packageName,
                                            packageVersion: package.packageVersion, kind: .full,
                                            selected: full, full: full, delta: nil)
        try material.validate(against: package)
        return material
    }

    func validate(against package: ParsedPackage) throws {
        guard schemaVersion == 1, logicalPackageName == package.packageName,
              packageVersion == package.packageVersion, !logicalPackageName.isEmpty,
              selected.fileName == package.fullPackageName,
              Self.sameResourcePath(selected.path, package.path), selected.downloadSize == package.downloadSize,
              selected.downloadSize >= 0, selected.extractSize >= 0,
              Self.isLeafName(selected.fileName) else {
            throw HDPIMMaterialError.invalid("安装材料身份与清单不一致：\(package.fullPackageName)")
        }
        switch kind {
        case .full:
            guard delta == nil, full == selected else {
                throw HDPIMMaterialError.invalid("全量材料包含冲突的差分选择：\(logicalPackageName)")
            }
        case .delta:
            guard let delta, !delta.basePackageVersion.isEmpty, !delta.metadataFilePath.isEmpty,
                  selected == Payload(delta: delta), package.deltaPackages.contains(delta) else {
                throw HDPIMMaterialError.invalid("差分材料缺少对应版本或元数据：\(logicalPackageName)")
            }
        }
        if let full, !Self.isLeafName(full.fileName) || full.path.isEmpty || full.downloadSize < 0 {
            throw HDPIMMaterialError.invalid("全量来源无效：\(logicalPackageName)")
        }
    }

    func selectingFull() throws -> HDPIMPackageMaterial {
        guard let full else {
            throw HDPIMMaterialError.invalid("旧差分目录未保存全量来源，请重新准备 \(logicalPackageName) 的全量材料")
        }
        return HDPIMPackageMaterial(schemaVersion: schemaVersion, logicalPackageName: logicalPackageName,
                                    packageVersion: packageVersion, kind: .full, selected: full, full: full, delta: nil,
                                    sourceBaseURL: sourceBaseURL)
    }

    func resolvedDownloadURL(for path: String) throws -> URL {
        let url: URL?
        if let absolute = URL(string: path), absolute.scheme != nil {
            url = absolute
        } else if let sourceBaseURL, let base = URL(string: sourceBaseURL) {
            url = URL(string: path, relativeTo: base)?.absoluteURL
        } else {
            url = nil
        }
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host.hasSuffix(".adobe.com") || host.hasSuffix(".adobe.io"),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw HDPIMMaterialError.unavailable("\(logicalPackageName) 未保存可验证的 Adobe HTTPS 来源，请重新准备全量材料")
        }
        return url
    }

    func jsonObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else {
            throw HDPIMMaterialError.invalid("无法保存安装材料身份")
        }
        return object
    }

    static func isLeafName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private static func sameResourcePath(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs }
        func path(_ value: String) -> String {
            if let url = URL(string: value), url.scheme != nil { return url.path }
            return value.removingPercentEncoding ?? value
        }
        return path(lhs) == path(rhs)
    }
}

enum HDPIMMaterialError: Error, LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "安装材料不匹配：\(reason)"
        case .unavailable(let reason): return "无法准备安装材料：\(reason)"
        }
    }
}
