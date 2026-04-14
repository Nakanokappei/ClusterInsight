import SwiftUI

// Cluster window: parameter settings → execution with progress → summary → detail on demand.
struct ClusterResultsWindow: View {
    @Bindable var appState: AppState
    var viewModel: MainViewModel?

    // Controls whether the full cluster detail list is shown.
    @State private var showingDetail = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.currentEmbeddingRun == nil {
                placeholder(icon: "circle.grid.3x3", title: "クラスタリング",
                            message: "先に埋め込み処理を実行してください")
            } else if appState.clusterAssignments.isEmpty && !appState.isProcessing {
                // Ready to cluster: parameter settings + run button.
                clusteringSetupPanel
            } else if appState.isProcessing && appState.clusterAssignments.isEmpty {
                // Clustering in progress.
                progressPanel
            } else if showingDetail {
                // Full cluster detail list.
                detailView
            } else {
                // Summary view with action buttons.
                summaryView
            }
        }
    }

    // MARK: - Setup Panel

    private var clusteringSetupPanel: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("クラスタリング設定")
                .font(.title2)

            if let vm = viewModel {
                VStack(spacing: 12) {
                    Picker("手法", selection: $appState.clusteringMethod) {
                        ForEach(ClusteringMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .frame(width: 250)

                    switch appState.clusteringMethod {
                    case .kMeansPlusPlus:
                        Stepper("k = \(appState.kValue)", value: $appState.kValue, in: 2...20)
                            .frame(width: 200)
                    case .dbscan:
                        HStack {
                            Text("ε")
                            Slider(value: $appState.epsilon, in: 0.05...0.5, step: 0.01)
                            Text(String(format: "%.2f", appState.epsilon))
                                .monospacedDigit()
                                .frame(width: 40)
                        }
                        .frame(width: 300)
                        Text("小さいほど密なクラスター / 大きいほど統合")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Stepper("最小サンプル = \(appState.minSamples)", value: $appState.minSamples, in: 2...20)
                            .frame(width: 250)
                    }

                    Button("クラスタリング実行") {
                        Task { await vm.runClustering() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isProcessing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Progress Panel

    private var progressPanel: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("クラスタリングを実行中...")
                .font(.headline)
            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Summary View

    private var summaryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("クラスタリング完了")
                .font(.title2)

            if let run = appState.currentClusteringRun {
                HStack(spacing: 12) {
                    Text(run.method)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .cornerRadius(4)
                    Text(String(run.clusterCount) + " クラスター / " + String(appState.clusterAssignments.count) + " 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Cluster summary list (compact).
            VStack(alignment: .leading, spacing: 6) {
                ForEach(appState.clusterSummaries) { summary in
                    HStack {
                        Circle()
                            .fill(ClusterColors.color(for: summary.label))
                            .frame(width: 10, height: 10)
                        Text(summary.displayName)
                            .font(.callout)
                        Spacer()
                        Text(String(summary.count) + " 件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 400)

            // Action buttons.
            HStack(spacing: 16) {
                if let vm = viewModel {
                    if !appState.topics.isEmpty {
                        Label("トピック生成済み", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if appState.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                        Text(appState.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Button("トピック生成") {
                            Task { await vm.generateTopics() }
                        }
                        .disabled(!appState.hasAPIKey)
                    }
                }

                Button("クラスター一覧を表示") {
                    showingDetail = true
                }

                Button("再クラスタリング") {
                    showingDetail = false
                    appState.clusterAssignments = []
                    appState.topics = []
                    appState.currentClusteringRun = nil
                    appState.coordinates = []
                    appState.phase = .embeddingComplete
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail View

    private var detailView: some View {
        VStack(spacing: 0) {
            // Header with back button.
            HStack {
                Button {
                    showingDetail = false
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }

                Text("クラスター一覧")
                    .font(.title3)
                    .fontWeight(.medium)

                Spacer()

                if let run = appState.currentClusteringRun {
                    Text(run.method + " / " + String(run.clusterCount) + " クラスター")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            List {
                ForEach(appState.clusterSummaries) { summary in
                    Section {
                        if let topicText = summary.topicText {
                            Text(topicText)
                                .font(.callout)
                                .padding(.vertical, 4)
                        }

                        let clusterRecordIds = Set(
                            appState.clusterAssignments
                                .filter { $0.clusterLabel == summary.label }
                                .map(\.recordId)
                        )
                        let clusterRecords = appState.records.filter { r in
                            guard let rid = r.id else { return false }
                            return clusterRecordIds.contains(rid)
                        }

                        ForEach(clusterRecords.prefix(8)) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("No." + record.originalNo)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(record.status ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(record.textLength) + " 文字")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(String(record.textContent.prefix(150)))
                                    .font(.caption)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if clusterRecords.count > 8 {
                            Text("他 " + String(clusterRecords.count - 8) + " 件...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } header: {
                        HStack {
                            Circle()
                                .fill(ClusterColors.color(for: summary.label))
                                .frame(width: 10, height: 10)
                            Text(summary.displayName)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(String(summary.count) + " 件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Placeholder

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
