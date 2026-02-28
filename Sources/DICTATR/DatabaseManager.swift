import Foundation
import GRDB

final class DatabaseManager: Sendable {
    private let dbQueue: DatabaseQueue

    init() throws {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("DICTATR", isDirectory: true)

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
                .order(DictationRecord.orderByRecent)
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
        try dbQueue.write { db in
            let totalCount = try DictationRecord.fetchCount(db)
            if totalCount > count {
                let toDelete = try DictationRecord
                    .order(DictationRecord.orderByRecent)
                    .limit(totalCount - count, offset: count)
                    .fetchAll(db)

                for record in toDelete {
                    // Delete associated audio file if it exists
                    if let audioPath = record.audioFilePath {
                        try? FileManager.default.removeItem(atPath: audioPath)
                    }
                    _ = try record.delete(db)
                }
            }
        }
    }

    func search(query: String) throws -> [DictationRecord] {
        try dbQueue.read { db in
            try DictationRecord
                .filter(Column("text").like("%\(query)%"))
                .order(DictationRecord.orderByRecent)
                .fetchAll(db)
        }
    }
}
