//
//  NewJSONParser.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation

/**
    v6: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v6/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
    v5: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v5/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
    v4: https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v4/products/all?channel=ccm&channel=sti&platform=macarm64,macuniversal,osx10-64,osx10&_type=json&productType=Desktop
*/

class NewJSONParser {
    static func parse(jsonString: String) throws {
        let results = try parseResults(jsonString: jsonString)
        globalStiResult = results.sti
        globalCcmResult = results.ccm
        
        if !globalCcmResult.cdn.isEmpty {
            globalCdn = globalCcmResult.cdn
        } else if !globalStiResult.cdn.isEmpty {
            globalCdn = globalStiResult.cdn
        }
    }

    static func parseResults(jsonString: String) throws -> (sti: NewParseResult, ccm: NewParseResult) {
        if isXMLResponse(jsonString) {
            return try parseXMLResults(xmlString: jsonString)
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParserError.invalidJSON
        }
        let apiVersion = Int(StorageData.shared.apiVersion) ?? 6
        let previousStiResult = globalStiResult
        let previousDependencyCache = globalDependencyCache

        let stiResult = try parseStiResolved(jsonObject: jsonObject, apiVersion: apiVersion)

        globalStiResult = stiResult
        globalDependencyCache = [:]

        let ccmResult = try parseCcm(jsonObject: jsonObject, apiVersion: apiVersion)

        globalStiResult = previousStiResult
        globalDependencyCache = previousDependencyCache

        return (sti: stiResult, ccm: ccmResult)
    }

    static func parseStiProducts(jsonString: String) throws {
        if isXMLResponse(jsonString) {
            let result = try parseXMLResults(xmlString: jsonString).sti
            globalStiResult = result
            globalCdn = result.cdn
            return
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParserError.invalidJSON
        }
        let apiVersion = Int(StorageData.shared.apiVersion) ?? 6
        let result = try parseStiResolved(jsonObject: jsonObject, apiVersion: apiVersion)
        globalStiResult = result
        
        // 更新全局 CDN
        globalCdn = result.cdn
    }

    static func parseCcmProducts(jsonString: String) throws {
        if isXMLResponse(jsonString) {
            let result = try parseXMLResults(xmlString: jsonString).ccm
            globalCcmResult = result
            globalCdn = result.cdn
            return
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ParserError.invalidJSON
        }
        let apiVersion = Int(StorageData.shared.apiVersion) ?? 6
        let result = try parseCcm(jsonObject: jsonObject, apiVersion: apiVersion)
        globalCcmResult = result
        
        // 更新全局 CDN
        globalCdn = result.cdn
    }

