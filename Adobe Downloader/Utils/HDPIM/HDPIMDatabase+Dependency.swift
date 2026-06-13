import Foundation
import SQLite3

extension HDPIMDatabase {

    func addDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) {
        addDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            dependencyProcessorFamily: .bit64,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion,
            referencingProcessorFamily: .bit64,
            type: "install"
        )
    }

    func addDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        dependencyProcessorFamily: HDPIMProcessorFamily,
        referencingSapCode: String,
        referencingVersion: String,
        referencingProcessorFamily: HDPIMProcessorFamily,
        type: String
    ) {
        let sql = """
        INSERT OR IGNORE INTO product_reference_info
        (SAPCode, ProductVersion, ProcessorFamily, ReferencingSAPCode, ReferencingProductVersion, ReferencingProcessorFamily, Type)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """

        execute(sql, parameters: [
            dependencySapCode,
            dependencyVersion,
            dependencyProcessorFamily.rawValue,
            referencingSapCode,
            referencingVersion,
            referencingProcessorFamily.rawValue,
            type
        ])
    }

    func removeDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) {
        removeDependencyReference(
            dependencySapCode: dependencySapCode,
            dependencyVersion: dependencyVersion,
            dependencyProcessorFamily: .bit64,
            referencingSapCode: referencingSapCode,
            referencingVersion: referencingVersion,
            referencingProcessorFamily: .bit64
        )
    }

    func removeDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        dependencyProcessorFamily: HDPIMProcessorFamily,
        referencingSapCode: String,
        referencingVersion: String,
        referencingProcessorFamily: HDPIMProcessorFamily
    ) {
        let sql = """
        DELETE FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ?
        AND ReferencingSAPCode = ? AND ReferencingProductVersion = ? AND ReferencingProcessorFamily = ?
        """

        execute(sql, parameters: [
            dependencySapCode,
            dependencyVersion,
            dependencyProcessorFamily.rawValue,
            referencingSapCode,
            referencingVersion,
            referencingProcessorFamily.rawValue
        ])
    }

    func getDependencyReferenceCount(sapCode: String, version: String) -> Int {
        getDependencyReferenceCount(
            sapCode: sapCode,
            version: version,
            processorFamily: nil
        )
    }

    func getDependencyReferenceCount(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily?
    ) -> Int {
        let familyClause = processorFamily == nil ? "" : " AND ProcessorFamily = ?"
        let sql = """
        SELECT COUNT(*) FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ?\(familyClause)
        """

        var count = 0
        var parameters = [sapCode, version]
        if let processorFamily {
            parameters.append(processorFamily.rawValue)
        }
        query(sql, parameters: parameters) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    func getDependencyReferences(sapCode: String, version: String) -> [DependencyReference] {
        getDependencyReferences(
            sapCode: sapCode,
            version: version,
            processorFamily: nil
        )
    }

    func getDependencyReferences(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily?
    ) -> [DependencyReference] {
        let familyClause = processorFamily == nil ? "" : " AND ProcessorFamily = ?"
        let sql = """
        SELECT ProcessorFamily, ReferencingSAPCode, ReferencingProductVersion, ReferencingProcessorFamily, Type
        FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ?\(familyClause)
        """

        var references: [DependencyReference] = []
        var parameters = [sapCode, version]
        if let processorFamily {
            parameters.append(processorFamily.rawValue)
        }
        query(sql, parameters: parameters) { stmt in
            let dependencyProcessorFamily = HDPIMProcessorFamily.from(platform: String(cString: sqlite3_column_text(stmt, 0)))
            let referencingSapCode = String(cString: sqlite3_column_text(stmt, 1))
            let referencingVersion = String(cString: sqlite3_column_text(stmt, 2))
            let referencingProcessorFamily = HDPIMProcessorFamily.from(platform: String(cString: sqlite3_column_text(stmt, 3)))
            let type = String(cString: sqlite3_column_text(stmt, 4))

            references.append(DependencyReference(
                dependencySapCode: sapCode,
                dependencyVersion: version,
                dependencyProcessorFamily: dependencyProcessorFamily,
                referencingSapCode: referencingSapCode,
                referencingVersion: referencingVersion,
                referencingProcessorFamily: referencingProcessorFamily,
                referenceType: type
            ))
        }
        return references
    }

    func getDependencyReferencesForReferencingProduct(
        sapCode: String,
        version: String
    ) -> [DependencyReference] {
        getDependencyReferencesForReferencingProduct(
            sapCode: sapCode,
            version: version,
            processorFamily: nil
        )
    }

    func getDependencyReferencesForReferencingProduct(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily?
    ) -> [DependencyReference] {
        let familyClause = processorFamily == nil ? "" : " AND ReferencingProcessorFamily = ?"
        let sql = """
        SELECT SAPCode, ProductVersion, ProcessorFamily, ReferencingProcessorFamily, Type
        FROM product_reference_info
        WHERE ReferencingSAPCode = ? AND ReferencingProductVersion = ?\(familyClause)
        """

        var references: [DependencyReference] = []
        var parameters = [sapCode, version]
        if let processorFamily {
            parameters.append(processorFamily.rawValue)
        }
        query(sql, parameters: parameters) { stmt in
            let dependencySapCode = String(cString: sqlite3_column_text(stmt, 0))
            let dependencyVersion = String(cString: sqlite3_column_text(stmt, 1))
            let dependencyProcessorFamily = HDPIMProcessorFamily.from(platform: String(cString: sqlite3_column_text(stmt, 2)))
            let referencingProcessorFamily = HDPIMProcessorFamily.from(platform: String(cString: sqlite3_column_text(stmt, 3)))
            let type = String(cString: sqlite3_column_text(stmt, 4))

            references.append(DependencyReference(
                dependencySapCode: dependencySapCode,
                dependencyVersion: dependencyVersion,
                dependencyProcessorFamily: dependencyProcessorFamily,
                referencingSapCode: sapCode,
                referencingVersion: version,
                referencingProcessorFamily: referencingProcessorFamily,
                referenceType: type
            ))
        }
        return references
    }

    func isInstalledProduct(
        sapCode: String,
        version: String,
        processorFamily: HDPIMProcessorFamily
    ) -> Bool {
        let sql = """
        SELECT COUNT(*) FROM product_installation_info
        WHERE SAPCode = ? AND ProductVersion = ? AND ProcessorFamily = ? AND Status = ?
        """

        var count = 0
        query(sql, parameters: [
            sapCode,
            version,
            processorFamily.rawValue,
            HDPIMInstallStatus.installed.rawValue
        ]) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count > 0
    }

    private func execute(_ sql: String, parameters: [String]) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        for (index, param) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, nil)
        }

        sqlite3_step(stmt)
    }

    private func query(_ sql: String, parameters: [String], handler: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        for (index, param) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, nil)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            handler(stmt!)
        }
    }
}
