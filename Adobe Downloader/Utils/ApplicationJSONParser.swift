//
//  Adobe Downloader
//  ApplicationJSONParser.swift
//
//  Created by X1a0He on 2026/03/17.
//

import Foundation

struct ConflictingProcessInfo: Codable, Equatable {
    var regularExpression: String = ""
    var processDisplayName: String = ""
    var relativePath: String = ""
    var parentRegularExpression: String = ""
    var parentDisplayName: String = ""
    var headless: String = ""
    var forceKillAllowed: String = ""
    var adobeOwned: String = ""
}

struct DeltaPackageInfo: Codable, Equatable {
    var basePackageVersion: String = ""
    var packageName: String = ""
    var metadataFilePath: String = ""
    var properties: [String: String] = [:]
}

struct ApplicationInfo {
    var properties: [String: Any] = [:]

    var compressionType: String = ""
    var displayName: String = ""

    var codexVersion: String = ""
    var productVersion: String = ""
    var baseVersion: String = ""

    var softDependencies: [String] = [] // SAP codes

    var supportedLanguages: [String] = []

    var osVersionRanges: [(min: String, max: String)] = []
    var systemRequirementExternalUrlProd: String = ""
    var systemRequirementExternalUrlStage: String = ""

    var conflictingProcesses: [ConflictingProcessInfo] = []

    var installDir: String = ""
    var isInstallDirFixed: Bool = false
    var autoInstall: Bool = false
    var isVisibleProduct: Bool = true
    var isSelfReference: Bool = false
    var isNonCCProduct: Bool = false

    var packages: [ParsedPackage] = []

    var modules: [ParsedModule] = []

    var amtConfig: [String: String] = [:]

    var rawJSON: String = ""
}

struct ParsedPackage: Codable, Equatable {
    var packageName: String = ""
    var fullPackageName: String = ""
    var type: String = "noncore"
    var isShared: Bool = false
    var processorFamily: String = ""
    var downloadSize: Int64 = 0
    var extractSize: Int64 = 0
    var installSequenceNumber: Int = 0
    var path: String = ""
    var packageVersion: String = ""
    var condition: String = ""

    var validationURLType2: String?

    var features: Set<String> = []

    var deltaPackages: [DeltaPackageInfo] = []

    var systemRequirements: [String: String] = [:]

    var aliasPackageName: String = ""
}

struct ParsedModule: Codable, Equatable {
    var id: String = ""
    var referencePackages: [String] = []  // 包名列表
    var properties: [String: String] = [:]
}

class ApplicationJSONParser {
    static func parse(jsonString: String) throws -> ApplicationInfo {
        guard let jsonData = jsonString.data(using: .utf8),
              let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NetworkError.invalidData("Error in parsing Application JSON")
        }

        var info = ApplicationInfo()
        info.rawJSON = jsonString

        info.properties = flattenJSON(jsonObject, prefix: "")
        info.compressionType = jsonObject["CompressionType"] as? String ?? ""
        info.displayName = (jsonObject["Name"] as? String)
            ?? (jsonObject["ProductName"] as? String)
            ?? (jsonObject["DisplayName"] as? String)
            ?? ""

        info.codexVersion = jsonObject["CodexVersion"] as? String ?? ""
        info.productVersion = jsonObject["ProductVersion"] as? String ?? ""
        if info.codexVersion.isEmpty {
            info.codexVersion = info.productVersion
        }
        info.baseVersion = jsonObject["BaseVersion"] as? String ?? ""

        if let softDeps = getNestedValue(jsonObject, path: "SoftDependencies.Dependency") as? [[String: Any]] {
            info.softDependencies = softDeps.compactMap { $0["SAPCode"] as? String }
        }

        if let langs = getNestedValue(jsonObject, path: "SupportedLanguages.Language") as? [[String: Any]] {
            var seenLanguages: Set<String> = []
            for lang in langs {
                if let locale = lang["locale"] as? String, seenLanguages.insert(locale).inserted {
                    info.supportedLanguages.append(locale)
                }
            }
        }

        parseSystemRequirements(from: jsonObject, into: &info)

        parseConflictingProcesses(from: jsonObject, into: &info)

