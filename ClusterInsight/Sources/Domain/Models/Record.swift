import Foundation
import GRDB

// A single phone transcript record parsed from a CSV row.
struct TranscriptRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var datasetId: Int64
    var originalNo: String
    var datetime: String?
    var duration: String?
    var status: String?
    var textContent: String
    var textLength: Int

    static let databaseTableName = "records"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
