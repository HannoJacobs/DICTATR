import Foundation
import GRDB

final class DatabaseManager: Sendable {
    private let dbQueue: DatabaseQueue
    private let dbPath: String

    init() throws {
        guard let appSupportBase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DatabaseManagerError.applicationSupportNotFound
        }

        let appSupportURL = appSupportBase.appendingPathComponent("DICTATR", isDirectory: true)

        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )

        let dbPath = appSupportURL.appendingPathComponent("dictatr.db").path
        self.dbPath = dbPath
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
        AppDiagnostics.info(.database, "database initialized path=\(dbPath)")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "dictations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("duration", .double).notNull()
                t.column("audioFilePath", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
        AppDiagnostics.info(.database, "database migration completed path=\(dbPath)")
    }

    func save(_ record: inout DictationRecord) throws {
        AppDiagnostics.info(
            .database,
            "save requested path=\(dbPath) chars=\(record.text.count) duration=\(String(format: "%.3f", record.duration)) createdAt=\(record.createdAt) audioFilePath=\(record.audioFilePath ?? "nil") text=\(AppDiagnostics.quoted(record.text, limit: 1200))"
        )
        try dbQueue.write { db in
            try record.save(db)
        }
        AppDiagnostics.info(.database, "save completed path=\(dbPath) recordID=\(record.id ?? -1)")
    }

    func fetchRecent(limit: Int = 50) throws -> [DictationRecord] {
        let records = try dbQueue.read { db in
            try DictationRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        AppDiagnostics.info(.database, "fetchRecent completed path=\(dbPath) limit=\(limit) returned=\(records.count)")
        return records
    }

    func delete(_ record: DictationRecord) throws {
        AppDiagnostics.info(.database, "delete requested path=\(dbPath) recordID=\(record.id ?? -1) createdAt=\(record.createdAt)")
        try dbQueue.write { db in
            _ = try record.delete(db)
        }
        AppDiagnostics.info(.database, "delete completed path=\(dbPath) recordID=\(record.id ?? -1)")
    }

    func deleteOld(keepLast count: Int) throws {
        guard count > 0 else { return }
        AppDiagnostics.info(.database, "deleteOld requested path=\(dbPath) keepLast=\(count)")

        // Collect paths to delete inside the transaction, then delete files
        // outside the transaction to avoid holding the DB write lock during I/O.
        let pathsToDelete: [String] = try dbQueue.write { db in
            let totalCount = try DictationRecord.fetchCount(db)
            guard totalCount > count else { return [] }

            let toDelete = try DictationRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(totalCount - count, offset: count)
                .fetchAll(db)

            let paths = toDelete.compactMap { $0.audioFilePath }

            for record in toDelete {
                _ = try record.delete(db)
            }
            return paths
        }

        for path in pathsToDelete {
            try? FileManager.default.removeItem(atPath: path)
        }
        AppDiagnostics.info(.database, "deleteOld completed path=\(dbPath) keepLast=\(count) deletedAudioFiles=\(pathsToDelete.count)")
    }

    func search(query: String, limit: Int = 200) throws -> [DictationRecord] {
        // Escape SQL LIKE wildcard characters so they are matched literally
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let records = try dbQueue.read { db in
            try DictationRecord
                .filter(sql: "text LIKE ? ESCAPE '\\'", arguments: ["%\(escaped)%"])
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        AppDiagnostics.info(
            .database,
            "search completed path=\(dbPath) limit=\(limit) query=\(AppDiagnostics.quoted(query, limit: 400)) returned=\(records.count)"
        )
        return records
    }
}

enum DatabaseManagerError: LocalizedError {
    case applicationSupportNotFound

    var errorDescription: String? {
        switch self {
        case .applicationSupportNotFound:
            return "Could not locate Application Support directory"
        }
    }
}
