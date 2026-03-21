//
//  Adobe Downloader
//
//  Created by X1a0He on 2/26/25.
//

import Foundation
struct Product: Codable, Equatable {
    var type: String
    var displayName: String
    var family: String
    var appLineage: String
    var familyName: String
    var productIcons: [ProductIcon]
    var platforms: [Platform]
    var referencedProducts: [ReferencedProduct]
    var version: String
    var id: String
    var hidden: Bool
    
    func hasValidVersions(allowedPlatform: [String]) -> Bool {
        return platforms.contains { platform in
            allowedPlatform.contains(platform.id) && !platform.languageSet.isEmpty
        }
    }

    struct ProductIcon: Codable, Equatable {
        var value: String
        var size: String

        var dimension: Int {
            let components = size.split(separator: "x")
            if components.count == 2,
               let dimension = Int(components[0]) {
                return dimension
            }
            return 0
        }
    }

    struct Platform: Codable, Equatable {
        var languageSet: [LanguageSet]
        var modules: [Module]
        var range: [Range]
        var id: String

        struct LanguageSet: Codable, Equatable {
            var manifestURL: String
            var dependencies: [Dependency]
            var productCode: String
            var name: String
            var installSize: Int
            var buildGuid: String
            var baseVersion: String
            var productVersion: String

            struct Dependency: Codable, Equatable {
                var sapCode: String
                var baseVersion: String
                var productVersion: String
                var buildGuid: String
                var isMatchPlatform: Bool
                var targetPlatform: String
                var selectedPlatform: String
                var selectedReason: String
                var isSoftDependency: Bool

                init(sapCode: String, baseVersion: String, productVersion: String, buildGuid: String, isMatchPlatform: Bool = false, targetPlatform: String = "", selectedPlatform: String = "", selectedReason: String = "", isSoftDependency: Bool = false) {
                    self.sapCode = sapCode
                    self.baseVersion = baseVersion
                    self.productVersion = productVersion
                    self.buildGuid = buildGuid
                    self.isMatchPlatform = isMatchPlatform
                    self.targetPlatform = targetPlatform
                    self.selectedPlatform = selectedPlatform
                    self.selectedReason = selectedReason
                    self.isSoftDependency = isSoftDependency
                }
            }
        }

        struct Module: Codable, Equatable {
            var displayName: String
            var deploymentType: String
            var id: String
        }

        struct Range: Codable, Equatable {
            var min: String
            var max: String
        }
    }

    struct ReferencedProduct: Codable, Equatable {
        var sapCode: String
        var version: String
    }

    func getBestIcon() -> ProductIcon? {
        if let icon = productIcons.first(where: { $0.size == "192x192" }) {
            return icon
        }
        return productIcons.max(by: { $0.dimension < $1.dimension })
    }
}

struct NewParseResult {
    var products: [Product]
    var cdn: String
}

/* ========== */
struct UniqueProduct: Equatable {
    var id: String
    var displayName: String
    
    static func == (lhs: UniqueProduct, rhs: UniqueProduct) -> Bool {
        return lhs.id == rhs.id && lhs.displayName == rhs.displayName
    }
}

/* ========== */
class DependenciesToDownload: ObservableObject, Codable {
    // 别人依赖就他吗叫sapCode，Adobe也是傻逼，一会id一会sapCode
    var sapCode: String
    var version: String
    var buildGuid: String
    var applicationJson: String?
    var isSoftDependency: Bool
    @Published var packages: [Package] = []
    @Published var completedPackages: Int = 0

    var totalPackages: Int {
        packages.count
    }

    init(sapCode: String, version: String, buildGuid: String, applicationJson: String = "", isSoftDependency: Bool = false) {
        self.sapCode = sapCode
        self.version = version
        self.buildGuid = buildGuid
        self.applicationJson = applicationJson
        self.isSoftDependency = isSoftDependency
    }

    func updateCompletedPackages() {
        Task { @MainActor in
            completedPackages = packages.filter { $0.downloaded }.count
            objectWillChange.send()
        }
    }

    enum CodingKeys: String, CodingKey {
        case sapCode, version, buildGuid, applicationJson, packages, isSoftDependency
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sapCode, forKey: .sapCode)
        try container.encode(version, forKey: .version)
        try container.encode(buildGuid, forKey: .buildGuid)
        try container.encodeIfPresent(applicationJson, forKey: .applicationJson)
        try container.encode(packages, forKey: .packages)
        try container.encode(isSoftDependency, forKey: .isSoftDependency)
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sapCode = try container.decode(String.self, forKey: .sapCode)
        version = try container.decode(String.self, forKey: .version)
        buildGuid = try container.decode(String.self, forKey: .buildGuid)
        applicationJson = try container.decodeIfPresent(String.self, forKey: .applicationJson)
        packages = try container.decode([Package].self, forKey: .packages)
        isSoftDependency = try container.decodeIfPresent(Bool.self, forKey: .isSoftDependency) ?? false
        completedPackages = 0
    }
}

