# 008_Engineer_Design_Proposal

**Date:** 2026-04-13
**From:** Senior Engineer (Claude)
**To:** CTO
**Subject:** 007_CTO_Design_Phase_Instruction_v1.md に対する設計提案

---

## 総合評価

設計指示の方向性は妥当であり、実装可能と判断します。
本文書にて6つの依頼事項すべてに設計案を提示します。

**重要な技術的指摘が1件あります（UMAP導入方式）。** 詳細は「4. UMAP導入方式」を参照してください。

---

## 1. アーキテクチャ設計案

### 1.1 レイヤ構成

```
┌─────────────────────────────────────────────┐
│  Presentation Layer (SwiftUI)               │
│  - Views / ViewModels                       │
│  - 3D Visualization (SceneKit)              │
├─────────────────────────────────────────────┤
│  Application Layer                          │
│  - UseCases (ImportCSV, RunEmbedding,       │
│    RunClustering, GenerateTopics, RunUMAP)  │
│  - AppState (状態遷移管理)                    │
├─────────────────────────────────────────────┤
│  Domain Layer                               │
│  - Models (Dataset, Record, Embedding,      │
│    Cluster, Topic, UMAPCoordinate)          │
│  - Analysis (KMeans, DBSCAN, UMAP, PCA)    │
│  - Protocols (EmbeddingProvider,            │
│    CompletionProvider)                      │
├─────────────────────────────────────────────┤
│  Infrastructure Layer                       │
│  - SQLiteStore (GRDB)                       │
│  - OpenAIClient (URLSession)               │
│  - CSVParser                                │
└─────────────────────────────────────────────┘
```

### 1.2 技術スタック

| 領域 | 技術 | 理由 |
|------|------|------|
| UI | SwiftUI | macOS標準。宣言的UIで迅速な開発 |
| 3D可視化 | SceneKit | macOS内蔵。散布図の描画に十分 |
| DB | SQLite (GRDB.swift) | ローカル完結。GRDBはSwift Concurrency対応済み |
| HTTP | URLSession | 標準ライブラリ。追加依存なし |
| 数値計算 | Accelerate | 行列演算・距離計算に最適。OS内蔵 |
| 並列処理 | Swift Structured Concurrency | TaskGroup による並列API呼び出し |
| CSV解析 | 自作またはSwiftCSV | BOM対応が必要（データにBOM付きUTF-8を確認済み） |

### 1.3 外部依存（Swift Package）

| パッケージ | 用途 |
|-----------|------|
| GRDB.swift | SQLite ORM |
| (UMAP実装) | 後述 — 自作 or ライブラリ |

> **方針:** 外部依存は最小限に抑える。数値計算はAccelerateで自前実装し、サードパーティへの依存リスクを回避する。

---

## 2. SQLiteスキーマ定義

### 2.1 ER構造

```
datasets ──1:N── records
datasets ──1:N── embedding_runs ──1:N── embeddings
                                  └──1:N── dimension_reductions
datasets ──1:N── clustering_runs ──1:N── cluster_assignments
clustering_runs ──1:N── topics
```

### 2.2 テーブル定義

#### datasets

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| name | TEXT | NOT NULL | CSVファイル名 |
| file_path | TEXT | NOT NULL | 元ファイルパス |
| record_count | INTEGER | NOT NULL | レコード数 |
| imported_at | TEXT | NOT NULL | ISO 8601 |

#### records

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| dataset_id | INTEGER | FK → datasets.id | |
| original_no | TEXT | NOT NULL | CSV元番号 |
| datetime | TEXT | | 通話日時 |
| duration | TEXT | | 通話時間 |
| status | TEXT | | 対応状況 |
| text_content | TEXT | NOT NULL | 文字起こし本文 |
| text_length | INTEGER | NOT NULL | 文字数 |

#### embedding_runs

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| dataset_id | INTEGER | FK → datasets.id | |
| model_name | TEXT | NOT NULL | e.g. "text-embedding-3-small" |
| dimensions | INTEGER | NOT NULL | ベクトル次元数 |
| token_limit | INTEGER | NOT NULL | 適用したトークン上限 |
| total_records | INTEGER | NOT NULL | 処理対象件数 |
| skipped_records | INTEGER | NOT NULL DEFAULT 0 | スキップ件数（空テキスト等） |
| created_at | TEXT | NOT NULL | ISO 8601 |

#### embeddings

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| embedding_run_id | INTEGER | FK → embedding_runs.id | |
| record_id | INTEGER | FK → records.id | |
| vector | BLOB | NOT NULL | Float32配列のバイナリ表現 |

