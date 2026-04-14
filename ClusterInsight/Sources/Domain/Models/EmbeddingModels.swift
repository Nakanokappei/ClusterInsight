import Foundation
import GRDB

// Tracks a single embedding execution run with its parameters and metadata.
struct EmbeddingRun: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var datasetId: Int64
    var modelName: String
    var dimensions: Int
    var tokenLimit: Int
    var totalRecords: Int
    var skippedRecords: Int
    var createdAt: Date

    static let databaseTableName = "embedding_runs"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// An embedding vector for a single transcript record, stored as raw Float32 bytes.
struct Embedding: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var embeddingRunId: Int64
    var recordId: Int64
    var vector: Data

    static let databaseTableName = "embeddings"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // Convert the raw BLOB data to a Float32 array for numerical computation.
    func toFloatArray() -> [Float] {
        vector.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    // Create an Embedding from a Float32 array, packing into raw bytes.
    static func vectorData(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
    }
}
