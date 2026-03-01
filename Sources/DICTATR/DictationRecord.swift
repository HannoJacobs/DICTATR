import Foundation
import GRDB

struct DictationRecord: Codable, Identifiable, Sendable {
    var id: Int64?
    var text: String
    var duration: TimeInterval
    var audioFilePath: String?
    var createdAt: Date

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    var previewText: String {
        if text.count <= 80 {
            return text
        }
        return String(text.prefix(80)) + "..."
    }
}

extension DictationRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "dictations"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}