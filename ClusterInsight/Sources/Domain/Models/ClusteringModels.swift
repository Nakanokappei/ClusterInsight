import Foundation
import GRDB

// Tracks a single clustering execution run with its algorithm and parameters.
struct ClusteringRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var datasetId: Int64
    var embeddingRunId: Int64
    var method: String
    var parameters: String
    var clusterCount: Int
    var createdAt: Date

    static let databaseTableName = "clustering_runs"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Maps a transcript record to its assigned cluster label within a clustering run.
struct ClusterAssignment: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var clusteringRunId: Int64
    var recordId: Int64
    var clusterLabel: Int

    static let databaseTableName = "cluster_assignments"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// An LLM-generated topic summary for a cluster of transcript records.
struct Topic: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var clusteringRunId: Int64
    var clusterLabel: Int
    var topicText: String
    var representativeIds: String
    var modelName: String
    var createdAt: Date

    static let databaseTableName = "topics"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
