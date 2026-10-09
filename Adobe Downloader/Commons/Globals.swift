//
//  Globals.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

// 目录状态通过一个不可变快照同步读取。
private var _globalNetworkService: NewNetworkService?
private var _globalNetworkManager: NetworkManager?
private var _globalNewDownloadUtils: NewDownloadUtils?
private var _globalCancelTracker: CancelTracker?

var globalStiResult: NewParseResult {
    CatalogStore.shared.snapshot?.sti ?? NewParseResult(products: [], cdn: "")
}

var globalCcmResult: NewParseResult {
    CatalogStore.shared.snapshot?.ccm ?? NewParseResult(products: [], cdn: "")
}

var globalCdn: String { CatalogStore.shared.snapshot?.cdn ?? "" }

var globalNetworkService: NewNetworkService {
    get {
        if _globalNetworkService == nil {
            fatalError("NewNetworkService 没有被初始化，请确保在应用启动时初始化")
        }
        return _globalNetworkService!
    }
    set {
        _globalNetworkService = newValue
    }
}

var globalNetworkManager: NetworkManager {
    get {
        if _globalNetworkManager == nil {
            fatalError("NetworkManager 没有被初始化，请确保在应用启动时初始化")
        }
        return _globalNetworkManager!
    }
    set {
        _globalNetworkManager = newValue
    }
}

var globalNewDownloadUtils: NewDownloadUtils {
    get {
        if _globalNewDownloadUtils == nil {
            fatalError("NewDownloadUtils 没有被初始化，请确保在应用启动时初始化")
        }
        return _globalNewDownloadUtils!
    }
    set {
        _globalNewDownloadUtils = newValue
    }
}

var globalCancelTracker: CancelTracker {
    get {
        if _globalCancelTracker == nil {
            _globalCancelTracker = CancelTracker()
        }
        return _globalCancelTracker!
    }
    set {
        _globalCancelTracker = newValue
    }
}

var globalProducts: [Product] { CatalogStore.shared.snapshot?.visibleProducts ?? [] }
var globalRawProducts: [Product] { CatalogStore.shared.snapshot?.ccm.products ?? [] }
var globalUniqueProducts: [UniqueProduct] { CatalogStore.shared.snapshot?.uniqueProducts ?? [] }

func getAllProducts() -> [Product] {
    guard let snapshot = CatalogStore.shared.snapshot else { return [] }
    return snapshot.sti.products + snapshot.ccm.products
}

func getDependencyProducts() -> [Product] {
    CatalogStore.shared.snapshot?.allProducts ?? []
}

enum ProductQueryScope {
    case visible
    case raw
    case ccm
    case sti
}

private func products(in scope: ProductQueryScope) -> [Product] {
    switch scope {
    case .visible:
        return globalProducts
    case .raw:
        return globalRawProducts
    case .ccm:
        return globalCcmResult.products
    case .sti:
        return globalStiResult.products
    }
}

/// 根据产品ID和版本号快速查找产品
/// - Parameters:
///   - id: 产品ID
///   - version: 版本号（可选）
/// - Returns: 如果提供版本号，返回指定版本的产品；否则返回最新版本的产品
func findProduct(
    id: String,
    version: String? = nil,
    scope: ProductQueryScope = .visible
) -> Product? {
    let productPool = products(in: scope)
    guard let product = productPool.first(where: { $0.id == id }) else {
        return nil
    }
    
    // 如果没有指定版本，直接返回找到的产品
    guard let version = version else {
        return product
    }

    if let matchedProduct = productPool.first(where: { $0.id == id && $0.version == version }) {
        return matchedProduct
    }

    for product in productPool.filter({ $0.id == id }) {
        for platform in product.platforms {
            for languageSet in platform.languageSet {
                if languageSet.productVersion == version {
                    return product
                }
            }
        }
    }
    
    return nil
}

/// 获取产品的所有可用版本
/// - Parameter id: 产品ID
/// - Returns: 版本号数组，已去重并按版本号排序
func getProductVersions(id: String, scope: ProductQueryScope = .visible) -> [String] {
    guard let product = products(in: scope).first(where: { $0.id == id }) else {
        return []
    }
    
    // 收集所有平台和语言集中的版本号
    var versions = Set<String>()
    for platform in product.platforms {
        for languageSet in platform.languageSet {
            versions.insert(languageSet.productVersion)
        }
    }
    
    // 转换为数组并按版本号排序（降序）
    return Array(versions).sorted { version1, version2 in
        version1.compare(version2, options: .numeric) == .orderedDescending
    }
}

