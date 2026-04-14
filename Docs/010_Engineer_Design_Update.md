# 010_Engineer_Design_Update

**Date:** 2026-04-13
**From:** Senior Engineer (Claude)
**To:** CTO
**Subject:** 009_CTO_Design_Phase_Decisions_v1.md を反映した設計差分

---

## 概要

CTO判断（009）を設計提案（008）に反映した差分を以下に示します。
指示された6項目すべてに対応しました。

本文書の承認をもって、**設計フェイズの完了を宣言**いただきたく存じます。

---

## 差分一覧

### 差分1: UMAP方式Dを正式採用と明記

**008 原文（セクション4.3）:**
> 推奨: 方式D — Swift簡易UMAP実装
> リスク緩和策: 実装後にPython版umap-learnの結果と比較検証を行い、不十分であれば方式Bにフォールバック。

**変更後:**
> **確定: 方式D — Swift簡易UMAP実装**
> - CTO判断（009）により正式採用
> - 外部依存を増やさずローカル完結性を維持する方針
> - Python版との比較検証は品質確認として実施するが、方式Bへのフォールバックは計画しない

008 セクション4.4「CTOへの判断依頼」は解決済みにつき削除。

---

### 差分2: 簡易UMAPのパラメータ初期値を設計に反映

**008 原文（セクション4.3）:**
> パラメータ: n_neighbors: 15, min_dist: 0.1, n_epochs: 200

**変更後:**

| パラメータ | 値 | 備考 |
|-----------|-----|------|
| n_neighbors | 15 | 局所構造の解像度。500件に対して妥当 |
| min_dist | 0.1 | 点の最小間隔。小さいほどクラスターが密集 |
| n_epochs | 200 | SGD反復回数。500件なら十分な収束 |
| learning_rate | 1.0 | SGDの学習率。標準的な初期値 |
| negative_sample_rate | 5 | 各正例ペアに対する負例サンプル数 |

UIでの変更は不要（固定値）。デモ用途のため、パラメータ調整UIは設けない。

---

### 差分3: 埋め込みモデル固定に伴うモデル選択分岐の削除

**008 原文（セクション7.1）:**
> API: OpenAI Embeddings API（`text-embedding-3-small`、1,536次元を想定）

**変更後:**
> API: OpenAI Embeddings API — **`text-embedding-3-small` 固定**（1,536次元）
> - CTO判断（009）により固定。他モデルへの切り替え機能は実装しない
> - embedding_runs テーブルの model_name は固定値 "text-embedding-3-small" を記録

**UI影響:**
- 設定画面の埋め込みモデル選択UIを削除
- APIキー入力のみを設定画面に残す

**アーキテクチャ影響:**
- EmbeddingProvider プロトコルは維持するが、実装は OpenAIEmbeddingProvider のみ
- モデル名の外部注入は不要。定数として保持

---

### 差分4: トピック生成LLM固定に伴うモデル選択分岐の削除

**008 原文（セクション5.3）:**
> プロンプト構造（モデル未指定）

**変更後:**
> LLMモデル: **`gpt-4o-mini` 固定**
> - CTO判断（009）により固定。他モデルへの切り替え機能は実装しない
> - topics テーブルの model_name は固定値 "gpt-4o-mini" を記録

**UI影響:**
- 設定画面のトピック生成LLM選択UIを削除

**アーキテクチャ影響:**
- CompletionProvider プロトコルは維持するが、実装は OpenAICompletionProvider のみ
- API呼び出し時のモデル名は定数として保持

---

### 差分5: 署名・公証フローを配布設計に追加

**008 には配布設計セクションが未記載。以下を新規追加。**

#### 配布設計

##### ビルド・署名・公証フロー

