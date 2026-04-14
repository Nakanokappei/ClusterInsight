import SwiftUI

// 3D scatter plot window: UMAP execution + interactive SceneKit visualization.
struct ScatterPlot3DWindow: View {
    @Bindable var appState: AppState
    var viewModel: MainViewModel?

    var body: some View {
        if appState.currentClusteringRun == nil {
            placeholder(message: "先にクラスタリングを実行してください")
        } else if appState.coordinates.isEmpty && !appState.isProcessing {
            // Ready to run UMAP.
            VStack(spacing: 16) {
                Image(systemName: "cube")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("3D 散布図")
                    .font(.title2)
                Text("クラスタリング結果を3D空間に可視化します")
                    .foregroundStyle(.secondary)
                if let vm = viewModel {
                    Button("UMAP 実行") {
                        Task { await vm.runUMAP() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.isProcessing && appState.coordinates.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("UMAP を計算中...")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Visualization with cluster legend.
            HStack(spacing: 0) {
                // Cluster legend.
                VStack(alignment: .leading, spacing: 0) {
                    Text("クラスター")
                        .font(.headline)
                        .padding()

                    Divider()

                    List {
                        HStack {
                            Image(systemName: "circle.grid.3x3")
                            Text("すべて表示")
                        }
                        .onTapGesture { appState.selectedClusterLabel = nil }
                        .fontWeight(appState.selectedClusterLabel == nil ? .bold : .regular)

                        ForEach(appState.clusterSummaries) { summary in
                            HStack {
                                Circle()
                                    .fill(ClusterColors.color(for: summary.label))
                                    .frame(width: 10, height: 10)
                                Text(summary.displayName)
                                    .font(.callout)
                                    .fontWeight(appState.selectedClusterLabel == summary.label ? .bold : .regular)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(summary.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.selectedClusterLabel =
                                    appState.selectedClusterLabel == summary.label ? nil : summary.label
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
                .frame(width: 200)

                Divider()

                ScatterPlot3DView(appState: appState)
            }
        }
    }

    private func placeholder(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "cube")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("3D 散布図")
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
