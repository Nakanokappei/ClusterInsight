# 010_Engineer_Design_Update_v2

**Date:** 2026-04-13
**From:** Senior Engineer (Claude)
**To:** CTO
**Subject:** 実装結果を反映した設計確定事項の最終版

---

## 設計確定事項（最終版）

v1 からの変更を反映した、実装と完全に整合する設計確定事項の一覧です。

| 項目 | 確定内容 | v1からの変更 |
|------|---------|------------|
| アーキテクチャ | 4層構造（Presentation/Application/Domain/Infrastructure） | — |
| UI構成 | メニューバー駆動、2ウィンドウ（データ＋分析タブ） | **変更** v1: サイドバー+メインの単一ウィンドウ |
| 3D座標生成 | PCA + クラスター重心スケーリング（LAPACK ssyev_） | **変更** v1: 簡易UMAP（方式D） |
| 埋め込みモデル | text-embedding-3-small 固定（1,536次元） | — |
| トピック生成LLM | gpt-4o-mini 固定 | — |
| トピック生成方式 | データセット推定 → サイズ降順生成 → 重複検出再生成 | **変更** v1: 単純逐次生成 |
| プロンプト設計 | 具体キーワード強制、抽象化防止、良い例/悪い例を提示 | **追加** |
| 埋め込み並列 | レート制限ヘッダー適応的バッチサイズ（初期20） | **変更** v1: 固定10並列 |
| APIキー保存 | macOS Keychain（KeychainHelper） | **変更** v1: 未指定（UserDefaults） |
| 埋め込み対象列 | ユーザー選択可能（ピッカーUI） | **追加** |
| DBSCAN ε デフォルト | 0.15（範囲: 0.05〜0.50） | **変更** v1: 0.5（範囲: 0.1〜2.0） |
| 配布 | Developer ID + Notarization + Staple + ditto zip | — |
| 外部依存 | GRDB.swift のみ | — |

---

## ソースファイル一覧（最終版）

```
ClusterInsight/Sources/ (24 files, 3,012 lines)

App/
  ClusterInsightApp.swift         — メニューバー駆動の2ウィンドウ構成

Domain/Models/
  AppPhase.swift                  — 状態遷移 S0-S6 + エラー
  Dataset.swift                   — CSVデータセットモデル
  Record.swift                    — 電話応対レコードモデル
  EmbeddingModels.swift           — 埋め込み実行・ベクトルモデル
  ClusteringModels.swift          — クラスタリング実行・割当・トピックモデル
  DimensionReductionModels.swift  — 次元削減座標モデル

Domain/Analysis/
  KMeansPlusPlus.swift            — k-means++ (Accelerate)
  DBSCAN.swift                    — DBSCAN (コサイン距離)
  SimpleUMAP.swift                — PCA + クラスター重心スケーリング

Infrastructure/Database/
  DatabaseManager.swift           — GRDB マイグレーション (8テーブル)

Infrastructure/CSV/
  CSVParser.swift                 — BOM対応CSVパーサ

Infrastructure/API/
  OpenAIClient.swift              — レート制限適応的API呼び出し

Infrastructure/Keychain/
  KeychainHelper.swift            — APIキーのKeychain保存

Presentation/
  AppState.swift                  — @Observable 状態管理

Presentation/ViewModels/
  MainViewModel.swift             — パイプラインオーケストレーション

Presentation/Views/
  MainView.swift                  — メインウィンドウ（データテーブル）
  AnalysisWindow.swift            — 分析タブウィンドウ
  EmbeddingProgressView.swift     — 埋め込みタブ
  ClusterResultsWindow.swift      — クラスタリングタブ
  ScatterPlot3DWindow.swift       — 3D散布図タブ
  ScatterPlot3DView.swift         — SceneKit 3D描画
  SidebarView.swift               — ClusterColors 共有定義
  DetailView.swift                — (未使用、互換性保持)
```