```
[1] Xcode Archive
       │
       ▼
[2] Developer ID 署名
    - signing identity: "Developer ID Application: {チーム名}"
    - Hardened Runtime 有効化（公証の前提条件）
    - entitlements:
      - com.apple.security.network.client = true  (API通信)
      - com.apple.security.files.user-selected.read-only = true  (CSVファイル読込)
       │
       ▼
[3] 公証（Notarization）
    - `xcrun notarytool submit` で Apple に提出
    - 審査完了（通常数分）を待機
    - `xcrun stapler staple` で公証チケットを埋め込み
       │
       ▼
[4] 検証
    - `spctl --assess --verbose` で Gatekeeper 通過を確認
    - 別の Mac で起動テスト（初回起動時の警告が出ないことを確認）
       │
       ▼
[5] 配布
    - `.app` を zip 圧縮（ditto --norsrc --noextattr 使用）
    - 社内掲示板にアップロード
```

##### Entitlements 設計

| Entitlement | 値 | 理由 |
|------------|-----|------|
| com.apple.security.network.client | true | OpenAI API への HTTPS 通信 |
| com.apple.security.files.user-selected.read-only | true | NSOpenPanel でのCSVファイル選択 |
| com.apple.security.app-sandbox | true | App Sandbox（公証推奨） |

##### 配布時の制約事項

- 対応OS: macOS Tahoe 26 以上
- Apple Silicon / Intel 両対応（Universal Binary）
- 初回起動時にインターネット接続が必要（Gatekeeper のオンライン検証）
- OpenAI APIキーは各ユーザーが自身で設定する（アプリ内に埋め込まない）

---

### 差分6: 設計書差分の総括

以下に、008 → 010 の変更を総括します。

| セクション | 変更種別 | 内容 |
|-----------|---------|------|
| 4.3 UMAP導入方式 | 確定 | 方式D正式採用。フォールバック計画を削除 |
| 4.3 UMAPパラメータ | 追加 | learning_rate, negative_sample_rate を追加定義 |
| 4.4 CTO判断依頼 | 削除 | 解決済み |
| 7.1 埋め込み処理 | 変更 | モデル固定（text-embedding-3-small） |
| 5.3 トピック生成 | 変更 | モデル固定（gpt-4o-mini） |
| UI設計 | 変更 | モデル選択UI 2箇所を削除 |
| 配布設計 | 新規追加 | 署名・公証・配布フロー全体を追加 |
| 10 未解決事項 | 削除 | 3件すべて解決済み |

---

## CTO補佐指摘事項への対応状況

| 補佐指摘 | 対応 |
|---------|------|
| 状態遷移とUI制御の整合 | 008 セクション3 で定義済み。差分なし |
| SQLiteスキーマと実行履歴保存の整合 | 008 セクション2 で定義済み。モデル固定に伴い model_name を定数化 |
| UMAP結果とクラスター表示の視覚的一貫性 | 008 セクション6.3 で定義済み。差分なし |
| 公証済みアプリ配布手順の明文化 | 本文書の差分5 で新規追加 |

---

## 設計フェイズ完了の確認

すべての設計事項が確定しました。未解決事項はありません。

| 項目 | 状態 |
|------|------|
| アーキテクチャ（4層構造） | ✅ 確定 |
| SQLiteスキーマ（8テーブル） | ✅ 確定 |
| 状態遷移（S0〜S6 + エラー2種） | ✅ 確定 |
| UMAP導入方式（方式D: Swift簡易実装） | ✅ 確定 |
| 埋め込みモデル（text-embedding-3-small固定） | ✅ 確定 |
| トピック生成LLM（gpt-4o-mini固定） | ✅ 確定 |
| トピック生成フロー（逐次生成） | ✅ 確定 |
| UIフロー（サイドバー＋メインコンテンツ） | ✅ 確定 |
| 3D可視化（SceneKit + UMAP座標） | ✅ 確定 |
| 配布（Developer ID署名 + 公証） | ✅ 確定 |

**CTOに設計フェイズ完了の宣言を依頼します。**