    private static func isXMLResponse(_ response: String) -> Bool {
        response.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    private static func parseSti(jsonObject: [String: Any], apiVersion: Int) throws -> NewParseResult {
        let cdnPath: [String]
        if apiVersion == 6 {
            cdnPath = ["channels", "channel"]
        } else {
            cdnPath = ["channel"]
        }

        func getValue(from dict: [String: Any], path: [String]) -> Any? {
            var current: Any = dict
            for key in path {
                guard let dict = current as? [String: Any],
                      let value = dict[key] else {
                    return nil
                }
                current = value
            }
            return current
        }

        var channelArray: [[String: Any]] = []
        if let channels = getValue(from: jsonObject, path: cdnPath) {
            if let array = channels as? [[String: Any]] {
                channelArray = array
            } else if let dict = channels as? [String: Any],
                      let array = dict["channel"] as? [[String: Any]] {
                channelArray = array
            }
        }

        guard let firstChannel = channelArray.first,
              let cdn = (firstChannel["cdn"] as? [String: Any])?["secure"] as? String else {
            throw ParserError.missingCDN
        }

        var products = [Product]()

        for channel in channelArray {
            let channelName = channel["name"] as? String ?? ""
            if(channelName != "sti") { continue }

            guard let productsContainer = channel["products"] as? [String: Any],
                  let productArray = productsContainer["product"] as? [[String: Any]] else {
                continue
            }

            for product in productArray {

                guard let productId = product["id"] as? String,
                      let productDisplayName = product["displayName"] as? String,
                      let productVersion = product["version"] as? String else {
                    continue
                }

                /**
                 sti 的 referencedProducts 就是空的，不需要
                 同时也不需要 icon，因为是隐藏的，所以这个不要也罢
                 */
                var productObject = Product(
                    type: product["type"] as? String ?? "",
                    displayName: productDisplayName,
                    family: product["family"] as? String ?? "",
                    appLineage: product["appLineage"] as? String ?? "",
                    familyName: product["familyName"] as? String ?? "",
                    productIcons: [],
                    platforms: [],
                    referencedProducts: [],
                    version: productVersion,
                    id: productId,
                    hidden: true
                )

                if let platforms = product["platforms"] as? [String: Any],
                   let platformArray = platforms["platform"] as? [[String: Any]] {
                    for platform in platformArray {
                        guard let platformId = platform["id"] as? String,
                              let languageSets = platform["languageSet"] as? [[String: Any]],
                              let languageSet = languageSets.first else {
                            continue
                        }

                        // sti 的 dependencies 就是空的
                        let newLanguageSet = Product.Platform.LanguageSet(
                            manifestURL: (languageSet["urls"] as? [String: Any])?["manifestURL"] as? String ?? "",
                            dependencies: [],
                            productCode: languageSet["productCode"] as? String ?? "",
                            name: languageSet["name"] as? String ?? "",
                            installSize: languageSet["installSize"] as? Int ?? 0,
                            buildGuid: languageSet["buildGuid"] as? String ?? "", // 将 buildGuid 赋值给 LanguageSet
                            baseVersion: languageSet["baseVersion"] as? String ?? "",
                            productVersion: languageSet["productVersion"] as? String ?? ""
                        )

                        // sti 的 module 也是空的，不需要
                        var newPlatform = Product.Platform(
                            languageSet: [newLanguageSet],
                            modules: [],
                            range: [],
                            id: platformId
                        )

                        if let range = platform["systemCompatibility"] as? [String: Any],
                           let operatingSystem = range["operatingSystem"] as? [String: Any],
                           let rangeArray = operatingSystem["range"] as? [String] {
                            let min = rangeArray.first ?? ""
                            let max = rangeArray.count > 1 ? rangeArray[1] : ""
                            let newRange = Product.Platform.Range(min: min, max: max)
                            newPlatform.range = [newRange]
                        }

                        productObject.platforms.append(newPlatform)
                    }
                }
                products.append(productObject)
                
            }
        }

        return NewParseResult(products: products, cdn: cdn)
    }

    private static func parseStiResolved(jsonObject: [String: Any], apiVersion: Int) throws -> NewParseResult {
        let previousStiResult = globalStiResult
        let previousDependencyCache = globalDependencyCache

        defer {
            globalStiResult = previousStiResult
            globalDependencyCache = previousDependencyCache
        }

        globalDependencyCache = [:]
        let firstPass = try parseSti(jsonObject: jsonObject, apiVersion: apiVersion)

        globalStiResult = firstPass
        globalDependencyCache = [:]

        return try parseSti(jsonObject: jsonObject, apiVersion: apiVersion)
    }

    private static func parseCcm(jsonObject: [String: Any], apiVersion: Int) throws -> NewParseResult {
        let cdnPath: [String]
        if apiVersion == 6 {
            cdnPath = ["channels", "channel"]
        } else {
            cdnPath = ["channel"]
        }

        func getValue(from dict: [String: Any], path: [String]) -> Any? {
            var current: Any = dict
            for key in path {
                guard let dict = current as? [String: Any],
                      let value = dict[key] else {
                    return nil
                }
                current = value
            }
            return current
        }

        var channelArray: [[String: Any]] = []
        if let channels = getValue(from: jsonObject, path: cdnPath) {
            if let array = channels as? [[String: Any]] {
                channelArray = array
            } else if let dict = channels as? [String: Any],
                      let array = dict["channel"] as? [[String: Any]] {
                channelArray = array
            }
        }

        guard let firstChannel = channelArray.first,
              let cdn = (firstChannel["cdn"] as? [String: Any])?["secure"] as? String else {
            throw ParserError.missingCDN
        }

        var products = [Product]()

        for channel in channelArray {
            let channelName = channel["name"] as? String ?? ""
            if(channelName != "ccm") { continue }

            guard let productsContainer = channel["products"] as? [String: Any],
                  let productArray = productsContainer["product"] as? [[String: Any]] else {
                continue
            }

            for product in productArray {
                guard let productId = product["id"] as? String,
                      let productDisplayName = product["displayName"] as? String,
                      let productVersion = product["version"] as? String else {
                    continue
                }

                if(productDisplayName == "Creative Cloud" || productDisplayName == "Substance Alchemist") { continue }

                let icons = (product["productIcons"] as? [String: Any])?["icon"] as? [[String: Any]] ?? []
                let productIcons = icons.compactMap { icon -> Product.ProductIcon? in
                    guard let size = icon["size"] as? String,
                          let value = icon["value"] as? String else {
                        return nil
                    }
                    return Product.ProductIcon(value: value, size: size)
                }

                var productObject = Product(
                    type: product["type"] as? String ?? "",
                    displayName: productDisplayName,
                    family: product["family"] as? String ?? "",
                    appLineage: product["appLineage"] as? String ?? "",
                    familyName: product["familyName"] as? String ?? "",
                    productIcons: productIcons,
                    platforms: [],
                    referencedProducts: [],
                    version: productVersion,
                    id: productId,
                    hidden: false
                )

                if let platforms = product["platforms"] as? [String: Any],
                   let platformArray = platforms["platform"] as? [[String: Any]] {
                    for platform in platformArray {
                        guard let platformId = platform["id"] as? String,
                              let languageSets = platform["languageSet"] as? [[String: Any]],
                              let languageSet = languageSets.first else {
                            continue
                        }

                        var newLanguageSet = Product.Platform.LanguageSet(
                            manifestURL: (languageSet["urls"] as? [String: Any])?["manifestURL"] as? String ?? "",
                            dependencies: [],
                            productCode: languageSet["productCode"] as? String ?? "",
                            name: languageSet["name"] as? String ?? "",
                            installSize: languageSet["installSize"] as? Int ?? 0,
                            buildGuid: languageSet["buildGuid"] as? String ?? "",
                            baseVersion: languageSet["baseVersion"] as? String ?? "",
                            productVersion: languageSet["productVersion"] as? String ?? ""
                        )

                        var dependencies: [Product.Platform.LanguageSet.Dependency] = []
                        if let deps = languageSet["dependencies"] as? [String: Any],
                           let depArray = deps["dependency"] as? [[String: Any]] {
                            dependencies = depArray.compactMap { dep in
                                guard let sapCode = dep["sapCode"] as? String,
                                      let baseVersion = dep["baseVersion"] as? String else {
                                    return Product.Platform.LanguageSet.Dependency(sapCode: "",baseVersion: "",productVersion: "",buildGuid: "")
                                }
                                let targetArchitecture = HDPIMParityTargetArchitecture.currentSelection
                                let selectedPlatform = (dep["selectedPlatform"] as? String)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                let targetPlatform = selectedPlatform.isEmpty
                                    ? targetArchitecture.defaultRequestedPlatform
                                    : selectedPlatform
                                let cacheKey = DependencyCacheKey(
                                    sapCode: sapCode,
                                    targetPlatform: targetPlatform,
                                    baseVersion: baseVersion
                                )

                                if let cachedDependency = globalDependencyCache[cacheKey] {
                                    return cachedDependency
                                }

                                let rawDependency = Product.Platform.LanguageSet.Dependency(
                                    sapCode: sapCode,
                                    baseVersion: baseVersion,
                                    productVersion: dep["productVersion"] as? String ?? "",
                                    buildGuid: dep["buildGuid"] as? String ?? "",
                                    targetPlatform: targetPlatform,
                                    selectedPlatform: selectedPlatform
                                )
                                let dependency = HDPIMParityDecisionEngine.shared.resolveDependencyPreview(
                                    rawDependency: rawDependency,
                                    targetArchitecture: targetArchitecture
                                )

                                globalDependencyCache[cacheKey] = dependency
                                
                                return dependency
                            }
                            newLanguageSet.dependencies.append(contentsOf: dependencies)
                        }

                        var newPlatform = Product.Platform(
                            languageSet: [newLanguageSet],
                            modules: [],
                            range: [],
                            id: platformId
                        )

                        if let modules = platform["modules"] as? [String: Any],
                           let moduleArray = modules["module"] as? [[String: Any]] {
                            let newModules: [Product.Platform.Module] = moduleArray.compactMap { (module: [String: Any]) -> Product.Platform.Module? in
                                guard let displayName = module["displayName"] as? String,
                                      let deploymentType = module["deploymentType"] as? String,
                                      let id = module["id"] as? String else {
                                    return nil
                                }
                                return Product.Platform.Module(displayName: displayName, deploymentType: deploymentType, id: id)
                            }
                            newPlatform.modules = newModules
                        }

                        if let range = platform["systemCompatibility"] as? [String: Any],
                           let operatingSystem = range["operatingSystem"] as? [String: Any],
                           let rangeArray = operatingSystem["range"] as? [String] {
                            let min = rangeArray.first ?? ""
                            let max = rangeArray.count > 1 ? rangeArray[1] : ""
                            let newRange = Product.Platform.Range(min: min, max: max)
                            newPlatform.range = [newRange]
                        }

                        productObject.platforms.append(newPlatform)
                    }
                }

                if let referencedProductsArray = product["referencedProducts"] as? [[String: Any]] {
                    let referencedProducts: [Product.ReferencedProduct] = referencedProductsArray.compactMap { (refProduct: [String: Any]) -> Product.ReferencedProduct? in
                        guard let sapCode = refProduct["sapCode"] as? String,
                              let version = refProduct["version"] as? String else {
                            return nil
                        }
                        return Product.ReferencedProduct(sapCode: sapCode, version: version)
                    }
                    productObject.referencedProducts = referencedProducts
                }
                products.append(productObject)
            }
        }

        return NewParseResult(products: products, cdn: cdn)
    }

    private static func parseXMLResults(xmlString: String) throws -> (sti: NewParseResult, ccm: NewParseResult) {
        guard let xmlData = xmlString.data(using: .utf8) else {
            throw ParserError.invalidJSON
        }

        let document = try XMLDocument(data: xmlData, options: [])
        let previousStiResult = globalStiResult
        let previousDependencyCache = globalDependencyCache

        let stiResult = try parseXMLStiResolved(document: document)

        globalStiResult = stiResult
        globalDependencyCache = [:]

        let ccmResult = try parseXMLChannel(document: document, channelName: "ccm")

        globalStiResult = previousStiResult
        globalDependencyCache = previousDependencyCache

        return (sti: stiResult, ccm: ccmResult)
    }

    private static func parseXMLStiResolved(document: XMLDocument) throws -> NewParseResult {
        let previousStiResult = globalStiResult
        let previousDependencyCache = globalDependencyCache

        defer {
            globalStiResult = previousStiResult
            globalDependencyCache = previousDependencyCache
        }

        globalDependencyCache = [:]
        let firstPass = try parseXMLChannel(document: document, channelName: "sti")

        globalStiResult = firstPass
        globalDependencyCache = [:]

        return try parseXMLChannel(document: document, channelName: "sti")
    }

    private static func parseXMLChannel(
        document: XMLDocument,
        channelName: String
    ) throws -> NewParseResult {
        guard let cdn = try document.nodes(forXPath: "/response/channels/channel[1]/cdn/secure").first?.stringValue,
              !cdn.isEmpty else {
            throw ParserError.missingCDN
        }

        let productNodes = try document.nodes(forXPath: "/response/channels/channel[@name='\(channelName)']/products/product")
        let products = productNodes.compactMap { node -> Product? in
            guard let productElement = node as? XMLElement else {
                return nil
            }
            return parseXMLProduct(productElement, channelName: channelName)
        }

        return NewParseResult(products: products, cdn: cdn)
    }

    private static func parseXMLProduct(
        _ productElement: XMLElement,
        channelName: String
    ) -> Product? {
        let productId = xmlAttribute(productElement, "id")
        let productVersion = xmlAttribute(productElement, "version")
        let productDisplayName = xmlChildText(productElement, "displayName")

        guard !productId.isEmpty,
              !productVersion.isEmpty,
              !productDisplayName.isEmpty else {
            return nil
        }

        let productIcons = xmlElements(productElement, "productIcons/icon").compactMap { icon -> Product.ProductIcon? in
            let size = xmlAttribute(icon, "size")
            let value = icon.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !size.isEmpty, !value.isEmpty else {
                return nil
            }
            return Product.ProductIcon(value: value, size: size)
        }

        var productObject = Product(
            type: xmlChildText(productElement, "type"),
            displayName: productDisplayName,
            family: xmlChildText(productElement, "family"),
            appLineage: xmlChildText(productElement, "appLineage"),
            familyName: xmlChildText(productElement, "familyName"),
            productIcons: productIcons,
            platforms: [],
            referencedProducts: [],
            version: productVersion,
            id: productId,
            hidden: channelName == "sti"
        )

        productObject.platforms = xmlElements(productElement, "platforms/platform").compactMap { platformElement in
            parseXMLPlatform(platformElement)
        }

        productObject.referencedProducts = xmlElements(productElement, "referencedProducts/referencedProduct").compactMap { element in
            let sapCode = xmlChildText(element, "sapCode")
            let version = xmlChildText(element, "version")
            guard !sapCode.isEmpty, !version.isEmpty else {
                return nil
            }
            return Product.ReferencedProduct(sapCode: sapCode, version: version)
        }

        return productObject
    }

    private static func parseXMLPlatform(_ platformElement: XMLElement) -> Product.Platform? {
        let platformId = xmlAttribute(platformElement, "id")
        guard !platformId.isEmpty else {
            return nil
        }

        let languageSets = xmlElements(platformElement, "languageSet").compactMap { languageSetElement in
            parseXMLLanguageSet(languageSetElement)
        }

        let modules = xmlElements(platformElement, "modules/module").compactMap { moduleElement -> Product.Platform.Module? in
            let id = xmlAttribute(moduleElement, "id").isEmpty ? xmlChildText(moduleElement, "id") : xmlAttribute(moduleElement, "id")
            let displayName = xmlChildText(moduleElement, "displayName")
            let deploymentType = xmlChildText(moduleElement, "deploymentType")
            guard !id.isEmpty else {
                return nil
            }
            return Product.Platform.Module(displayName: displayName, deploymentType: deploymentType, id: id)
        }

        let ranges = xmlElements(platformElement, "systemCompatibility/operatingSystem/range").compactMap { rangeElement -> Product.Platform.Range? in
            let rawRange = (rangeElement.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawRange.isEmpty else {
                return nil
            }
            let components = rawRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let min = components.first.map(String.init) ?? ""
            let max = components.count > 1 ? String(components[1]) : ""
            return Product.Platform.Range(min: min, max: max)
        }

        return Product.Platform(
            languageSet: languageSets,
            modules: modules,
            range: ranges,
            id: platformId
        )
    }

    private static func parseXMLLanguageSet(_ languageSetElement: XMLElement) -> Product.Platform.LanguageSet? {
        var languageSet = Product.Platform.LanguageSet(
            manifestURL: xmlChildText(languageSetElement, "urls/manifestURL"),
            dependencies: [],
            productCode: xmlAttribute(languageSetElement, "productCode"),
            name: xmlAttribute(languageSetElement, "name"),
            installSize: Int(xmlAttribute(languageSetElement, "installSize")) ?? 0,
            buildGuid: xmlAttribute(languageSetElement, "buildGuid"),
            baseVersion: xmlAttribute(languageSetElement, "baseVersion"),
            productVersion: xmlAttribute(languageSetElement, "productVersion")
        )

        let dependencyElements = xmlElements(languageSetElement, "dependencies/dependency")
        languageSet.dependencies = dependencyElements.compactMap { dependencyElement in
            let sapCode = xmlChildText(dependencyElement, "sapCode")
            let baseVersion = xmlChildText(dependencyElement, "baseVersion")
            guard !sapCode.isEmpty, !baseVersion.isEmpty else {
                return nil
            }

            let targetArchitecture = HDPIMParityTargetArchitecture.currentSelection
            let selectedPlatform = xmlChildText(dependencyElement, "selectedPlatform")
            let targetPlatform = selectedPlatform.isEmpty
                ? targetArchitecture.defaultRequestedPlatform
                : selectedPlatform
            let cacheKey = DependencyCacheKey(
                sapCode: sapCode,
                targetPlatform: targetPlatform,
                baseVersion: baseVersion
            )

            if let cached = globalDependencyCache[cacheKey] {
                return cached
            }

            let rawDependency = Product.Platform.LanguageSet.Dependency(
                sapCode: sapCode,
                baseVersion: baseVersion,
                productVersion: xmlChildText(dependencyElement, "productVersion"),
                buildGuid: xmlChildText(dependencyElement, "buildGuid"),
                targetPlatform: targetPlatform,
                selectedPlatform: selectedPlatform
            )

            let dependency = HDPIMParityDecisionEngine.shared.resolveDependencyPreview(
                rawDependency: rawDependency,
                targetArchitecture: targetArchitecture
            )
            globalDependencyCache[cacheKey] = dependency
            return dependency
        }

        return languageSet
    }

    private static func xmlElements(_ element: XMLElement, _ xpath: String) -> [XMLElement] {
        (try? element.nodes(forXPath: xpath))?.compactMap { $0 as? XMLElement } ?? []
    }

    private static func xmlChildText(_ element: XMLElement, _ xpath: String) -> String {
        ((try? element.nodes(forXPath: xpath).first?.stringValue) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func xmlAttribute(_ element: XMLElement, _ name: String) -> String {
        (element.attribute(forName: name)?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NewParseResult {
    func merged(with other: NewParseResult) -> NewParseResult {
        let mergedProducts = mergeProducts(products + other.products)
        let mergedCDN = cdn.isEmpty ? other.cdn : cdn
        return NewParseResult(products: mergedProducts, cdn: mergedCDN)
    }

    private func mergeProducts(_ candidates: [Product]) -> [Product] {
        var mergedByKey: [String: Product] = [:]

        for product in candidates {
            let key = "\(product.id)|\(product.version)"
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
            return AppStatics.compareVersions(lhs.version, rhs.version) > 0
        }
    }

    private func mergeProduct(_ lhs: Product, _ rhs: Product) -> Product {
        var merged = lhs
        merged.hidden = lhs.hidden && rhs.hidden
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
            return AppStatics.compareVersions(lhs.version, rhs.version) > 0
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
            AppStatics.compareVersions($0.productVersion, $1.productVersion) > 0
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
        var orderedKeys: [String] = []
        var mergedByKey: [String: Product.Platform.LanguageSet] = [:]

        for item in items {
            let key = "\(item.name)|\(item.productVersion)|\(item.baseVersion)|\(item.buildGuid)"
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
        merged.dependencies = mergedDependencies(lhs.dependencies + rhs.dependencies)
        return merged
    }

    private func mergedDependencies(
        _ items: [Product.Platform.LanguageSet.Dependency]
    ) -> [Product.Platform.LanguageSet.Dependency] {
        var orderedKeys: [String] = []
        var mergedByKey: [String: Product.Platform.LanguageSet.Dependency] = [:]

        for item in items {
            let key = "\(item.sapCode)|\(item.productVersion)|\(item.baseVersion)|\(item.buildGuid)"
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
            hostValidation: lhs.hostValidation ?? rhs.hostValidation
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