        if let installDir = jsonObject["InstallDir"] as? [String: Any] {
            info.installDir = installDir["value"] as? String ?? ""
            info.isInstallDirFixed = (installDir["isFixed"] as? String) == "true"
        }
        info.autoInstall = stringBool(jsonObject["AutoInstall"])
        if jsonObject.keys.contains("IsVisibleProduct") {
            info.isVisibleProduct = stringBool(jsonObject["IsVisibleProduct"])
        }
        info.isSelfReference = stringBool(jsonObject["IsSelfReference"])
        info.isNonCCProduct = stringBool(jsonObject["IsNonCCProduct"])

        if let packages = getNestedValue(jsonObject, path: "Packages.Package") as? [[String: Any]] {
            info.packages = packages.map { parsePackage($0) }
        }

        if let modules = getNestedValue(jsonObject, path: "Modules.Module") as? [[String: Any]] {
            info.modules = modules.map { parseModule($0) }
        }

        if let amtConfig = jsonObject["AMTConfig"] as? [String: Any] {
            info.amtConfig = flattenJSONToStringMap(amtConfig, prefix: "AMTConfig", depth: 2)
        }

        return info
    }

    private static func parsePackage(_ json: [String: Any]) -> ParsedPackage {
        var pkg = ParsedPackage()

        pkg.packageName = json["PackageName"] as? String ?? ""
        pkg.fullPackageName = json["fullPackageName"] as? String ?? ""
        if pkg.fullPackageName.isEmpty && !pkg.packageName.isEmpty {
            pkg.fullPackageName = pkg.packageName.hasSuffix(".zip") ? pkg.packageName : "\(pkg.packageName).zip"
        }

        let type = json["Type"] as? String ?? ""
        pkg.type = type.isEmpty ? "noncore" : type
        pkg.isShared = stringBool(json["IsShared"]) || stringBool(json["isShared"])
        pkg.processorFamily = json["ProcessorFamily"] as? String ?? ""

        switch json["DownloadSize"] {
        case let n as NSNumber: pkg.downloadSize = n.int64Value
        case let s as String: pkg.downloadSize = Int64(s) ?? 0
        default: pkg.downloadSize = 0
        }

        switch json["ExtractSize"] {
        case let n as NSNumber: pkg.extractSize = n.int64Value
        case let s as String: pkg.extractSize = Int64(s) ?? 0
        default: pkg.extractSize = 0
        }

        switch json["InstallSequenceNumber"] {
        case let n as NSNumber: pkg.installSequenceNumber = n.intValue
        case let s as String: pkg.installSequenceNumber = Int(s) ?? 0
        default: pkg.installSequenceNumber = 0
        }

        pkg.path = json["Path"] as? String ?? ""
        pkg.packageVersion = json["PackageVersion"] as? String ?? ""
        pkg.condition = json["Condition"] as? String ?? ""

        if let validationURLs = json["ValidationURLs"] as? [String: Any] {
            pkg.validationURLType2 = validationURLs["TYPE2"] as? String
        }

        if let features = getNestedValue(json, path: "Features.Feature") as? [[String: Any]] {
            for feature in features {
                if let name = feature["Name"] as? String {
                    pkg.features.insert(name)
                }
            }
        }

        if let deltas = json["DeltaPackages"] as? [[String: Any]] {
            pkg.deltaPackages = deltas.map { delta in
                var dp = DeltaPackageInfo()
                dp.basePackageVersion = delta["BasePackageVersion"] as? String ?? ""
                dp.packageName = delta["PackageName"] as? String ?? ""
                dp.metadataFilePath = delta["MetadataFilePath"] as? String ?? ""
                if let dict = delta as? [String: String] {
                    dp.properties = dict
                }
                return dp
            }
        }

        if let sysReq = getNestedValue(json, path: "PackageSystemRequirement.CheckCompatibility") as? [String: Any] {
            pkg.systemRequirements = flattenJSONToStringMap(sysReq, prefix: "", depth: 2)
        }

        pkg.aliasPackageName = json["AliasPackageName"] as? String ?? ""

        return pkg
    }

    private static func stringBool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    private static func parseModule(_ json: [String: Any]) -> ParsedModule {
        var module = ParsedModule()

        module.id = json["Id"] as? String ?? ""

        if let refPkgs = getNestedValue(json, path: "ReferencePackages.ReferencePackage") {
            if let array = refPkgs as? [String] {
                module.referencePackages = array
            } else if let single = refPkgs as? String {
                module.referencePackages = [single]
            }
        }

        for (key, value) in json {
            if let strValue = value as? String {
                module.properties[key] = strValue
            }
        }

        return module
    }

    private static func parseSystemRequirements(from json: [String: Any], into info: inout ApplicationInfo) {
        guard let sysReq = json["SystemRequirement"] as? [String: Any] else { return }

        if let osVersion = sysReq["OsVersion"] as? [String: Any] {
            let min = osVersion["min"] as? String ?? ""
            let max = osVersion["max"] as? String ?? ""
            if !min.isEmpty || !max.isEmpty {
                info.osVersionRanges.append((min: min, max: max))
            }
        }

        if let ranges = sysReq["SupportedOsVersionRange"] as? [[String: Any]] {
            for range in ranges {
                let min = range["min"] as? String ?? ""
                let max = range["max"] as? String ?? ""
                info.osVersionRanges.append((min: min, max: max))
            }
        }

        if let extUrl = sysReq["ExternalUrl"] as? [String: Any] {
            if let prod = extUrl["Prod"] as? [String: Any] {
                info.systemRequirementExternalUrlProd = prod["mul"] as? String ?? ""
            } else if let prod = extUrl["Prod"] as? String {
                info.systemRequirementExternalUrlProd = prod
            }
            if let stage = extUrl["Stage"] as? [String: Any] {
                info.systemRequirementExternalUrlStage = stage["mul"] as? String ?? ""
            } else if let stage = extUrl["Stage"] as? String {
                info.systemRequirementExternalUrlStage = stage
            }
        }
    }

    private static func parseConflictingProcesses(from json: [String: Any], into info: inout ApplicationInfo) {
        if let procs = getNestedValue(json, path: "ConflictingProcesses.ConflictingProcess") as? [[String: Any]] {
            for proc in procs {
                var cp = ConflictingProcessInfo()
                cp.regularExpression = proc["RegularExpression"] as? String ?? ""
                cp.processDisplayName = proc["ProcessDisplayName"] as? String ?? ""
                cp.relativePath = proc["RelativePath"] as? String ?? ""
                cp.parentRegularExpression = proc["ParentRegularExpression"] as? String ?? ""
                cp.parentDisplayName = proc["ParentDisplayName"] as? String ?? ""
                cp.headless = proc["headless"] as? String ?? ""
                cp.forceKillAllowed = proc["forceKillAllowed"] as? String ?? ""
                cp.adobeOwned = proc["adobeOwned"] as? String ?? ""
                info.conflictingProcesses.append(cp)
            }
        }

        if let simpleProcs = getNestedValue(json, path: "conflictingProcesses.process") as? [String] {
            for regex in simpleProcs {
                var cp = ConflictingProcessInfo()
                cp.regularExpression = regex
                info.conflictingProcesses.append(cp)
            }
        }
    }

    static func getNestedValue(_ json: [String: Any], path: String) -> Any? {
        let keys = path.split(separator: ".").map(String.init)
        var current: Any = json
        for key in keys {
            guard let dict = current as? [String: Any], let value = dict[key] else {
                return nil
            }
            current = value
        }
        return current
    }

    private static func flattenJSON(_ json: [String: Any], prefix: String) -> [String: Any] {
        var result = [String: Any]()
        for (key, value) in json {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let dict = value as? [String: Any] {
                result.merge(flattenJSON(dict, prefix: fullKey)) { _, new in new }
            } else {
                result[fullKey] = value
            }
        }
        return result
    }

    private static func flattenJSONToStringMap(_ json: [String: Any], prefix: String, depth: Int) -> [String: String] {
        var result = [String: String]()
        for (key, value) in json {
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if depth > 0, let dict = value as? [String: Any] {
                result.merge(flattenJSONToStringMap(dict, prefix: fullKey, depth: depth - 1)) { _, new in new }
            } else if let strValue = value as? String {
                result[fullKey] = strValue
            } else {
                result[fullKey] = "\(value)"
            }
        }
        return result
    }
}