> **設計判断:** ベクトルはBLOB型で格納。500件×1,536次元×4bytes = 約3MBであり、SQLiteで十分扱えるサイズ。JSON配列よりも読み書きが高速で省スペース。

#### dimension_reductions

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| embedding_run_id | INTEGER | FK → embedding_runs.id | |
| method | TEXT | NOT NULL | "UMAP" |
| parameters | TEXT | NOT NULL | JSON (n_neighbors, min_dist等) |
| created_at | TEXT | NOT NULL | ISO 8601 |

#### dimension_reduction_coords

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| reduction_id | INTEGER | FK → dimension_reductions.id | |
| record_id | INTEGER | FK → records.id | |
| x | REAL | NOT NULL | |
| y | REAL | NOT NULL | |
| z | REAL | NOT NULL | |

> **設計判断:** UMAP座標はクラスタリングと独立（埋め込み結果のみに依存）。別テーブルにすることで、クラスタリングを再実行しても座標は再利用できる。

#### clustering_runs

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| dataset_id | INTEGER | FK → datasets.id | |
| embedding_run_id | INTEGER | FK → embedding_runs.id | |
| method | TEXT | NOT NULL | "kmeans++" / "dbscan" |
| parameters | TEXT | NOT NULL | JSON (k, epsilon, min_samples等) |
| cluster_count | INTEGER | NOT NULL | 生成クラスター数 |
| created_at | TEXT | NOT NULL | ISO 8601 |

#### cluster_assignments

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| clustering_run_id | INTEGER | FK → clustering_runs.id | |
| record_id | INTEGER | FK → records.id | |
| cluster_label | INTEGER | NOT NULL | クラスター番号（-1=ノイズ/DBSCAN） |

#### topics

| Column | Type | Constraint | Description |
|--------|------|------------|-------------|
| id | INTEGER | PK AUTOINCREMENT | |
| clustering_run_id | INTEGER | FK → clustering_runs.id | |
| cluster_label | INTEGER | NOT NULL | 対象クラスター番号 |
| topic_text | TEXT | NOT NULL | LLM生成トピック |
| representative_ids | TEXT | NOT NULL | JSON配列 (record_id群) |
| model_name | TEXT | NOT NULL | 使用LLMモデル |
| created_at | TEXT | NOT NULL | ISO 8601 |

### 2.3 インデックス

```sql
CREATE INDEX idx_records_dataset ON records(dataset_id);
CREATE INDEX idx_embeddings_run ON embeddings(embedding_run_id);
CREATE INDEX idx_embeddings_record ON embeddings(record_id);
CREATE INDEX idx_coords_reduction ON dimension_reduction_coords(reduction_id);
CREATE INDEX idx_assignments_run ON cluster_assignments(clustering_run_id);
CREATE INDEX idx_topics_run ON topics(clustering_run_id);
```

---

## 3. 状態遷移設計

### 3.1 状態遷移図

```
                    ┌──────────────────────────────────────┐
                    │          E_API: API呼び出し失敗        │
                    │   (リトライ or 前状態に戻る)            │
                    └──────┬───────────────────────────────┘
                           │ (どの API 呼び出し状態からも遷移)
                           ▼
  ┌──────┐  CSV読込  ┌──────┐  列選択  ┌──────┐
  │  S0  │─────────▶│  S1  │────────▶│  S2  │
  │初期状態│          │データ │          │列選択 │
  └──────┘          │読込済 │          │  済  │
                    └──┬───┘          └──┬───┘
                       │                  │
              別CSV読込 │          埋め込み実行│
              で S1に戻る│                  ▼
                       │            ┌──────┐  クラスタ実行  ┌──────┐
                       │            │  S4  │──────────────▶│  S5  │
                       │            │埋込完了│               │クラスタ│
                       │            └──────┘               │  完了 │
                       │                 ▲                  └──┬───┘
                       │                 │ 再埋め込みで          │
                       │                 │ S5,S6を破棄        トピック生成
                       │                 │                    ▼
                       │                 │              ┌──────┐
                       │                 │              │  S6  │
                       │                 │              │全完了 │
                       │                 │              └──────┘
                       │                 │
                    ┌──┴───┐             │
                    │E_DATA│             │
                    │データ  │─────────────┘
                    │不整合 │  再実行を促す
                    └──────┘
```

### 3.2 状態定義と UI 制御

