# cursor-delegate

> English: [README.md](./README.md)

コーディング作業を **Cursor CLI**(`agent`)へ委譲する Claude Code プラグイン。
環境を **準備する** スキルと、委譲を **実行する** スキルの 2 つを同梱しており、
レビュー / 監査 / 計画 / 実装のジョブを(複数を並列で)Cursor に渡しつつ、
Claude は別の作業を続けられます。

## 同梱物

| スキル | 起動 | 役割 |
|--------|------|------|
| `cursor-setup` | `/cursor-delegate:cursor-setup` | **準備する。** OS を検出し、依存関係と認証を 1 パスで点検(Cursor トークン消費なし)、読み取り専用の権限 allowlist を設定。マシンごとに 1 回実行。 |
| `cursor` | `/cursor-delegate:cursor` | **作業する。** implement / review / plan / investigate / security タスクを Cursor へ委譲 — 単発ジョブ、並列 `fanout`、`resume` / `status` / `cancel`、タスク別 `preamble`。実行方法は [`cursor/README_ja.md`](plugins/cursor-delegate/skills/cursor/README_ja.md) を参照。 |

2 つは一体です。`cursor-setup` は `cursor` が使うのと同じエンジン
(`lib/setup.sh`)を駆動し、両者とも実行時に
`${CLAUDE_PLUGIN_ROOT}/skills/cursor/…` に解決されます — そのため setup と
委譲はパス・モデル・権限について常に一致します。

## 全体の流れ

```
   install plugin                       プラグインを導入
        │
        ▼
   /cursor-delegate:cursor-setup        一度だけ: 依存 · 認証 · 権限
        │   READY ✓
        ▼
   /cursor-delegate:cursor <task …>     日常: Cursor へ委譲
        │
        ├─ review / investigate / security / plan   (読み取り専用、自動承認)
        ├─ implement                                (worktree、まず確認)
        └─ fanout a:… b:…                           (並列ジョブ)
```

## 機能概要

**委譲(`cursor`)**
- 明示的な 5 タスクタイプ — `implement` / `review` / `plan` / `investigate` / `security`(自由文からの推論は一切なし)。
- 並列 `fanout`、さらに `resume` / `status` / `cancel`、トークン消費ゼロの `--dry-run`。
- タスク別 `preamble` で各レンズを特化。`.cursor.json` による決定論的な設定(3 層 deep-merge)。
- 読み取り専用レンズはプロンプトなしで実行。書き込み(`implement`)は常に確認。

**準備(`cursor-setup`)**
- OS 検出(WSL / Linux / macOS。ネイティブ Windows → WSL)と OS 別の修正手順。
- 依存 + 認証ドクター(`agent` を呼ばず、トークンコストゼロ)。
- `~/.claude/settings.json` の権限 allowlist を生成 / 監査。
- macOS stock の **bash 3.2** を第一級サポート。BSD coreutils も許容。

## 要件

- `bash`(macOS stock 3.2 をサポート)、`jq`、`timeout` / `gtimeout`(coreutils)
- Cursor CLI(`agent`)がインストール済みかつ認証済み(`CURSOR_API_KEY` または `agent login`)
- プラットフォーム: WSL Ubuntu / ネイティブ Linux / macOS が第一級。ネイティブ
  Windows は非サポート — WSL を使用。`cursor-setup` がこれらをすべて点検します。

## クイックスタート

```
# 1. このマーケットプレイスを追加してプラグインをインストール
/plugin marketplace add HiroFumiko/cursor-delegate-skills
/plugin install cursor-delegate@cursor-delegate

# 2. 一度だけの準備チェック(依存/認証を検証し、権限設定を提案)
/cursor-delegate:cursor-setup

# 3. 委譲
/cursor-delegate:cursor review "audit src/auth.ts"
/cursor-delegate:cursor fanout review:src/a.ts security:src/a.ts
```

プラグイン編集後はリロード: `/reload-plugins`。

## モデルの選択(`.cursor.json`)

