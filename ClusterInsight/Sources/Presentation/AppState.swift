import Foundation
import SwiftUI

// Central application state that drives the UI through the phase state machine (S0-S6).
// Published properties trigger SwiftUI view updates as the analysis pipeline progresses.
@MainActor
@Observable
final class AppState {
    // Current phase in the analysis pipeline.
    var phase: AppPhase = .initial

    // Persisted data references.
    var currentDataset: Dataset?
    var currentEmbeddingRun: EmbeddingRun?
    var currentClusteringRun: ClusteringRun?
    var currentDimensionReduction: DimensionReduction?

    // In-memory working data loaded from the database.
    var records: [TranscriptRecord] = []
    var clusterAssignments: [ClusterAssignment] = []
    var topics: [Topic] = []
    var coordinates: [DimensionReductionCoord] = []

    // UI state for progress and feedback.
    var statusMessage: String = "CSV ファイルを読み込んでください"
    var progressValue: Double = 0
    var progressTotal: Double = 0
    var isProcessing: Bool = false

    // API key: in-memory cache backed by Keychain for persistence.
    // The cached value triggers @Observable view updates when changed.
    var apiKey: String = KeychainHelper.load(key: "openai_api_key") ?? "" {
        didSet { _ = KeychainHelper.save(key: "openai_api_key", value: apiKey) }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    // CSV column headers for embedding target selection.
    var columnHeaders: [String] = []
    var selectedColumn: String = "textContent"

    // Clustering parameters with sensible defaults for the 500-record demo dataset.
    var clusteringMethod: ClusteringMethod = .kMeansPlusPlus
    var kValue: Int = 5
    // Cosine distance between embeddings typically ranges 0.05-0.4.
    // A smaller epsilon finds tighter, more numerous clusters.
    var epsilon: Double = 0.15
    var minSamples: Int = 3

    // Selected cluster in the sidebar for highlight synchronization.
    var selectedClusterLabel: Int?

    // Human-readable phase label for the status bar badge.
    var phaseBadge: String {
        switch phase {
        case .initial: return "S0: 初期"
        case .dataLoaded: return "S1: データ読込済"
        case .columnSelected: return "S2: 列選択済"
        case .apiKeyMissing: return "S3: APIキー未設定"
        case .embeddingComplete: return "S4: 埋め込み完了"
        case .clusteringComplete: return "S5: クラスタリング完了"
        case .allComplete: return "S6: 全完了"
        case .apiError: return "E: エラー"
        case .dataInconsistency: return "E: データ不整合"
        }
    }

    // Derived property: cluster summary for sidebar display.
    var clusterSummaries: [ClusterSummary] {
        let grouped = Dictionary(grouping: clusterAssignments, by: \.clusterLabel)
        return grouped.keys.sorted().map { label in
            let count = grouped[label]?.count ?? 0
            let topic = topics.first(where: { $0.clusterLabel == label })
            return ClusterSummary(label: label, count: count, topicText: topic?.topicText)
        }
    }
}

// Supported clustering algorithms.
enum ClusteringMethod: String, CaseIterable, Sendable {
    case kMeansPlusPlus = "k-means++"
    case dbscan = "DBSCAN"
}

// Summary of a single cluster for sidebar display.
struct ClusterSummary: Identifiable {
    let label: Int
    let count: Int
    let topicText: String?

    var id: Int { label }

    // Show topic name as cluster display name when available, otherwise "クラスター N".
    var displayName: String {
        if label == -1 { return "ノイズ" }
        if let topicText, let topicName = extractTopicName(from: topicText) {
            return topicName
        }
        return "クラスター \(label)"
    }

    // Parse "トピック名: ..." from the LLM response to extract just the name.
    private func extractTopicName(from text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("トピック名:") || trimmed.hasPrefix("トピック名：") {
                let name = trimmed
                    .replacingOccurrences(of: "トピック名:", with: "")
                    .replacingOccurrences(of: "トピック名：", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        // Fallback: use the first line if it's short enough for a title.
        let firstLine = text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.count <= 30 ? firstLine : nil
    }
}