| 状態 | 条件 | 有効な操作 | 無効な操作 |
|------|------|-----------|-----------|
| S0 初期 | アプリ起動直後 | CSV読み込み、APIキー設定 | 他すべて |
| S1 データ読込済 | CSV解析完了 | 列選択、CSV再読み込み | 埋め込み、クラスタリング、トピック、3D |
| S2 列選択済 | テキスト列確定 | 埋め込み実行（APIキー設定済みの場合） | クラスタリング、トピック、3D |
| S3 APIキー未設定 | S2かつキー空 | APIキー設定 | 埋め込み実行 |
| S4 埋め込み完了 | 全レコード処理済み | クラスタリング実行、UMAP実行 | トピック生成 |
| S5 クラスタリング完了 | クラスター割当済み | トピック生成、3D表示、再クラスタリング | — |
| S6 全完了 | トピック生成済み | 全操作、結果閲覧 | — |
| E_API | API呼び出し失敗 | リトライ、キー再設定 | 後続処理 |
| E_DATA | データ不整合検出 | 再実行を促すアラート表示 | 不整合データでの続行 |

### 3.3 状態巻き戻しルール

再実行時に下流の結果を自動破棄する：

| 操作 | 破棄対象 |
|------|---------|
| CSV再読み込み | embeddings, dimension_reductions, clustering, topics すべて |
| 埋め込み再実行 | dimension_reductions, clustering, topics |
| クラスタリング再実行 | topics のみ（UMAP座標は保持） |

### 3.4 データ整合性検証

| タイミング | 検証内容 | 不整合時の動作 |
|-----------|---------|---------------|
| クラスタリング実行前 | embedding_run.total_records == 現レコード数 | アラート表示、再埋め込みを促す |
| トピック生成前 | clustering_run.embedding_run_id が最新か | アラート表示、再クラスタリングを促す |
| アプリ起動時 | 保存済みデータセットのファイルパス存在確認 | 警告表示（処理は続行可能） |

---

## 4. UMAP導入方式

### 4.1 課題

UMAPはPython (`umap-learn`) では成熟していますが、**Swift向けの成熟したUMAPライブラリは存在しません。** これは本プロジェクト最大の技術的判断ポイントです。

### 4.2 選択肢の比較

| 方式 | メリット | デメリット | 工数 |
|------|---------|-----------|------|
| **A. Swift自前実装** | 外部依存ゼロ、配布が簡潔 | 実装工数大（KNN+SGD）、精度検証が必要 | 大 |
| **B. Pythonサブプロセス** | umap-learn直接使用、高精度 | Python同梱が必要、アプリサイズ増大 | 中 |
| **C. 事前計算済みバイナリ同梱** | 高速 | データが固定される、汎用性なし | 小 |
| **D. Swift自前実装（簡易版）** | 外部依存ゼロ、500件なら十分 | 大規模データに非対応 | 中 |

### 4.3 推奨: 方式D — Swift簡易UMAP実装

**500件のデモデータに特化した簡易版UMAPをSwiftで実装**することを推奨します。

理由：
- 500件×1,536次元であれば、距離行列（500×500）は約1MBで計算量も軽微
- Accelerateフレームワークでベクトル演算を高速化可能
- 外部依存ゼロでアプリ配布が簡潔（公証も通しやすい）
- 完全なUMAPではなく、コア部分（KNN + 模倣的SGD最適化）に絞れば実装は現実的

実装の核心部分：
1. **ペアワイズ距離計算** — Accelerate (vDSP) でコサイン距離を高速算出
2. **K近傍グラフ構築** — 距離行列から上位K個を抽出
3. **模倣的力学モデル** — 近傍ペアに引力、非近傍に斥力を適用してSGDで3D座標を最適化

パラメータ：
- `n_neighbors`: 15（デフォルト）
- `min_dist`: 0.1（デフォルト）
- `n_epochs`: 200（500件なら十分）

> **リスク緩和策:** 実装後にPython版umap-learnの結果と比較検証を行い、クラスター分離性が十分であることを確認する。不十分であれば方式Bにフォールバック。

### 4.4 CTOへの判断依頼

方式Dを推奨しますが、以下の場合は方式Bが適切です：
- 500件を超えるデータにも対応したい場合
- Python（Homebrew等）が全員のMacに導入済みという前提がある場合

**いずれの方式にするか、CTO判断を仰ぎます。**

---

## 5. トピック生成フロー設計

### 5.1 全体フロー