各タスクタイプは `.cursor.json` から解決される `model` にルーティングされます。
同梱のデフォルトは **`auto`**(Cursor がサーバ側でモデルを選択)なので、始める
にあたって設定は不要です。特定のモデルに固定したい場合は、任意の設定レイヤで
`model` を指定します。

**モデル名は `agent --list-models` から取得します。** 各行は
`<name> - <description>` 形式で出力され、**` - ` の左側のトークンがモデル名**
です — この先頭のプレフィックスを `.cursor.json` で参照します。そのままコピー
します:

```
$ agent --list-models
Available models

auto - Auto (current)
gpt-5.3-codex - Codex 5.3
gpt-5.3-codex-high - Codex 5.3 High
claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking
composer-2.5 - Composer 2.5
…
```

| `agent --list-models` の行 | 使用する `"model"` 値 |
|----------------------------|------------------------|
| `auto - Auto (current)`                              | `"auto"`                          |
| `gpt-5.3-codex-high - Codex 5.3 High`                | `"gpt-5.3-codex-high"`            |
| `claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking` | `"claude-opus-4-8-thinking-high"` |

タスクタイプごとに、対象スコープに合うレイヤで設定します:

```jsonc
// <repo>/.cursor.json — このプロジェクトだけ review と security を固定
{
  "defaults": {
    "review":   { "model": "gpt-5.3-codex-high" },
    "security": { "model": "claude-opus-4-8-thinking-high" }
  }
}
```

優先順位は 3 レイヤの **deep-merge(後勝ち)** です:

1. `${CLAUDE_PLUGIN_ROOT}/skills/cursor/config/.cursor.json` — スキル既定
2. `~/.cursor.json` — ユーザ上書き(どこでも適用)
3. `<cwd>/.cursor.json` — プロジェクト上書き(リポジトリに commit して共有)

マージはリーフ単位なので、`review.model` だけを設定した `<repo>/.cursor.json`
は、他のフィールド(`mode`、`preamble`、`sandbox` …)を下位レイヤから引き継ぎ
ます。

**検証。** 解決されたモデルは起動時に `agent --list-models` と照合され、行頭
トークンにアンカーされます(そのため `composer-2` は `composer-2.5` にマッチ
しません)。未知の名前は exit 3 で即座に失敗し、利用可能な一覧を表示します —
Cursor へは何も送られないため、タイプミスでトークンを消費しません。

完全なスキーマ・ルーティング既定・`auto` の挙動は
[`skills/cursor/references/configuration.md`](plugins/cursor-delegate/skills/cursor/references/configuration.md)
にあります。

## 構成

```
cursor-delegate/
├── .claude-plugin/
│   └── marketplace.json                 # マーケットプレイス manifest(source -> ./plugins/cursor-delegate)
├── plugins/
│   └── cursor-delegate/
│       ├── .claude-plugin/
│       │   └── plugin.json              # プラグイン manifest
│       └── skills/                      # 自動検出される
│           ├── cursor/                  # 委譲エンジン(lib/, config/, references/, tests/)
│           └── cursor-setup/            # 準備ドクター(cursor/lib/setup.sh を共有)
├── README.md                            # 英語版 README
└── README_ja.md                         # このファイル
```

## 補足

- スキル内部は `BASH_SOURCE` で自身の位置を解決するため、エンジンはパス非依存
  です。各 `SKILL.md` の起動コマンドは `${CLAUDE_PLUGIN_ROOT}` を使い、プラグイン
  のインストール先がどこでも動作します。
- 同梱の各スキルは独自の詳細ドキュメントを持ちます: `skills/cursor/README.md` /
  `README_ja.md`(および `references/`)。これらは `~/.claude/skills/` 下への
  **手動** インストールを説明しています。プラグイン利用時は上記の手順に従って
  ください。
- ユニットテストがプラグインに同梱されています:
  `bash skills/cursor/tests/run.sh unit`(`agent` をスタブ化、キー不要)—
  macOS bash 3.2 で 17/17。
