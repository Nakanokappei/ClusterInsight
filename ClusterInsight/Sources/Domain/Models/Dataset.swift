import Foundation
import GRDB

// A dataset represents a single imported CSV file containing phone transcript records.
struct Dataset: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var filePath: String
    var recordCount: Int
    var importedAt: Date

    static let databaseTableName = "datasets"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