```
クラスタリング完了
       │
       ▼
[1] グラウンディング用ランダム抽出（データセット全体から20件）
       │
       ▼
[2] クラスター順に逐次処理（cluster_label = 0, 1, 2, ...）
       │
       ├─▶ [2a] 代表データ抽出（重心に近い5件）
       │
       ├─▶ [2b] プロンプト構築（グラウンディング + 既生成トピック + 代表データ）
       │
       ├─▶ [2c] LLM呼び出し → トピックテキスト取得
       │
       ├─▶ [2d] topics テーブルに保存
       │
       └─▶ 次のクラスターへ（[2b]で今回の結果を既生成トピックに追加）
       │
       ▼
全クラスター完了 → S6へ遷移
```

### 5.2 代表データ抽出ロジック

1. クラスター内の全埋め込みベクトルの重心（平均ベクトル）を計算
2. 各レコードと重心のコサイン距離を算出
3. 距離が近い順に上位5件を抽出
4. テキストが8Kトークン上限を超過する場合は後方切り捨て済みの版を使用

> **設計判断:** ランダム抽出ではなく重心近傍を選ぶことで、クラスターの「典型例」を安定的に取得できる。

### 5.3 プロンプト構造

```
[システムプロンプト]
あなたは電話応対データの分析アシスタントです。
以下はデータセット全体のランダムサンプルです。全体の傾向を把握してください。
---
{20件のランダムサンプル（各100文字に要約 or 冒頭100文字）}
---

[既生成トピック（2番目以降のクラスターで追加）]
以下は他のクラスターに付与済みのトピック名です。
今回のクラスターはこれらとは異なる特徴を持っています。重複しない観点で要約してください。
- クラスター0: {トピックテキスト}
- クラスター1: {トピックテキスト}
---

[ユーザープロンプト]
以下はあるクラスターの代表的な電話応対記録です。
このクラスターの共通テーマを、簡潔な日本語のトピック名（20文字以内）と
説明文（100文字以内）で表現してください。

代表データ:
1. {レコード1のテキスト}
2. {レコード2のテキスト}
...
5. {レコード5のテキスト}

出力形式:
トピック名: ...
説明: ...
```

### 5.4 保存と再表示

- **保存単位:** clustering_run_id 単位。1回のクラスタリングに対して全クラスターのトピックをセットで保存。
- **破棄条件:** 再クラスタリング時に全トピックを削除。
- **再表示:** topics テーブルから clustering_run_id で引き当て。

---

## 6. UIフロー設計

### 6.1 画面構成

```
┌─────────────────────────────────────────────────────────┐
│  ToolBar: [CSV読込] [APIキー設定]                          │
├──────────────────────┬──────────────────────────────────┤
│                      │                                  │
│  Sidebar             │  Main Content                    │
│                      │                                  │
│  ┌────────────────┐  │  ┌──────────────────────────┐    │
│  │ データセット情報  │  │  │                          │    │
│  │ - ファイル名     │  │  │  (状態に応じて切り替え)     │    │
│  │ - 件数          │  │  │                          │    │
│  │ - 読込日時       │  │  │  S0-S2: 設定パネル        │    │
│  └────────────────┘  │  │  S4:    埋め込み結果       │    │
│                      │  │  S5-S6: 分析結果           │    │
│  ┌────────────────┐  │  │         + 3D可視化         │    │
│  │ 分析パラメータ    │  │  │                          │    │
│  │ - 埋め込みモデル   │  │  │                          │    │
│  │ - クラスタ手法    │  │  │                          │    │
│  │ - パラメータ      │  │  └──────────────────────────┘    │
│  └────────────────┘  │                                  │
│                      │                                  │
│  ┌────────────────┐  │                                  │
│  │ クラスター一覧    │  │                                  │
│  │ - トピック名     │  │                                  │
│  │ - 件数          │  │                                  │
│  │ (選択で連動)     │  │                                  │
│  └────────────────┘  │                                  │
│                      │                                  │
├──────────────────────┴──────────────────────────────────┤
│  StatusBar: [進捗バー] [状態メッセージ]                      │
└─────────────────────────────────────────────────────────┘
```

### 6.2 メインコンテンツ切り替え

| 状態 | メインコンテンツ |
|------|---------------|
| S0 | ウェルカム画面（CSV読み込みを促すメッセージ） |
| S1 | データプレビュー（テーブル表示）+ 列選択UI |
| S2 | 埋め込み実行ボタン + パラメータ設定 |
| S4 | 埋め込み完了サマリ + クラスタリング設定 |
| S5 | クラスター結果テーブル + 3D散布図 + トピック生成ボタン |
| S6 | クラスター結果テーブル + 3D散布図 + トピック表示 |

### 6.3 3D可視化の操作設計

