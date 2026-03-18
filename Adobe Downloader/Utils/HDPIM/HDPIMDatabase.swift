//
//  HDPIMDatabase.swift
//  Adobe Downloader
//
//  Created by X1a0He on 2026/03/18.
//

import Foundation
import SQLite3

struct HDPIMInstallRecord {
    let sapCode: String
    let codexVersion: String
    let platform: String
    let packageName: String
    let packageVersion: String
    let installPath: String
    let uninstallPIMXPath: String?
    let uninstallPIMXHash: String?
    let installTimestamp: Date
}

class HDPIMDatabase {

    static let shared = HDPIMDatabase()

    private var db: OpaquePointer?
    private let dbPath: URL

    private init() {
        let appSupport = URL(fileURLWithPath: HDPIMRuntimeEnvironment.userHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dbDir = appSupport.appendingPathComponent("Adobe Downloader")
        dbPath = dbDir.appendingPathComponent("hdpim.db")

        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    }

    func open() throws {
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            throw HDPIMDatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try createTables()
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS installations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sap_code TEXT NOT NULL,
            codex_version TEXT NOT NULL,
            platform TEXT NOT NULL,
            package_name TEXT NOT NULL,
            package_version TEXT NOT NULL,
            install_path TEXT NOT NULL,
            uninstall_pimx_path TEXT,
            uninstall_pimx_hash TEXT,
            install_timestamp REAL NOT NULL,
            UNIQUE(sap_code, codex_version, platform, package_name)
        );
        """

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func recordInstall(_ record: HDPIMInstallRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO installations
        (sap_code, codex_version, platform, package_name, package_version,
         install_path, uninstall_pimx_path, uninstall_pimx_hash, install_timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (record.sapCode as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (record.codexVersion as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (record.platform as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (record.packageName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (record.packageVersion as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (record.installPath as NSString).utf8String, -1, nil)

        if let pimxPath = record.uninstallPIMXPath {
            sqlite3_bind_text(stmt, 7, (pimxPath as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if let hash = record.uninstallPIMXHash {
            sqlite3_bind_text(stmt, 8, (hash as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        sqlite3_bind_double(stmt, 9, record.installTimestamp.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func isInstalled(sapCode: String, version: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM installations WHERE sap_code = ? AND codex_version = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sapCode as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (version as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) > 0
        }
        return false
    }

    func getInstalledPackages(sapCode: String, version: String) -> [HDPIMInstallRecord] {
        let sql = """
        SELECT sap_code, codex_version, platform, package_name, package_version,
               install_path, uninstall_pimx_path, uninstall_pimx_hash, install_timestamp
        FROM installations WHERE sap_code = ? AND codex_version = ?
        ORDER BY id;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sapCode as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (version as NSString).utf8String, -1, nil)

        var records: [HDPIMInstallRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = HDPIMInstallRecord(
                sapCode: String(cString: sqlite3_column_text(stmt, 0)),
                codexVersion: String(cString: sqlite3_column_text(stmt, 1)),
                platform: String(cString: sqlite3_column_text(stmt, 2)),
                packageName: String(cString: sqlite3_column_text(stmt, 3)),
                packageVersion: String(cString: sqlite3_column_text(stmt, 4)),
                installPath: String(cString: sqlite3_column_text(stmt, 5)),
                uninstallPIMXPath: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                uninstallPIMXHash: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                installTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            )
            records.append(record)
        }
        return records
    }

    func removeInstallation(sapCode: String, version: String) throws {
        let sql = "DELETE FROM installations WHERE sap_code = ? AND codex_version = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sapCode as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (version as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HDPIMDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func getAllInstalledProducts() -> [(sapCode: String, version: String, platform: String)] {
        let sql = "SELECT DISTINCT sap_code, codex_version, platform FROM installations ORDER BY sap_code;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var products: [(String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            products.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                String(cString: sqlite3_column_text(stmt, 2))
            ))
        }
        return products
    }
}

enum HDPIMDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "数据库打开失败: \(msg)"
        case .queryFailed(let msg): return "数据库查询失败: \(msg)"
        }
    }
}
