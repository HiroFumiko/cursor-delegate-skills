# cursor-delegate

> English: [README.md](./README.md)

コーディング作業を **Cursor CLI**(`agent`)に肩代わりさせる Claude Code プラグインです。環境を整えるスキルと、委譲を実行するスキルの 2 つからなり、レビュー・監査・計画・実装といった仕事を(必要なら複数まとめて)Cursor に任せている間、Claude は手を止めずに別の作業を進められます。

## 同梱スキル

| スキル | 起動コマンド | 役割 |
|--------|--------------|------|
| `cursor-setup` | `/cursor-delegate:cursor-setup` | **環境を整える。** OS を判別し、依存コマンドと認証をまとめて確認したうえで(Cursor のトークンは消費しません)、読み取り専用タスク用の権限 allowlist を設定します。マシンごとに最初の 1 回だけ実行します。 |
| `cursor` | `/cursor-delegate:cursor` | **実際に委譲する。** implement / review / plan / investigate / security の各タスクを Cursor に渡します。単発実行のほか、並列実行(`fanout`)、`resume` / `status` / `cancel`、タスクごとの `preamble` に対応。使い方の詳細は [`cursor/README_ja.md`](plugins/cursor-delegate/skills/cursor/README_ja.md) を参照してください。 |

この 2 つは一体で動きます。`cursor-setup` は `cursor` と同じエンジン(`lib/setup.sh`)を使い、どちらも実行時に `${CLAUDE_PLUGIN_ROOT}/skills/cursor/…` を参照します。そのため、セットアップ側と委譲側でパス・モデル・権限がずれることはありません。

## 全体の流れ

```
   install plugin                       プラグインを導入
        │
        ▼
   /cursor-delegate:cursor-setup        最初の 1 回: 依存 · 認証 · 権限
        │   READY ✓
        ▼
   /cursor-delegate:cursor <task …>     日常: Cursor へ委譲
        │
        ├─ review / investigate / security / plan   (読み取り専用、自動承認)
        ├─ implement                                (worktree、まず確認)
        └─ fanout a:… b:…                           (並列ジョブ)
```

## できること

**委譲側(`cursor`)**
- タスクタイプは `implement` / `review` / `plan` / `investigate` / `security` の 5 種類だけ。自由文から勝手に推測することはありません。
- 並列実行(`fanout`)に加え、`resume` / `status` / `cancel`、そしてトークンを使わない `--dry-run` を備えています。
- タスクごとに `preamble` を差し込んで役割を持たせられます。挙動は `.cursor.json` で決まるので(3 層の deep-merge)、いつ実行しても同じ結果になります。
- 読み取り専用のタスクは確認なしで実行し、ファイルを書き換える `implement` は必ず確認を挟みます。

**準備側(`cursor-setup`)**
- OS を判別し(WSL / Linux / macOS。ネイティブ Windows は WSL へ誘導)、環境ごとの対処手順を示します。
- 依存コマンドと認証を診断します(`agent` を呼ばないのでトークンは一切かかりません)。
- `~/.claude/settings.json` の権限 allowlist を生成・点検します。
- macOS 標準の **bash 3.2** をそのまま正式サポート。BSD 版 coreutils にも対応しています。

## 動作要件

- `bash`(macOS 標準の 3.2 で動作)、`jq`、`timeout` / `gtimeout`(coreutils)
- インストール・認証済みの Cursor CLI(`agent`)。認証は `CURSOR_API_KEY` か `agent login` のどちらかで行います
- 対応プラットフォームは WSL Ubuntu / Linux / macOS です。ネイティブ Windows は非対応なので WSL を使ってください。これらはすべて `cursor-setup` がまとめて確認します。

## クイックスタート

```
# 1. マーケットプレイスを追加してプラグインをインストール
/plugin marketplace add HiroFumiko/cursor-delegate-skills
/plugin install cursor-delegate@cursor-delegate

# 2. 初回の準備チェック(依存・認証を検証し、権限設定を提案)
/cursor-delegate:cursor-setup

# 3. 委譲する
/cursor-delegate:cursor review "audit src/auth.ts"
/cursor-delegate:cursor fanout review:src/a.ts security:src/a.ts
```

