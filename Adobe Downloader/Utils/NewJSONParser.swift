//
//  NewJSONParser.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation
import CoreFoundation

/**
    v6: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v6/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
    v5: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v5/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
    v4: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v4/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
*/

class NewJSONParser {
    /// 每个响应只解码一次；XML/JSON 共用字段适配及产品构造。
    static func parse(data: Data, context: CatalogRequestContext) throws -> ParsedCatalog {
        try Task.checkCancellation()
        let root: CatalogNode
        let first = data.drop(while: { [9, 10, 13, 32].contains($0) }).first
        if first == 60 || data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let document = try XMLDocument(data: data, options: [])
            guard let element = document.rootElement() else { throw ParserError.missingRequired }
            root = CatalogNode(xml: element)
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ParserError.invalidJSON
            }
            root = CatalogNode(json: object)
        }
        let response = root.nodes("response").first ?? root
        let channelRoot: CatalogNode
        if response.xml?.name == "channels" || response.has("channel") {
            channelRoot = response
        } else if let channels = response.nodes("channels").first {
            channelRoot = channels
        } else {
            throw ParserError.missingRequired
        }
        var metadata: [[String]: [CatalogBuildMetadata]] = [:]
        for build in response.nodes("builds/build") {
            try Task.checkCancellation()
            let key = ["id", "version", "platform", "languageSet"].map { build.value($0) }
            metadata[key, default: []].append(buildMetadata(build))
        }

        var result = ParsedCatalog()
        for channel in channelRoot.nodes("channel") {
            try Task.checkCancellation()
            let name = channel.value("name")
            guard !name.isEmpty else { throw ParserError.missingRequired }
            let cdn = channel.value("cdn/secure")
            result.channelCDNs[name] = cdn
            for node in channel.nodes("products/product") {
                try Task.checkCancellation()
                let product = try autoreleasepool {
                    try parseProduct(node, channel: name, cdn: cdn, context: context, metadata: metadata)
                }
                for platform in product.platforms {
                    for language in platform.languageSet {
                        result.dependencyChannels.formUnion(language.dependencyChannels ?? [])
                        for dependency in language.dependencies {
                            result.dependencyChannels.formUnion(dependency.declaredChannels ?? [])
                        }
                    }
                }
                result.products.append(product)
            }
        }
        return result
    }

    private static func parseProduct(
        _ node: CatalogNode, channel: String, cdn: String, context: CatalogRequestContext,
        metadata: [[String]: [CatalogBuildMetadata]]
    ) throws -> Product {
        let id = node.value("id"), version = node.value("version")
        guard !id.isEmpty, !version.isEmpty, !node.value("displayName").isEmpty else {
            throw ParserError.missingRequired
        }
        let icons = node.nodes("productIcons/icon").compactMap { icon -> Product.ProductIcon? in
            let value = icon.text
            guard !value.isEmpty, !icon.value("size").isEmpty else { return nil }
            return Product.ProductIcon(value: value, size: icon.value("size"))
        }
        var product = Product(
            type: node.value("type"), displayName: node.value("displayName"),
            family: node.value("family"), appLineage: node.value("appLineage"),
            familyName: node.value("familyName"), productIcons: icons, platforms: [],
            referencedProducts: node.nodes("referencedProducts/referencedProduct").map {
                Product.ReferencedProduct(sapCode: $0.value("sapCode"), version: $0.value("version"))
            }, version: version, id: id, hidden: channel != "ccm"
        )
        product.catalogChannel = channel
        product.channelCDN = cdn
        let productAvailability = catalogAvailability(node)
        product.platforms = try node.nodes("platforms/platform").map { platform in
            try Task.checkCancellation()
            let platformID = platform.value("id")
            guard !platformID.isEmpty else { throw ParserError.missingRequired }
            let channels = dependencyChannels(platform)
            let availability = catalogAvailability(platform, inheriting: productAvailability)
            let languages = try platform.nodes("languageSet").map { language -> Product.Platform.LanguageSet in
                try Task.checkCancellation()
                let localChannels = dependencyChannels(language)
                let declaredChannels = localChannels.isEmpty ? channels : localChannels
                var parsed = Product.Platform.LanguageSet(
                    manifestURL: language.value("urls/manifestURL"), lbsURL: language.value("urls/lbsURL"),
                    dependencies: language.nodes("dependencies/dependency").map { dependency in
                        let selected = dependency.value("selectedPlatform")
                        var parsed = Product.Platform.LanguageSet.Dependency(
                            sapCode: dependency.value("sapCode"), baseVersion: dependency.value("baseVersion"),
                            productVersion: dependency.value("productVersion"), buildGuid: dependency.value("buildGuid"),
                            targetPlatform: selected.isEmpty ? context.architecture.defaultRequestedPlatform : selected,
                            selectedPlatform: selected
                        )
                        let ownChannels = dependencyChannels(dependency)
                        parsed.declaredChannels = (ownChannels.isEmpty ? declaredChannels : ownChannels).sorted()
                        parsed.declaredPlatform = selected
                        return parsed
                    },
                    productCode: language.value("productCode"), name: language.value("name"),
                    installSize: Int(language.value("installSize")) ?? 0, buildGuid: language.value("buildGuid"),
                    baseVersion: language.value("baseVersion"), productVersion: language.value("productVersion")
                )
                parsed.locales = Array(Set(language.nodes("locales/locale").map { $0.value("name") }.filter { !$0.isEmpty })).sorted()
                parsed.packageType = language.rawValue("packageType")
                parsed.catalogAvailability = availability
                parsed.dependencyChannels = declaredChannels.sorted()
                let associated = metadata[[id, version, platformID, parsed.name]] ?? []
                parsed.buildMetadata = associated.isEmpty ? [buildMetadata(language)] : associated
                return parsed
            }
            return Product.Platform(
                languageSet: languages,
                modules: platform.nodes("modules/module").map {
                    Product.Platform.Module(displayName: $0.value("displayName"), deploymentType: $0.value("deploymentType"), id: $0.value("id"))
                },
                range: platform.nodes("systemCompatibility/operatingSystem/range").compactMap {
                    let text = $0.text
                    guard !text.isEmpty else { return nil }
                    let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    return Product.Platform.Range(min: String(parts[0]), max: parts.count > 1 ? String(parts[1]) : "")
                }, id: platformID
            )
        }
        return product
    }

    // HUM 的平台 custom-data 覆盖产品声明；各平台独立继承，避免遍历顺序造成字段残留。
    private static func catalogAvailability(
        _ node: CatalogNode, inheriting inherited: CatalogAvailability = CatalogAvailability()
    ) -> CatalogAvailability {
        var availability = inherited
        for entry in node.nodes("custom-data/custom-entry") {
            guard let value = entry.nodes("value").first?.rawText else { continue }
            switch entry.rawValue("key") {
            case "isVersionDisabled":
                availability.isVersionDisabled = value.lowercased() == "true"
            case "showInNewApps":
                availability.showInNewApps = value
            default:
                break
            }
        }
        return availability
    }

    private static func dependencyChannels(_ node: CatalogNode) -> Set<String> {
        var channels = Set(node.nodes("dependencyFFCChannel").map(\.text))
        for entry in node.nodes("custom-data/custom-entry") where entry.value("key").lowercased() == "dependencyffcchannel" {
            channels.formUnion(entry.nodes("value").map(\.text))
        }
        return Set(channels.filter { !$0.isEmpty })
    }

    private static func buildMetadata(_ node: CatalogNode) -> CatalogBuildMetadata {
        let keys = ["appId", "appVersion", "libVersion", "buildId", "imsClientId", "imsAppProfileScope", "licenseMode"]
        var licensing: [String: String] = [:]
        for key in keys {
            let value = node.value("nglLicensingInfo/\(key)")
            if !value.isEmpty { licensing[key] = value }
        }
        return CatalogBuildMetadata(
            entitled: node.value("entitled"), maintenanceBuild: node.value("maintenanceBuild"),
            goLiveTime: node.value("goLiveTime"), licensing: licensing
        )
    }
}

