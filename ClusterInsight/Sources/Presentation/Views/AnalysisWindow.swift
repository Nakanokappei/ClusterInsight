import SwiftUI

// Unified analysis window with tab-based navigation between
// Embedding, Clustering, and 3D Scatter Plot views.
struct AnalysisWindow: View {
    @Bindable var appState: AppState
    var viewModel: MainViewModel?

    @State private var selectedTab: AnalysisTab = .embedding

    enum AnalysisTab: String, CaseIterable {
        case embedding = "埋め込み"
        case clustering = "クラスタリング"
        case scatter3d = "3D 散布図"

        var icon: String {
            switch self {
            case .embedding: return "square.stack.3d.up"
            case .clustering: return "circle.grid.3x3"
            case .scatter3d: return "cube"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(AnalysisTab.embedding.rawValue, systemImage: AnalysisTab.embedding.icon, value: .embedding) {
                EmbeddingProgressView(appState: appState, viewModel: viewModel)
            }

            Tab(AnalysisTab.clustering.rawValue, systemImage: AnalysisTab.clustering.icon, value: .clustering) {
                ClusterResultsWindow(appState: appState, viewModel: viewModel)
            }

            Tab(AnalysisTab.scatter3d.rawValue, systemImage: AnalysisTab.scatter3d.icon, value: .scatter3d) {
                ScatterPlot3DWindow(appState: appState, viewModel: viewModel)
            }
        }
    }
}
