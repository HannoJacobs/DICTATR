import Foundation
import GRDB

final class DatabaseManager: Sendable {
    private let dbQueue: DatabaseQueue

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
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
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
    }

    func save(_ record: inout DictationRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    func fetchRecent(limit: Int = 50) throws -> [DictationRecord] {
        try dbQueue.read { db in
            try DictationRecord
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func delete(_ record: DictationRecord) throws {
        try dbQueue.write { db in
            _ = try record.delete(db)
        }
    }

    func deleteOld(keepLast count: Int) throws {
        guard count > 0 else { return }

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
    }

    func search(query: String) throws -> [DictationRecord] {
        // Escape SQL LIKE wildcard characters so they are matched literally
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try dbQueue.read { db in
            try DictationRecord
                .filter(sql: "text LIKE ? ESCAPE '\\'", arguments: ["%\(escaped)%"])
                .order(Column("createdAt").desc, Column("id").desc)
                .fetchAll(db)
        }
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