/* ========== */
class Package: Identifiable, ObservableObject, Codable {
    var id = UUID()
    var type: String
    var fullPackageName: String
    var downloadSize: Int64
    var downloadURL: String
    var packageVersion: String
    var validationURL: String?

    @Published var downloadedSize: Int64 = 0 {
        didSet {
            if downloadSize > 0 {
                progress = Double(downloadedSize) / Double(downloadSize)
            }
        }
    }
    @Published var progress: Double = 0
    @Published var speed: Double = 0
    @Published var status: PackageStatus = .waiting
    @Published var downloaded: Bool = false

    @Published var isSelected: Bool = false
    var isRequired: Bool = false
    var condition: String = ""

    var lastUpdated: Date = Date()
    var lastRecordedSize: Int64 = 0
    var retryCount: Int = 0
    var lastError: Error?

    var canRetry: Bool {
        if case .failed = status {
            return retryCount < 3
        }
        return false
    }

    func markAsFailed(_ error: Error) {
        Task { @MainActor in
            self.lastError = error
            self.status = .failed(error.localizedDescription)
            objectWillChange.send()
        }
    }

    func prepareForRetry() {
        Task { @MainActor in
            self.retryCount += 1
            self.status = .waiting
            self.progress = 0
            self.speed = 0
            self.downloadedSize = 0
            objectWillChange.send()
        }
    }

    init(type: String, fullPackageName: String, downloadSize: Int64, downloadURL: String, packageVersion: String, condition: String = "", isRequired: Bool = false, validationURL: String? = nil) {
        self.type = type
        self.fullPackageName = fullPackageName
        self.downloadSize = downloadSize
        self.downloadURL = downloadURL
        self.packageVersion = packageVersion
        self.validationURL = validationURL
        self.condition = condition
        self.isRequired = isRequired
        self.isSelected = isRequired
        if !isRequired {
            self.isSelected = shouldBeSelectedByDefault
        }
    }

    func updateProgress(downloadedSize: Int64, speed: Double) {
        Task { @MainActor in
            self.downloadedSize = downloadedSize
            self.speed = speed
            self.status = .downloading
            objectWillChange.send()
        }
    }

    func markAsCompleted() {
        Task { @MainActor in
            self.downloaded = true
            self.progress = 1.0
            self.speed = 0
            self.status = .completed
            self.downloadedSize = downloadSize
            objectWillChange.send()
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file)
    }

    var formattedDownloadedSize: String {
        ByteCountFormatter.string(fromByteCount: downloadedSize, countStyle: .file)
    }

