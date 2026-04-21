import SwiftUI
import UniformTypeIdentifiers

// Main window: data table display only.
// CSV file opening and API key are triggered from the menu bar.
struct MainView: View {
    @Bindable var appState: AppState
    let viewModel: MainViewModel

    @State private var isShowingAPIKeySheet = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.records.isEmpty {
                WelcomeView()
            } else {
                DataTableView(records: appState.records)
            }

            Divider()

            // API key validation warning banner.
            apiKeyWarningBanner

            // Minimal status bar.
            HStack {
                if appState.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("処理中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                apiKeyStatusIndicator
                Spacer()
                if let dataset = appState.currentDataset {
                    Text(dataset.name + " — " + String(dataset.recordCount) + " 件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(appState.phaseBadge)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 700, minHeight: 400)
        .sheet(isPresented: $isShowingAPIKeySheet) {
            APIKeySheet(appState: appState, viewModel: viewModel, isPresented: $isShowingAPIKeySheet)
        }
        // Listen for menu commands via NotificationCenter.
        .onReceive(NotificationCenter.default.publisher(for: .openCSVFile)) { _ in
            openCSVFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAPIKeySheet)) { _ in
            isShowingAPIKeySheet = true
        }
    }

    // Yellow banner shown at the top when the stored API key is invalid.
    @ViewBuilder
    private var apiKeyWarningBanner: some View {
        if case .invalid(let reason) = appState.apiKeyStatus {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text("APIキー検証エラー: " + reason)
                    .font(.caption)
                    .foregroundStyle(.white)
                Spacer()
                Button("APIキーを再設定") {
                    isShowingAPIKeySheet = true
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange)
        }
    }

    // Small status indicator showing current API key validity.
    @ViewBuilder
    private var apiKeyStatusIndicator: some View {
        switch appState.apiKeyStatus {
        case .unknown:
            EmptyView()
        case .validating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("APIキー確認中...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .valid:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("APIキー有効")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .invalid:
            HStack(spacing: 4) {
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text("APIキー無効")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func openCSVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "電話応対の文字起こしCSVファイルを選択してください"

        // Restore last-used directory from saved path.
        let lastDirKey = "lastCSVDirectoryPath"
        if let savedPath = UserDefaults.standard.string(forKey: lastDirKey) {
            let dirURL = URL(fileURLWithPath: savedPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: savedPath) {
                panel.directoryURL = dirURL
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Save parent directory path for next time.
        let parentDir = url.deletingLastPathComponent().path
        UserDefaults.standard.set(parentDir, forKey: lastDirKey)

        Task { await viewModel.importCSV(url: url) }
    }
}

// MARK: - API Key Sheet

struct APIKeySheet: View {
    @Bindable var appState: AppState
    let viewModel: MainViewModel
    @Binding var isPresented: Bool
    @State private var keyInput: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("OpenAI API キー設定")
                .font(.headline)
            SecureField("sk-...", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
            HStack {
                Button("キャンセル") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    viewModel.setAPIKey(keyInput)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyInput.isEmpty)
            }
        }
        .padding(24)
        .onAppear { keyInput = appState.apiKey }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("ClusterInsight")
                .font(.largeTitle)
                .fontWeight(.light)
            Text("電話応対データのクラスタリング分析ツール")
                .foregroundStyle(.secondary)
            Text("ファイル → CSV を開く (⌘O) でデータを読み込んでください")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Table View

struct DataTableView: View {
    let records: [TranscriptRecord]

    var body: some View {
        Table(records) {
            TableColumn("No.") { record in
                Text(record.originalNo)
            }
            .width(50)
            TableColumn("日時") { record in
                Text(record.datetime ?? "")
            }
            .width(140)
            TableColumn("通話時間") { record in
                Text(record.duration ?? "")
            }
            .width(80)
            TableColumn("対応状況") { record in
                Text(record.status ?? "")
            }
            .width(80)
            TableColumn("テキスト") { record in
                Text(record.textContent.prefix(100) + (record.textContent.count > 100 ? "..." : ""))
                    .lineLimit(2)
            }
        }
    }
}
