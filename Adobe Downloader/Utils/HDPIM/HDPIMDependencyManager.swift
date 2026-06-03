import Foundation

final class HDPIMDependencyManager {

    static let shared = HDPIMDependencyManager()
    private init() {}

    func incrementReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) -> Int {
        HDPIMDatabase.shared.addDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion
        )
        return getReferenceCount(sapCode: dependencySapCode, version: dependencyVersion)
    }

    func decrementReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) -> Int {
        HDPIMDatabase.shared.removeDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion
        )
        return getReferenceCount(sapCode: dependencySapCode, version: dependencyVersion)
    }

    func getReferenceCount(sapCode: String, version: String) -> Int {
        return HDPIMDatabase.shared.getDependencyReferenceCount(
            sapCode: sapCode,
            version: version
        )
    }

    func canUninstall(sapCode: String, version: String) -> (canUninstall: Bool, reason: String?, referenceCount: Int) {
        let refCount = getReferenceCount(sapCode: sapCode, version: version)

        if refCount > 0 {
            let references = HDPIMDatabase.shared.getDependencyReferences(
                sapCode: sapCode,
                version: version
            )
            let refList = references.map { "\($0.referencingSapCode) \($0.referencingVersion)" }.joined(separator: ", ")
            return (false, "Product is referenced by \(refCount) other products: \(refList)", refCount)
        }

        return (true, nil, 0)
    }
}
