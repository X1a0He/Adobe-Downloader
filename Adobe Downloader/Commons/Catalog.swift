import Foundation
import CryptoKit
import Darwin

struct CatalogRequestContext: Equatable, Sendable {
    let apiVersion: String
    let architecture: HDPIMParityTargetArchitecture
    let platforms: [String]
    let channels: [String]
    let headers: [String: String]
    let authenticationScope: String

    @MainActor
    static func capture() -> CatalogRequestContext {
        let version = StorageData.shared.apiVersion
        let architecture = HDPIMParityTargetArchitecture.currentSelection
        var headers = NetworkConstants.ffcRequestHeaders
        headers["x-api-key"] = "Creative Cloud_v\(version)_4"
        let scope = SHA256.hash(data: Data((headers["Authorization"] ?? "").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CatalogRequestContext(
            apiVersion: version, architecture: architecture,
            platforms: architecture.catalogPlatformIds, channels: ["ccm", "sti", "nocc"],
            headers: headers, authenticationScope: scope
        )
    }

    func url(channels: [String], platforms: [String]) throws -> URL {
        let endpoint = "https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v\(apiVersion)/products/all"
        var components = URLComponents(string: endpoint)
        components?.queryItems = channels.map { URLQueryItem(name: "channel", value: $0) }
            + platforms.map { URLQueryItem(name: "platform", value: $0) }
            + [URLQueryItem(name: "payload", value: "true"),
               URLQueryItem(name: "productType", value: "Desktop"),
               URLQueryItem(name: "_type", value: "xml")]
        guard let url = components?.url else { throw NetworkError.invalidURL(endpoint) }
        return url
    }
}

struct CatalogBuildMetadata: Codable, Equatable {
    var entitled: String
    var maintenanceBuild: String
    var goLiveTime: String
    var licensing: [String: String]
}

struct CatalogAvailability: Codable, Equatable {
    var isVersionDisabled = false
    var showInNewApps: String?
}

struct CatalogBuildIdentity: Hashable, Comparable {
    let fields: [String]

    init(product: Product, platform: Product.Platform, languageSet: Product.Platform.LanguageSet) {
        fields = [product.catalogChannel ?? "", product.id, product.version, platform.id]
            + languageSet.catalogIdentity
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.fields.lexicographicallyPrecedes(rhs.fields)
    }
}

extension Product.Platform.LanguageSet {
    var catalogIdentity: [String] {
        [name, packageType ?? "", baseVersion, productVersion, buildGuid]
            + (buildGuid.isEmpty ? [productCode, manifestURL, lbsURL] : [])
    }

    var declaredLocales: Set<String> {
        Set((locales ?? []).map { $0.replacingOccurrences(of: "-", with: "_").lowercased() })
    }

    func usesEnglishFallback(for locale: String?) -> Bool {
        guard let locale else { return false }
        let requested = locale.replacingOccurrences(of: "-", with: "_").lowercased()
        let supported = declaredLocales
        return requested != "all" && !supported.contains(requested)
            && !supported.contains("mul") && supported.contains("en_us")
    }
}

enum CatalogSelection {
    static func productCandidate(
        _ product: Product, architecture: HDPIMParityTargetArchitecture, locale: String?
    ) throws -> CatalogCandidate {
        if isManifestInstallerProduct(product.id) {
            let match = try catalogInstallerMatch(product: product, targetArchitecture: architecture, requestedLanguage: locale)
            return CatalogCandidate(product: product, platform: match.platform, languageSet: match.languageSet)
        }
        var languageError: Error?
        for platformID in architecture.platformPreference {
            for platform in product.platforms.filter({ $0.id == platformID }) {
                do {
                    let language = try languageSet(platform.languageSet, locale: locale)
                    return CatalogCandidate(product: product, platform: platform, languageSet: language)
                } catch { languageError = error }
            }
        }
        throw languageError ?? NetworkError.unsupportedPlatform("产品 \(product.id) 没有可用平台")
    }

    static func languageSet(
        _ candidates: [Product.Platform.LanguageSet],
        locale: String?,
        installer: Bool = false,
        allowEnglishFallback: Bool = false
    ) throws -> Product.Platform.LanguageSet {
        guard !candidates.isEmpty else { throw NetworkError.invalidData("没有可用语言组") }
        let materials = installer ? candidates : candidates.filter { $0.packageType == "hdPackage" }
        guard !materials.isEmpty else {
            throw NetworkError.invalidData("此版本没有可用于普通下载的 hdPackage 安装包")
        }
        let enabled = materials.filter { $0.catalogAvailability?.isVersionDisabled != true }
        guard !enabled.isEmpty else {
            throw NetworkError.invalidData("此版本已被 Adobe 禁用")
        }
        var eligible = enabled
        let requested = locale?.replacingOccurrences(of: "-", with: "_").lowercased()
        if requested == "all" {
            let declared = enabled.reduce(into: Set<String>()) { $0.formUnion($1.declaredLocales) }
            if enabled.count > 1 {
                eligible = enabled.filter {
                    !$0.declaredLocales.isEmpty && $0.declaredLocales.isSuperset(of: declared)
                }
                // 同一语言组的不同材料仍是一次构建选择。
                if eligible.isEmpty && declared.isEmpty && Set(enabled.map(\.name)).count == 1 {
                    eligible = enabled
                }
            }
            guard !eligible.isEmpty else {
                throw NetworkError.invalidData("此版本的语言分布在多个语言组，请选择具体语言")
            }
        } else if let requested {
            let exact = enabled.filter { $0.declaredLocales.contains(requested) }
            eligible = exact.isEmpty
                ? enabled.filter { $0.declaredLocales.contains("mul") }
                : exact
            if eligible.isEmpty && allowEnglishFallback {
                eligible = enabled.filter { $0.declaredLocales.contains("en_us") }
            }
            guard !eligible.isEmpty else {
                let fallback = allowEnglishFallback ? "，且不支持回退语言 en_US" : ""
                throw NetworkError.invalidData("此版本不支持语言 \(locale ?? "")\(fallback)")
            }
        }
        return eligible.sorted {
            let version = AppStatics.compareVersions($0.productVersion, $1.productVersion)
            if version != 0 { return version > 0 }
            return $0.catalogIdentity.lexicographicallyPrecedes($1.catalogIdentity)
        }[0]
    }

    static func dependencyPlatforms(_ target: String, architecture: HDPIMParityTargetArchitecture) -> [String] {
        if architecture == .appleSilicon {
            switch target.lowercased() {
            case "macuniversal": return ["macuniversal", "osx10-64", "osx10"]
            case "osx10-64": return ["osx10-64", "osx10"]
            case "osx10": return ["osx10"]
            default: return ["macarm64", "macuniversal", "osx10-64", "osx10"]
            }
        }
        switch target.lowercased() {
        case "macarm64", "macuniversal": return ["macuniversal", "osx10-64", "osx10"]
        case "osx10": return ["osx10", "osx10-64", "macuniversal"]
        default: return ["osx10-64", "osx10", "macuniversal"]
        }
    }
}

struct CatalogCandidate {
    let product: Product
    let platform: Product.Platform
    let languageSet: Product.Platform.LanguageSet
    var identity: CatalogBuildIdentity {
        CatalogBuildIdentity(product: product, platform: platform, languageSet: languageSet)
    }
    var cdn: String { product.channelCDN ?? "" }
}

struct CatalogIndex {
    let productsBySAP: [String: [Product]]
    let candidatesBySAP: [String: [CatalogCandidate]]
    let candidatesByBaseline: [[String]: [CatalogCandidate]]
    let builds: [CatalogBuildIdentity: CatalogCandidate]

    init(products: [Product]) {
        productsBySAP = Dictionary(grouping: products, by: \.id)
        var bySAP: [String: [CatalogCandidate]] = [:]
        var byBaseline: [[String]: [CatalogCandidate]] = [:]
        var builds: [CatalogBuildIdentity: CatalogCandidate] = [:]
        for product in products {
            for platform in product.platforms {
                for languageSet in platform.languageSet {
                    let candidate = CatalogCandidate(product: product, platform: platform, languageSet: languageSet)
                    guard builds[candidate.identity] == nil else { continue }
                    builds[candidate.identity] = candidate
                    bySAP[product.id, default: []].append(candidate)
                    byBaseline[[product.id, languageSet.baseVersion], default: []].append(candidate)
                }
            }
        }
        candidatesBySAP = bySAP
        candidatesByBaseline = byBaseline
        self.builds = builds
    }

    func dependency(
        _ declaration: Product.Platform.LanguageSet.Dependency,
        architecture: HDPIMParityTargetArchitecture,
        locale: String? = nil
    ) throws -> CatalogCandidate {
        let sap = declaration.sapCode
        guard candidatesBySAP[sap] != nil else {
            throw NetworkError.invalidData("依赖 \(sap) 不在本次目录中")
        }
        var candidates = candidatesByBaseline[[sap, declaration.baseVersion]] ?? []
        guard !candidates.isEmpty else {
            throw NetworkError.invalidData("依赖 \(sap) 缺少精确 BaseVersion \(declaration.baseVersion)")
        }
        let channels = Set(declaration.declaredChannels ?? [])
        if !channels.isEmpty {
            candidates = candidates.filter { channels.contains($0.product.catalogChannel ?? "") }
            guard !candidates.isEmpty else {
                throw NetworkError.invalidData("依赖 \(sap) 的基线 \(declaration.baseVersion) 不在声明频道 \(channels.sorted().joined(separator: ", ")) 中")
            }
        }
        let preference = CatalogSelection.dependencyPlatforms(
            declaration.declaredPlatform ?? declaration.selectedPlatform, architecture: architecture
        )
        candidates = candidates.filter { preference.contains($0.platform.id) }
        guard !candidates.isEmpty else {
            throw NetworkError.unsupportedPlatform("依赖 \(sap) 的精确基线没有兼容平台")
        }
        let groups = Dictionary(grouping: candidates) {
            [$0.product.catalogChannel ?? "", $0.product.id, $0.product.version, $0.platform.id]
        }.values.sorted { lhs, rhs in
            let left = lhs[0], right = rhs[0]
            let order = AppStatics.compareVersions(left.product.version, right.product.version)
            if order != 0 { return order > 0 }
            let lp = preference.firstIndex(of: left.platform.id) ?? Int.max
            let rp = preference.firstIndex(of: right.platform.id) ?? Int.max
            if lp != rp { return lp < rp }
            return left.identity < right.identity
        }
        var languageError: Error?
        for group in groups {
            do {
                let language = try CatalogSelection.languageSet(
                    group.map(\.languageSet), locale: locale, allowEnglishFallback: true
                )
                return group.first { $0.languageSet == language }!
            } catch {
                languageError = error
            }
        }
        if let languageError {
            throw NetworkError.invalidData("依赖 \(sap)：\(languageError.localizedDescription)")
        }
        throw NetworkError.invalidData("依赖 \(sap) 没有可用构建")
    }

    func preview(
        _ declaration: Product.Platform.LanguageSet.Dependency,
        architecture: HDPIMParityTargetArchitecture,
        locale: String? = nil
    ) -> Product.Platform.LanguageSet.Dependency {
        var result = declaration
        do {
            let match = try dependency(declaration, architecture: architecture, locale: locale)
            result.productVersion = match.product.version
            result.buildGuid = match.languageSet.buildGuid
            result.selectedPlatform = match.platform.id
            result.isMatchPlatform = true
            result.selectedReason = "已匹配精确基线及声明频道"
            if match.languageSet.usesEnglishFallback(for: locale) {
                result.selectedReason += "；依赖语言回退至 en_US"
            }
        } catch {
            result.selectedPlatform = ""
            result.isMatchPlatform = false
            result.selectedReason = error.localizedDescription
        }
        return result
    }
}

struct ParsedCatalog {
    var products: [Product] = []
    var channelCDNs: [String: String] = [:]
    var dependencyChannels: Set<String> = []

    mutating func merge(_ other: ParsedCatalog) {
        products = NewParseResult(products: products, cdn: "").merged(
            with: NewParseResult(products: other.products, cdn: "")
        ).products
        channelCDNs.merge(other.channelCDNs) { left, right in
            left.isEmpty ? right : (right.isEmpty ? left : min(left, right))
        }
        dependencyChannels.formUnion(other.dependencyChannels)
    }
}

struct CatalogMeasurements {
    var requests: TimeInterval = 0
    var decoding: TimeInterval = 0
    var mergingAndIndexing: TimeInterval = 0
    var dependencies: TimeInterval = 0
    var projection: TimeInterval = 0
    var responseBytes = 0
    var peakResidentBytes: Int64 = 0
}

final class CatalogSnapshot: @unchecked Sendable {
    let generation: UUID
    let context: CatalogRequestContext
    let index: CatalogIndex
    let allProducts: [Product]
    let ccm: NewParseResult
    let sti: NewParseResult
    let visibleProducts: [Product]
    let uniqueProducts: [UniqueProduct]
    let channelCDNs: [String: String]
    let measurements: CatalogMeasurements

    var cdn: String { ccm.cdn.isEmpty ? sti.cdn : ccm.cdn }

    init(parsed: ParsedCatalog, context: CatalogRequestContext, generation: UUID, measurements: CatalogMeasurements) throws {
        self.context = context
        self.generation = generation
        var metrics = measurements
        var start = ProcessInfo.processInfo.systemUptime
        let catalogIndex = CatalogIndex(products: parsed.products)
        index = catalogIndex
        metrics.mergingAndIndexing += ProcessInfo.processInfo.systemUptime - start
        start = ProcessInfo.processInfo.systemUptime
        var resolved: [Product] = []
        var previews: [[String]: Product.Platform.LanguageSet.Dependency] = [:]
        for var product in parsed.products {
            try Task.checkCancellation()
            for p in product.platforms.indices {
                for l in product.platforms[p].languageSet.indices {
                    product.platforms[p].languageSet[l].dependencies = product.platforms[p].languageSet[l].dependencies.map { declaration in
                        let key = [declaration.sapCode, declaration.baseVersion, declaration.declaredPlatform ?? "",
                                   declaration.productVersion, declaration.buildGuid, declaration.targetPlatform]
                            + (declaration.declaredChannels ?? []).sorted()
                        if let preview = previews[key] { return preview }
                        let preview = catalogIndex.preview(declaration, architecture: context.architecture)
                        previews[key] = preview
                        return preview
                    }
                }
            }
            resolved.append(product)
        }
        allProducts = resolved
        metrics.dependencies = ProcessInfo.processInfo.systemUptime - start
        start = ProcessInfo.processInfo.systemUptime
        channelCDNs = parsed.channelCDNs
        let ccmProducts = resolved.filter { $0.catalogChannel == "ccm" }
        ccm = NewParseResult(products: ccmProducts, cdn: parsed.channelCDNs["ccm"] ?? "")
        sti = NewParseResult(products: resolved.filter { $0.catalogChannel == "sti" }, cdn: parsed.channelCDNs["sti"] ?? "")
        visibleProducts = ccmProducts.filter {
            !isBlockedVisibleProduct($0.id)
                && HDPIMParityDecisionEngine.shared.hasVisibleVersion(product: $0, targetArchitecture: context.architecture)
        }
        var unique: [String: UniqueProduct] = [:]
        for product in visibleProducts {
            unique[product.id] = UniqueProduct(id: product.id, displayName: product.displayName)
        }
        uniqueProducts = unique.values.sorted {
            $0.displayName == $1.displayName ? $0.id < $1.id : $0.displayName < $1.displayName
        }
        metrics.projection = ProcessInfo.processInfo.systemUptime - start
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { metrics.peakResidentBytes = Int64(usage.ru_maxrss) }
        self.measurements = metrics
    }

    func product(id: String, version: String) -> Product? {
        ccm.products.first { $0.id == id && $0.version == version }
    }
}

// 后台读者只持有不可变快照；锁内仅复制/替换引用。
final class CatalogStore: @unchecked Sendable {
    static let shared = CatalogStore()
    private let lock = NSLock()
    private var value: CatalogSnapshot?

    var snapshot: CatalogSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @MainActor
    func replace(with snapshot: CatalogSnapshot?) {
        lock.lock()
        let previous = value
        value = snapshot
        lock.unlock()
        withExtendedLifetime(previous) {}
    }
}