- **描画:** SceneKit の SCNView を SwiftUI にラップ（NSViewRepresentable）
- **散布図:** 各レコードを球体ノード（SCNSphere）で描画
- **色分け:** クラスターラベルに応じた色をマテリアルに適用
- **凡例:** 3Dビュー横にクラスター色 + トピック名のリストを表示
- **選択連動:** サイドバーでクラスターを選択 → 該当点をハイライト（不透明度変更）
- **カメラ操作:** SCNView の allowsCameraControl = true（マウスドラッグで回転・ズーム）

---

## 7. 分析アルゴリズム設計

### 7.1 埋め込み処理

- **API:** OpenAI Embeddings API（`text-embedding-3-small`、1,536次元を想定）
- **並列処理:** TaskGroup で最大10並列（API rate limit考慮）
- **進捗表示:** 完了件数 / 全件数をStatusBarに表示
- **エラーハンドリング:** 個別レコードの失敗は3回リトライ後にスキップ（skipped_recordsに計上）
- **中断・再開:** 未実装（500件であれば全件再実行で十分。デモ用途の割り切り）

### 7.2 クラスタリング

#### k-means++
- **初期化:** k-means++法（最初の重心をランダム、以降は距離に比例した確率で選択）
- **距離関数:** コサイン距離（埋め込みベクトルにはユークリッドよりコサインが適切）
- **収束条件:** 重心の変化量 < 1e-6 または最大反復100回
- **k値:** UIでユーザーが指定（デフォルト: 5、範囲: 2〜20）

#### DBSCAN
- **距離関数:** コサイン距離
- **ε（epsilon）:** UIでユーザーが指定（デフォルト: 0.5、スライダー: 0.1〜2.0）
- **最小サンプル数（min_samples）:** UIでユーザーが指定（デフォルト: 3、範囲: 2〜20）
- **ノイズ点:** cluster_label = -1 として割り当て、3D表示ではグレーで描画

### 7.3 UMAP（簡易版）

- **入力:** 全レコードの埋め込みベクトル（N×D行列、N=500, D=1536）
- **出力:** N×3座標行列
- **アルゴリズム概要:**
  1. コサイン距離によるペアワイズ距離行列を計算（Accelerate使用）
  2. 各点のK近傍（K=15）を抽出
  3. 対称化した類似度グラフを構築
  4. 3D空間でランダム初期配置
  5. SGDにより引力（近傍ペア）・斥力（非近傍）を適用して座標を最適化
  6. 200エポック反復

---

## 8. 非機能要件への対応

| 要件 | 対応方針 |
|------|---------|
| 500件で実用的な応答時間 | 埋め込み: 並列10リクエストで約50秒。クラスタリング/UMAP: 数秒。トピック生成: 逐次で約30秒（クラスター数依存） |
| メモリ使用量 | 500×1536×4bytes = 3MB（埋め込み）。距離行列500×500×4bytes = 1MB。合計10MB以下 |
| API呼び出し最適化 | 埋め込み: バッチAPI未使用（1件1リクエスト、並列化で対応）。トピック: クラスター数分のみ |
| エラーハンドリング | API失敗→3回リトライ→スキップ。DB書き込み失敗→トランザクションロールバック |

---

## 9. 技術的リスクと緩和策

| リスク | 影響 | 緩和策 |
|--------|------|--------|
| 簡易UMAP実装の品質不足 | クラスターが視覚的に分離しない | Python版と比較検証。不十分なら方式B（Pythonサブプロセス）にフォールバック |
| OpenAI API変更・障害 | 埋め込み/トピック生成不可 | エラーメッセージ表示、保存済みデータでの閲覧は可能 |
| macOS Tahoe 26 API変更 | SceneKit非推奨化の可能性 | Tahoe 26のリリースノート確認後、必要に応じてRealityKitに切り替え |
| BOM付きCSVの解析 | 文字化け | BOM検出・スキップ処理を実装 |

---

## 10. 設計フェイズ未解決事項（CTO判断待ち）

1. **UMAP導入方式:** 方式D（Swift簡易実装）を推奨。承認 or 方式B（Python）の判断を仰ぐ。
2. **埋め込みモデル:** `text-embedding-3-small`（1,536次元）を想定。他モデルの検討は不要か。
3. **トピック生成LLM:** `gpt-4o-mini` 等の軽量モデルで十分と判断。承認を仰ぐ。

---

## 結論

設計案を上記のとおり提示します。
UMAP導入方式について**CTO判断をいただければ、設計フェイズを完了**できます。

それ以外の設計内容については、実装可能性を確認済みであり、懸念はありません。
