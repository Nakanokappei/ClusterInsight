import SwiftUI

// Application entry point with menu-driven two-window architecture.
// Main window: data table. Analysis window: tabbed embedding/clustering/3D.
@main
struct ClusterInsightApp: App {
    @State private var appState = AppState()
    @State private var viewModel: MainViewModel?
    @Environment(\.openWindow) private var openWindow

    init() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        // Main window: data table display.
        Window("ClusterInsight", id: "main-window") {
            Group {
                if let viewModel {
                    MainView(appState: appState, viewModel: viewModel)
                } else {
                    ProgressView("データベースを初期化中...")
                        .frame(width: 300, height: 200)
                }
            }
            .task {
                do {
                    let database = try DatabaseManager()
                    viewModel = MainViewModel(appState: appState, database: database)
                } catch {
                    appState.phase = .apiError("データベース初期化エラー: \(error.localizedDescription)")
                }
            }
        }
        .defaultSize(width: 800, height: 500)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("CSV を開く...") {
                    NotificationCenter.default.post(name: .openCSVFile, object: nil)
                }
                .keyboardShortcut("o")
            }

            CommandMenu("分析") {
                Button("API キー設定...") {
                    NotificationCenter.default.post(name: .showAPIKeySheet, object: nil)
                }
                .keyboardShortcut("k")

                Divider()

                Button("分析ウィンドウを開く") {
                    openWindow(id: "analysis-window")
                }
                .keyboardShortcut("a")
            }
        }

        // Unified analysis window with tabs.
        Window("分析", id: "analysis-window") {
            AnalysisWindow(appState: appState, viewModel: viewModel)
        }
        .defaultSize(width: 750, height: 600)
        .defaultLaunchBehavior(.suppressed)
    }
}

extension Notification.Name {
    static let openCSVFile = Notification.Name("openCSVFile")
    static let showAPIKeySheet = Notification.Name("showAPIKeySheet")
}
