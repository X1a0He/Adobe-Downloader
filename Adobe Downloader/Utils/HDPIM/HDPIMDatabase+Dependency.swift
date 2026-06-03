import Foundation
import SQLite3

extension HDPIMDatabase {

    func addDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) {
        let sql = """
        INSERT OR IGNORE INTO product_reference_info
        (SAPCode, ProductVersion, ProcessorFamily, ReferencingSAPCode, ReferencingProductVersion, ReferencingProcessorFamily, Type)
        VALUES (?, ?, '64Bit', ?, ?, '64Bit', 'install')
        """

        execute(sql, parameters: [dependencySapCode, dependencyVersion, referencingSapCode, referencingVersion])
    }

    func removeDependencyReference(
        dependencySapCode: String,
        dependencyVersion: String,
        referencingSapCode: String,
        referencingVersion: String
    ) {
        let sql = """
        DELETE FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ?
        AND ReferencingSAPCode = ? AND ReferencingProductVersion = ?
        """

        execute(sql, parameters: [dependencySapCode, dependencyVersion, referencingSapCode, referencingVersion])
    }

    func getDependencyReferenceCount(sapCode: String, version: String) -> Int {
        let sql = """
        SELECT COUNT(*) FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ?
        """

        var count = 0
        query(sql, parameters: [sapCode, version]) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    func getDependencyReferences(sapCode: String, version: String) -> [DependencyReference] {
        let sql = """
        SELECT ReferencingSAPCode, ReferencingProductVersion, Type
        FROM product_reference_info
        WHERE SAPCode = ? AND ProductVersion = ?
        """

        var references: [DependencyReference] = []
        query(sql, parameters: [sapCode, version]) { stmt in
            let referencingSapCode = String(cString: sqlite3_column_text(stmt, 0))
            let referencingVersion = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))

            references.append(DependencyReference(
                dependencySapCode: sapCode,
                dependencyVersion: version,
                referencingSapCode: referencingSapCode,
                referencingVersion: referencingVersion,
                referenceType: type
            ))
        }
        return references
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