private struct CatalogNode {
    let xml: XMLElement?
    let json: Any?

    init(xml: XMLElement) { self.xml = xml; json = nil }
    init(json: Any) { xml = nil; self.json = json }

    var text: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var rawText: String {
        if let xml { return xml.stringValue ?? "" }
        if let value = json as? String { return value }
        if let value = json as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "true" : "false" }
            return value.stringValue
        }
        if let object = json as? [String: Any] {
            for key in ["value", "content", "text"] {
                if let value = object[key] { return CatalogNode(json: value).rawText }
            }
        }
        return ""
    }

    func has(_ key: String) -> Bool {
        if let xml { return xml.children?.contains { $0.name == key } ?? false }
        return (json as? [String: Any])?[key] != nil
    }

    // 仅用于固定的子元素路径；无命名空间匹配和文档顺序与原 XPath 保持一致。
    func nodes(_ path: String) -> [CatalogNode] {
        var result = [self]
        for component in path.split(separator: "/") {
            let key = String(component)
            result = result.flatMap { parent -> [CatalogNode] in
                if let xml = parent.xml {
                    return (xml.children ?? []).compactMap { node in
                        guard let child = node as? XMLElement, child.name == key, (child.uri ?? "").isEmpty else { return nil }
                        return CatalogNode(xml: child)
                    }
                }
                guard let value = (parent.json as? [String: Any])?[key] else { return [] }
                if let array = value as? [Any] { return array.map { CatalogNode(json: $0) } }
                return [CatalogNode(json: value)]
            }
        }
        return result
    }

    func value(_ path: String) -> String {
        rawValue(path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rawValue(_ path: String) -> String {
        if !path.contains("/"), let value = xml?.attribute(forName: path)?.stringValue {
            return value
        }
        return nodes(path).first?.rawText ?? ""
    }
}

extension NewParseResult {
    func merged(with other: NewParseResult) -> NewParseResult {
        let mergedProducts = mergeProducts(products + other.products)
        let mergedCDN = cdn.isEmpty ? other.cdn : cdn
        return NewParseResult(products: mergedProducts, cdn: mergedCDN)
    }

    private func mergeProducts(_ candidates: [Product]) -> [Product] {
        var mergedByKey: [[String]: Product] = [:]

        for product in candidates {
            let key = [product.catalogChannel ?? "", product.id, product.version]
            guard let existing = mergedByKey[key] else {
                mergedByKey[key] = product
                continue
            }
            mergedByKey[key] = mergeProduct(existing, product)
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.id != rhs.id {
                return lhs.id < rhs.id
            }
            let order = AppStatics.compareVersions(lhs.version, rhs.version)
            if order != 0 { return order > 0 }
            return (lhs.catalogChannel ?? "") < (rhs.catalogChannel ?? "")
        }
    }

    private func mergeProduct(_ lhs: Product, _ rhs: Product) -> Product {
        var merged = lhs
        merged.hidden = lhs.hidden && rhs.hidden
        let cdns = [lhs.channelCDN, rhs.channelCDN].compactMap { $0 }.filter { !$0.isEmpty }
        merged.channelCDN = cdns.min()
        if merged.displayName.isEmpty {
            merged.displayName = rhs.displayName
        }
        if merged.family.isEmpty {
            merged.family = rhs.family
        }
        if merged.appLineage.isEmpty {
            merged.appLineage = rhs.appLineage
        }
        if merged.familyName.isEmpty {
            merged.familyName = rhs.familyName
        }

        merged.productIcons = deduplicatedPreservingLast(
            lhs.productIcons + rhs.productIcons,
            key: { "\($0.size)|\($0.value)" }
        ).sorted { $0.dimension > $1.dimension }

        merged.referencedProducts = deduplicatedPreservingLast(
            lhs.referencedProducts + rhs.referencedProducts,
            key: { "\($0.sapCode)|\($0.version)" }
        ).sorted { lhs, rhs in
            if lhs.sapCode != rhs.sapCode {
                return lhs.sapCode < rhs.sapCode
            }
            let order = AppStatics.compareVersions(lhs.version, rhs.version)
            if order != 0 { return order > 0 }
            return lhs.version < rhs.version
        }

        let combinedPlatforms = lhs.platforms + rhs.platforms
        var platformsById: [String: Product.Platform] = [:]
        for platform in combinedPlatforms {
            guard let existing = platformsById[platform.id] else {
                platformsById[platform.id] = platform
                continue
            }
            platformsById[platform.id] = mergePlatform(existing, platform)
        }
        merged.platforms = platformsById.values.sorted { $0.id < $1.id }
        return merged
    }

    private func mergePlatform(_ lhs: Product.Platform, _ rhs: Product.Platform) -> Product.Platform {
        var merged = lhs
        merged.languageSet = mergedLanguageSets(lhs.languageSet + rhs.languageSet).sorted {
            let order = AppStatics.compareVersions($0.productVersion, $1.productVersion)
            return order == 0 ? $0.catalogIdentity.lexicographicallyPrecedes($1.catalogIdentity) : order > 0
        }
        merged.modules = deduplicatedPreservingLast(
            lhs.modules + rhs.modules,
            key: { $0.id }
        ).sorted { $0.id < $1.id }
        merged.range = deduplicatedPreservingLast(
            lhs.range + rhs.range,
            key: { "\($0.min)|\($0.max)" }
        ).sorted { $0.min < $1.min }
        return merged
    }

    private func mergedLanguageSets(_ items: [Product.Platform.LanguageSet]) -> [Product.Platform.LanguageSet] {
        var orderedKeys: [[String]] = []
        var mergedByKey: [[String]: Product.Platform.LanguageSet] = [:]

        for item in items {
            let key = item.catalogIdentity
            if let existing = mergedByKey[key] {
                mergedByKey[key] = mergeLanguageSet(existing, item)
                continue
            }
            orderedKeys.append(key)
            mergedByKey[key] = item
        }

        return orderedKeys.compactMap { mergedByKey[$0] }
    }

    private func mergeLanguageSet(
        _ lhs: Product.Platform.LanguageSet,
        _ rhs: Product.Platform.LanguageSet
    ) -> Product.Platform.LanguageSet {
        var merged = lhs
        if merged.manifestURL.isEmpty {
            merged.manifestURL = rhs.manifestURL
        }
        if merged.lbsURL.isEmpty {
            merged.lbsURL = rhs.lbsURL
        }
        if merged.productCode.isEmpty {
            merged.productCode = rhs.productCode
        }
        if merged.installSize == 0 {
            merged.installSize = rhs.installSize
        }
        if merged.buildGuid.isEmpty {
            merged.buildGuid = rhs.buildGuid
        }
        if merged.baseVersion.isEmpty {
            merged.baseVersion = rhs.baseVersion
        }
        if merged.productVersion.isEmpty {
            merged.productVersion = rhs.productVersion
        }
        merged.locales = Array(Set((lhs.locales ?? []) + (rhs.locales ?? []))).sorted()
        merged.dependencyChannels = Array(Set((lhs.dependencyChannels ?? []) + (rhs.dependencyChannels ?? []))).sorted()
        merged.buildMetadata = (lhs.buildMetadata ?? []) + (rhs.buildMetadata ?? []).filter { !(lhs.buildMetadata ?? []).contains($0) }
        if let left = lhs.catalogAvailability, let right = rhs.catalogAvailability {
            // 单份响应已完成平台覆盖；跨响应的同构建声明冲突时，禁用优先且合并顺序无关。
            merged.catalogAvailability = CatalogAvailability(
                isVersionDisabled: left.isVersionDisabled || right.isVersionDisabled,
                showInNewApps: [left.showInNewApps, right.showInNewApps].compactMap { $0 }.min()
            )
        } else {
            merged.catalogAvailability = lhs.catalogAvailability ?? rhs.catalogAvailability
        }
        merged.dependencies = mergedDependencies(lhs.dependencies + rhs.dependencies)
        return merged
    }

    private func mergedDependencies(
        _ items: [Product.Platform.LanguageSet.Dependency]
    ) -> [Product.Platform.LanguageSet.Dependency] {
        var orderedKeys: [[String]] = []
        var mergedByKey: [[String]: Product.Platform.LanguageSet.Dependency] = [:]

        for item in items {
            let key = [item.sapCode, item.productVersion, item.baseVersion, item.buildGuid, item.declaredPlatform ?? ""] + (item.declaredChannels ?? []).sorted()
            if let existing = mergedByKey[key] {
                mergedByKey[key] = mergeDependency(existing, item)
                continue
            }
            orderedKeys.append(key)
            mergedByKey[key] = item
        }

        return orderedKeys.compactMap { mergedByKey[$0] }
    }

    private func mergeDependency(
        _ lhs: Product.Platform.LanguageSet.Dependency,
        _ rhs: Product.Platform.LanguageSet.Dependency
    ) -> Product.Platform.LanguageSet.Dependency {
        Product.Platform.LanguageSet.Dependency(
            sapCode: lhs.sapCode.isEmpty ? rhs.sapCode : lhs.sapCode,
            baseVersion: lhs.baseVersion.isEmpty ? rhs.baseVersion : lhs.baseVersion,
            productVersion: lhs.productVersion.isEmpty ? rhs.productVersion : lhs.productVersion,
            buildGuid: lhs.buildGuid.isEmpty ? rhs.buildGuid : lhs.buildGuid,
            isMatchPlatform: lhs.isMatchPlatform || rhs.isMatchPlatform,
            targetPlatform: lhs.targetPlatform.isEmpty ? rhs.targetPlatform : lhs.targetPlatform,
            selectedPlatform: lhs.selectedPlatform.isEmpty ? rhs.selectedPlatform : lhs.selectedPlatform,
            selectedReason: lhs.selectedReason.isEmpty ? rhs.selectedReason : lhs.selectedReason,
            isSoftDependency: lhs.isSoftDependency || rhs.isSoftDependency,
            hostValidation: lhs.hostValidation ?? rhs.hostValidation,
            declaredChannels: lhs.declaredChannels ?? rhs.declaredChannels,
            declaredPlatform: lhs.declaredPlatform ?? rhs.declaredPlatform
        )
    }

    private func deduplicatedPreservingLast<T>(
        _ items: [T],
        key: (T) -> String
    ) -> [T] {
        var orderedKeys: [String] = []
        var valuesByKey: [String: T] = [:]

        for item in items {
            let itemKey = key(item)
            if valuesByKey[itemKey] == nil {
                orderedKeys.append(itemKey)
            }
            valuesByKey[itemKey] = item
        }

        return orderedKeys.compactMap { valuesByKey[$0] }
    }
}