/// 获取产品在指定版本下的所有可用语言
/// - Parameters:
///   - id: 产品ID
///   - version: 版本号
/// - Returns: 语言代码数组
func getProductLanguages(
    id: String,
    version: String,
    scope: ProductQueryScope = .visible
) -> [String] {
    guard let product = products(in: scope).first(where: { $0.id == id }) else {
        return []
    }
    
    var languages = Set<String>()
    for platform in product.platforms {
        for languageSet in platform.languageSet {
            if languageSet.productVersion == version {
                languages.insert(languageSet.name)
            }
        }
    }
    
    return Array(languages).sorted()
}

/// 查找所有匹配指定ID的产品
/// - Parameter id: 产品ID
/// - Returns: 匹配的产品数组
func findProducts(
    id: String,
    scope: ProductQueryScope = .visible
) -> [Product] {
    products(in: scope).filter { $0.id == id }
}

func isManifestInstallerProduct(_ productId: String) -> Bool {
    ["APRO", "KCCC"].contains(productId)
}

func isBlockedVisibleProduct(_ productId: String) -> Bool {
    ["KCCC"].contains(productId)
}

func installerOutputName(productId: String, version: String, language: String, platform: String) -> String {
    if isManifestInstallerProduct(productId) {
        return "Adobe Downloader \(productId)_\(version)_\(platform).dmg"
    }
    return "Adobe Downloader \(productId)_\(version)-\(language)-\(platform)"
}

func installerSelectedPlatformId(
    productId: String,
    version: String,
    targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection
) -> String? {
    guard isManifestInstallerProduct(productId),
          let product = findProduct(id: productId, version: version, scope: .ccm)
            ?? findProduct(id: productId, version: version),
          let match = installerPlatformMatch(
            product: product,
            selectedVersion: version,
            targetArchitecture: targetArchitecture
          ) else {
        return HDPIMParityDecisionEngine.shared.preferredPlatformId(
            productId: productId,
            version: version,
            targetArchitecture: targetArchitecture
        )
    }

    return match.platform.id
}

func installerProductVersion(product: Product, languageSet: Product.Platform.LanguageSet, selectedVersion: String) -> String {
    if !languageSet.productVersion.isEmpty {
        return languageSet.productVersion
    }
    if !selectedVersion.isEmpty {
        return selectedVersion
    }
    return product.version
}

func installerPlatformMatch(
    product: Product,
    selectedVersion: String,
    targetArchitecture: HDPIMParityTargetArchitecture = .currentSelection,
    requestedLanguage: String? = nil
) -> (platform: Product.Platform, languageSet: Product.Platform.LanguageSet)? {
    try? catalogInstallerMatch(product: product, targetArchitecture: targetArchitecture, requestedLanguage: requestedLanguage)
}

func catalogInstallerMatch(
    product: Product,
    targetArchitecture: HDPIMParityTargetArchitecture,
    requestedLanguage: String?
) throws -> (platform: Product.Platform, languageSet: Product.Platform.LanguageSet) {
    let preferred = (product.id == "KCCC" ? ["osx10"] : []) + targetArchitecture.platformPreference
    let platforms = product.platforms.sorted {
        let left = preferred.firstIndex(of: $0.id) ?? Int.max
        let right = preferred.firstIndex(of: $1.id) ?? Int.max
        return left == right ? $0.id < $1.id : left < right
    }
    var languageError: Error?
    for platform in platforms {
        let materials = platform.languageSet.filter { !$0.manifestURL.isEmpty || !$0.lbsURL.isEmpty }
        guard !materials.isEmpty else { continue }
        do {
            let language = try CatalogSelection.languageSet(materials, locale: requestedLanguage, installer: true)
            return (platform, language)
        } catch { languageError = error }
    }
    throw languageError ?? NetworkError.unsupportedPlatform("\(product.id) 没有可用安装器")
}

func normalizedInstallerURL(_ value: String, cdn: String = globalCdn) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard URL(string: trimmed)?.scheme == nil else {
        return trimmed
    }

    let cleanCdn = cdn.hasSuffix("/") ? String(cdn.dropLast()) : cdn
    let cleanPath = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    return cleanCdn + cleanPath
}
