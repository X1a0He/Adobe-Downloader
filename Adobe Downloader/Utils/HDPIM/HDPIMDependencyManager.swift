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

    func incrementReference(
        dependencySapCode: String,
        dependencyVersion: String,
        dependencyProcessorFamily: HDPIMProcessorFamily,
        referencingSapCode: String,
        referencingVersion: String,
        referencingProcessorFamily: HDPIMProcessorFamily,
        type: String = "install"
    ) -> Int {
        HDPIMDatabase.shared.addDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            dependencyProcessorFamily: dependencyProcessorFamily,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion,
            referencingProcessorFamily: referencingProcessorFamily,
            type: type
        )
        return getReferenceCount(
            sapCode: dependencySapCode,
            version: dependencyVersion,
            processorFamily: dependencyProcessorFamily
        )
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

    func decrementReference(
        dependencySapCode: String,
        dependencyVersion: String,
        dependencyProcessorFamily: HDPIMProcessorFamily,
        referencingSapCode: String,
        referencingVersion: String,
        referencingProcessorFamily: HDPIMProcessorFamily
    ) -> Int {
        HDPIMDatabase.shared.removeDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            dependencyProcessorFamily: dependencyProcessorFamily,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion,
            referencingProcessorFamily: referencingProcessorFamily
        )
        return getReferenceCount(
            sapCode: dependencySapCode,
            version: dependencyVersion,
            processorFamily: dependencyProcessorFamily
        )
    }

    func getReferenceCount(sapCode: String, version: String) -> Int {
        return HDPIMDatabase.shared.getDependencyReferenceCount(
            sapCode: sapCode,
            version: version
        )
    }

    func getReferenceCount(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) -> Int {
        HDPIMDatabase.shared.getDependencyReferenceCount(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily
        )
    }

    func canUninstall(sapCode: String, version: String) -> (canUninstall: Bool, reason: String?, referenceCount: Int) {
        let references = HDPIMDatabase.shared.getDependencyReferences(
            sapCode: sapCode,
            version: version
        )
        let installedReferences = references.filter { reference in
            HDPIMDatabase.shared.isInstalledProduct(
                sapCode: reference.referencingSapCode,
                version: reference.referencingVersion,
                processorFamily: reference.referencingProcessorFamily
            )
        }
        let refCount = installedReferences.count

        if refCount > 0 {
            let refList = installedReferences.map { "\($0.referencingSapCode) \($0.referencingVersion)" }.joined(separator: ", ")
            return (false, "Product is referenced by \(refCount) other products: \(refList)", refCount)
        }

        return (true, nil, 0)
    }

    func canUninstall(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) -> (canUninstall: Bool, reason: String?, referenceCount: Int) {
        let references = HDPIMDatabase.shared.getDependencyReferences(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily
        )
        let installedReferences = references.filter { reference in
            HDPIMDatabase.shared.isInstalledProduct(
                sapCode: reference.referencingSapCode,
                version: reference.referencingVersion,
                processorFamily: reference.referencingProcessorFamily
            )
        }
        let refCount = installedReferences.count

        if refCount > 0 {
            let refList = installedReferences.map {
                "\($0.referencingSapCode) \($0.referencingVersion) \($0.referencingProcessorFamily.rawValue)"
            }.joined(separator: ", ")
            return (false, "Product is referenced by \(refCount) other products: \(refList)", refCount)
        }

        return (true, nil, 0)
    }

    func dependentReferences(
        forSapCode sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) -> [DependencyReference] {
        HDPIMDatabase.shared.getDependencyReferencesForReferencingProduct(
            sapCode: sapCode,
            version: version,
            processorFamily: processorFamily
        )
    }

    func canUninstallDependentProduct(
        _ reference: DependencyReference,
        excludingReferencingProduct excludedProduct: (sapCode: String, version: String, processorFamily: HDPIMProcessorFamily)
    ) -> (canUninstall: Bool, reason: String?, referenceCount: Int) {
        let references = HDPIMDatabase.shared.getDependencyReferences(
            sapCode: reference.dependencySapCode,
            version: reference.dependencyVersion,
            processorFamily: reference.dependencyProcessorFamily
        )
        let installedReferences = references.filter { installedReference in
            guard installedReference.referencingSapCode != excludedProduct.sapCode
                || installedReference.referencingVersion != excludedProduct.version
                || installedReference.referencingProcessorFamily != excludedProduct.processorFamily else {
                return false
            }
            return HDPIMDatabase.shared.isInstalledProduct(
                sapCode: installedReference.referencingSapCode,
                version: installedReference.referencingVersion,
                processorFamily: installedReference.referencingProcessorFamily
            )
        }
        let refCount = installedReferences.count

        if refCount > 0 {
            let refList = installedReferences.map {
                "\($0.referencingSapCode) \($0.referencingVersion) \($0.referencingProcessorFamily.rawValue)"
            }.joined(separator: ", ")
            return (false, "Product is referenced by \(refCount) other products: \(refList)", refCount)
        }

        return (true, nil, 0)
    }
}
