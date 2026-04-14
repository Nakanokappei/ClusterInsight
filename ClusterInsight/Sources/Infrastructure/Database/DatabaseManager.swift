import Foundation
import GRDB

// Manages the SQLite database lifecycle including creation, migration, and access.
// All tables follow the schema defined in design document 008.
final class DatabaseManager: Sendable {
    let writer: DatabasePool

    // Initialize the database at the specified path, running migrations to ensure
    // the schema is up to date. Uses the Application Support directory by default.
    init(path: String? = nil) throws {
        let databasePath: String
        if let path {
            databasePath = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let appDirectory = appSupport.appendingPathComponent("ClusterInsight", isDirectory: true)
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            databasePath = appDirectory.appendingPathComponent("cluster_insight.sqlite").path
        }

        writer = try DatabasePool(path: databasePath)
        try runMigrations()
    }

    // Execute all schema migrations in order. Each migration is idempotent and
    // only runs once, tracked by GRDB's built-in migration infrastructure.
    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        // v1: Initial schema with all tables from design document 008.
        migrator.registerMigration("v1_initial_schema") { db in
            // Parent table for imported CSV files.
            try db.create(table: "datasets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("recordCount", .integer).notNull()
                t.column("importedAt", .datetime).notNull()
            }

            // Individual phone transcript records parsed from CSV rows.
            try db.create(table: "records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("datasetId", .integer).notNull()
                    .references("datasets", onDelete: .cascade)
                t.column("originalNo", .text).notNull()
                t.column("datetime", .text)
                t.column("duration", .text)
                t.column("status", .text)
                t.column("textContent", .text).notNull()
                t.column("textLength", .integer).notNull()
            }

            // Metadata for each embedding computation pass.
            try db.create(table: "embedding_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("datasetId", .integer).notNull()
                    .references("datasets", onDelete: .cascade)
                t.column("modelName", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("tokenLimit", .integer).notNull()
                t.column("totalRecords", .integer).notNull()
                t.column("skippedRecords", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            // Raw embedding vectors stored as Float32 BLOB for compact storage.
            try db.create(table: "embeddings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("embeddingRunId", .integer).notNull()
                    .references("embedding_runs", onDelete: .cascade)
                t.column("recordId", .integer).notNull()
                    .references("records", onDelete: .cascade)
                t.column("vector", .blob).notNull()
            }

            // Metadata for each dimension reduction pass (UMAP).
            try db.create(table: "dimension_reductions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("embeddingRunId", .integer).notNull()
                    .references("embedding_runs", onDelete: .cascade)
                t.column("method", .text).notNull()
                t.column("parameters", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // 3D coordinates produced by dimension reduction for each record.
            try db.create(table: "dimension_reduction_coords") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("reductionId", .integer).notNull()
                    .references("dimension_reductions", onDelete: .cascade)
                t.column("recordId", .integer).notNull()
                    .references("records", onDelete: .cascade)
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
            }

            // Metadata for each clustering execution pass.
            try db.create(table: "clustering_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("datasetId", .integer).notNull()
                    .references("datasets", onDelete: .cascade)
                t.column("embeddingRunId", .integer).notNull()
                    .references("embedding_runs", onDelete: .cascade)
                t.column("method", .text).notNull()
                t.column("parameters", .text).notNull()
                t.column("clusterCount", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Maps each record to its assigned cluster within a clustering run.
            try db.create(table: "cluster_assignments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clusteringRunId", .integer).notNull()
                    .references("clustering_runs", onDelete: .cascade)
                t.column("recordId", .integer).notNull()
                    .references("records", onDelete: .cascade)
                t.column("clusterLabel", .integer).notNull()
            }

            // LLM-generated topic summaries for each cluster.
            try db.create(table: "topics") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clusteringRunId", .integer).notNull()
                    .references("clustering_runs", onDelete: .cascade)
                t.column("clusterLabel", .integer).notNull()
                t.column("topicText", .text).notNull()
                t.column("representativeIds", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Performance indexes for common query patterns.
            try db.create(indexOn: "records", columns: ["datasetId"])
            try db.create(indexOn: "embeddings", columns: ["embeddingRunId"])
            try db.create(indexOn: "embeddings", columns: ["recordId"])
            try db.create(indexOn: "dimension_reduction_coords", columns: ["reductionId"])
            try db.create(indexOn: "cluster_assignments", columns: ["clusteringRunId"])
            try db.create(indexOn: "topics", columns: ["clusteringRunId"])
        }

        try migrator.migrate(writer)
    }
}
