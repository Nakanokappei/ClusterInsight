import SwiftUI

// Embedding window: column selection, run button, and real-time progress.
// Auto-closes 2 seconds after embedding completes.
struct EmbeddingProgressView: View {
    @Bindable var appState: AppState
    var viewModel: MainViewModel?
    // No dismiss — this view lives inside a tab, not an independent window.

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("埋め込み処理")
                .font(.title2)

            if appState.currentEmbeddingRun != nil {
                // Completed state with close button.
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("埋め込み完了")
                        .font(.headline)
                    if let run = appState.currentEmbeddingRun {
                        Text("モデル: " + run.modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("次元数: " + String(run.dimensions) + " / 処理件数: " + String(run.totalRecords))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("「クラスタリング」タブに進んでください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else if appState.isProcessing && appState.progressTotal > 0 {
                // Active progress.
                VStack(spacing: 12) {
                    ProgressView(value: appState.progressValue, total: appState.progressTotal)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(String(Int(appState.progressValue)) + " / " + String(Int(appState.progressTotal)) + " 件")
                            .monospacedDigit()
                        Spacer()
                        let pct = appState.progressTotal > 0
                            ? Int(appState.progressValue / appState.progressTotal * 100) : 0
                        Text(String(pct) + "%")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 40)
            } else if let vm = viewModel, appState.currentDataset != nil {
                // Ready to run: show column selection and run button.
                VStack(spacing: 12) {
                    if !appState.columnHeaders.isEmpty {
                        Picker("対象列", selection: $appState.selectedColumn) {
                            ForEach(appState.columnHeaders, id: \.self) { col in
                                Text(columnDisplayName(col)).tag(col)
                            }
                        }
                        .frame(width: 250)
                    }

                    if !appState.hasAPIKey {
                        Label("API キーが未設定です", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("分析 → API キー設定... (⌘K) から設定してください")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("埋め込み実行") {
                            Task { await vm.runEmbedding() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isProcessing)
                    }
                }
            } else {
                Text("先に CSV ファイルを開いてください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func columnDisplayName(_ col: String) -> String {
        switch col {
        case "textContent": return "文字起こし"
        case "status": return "対応状況"
        case "duration": return "通話時間"
        case "datetime": return "日時"
        case "originalNo": return "No."
        default: return col
        }
    }
}