プラグインを編集したら `/reload-plugins` で再読み込みします。

## モデルの指定(`.cursor.json`)

各タスクは `.cursor.json` で決まる `model` に振り分けられます。初期値はすべて **`auto`**(モデルは Cursor 側で自動選択)なので、何も設定しなくてもそのまま使えます。モデルを固定したいときだけ、いずれかの設定レイヤで `model` を指定してください。

**モデル名は `agent --list-models` で確認できます。** 出力は 1 行が `<名前> - <説明>` の形式で、**` - ` より左がモデル名**です。この先頭部分をそのまま `.cursor.json` に書きます。

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

| `agent --list-models` の行 | `"model"` に書く値 |
|----------------------------|--------------------|
| `auto - Auto (current)`                              | `"auto"`                          |
| `gpt-5.3-codex-high - Codex 5.3 High`                | `"gpt-5.3-codex-high"`            |
| `claude-opus-4-8-thinking-high - Opus 4.8 1M Thinking` | `"claude-opus-4-8-thinking-high"` |

固定したいタスクだけを、適用したい範囲に合うレイヤに書きます。

```jsonc
// <repo>/.cursor.json — このプロジェクトに限って review と security を固定する例
{
  "defaults": {
    "review":   { "model": "gpt-5.3-codex-high" },
    "security": { "model": "claude-opus-4-8-thinking-high" }
  }
}
```

設定は次の 3 層を deep-merge し、下の層ほど優先されます。

1. `${CLAUDE_PLUGIN_ROOT}/skills/cursor/config/.cursor.json` — プラグイン同梱の既定値
2. `~/.cursor.json` — ユーザー全体の上書き
3. `<cwd>/.cursor.json` — プロジェクト単位の上書き(リポジトリに commit すれば共有できます)

マージは項目ごとに行われるので、`review.model` だけを書いた `<repo>/.cursor.json` でも、`mode` や `preamble`、`sandbox` といった他の項目は下の層の値がそのまま残ります。

指定したモデルは、起動時に `agent --list-models` と照合されます。照合は行頭から一致を見るため、`composer-2` が `composer-2.5` に誤ってマッチすることはありません。一覧にない名前を書いた場合はその場で exit 3 で停止し、利用可能な候補を表示します。Cursor へは何も送られないので、タイプミスでトークンを無駄にする心配はありません。

スキーマの全体像、ルーティングの既定値、`auto` の仕組みは [`skills/cursor/references/configuration.md`](plugins/cursor-delegate/skills/cursor/references/configuration.md) にまとめてあります。

## ディレクトリ構成

```
cursor-delegate/
├── .claude-plugin/
│   └── marketplace.json                 # マーケットプレイス manifest(source -> ./plugins/cursor-delegate)
├── plugins/
│   └── cursor-delegate/
│       ├── .claude-plugin/
│       │   └── plugin.json              # プラグイン manifest
│       └── skills/                      # 自動で読み込まれる
│           ├── cursor/                  # 委譲エンジン(lib/, config/, references/, tests/)
│           └── cursor-setup/            # 準備用ドクター(cursor/lib/setup.sh を共有)
├── README.md                            # 英語版
└── README_ja.md                         # このファイル
```

## 補足

- スキルは `BASH_SOURCE` で自分の置き場所を割り出すため、どこに置いても動きます。各 `SKILL.md` の起動コマンドも `${CLAUDE_PLUGIN_ROOT}` を使うので、インストール先を問いません。
- スキルごとに、より詳しいドキュメント(`skills/cursor/README.md` / `README_ja.md` と `references/`)が付属します。ただしこちらは `~/.claude/skills/` への**手動**インストールを前提とした説明です。プラグインとして使う場合は、上記のクイックスタートに従ってください。
- ユニットテストも同梱しています(`bash skills/cursor/tests/run.sh unit`)。`agent` をスタブ化するので API キーは不要、macOS の bash 3.2 でも 17 件すべて通ります。
