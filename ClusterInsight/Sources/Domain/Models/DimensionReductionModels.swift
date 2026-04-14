import Foundation
import GRDB

// Tracks a single dimension reduction execution run (UMAP) with its parameters.
struct DimensionReduction: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var embeddingRunId: Int64
    var method: String
    var parameters: String
    var createdAt: Date

    static let databaseTableName = "dimension_reductions"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// A 3D coordinate for a single record produced by dimension reduction (UMAP).
struct DimensionReductionCoord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var reductionId: Int64
    var recordId: Int64
    var x: Double
    var y: Double
    var z: Double

    static let databaseTableName = "dimension_reduction_coords"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
