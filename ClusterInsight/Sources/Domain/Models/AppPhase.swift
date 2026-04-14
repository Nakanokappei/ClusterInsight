import Foundation

// Represents the application state machine phases from S0 through S6,
// plus error states for API failures and data integrity violations.
enum AppPhase: Sendable, Equatable {
    case initial                // S0: App just launched, no data loaded
    case dataLoaded             // S1: CSV imported, records available
    case columnSelected         // S2: Text column confirmed for embedding
    case apiKeyMissing          // S3: API key not set, blocking embedding
    case embeddingComplete      // S4: All embeddings computed and stored
    case clusteringComplete     // S5: Cluster assignments done
    case allComplete            // S6: Topics generated, full results available

    case apiError(String)       // E_API: API call failed with message
    case dataInconsistency(String) // E_DATA: Stored data does not match current dataset
}
