import Foundation

enum DependencyType: Int {
    case conflicts = 0
    case upgrades = 1
    case requires = 2
    case required = 3
    case critical = 4
    case recommended = 5
    case loadPatch = 6
    case loadLangPack = 7
}

struct Dependency {
    let productSapCode: String
    let productVersion: String
    let dependencySapCode: String
    let dependencyVersion: String
    let dependencyType: DependencyType
    let isSoftDependency: Bool
}

struct DependencyReference {
    let dependencySapCode: String
    let dependencyVersion: String
    let referencingSapCode: String
    let referencingVersion: String
    let referenceType: String
}

struct RIBSCoexistence {
    let ribsCode: String
    let hdDependency: String
    let sapCode: String
    let version: String
    var installState: Int
}