    var formattedSpeed: String {
        ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    var hasValidSize: Bool {
        downloadSize > 0
    }
    
    var shouldBeSelectedByDefault: Bool {
        let targetArchitecture = StorageData.shared.downloadAppleSilicon ? "arm64" : "x64"
        let language = StorageData.shared.defaultLanguage
        let isCore = type == "core"
        
        if isCore {
            if condition.isEmpty {
                return true
            } else {
                if condition.contains("[OSArchitecture]==\(targetArchitecture)") {
                    return true
                }
                if condition.contains("[installLanguage]==\(language)") || language == "ALL" {
                    return true
                }
            }
        } else {
            return condition.contains("[installLanguage]==\(language)") || language == "ALL"
        }
        
        return false
    }

    func updateStatus(_ status: PackageStatus) {
        Task { @MainActor in
            self.status = status
            objectWillChange.send()
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, fullPackageName, downloadSize, downloadURL, packageVersion, validationURL, condition, isRequired
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(fullPackageName, forKey: .fullPackageName)
        try container.encode(downloadSize, forKey: .downloadSize)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(packageVersion, forKey: .packageVersion)
        try container.encodeIfPresent(validationURL, forKey: .validationURL)
        try container.encode(condition, forKey: .condition)
        try container.encode(isRequired, forKey: .isRequired)
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        fullPackageName = try container.decode(String.self, forKey: .fullPackageName)
        downloadSize = try container.decode(Int64.self, forKey: .downloadSize)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        packageVersion = try container.decode(String.self, forKey: .packageVersion)
        validationURL = try container.decodeIfPresent(String.self, forKey: .validationURL)
        condition = try container.decodeIfPresent(String.self, forKey: .condition) ?? ""
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        isSelected = isRequired
        if !isRequired {
            isSelected = shouldBeSelectedByDefault
        }
    }
}

/* ========== */
struct ValidationInfo {
    var segmentSize: Int64
    var version: String
    var algorithm: String
    var segmentCount: Int
    var lastSegmentSize: Int64
    var packageHashKey: String
    var segments: [SegmentInfo]
    
    struct SegmentInfo {
        var segmentNumber: Int
        var hash: String
    }
    
    static func parse(from xmlString: String) -> ValidationInfo? {
        guard let data = xmlString.data(using: .utf8) else { return nil }
        
        let parser = ValidationXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        
        guard xmlParser.parse() else { return nil }
        
        return ValidationInfo(
            segmentSize: parser.segmentSize,
            version: parser.version,
            algorithm: parser.algorithm,
            segmentCount: parser.segmentCount,
            lastSegmentSize: parser.lastSegmentSize,
            packageHashKey: parser.packageHashKey,
            segments: parser.segments
        )
    }
}

class ValidationXMLParser: NSObject, XMLParserDelegate {
    var segmentSize: Int64 = 0
    var version: String = ""
    var algorithm: String = ""
    var segmentCount: Int = 0
    var lastSegmentSize: Int64 = 0
    var packageHashKey: String = ""
    var segments: [ValidationInfo.SegmentInfo] = []
    
    private var currentElement: String = ""
    private var currentSegmentNumber: Int = 0
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "segment", let segmentNumber = attributeDict["segmentNumber"], let number = Int(segmentNumber) {
            currentSegmentNumber = number
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch currentElement {
        case "segmentSize":
            if let size = Int64(trimmedString) {
                segmentSize = size
            }
        case "version":
            version = trimmedString
        case "algorithm":
            algorithm = trimmedString
        case "segmentCount":
            if let count = Int(trimmedString) {
                segmentCount = count
            }
        case "lastSegmentSize":
            if let size = Int64(trimmedString) {
                lastSegmentSize = size
            }
        case "packageHashKey":
            packageHashKey = trimmedString
        case "segment":
            if !trimmedString.isEmpty {
                segments.append(ValidationInfo.SegmentInfo(segmentNumber: currentSegmentNumber, hash: trimmedString))
            }
        default:
            break
        }
    }
}

struct NetworkConstants {
    static let downloadTimeout: TimeInterval = 300
    static let maxRetryAttempts = 3
    static let retryDelay: UInt64 = 3_000_000_000
    static let bufferSize = 1024 * 1024
    static let maxConcurrentDownloads = 3
    static let progressUpdateInterval: TimeInterval = 1

    static let ffcRequestTimeout: TimeInterval = 90
    static let serviceCallTimeout: TimeInterval = 20
    static let maxServiceCallRetries = 3
    static let deadConnectionTimeout: TimeInterval = 101
    static let maxDeadConnections = 100

    static let adobeAppVersion = "6.8.1.856"

    static var productsURL: String {
        "https://prod-rel-ffc-ccm.oobesaas.adobe.com/adobe-ffc-external/core/v\(UserDefaults.standard.string(forKey: "apiVersion") ?? "6")/products/all"
    }

    static let applicationJsonURLV3 = "https://cdn-ffc.oobesaas.adobe.com/core/v3/applications"

    static var userAgent: String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return "Creative Cloud/\(adobeAppVersion)/Mac-\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }

    static var ffcRequestHeaders: [String: String] {
        var headers: [String: String] = [
            "x-adobe-app-id": "accc-hdcore-desktop",
            "x-api-key": "Creative Cloud_v\(UserDefaults.standard.string(forKey: "apiVersion") ?? "6")_4",
            "User-Agent": userAgent,
            "x-adobe-app-version": adobeAppVersion,
            "Content-Type": "application/json"
        ]
        if let token = UserDefaults.standard.string(forKey: "userAuthenticationToken"), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    static var applicationJsonHeaders: [String: String] {
        [
            "x-adobe-app-id": "accc-hdcore-desktop",
            "x-api-key": "Creative Cloud_v\(UserDefaults.standard.string(forKey: "apiVersion") ?? "6")_4",
            "User-Agent": userAgent
        ]
    }

    static var downloadHeaders: [String: String] {
        [
            "x-adobe-app-id": "accc-hdcore-desktop",
            "x-api-key": "Creative Cloud_v\(UserDefaults.standard.string(forKey: "apiVersion") ?? "6")_4",
            "User-Agent": userAgent
        ]
    }

    static var adobeRequestHeaders: [String: String] {
        ffcRequestHeaders
    }

    static var productsJSONURL: String { productsURL }
    static var applicationJsonURL: String { applicationJsonURLV3 }
}
