# cursor — Claude Code 用 Cursor CLI 委譲スキル

> Claude Code から `implement` / `review` / `plan` / `investigate` / `security`
> ジョブを Cursor CLI (`agent`) に非対話モードで委譲します。

**バージョン** v1.0.0 · **AS OF** 2026-04-27

> English: [README.md](./README.md)

---

## 概要

`cursor` は Claude Code 用の **スキル** で、Claude セッションの代理として
Cursor CLI の非対話ジョブ (`agent -p`) を発火します。プロンプトは Claude が
書き、外部 `agent` バイナリの駆動はこのスキルが担い、会話継続に使いやすい
1 ページの Markdown サマリだけを Claude に返します。Cursor の生 JSON は
監査用途でディスクに残り、Claude のコンテキストには **絶対に** 入りません。

設計は **同期バッチがデフォルト** です。Claude が 1 メッセージ内で複数の Bash
ツール呼び出しを発行すれば、複数の Cursor ジョブが並列に走ります。Claude
ランタイムが Bash 呼び出しを直列化する環境では、シェルレベルの
`--local-parallel` フォールバックが自動で起動します。

---

## クイックスタート

```bash
# 1. 単発の調査(read-only、worktree なし)
/cursor investigate "src/auth.ts の rate-limit 実装を説明して"

# 2. レビューとセキュリティ監査を並列実行
/cursor fanout review:src/auth.ts security:src/auth.ts

# 3. チャットを開始して後で続きを実行
CHAT_ID=$(/cursor resume --create-chat)
/cursor resume "$CHAT_ID" "今度は実装プランをください" --task plan

# 4. implement タスク — 隔離 worktree で実行される
/cursor implement "/healthz エンドポイント(200 OK json)を追加"
```

---

## 前提条件と環境構築

このスキルは純粋な Bash 実装で、外部バイナリ 4 つに依存します:
`bash`(macOS stock の **3.2** を含む)、`jq`、`timeout(1)`、`agent`(Cursor CLI)。

### 必須バイナリ

| バイナリ  | 用途                                              | 不在時の挙動           |
|-----------|---------------------------------------------------|------------------------|
| `bash`    | `lib/*.sh` の実行(macOS stock **3.2 で動作**。4.3+ は `fanout --local-parallel` の高速化のみ) | n/a (インタプリタ) |
| `jq`      | Cursor JSON 解析、設定マージ、meta ファイル生成   | exit 2 + インストール案内 |
| `timeout` | `agent` 呼び出しを 590 秒のハードタイムアウトで包む | exit 2 + インストール案内 |
| `agent`   | Cursor CLI 本体                                   | exit 2 + インストール案内 |

### 認証

最初の `/cursor` 呼び出し前に、いずれかが必須です:

- 環境変数 `CURSOR_API_KEY`(CI/共有ワークステーションで推奨)
- `agent` ログイン済みセッション(`~/.cursor/session.json` /
  `~/.cursor/cli-config.json` / `~/.cursor/chats/` のいずれかが存在)

両方とも無い場合、pre-flight が exit 2 で停止します。

> **`CURSOR_API_KEY` を `<repo>/.cursor.json` にコミットしないこと。**
> このスキルは環境変数からのみ読み取り、ディスクに書きません。

### プラットフォーム別の注意

#### Linux

```bash
# Debian / Ubuntu
sudo apt-get install -y bash jq coreutils

# Arch
sudo pacman -S --needed bash jq coreutils

# Cursor CLI — 公式インストーラを使用
curl https://cursor.com/install -fsS | bash
```

`coreutils` に `timeout(1)` が含まれます。多くのディストロに標準同梱です。

#### macOS

macOS には **BSD coreutils** しか同梱されておらず、**`timeout(1)` が
存在しません**。システムの `bash` はライセンス事情で v3.2 のままですが、
スキルはその **stock の bash 3.2 のまま動作** します — 実際に足りないのは
`timeout` だけなので GNU coreutils を入れます(bash の更新は任意):

```bash
# 1. GNU coreutils(`timeout`、`realpath` 等が入る)
brew install coreutils

# 2. 新しい Bash — 任意: fanout --local-parallel のポーリングを
#    より速い `wait -n` に置き換えるだけ。stock bash 3.2 のままでも動作します。
brew install bash

# 3. jq
brew install jq

# 4. Cursor CLI
brew install --cask cursor          # IDE 込み(`agent` 同梱)
# または
curl https://cursor.com/install -fsS | bash
```

`brew install coreutils` 後、GNU ツールは `gtimeout`、`grealpath` 等の名前で
インストールされます。**スキルは `timeout`(`g` 無し)を呼びます** ので、
GNU 版の bin ディレクトリを BSD 版より前に PATH に追加してください:

```bash
# ~/.zshrc または ~/.bash_profile
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"   # Apple Silicon
export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"      # Intel
```

確認:
```bash
which timeout && timeout --version | head -1
# /opt/homebrew/opt/coreutils/libexec/gnubin/timeout
# timeout (GNU coreutils) 9.x
```

#### Windows

Claude Code 自体は Windows ネイティブで動きますが、**このスキルは POSIX
シェルと Unix coreutils を必要とするため、ネイティブ Windows は非サポート**
です — WSL を使ってください。

**サポートされる経路は WSL2(Ubuntu / Debian)です。** WSL ディストロを
Linux マシンとして扱い、Linux の手順をそのまま適用してください。Claude Code
を WSL 内から起動すれば `~/.claude/skills/cursor/` が正しく解決されます。
Linux 版 Cursor CLI は WSL 内で素直にインストールできます。

```bash
# 管理者 PowerShell で:
wsl --install -d Ubuntu
# 再起動し Ubuntu を開いたら、WSL の中で:
sudo apt-get update && sudo apt-get install -y jq coreutils
curl https://cursor.com/install -fsS | bash
agent login
```

> **Git Bash / Cygwin は公式にはサポートしていません。** 部分的に動く可能性は
> ありますが、パス処理・ファイルモードビット・`timeout` ラップは未検証です。
> WSL を使ってください。

**WSL で動かす際の注意点:**
- `~/.cursor/worktrees/<repo>/impl-*/` は WSL 内では `/` 区切りですが、
  Windows 側ツールから見ると `\\wsl$\...` 表記になります。
  `implement` の diff レビューは WSL か Cursor 本体の中で完結させてください。
- `timeout 590s` でラップしているため、これより短いアイドルタイムアウトを
  かける Windows ターミナル(一部の企業設定)からは実行しないこと。
- 共有ワークステーションでは `umask 077` を明示すると、スキルが書き出す
  ファイルのモードビットを締められます。

### セットアップ後の確認

ユニットテストは `agent` をスタブにしているので API キー不要で実行できます:

```bash
bash ~/.claude/skills/cursor/tests/run.sh unit
```

非スキップのテストは 5 秒以内に全通過するはずです。`jq` 必須のテストは
未インストール時に exit 77(skip)になります。

---

## サブコマンド

### `dispatch` — 単発ジョブ

```
/cursor dispatch <task_type> "<prompt>" [--resume <chatId>]
/cursor <task_type> "<prompt>"                # ショートカット: dispatch 省略
```

Cursor を 1 回だけ起動します。`.cursor/delegate/` 配下に meta、生 JSON、
stderr ログ、Markdown サマリを書き出します。

**stdout 契約(厳格 2 行):**
- **1 行目**: `JOB_ID=<YYYYMMDD-HHMMSS-8hex>`
- **最終行**: `<JOB_ID>.summary.md` の絶対パス
- それ以外のログは **すべて stderr**

`<task_type>` は `implement | review | plan | investigate | security` の
いずれか。自由文からの推論は行わず、呼び出し側が必ず指定します。

### `fanout` — N 並列ジョブ

```
/cursor fanout <task1>:<prompt1> <task2>:<prompt2> [...] [--local-parallel [N]]
/cursor fanout --collect <FANOUT_TS>
/cursor fanout --clear-serialization-flag
```

デフォルトは **claude-driven** モード:Claude が N 件の並列 Bash ツール
呼び出しとして発火する機械可読なプランを出力します。全 dispatch が戻ったら
`--collect <FANOUT_TS>` を実行して結果を統合します。

> **最初の `:` のみ** が task と prompt の区切りです。プロンプト内に `:`
> があっても OK(例: `review:src/file.ts:42 30〜50 行を監査して`)。

オプション:
- `--local-parallel [N]` — `& wait` セマフォでシェル背景ジョブ実行。
  上限は `max_fanout`(既定 4)。
- `--collect <FANOUT_TS>` — 各ジョブのサマリを `fanout-<TS>.synthesis.md` に
  統合。
- `--clear-serialization-flag` — 自動検知フラグを削除。

**自動検知**: claude-driven fanout で
`wall_clock > 1.2 × max(duration_ms)` かつ N ≥ 2 を観測すると、
`.cursor/delegate/state/claude-serializes-bash` に JSON フラグを書き込み
ます。以降の fanout はそれを尊重(30 日 TTL + `omc_version` 一致)し、
自動的に `--local-parallel` に切り替えます。

### `resume` — チャット継続

```
/cursor resume <chatId> "<prompt>" [--task <task_type>]
/cursor resume --create-chat
```

`resume <chatId>` は dispatch を `--resume <chatId>` 付きで呼び、Cursor
側のセッションコンテキストを保持します。各呼び出しは `sessions.jsonl` に
追記されます:

```json
{"job_id":"...","chat_id":"...","task_type":"...","timestamp":"..."}
```

`--create-chat` は `agent create-chat` を実行し、ベストエフォートで chatId
を抽出します(JSON `.chatId` / `.chat_id` / `.id` / `.session_id`、次に
UUID 正規表現、最後に 16 文字以上の hex)。成功時は chatId を stdout、
失敗時は exit 3 と raw 出力を stderr に。

`--task <type>` の既定は `investigate`(read-only で最も安全)。

### `status` — 最近のジョブ一覧

```
/cursor status [--last N] [--since <dur>] [--with-pid]
```

`.cursor/delegate/*.meta.json` を `started_at` 降順で表示。

既定列: `JOB_ID TASK MODEL STARTED DURATION EXIT STATUS SESSION`。
ライブネスマーカ: `[RUNNING] / [DONE] / [ZOMBIE] / [CANCELLED] / [FAILED] /
[TIMED_OUT] / [MALFORMED]`。

ジョブ終了後にも残った `hooks-quarantined-*` sentinel(`~/.cursor/hooks.json`
の手動復元が必要なケース)を警告します。

### `cancel` — 実行中ジョブの停止

```
/cursor cancel <JOB_ID>
```

meta.json から PID を取り出して `SIGTERM`、5 秒待っても生きていれば
`SIGKILL`。meta を `status: "cancelled"`、`cancelled_at`、`exit_code`
(`143` = SIGTERM / `137` = SIGKILL)で更新し、hooks-quarantine を復旧
します。終了済みジョブにはべき等(exit 0、シグナル無し)。

### `orchestrate` — 自動分割委譲

```
/cursor orchestrate
```

Claude 内部のプロトコルで、複数パートからなるリクエストを Cursor 委譲可能な
サブタスクと Claude が直接処理するサブタスクに自動分割します。Claude が 2 件
以上の独立したサブタスクを識別し、うち少なくとも 1 件が標準タスクタイプ
(`review` / `security` / `investigate` / `plan` / `implement`)に該当する
場合、各タスクを委譲基準に照らして振り分けます。

**委譲基準**(すべて満たす必要あり): プロンプト自己完結、標準タスクタイプ、
ファイルスコープ、他タスクと独立、Claude Code ツール不要。

**ブロッカー**(1 つでも該当すれば委譲不可): 会話コンテキストが必要、
クロスファイルリファクタリング、他タスクの出力に依存、対話的な確認が必要、
外部データの統合が必要、アーキテクチャ判断。

委譲可能なタスクは `fanout` で Cursor へ、残りは Claude が直接処理し、
結果を統合して回答します。トリガ条件がすべて揃えば Claude がプロアクティブに
orchestrate することもあります。

詳細は [`SKILL.md`](./SKILL.md) の「Orchestrate」セクションを参照。

### `help` · `--version`

```
/cursor help | --help | -h
/cursor --version
```

---

## タスクタイプ

5 種類のみ、自由文推論は行いません:

| task_type    | 既定モデル    | 既定モード | force | worktree(必須) | sandbox |
|--------------|---------------|-----------:|------:|:----------------:|---------|
| implement    | auto          | —          | true  | **あり**         | enabled |
| review       | auto          | ask        | false | なし             | enabled |
| plan         | auto          | plan       | false | なし             | enabled |
| investigate  | auto          | ask        | false | なし             | enabled |
| security     | auto          | ask        | false | なし             | enabled |

既定モデルは全タスク **`auto`**(Cursor の「Auto」がサーバ側でモデルを選択)。
特定モデルに固定したい場合は、任意の設定レイヤでタスクごとに上書きします。

**`implement` には常に `--worktree impl-<8hex>` が付きます**(不変条件 #3)。
Cursor の worktree は `~/.cursor/worktrees/<repo>/impl-*/` に作られ、
**自動マージは行いません** — diff を見て呼び出し側が判断してください。

---

## 設定

### ファイル優先順位(deep-merge、後勝ち)

1. `~/.claude/skills/cursor/config/.cursor.json` — スキル既定
2. `~/.cursor.json` — ユーザ上書き
3. `<cwd>/.cursor.json` — プロジェクト上書き

3 レイヤとも同じ `.cursor.json` 形式(deep-merge、後勝ち)。

マージ結果は **JOB_ID ごと** に
`.cursor/delegate/state/resolved-config-<JOB_ID>.json` にスナップショット
されます — 共有パスなし、ジョブ間の TOCTOU なし。

### スキーマ(`.cursor.json`)

```jsonc
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "auto", "force": true,  "worktree": true,  "sandbox": "enabled" },
    "review":      { "model": "auto", "mode": "ask",  "sandbox": "enabled",
                     "preamble": ["コードレビュアーとして…", "", "{{prompt}}"] },
    "plan":        { "model": "auto", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "auto", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "auto", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry":       { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590,
  "max_fanout":  4
}
```

プロジェクト上書き例(`<repo>/.cursor.json`):
```json
{"defaults": {"review": {"model": "gpt-5.3-codex-high"}}}
```

既定の `auto` は Cursor がモデルを自動選択します。特定モデルに固定する場合は
`agent --list-models`(`auto` 自体も一覧に含まれます)の名前を使用してください。

### タスク別プロンプト(`preamble`)

各 `defaults.<task>` は任意の **`preamble`**(ユーザープロンプトと合成される
タスク固有テキスト)を持てます。読み取り専用レンズ(`review` / `investigate` /
`security`)はこれで差別化され既定 preamble を同梱(`implement` / `plan` は無し)。
`string` または文字列配列。`{{prompt}}` プレースホルダが在ればその位置に挿入、
無ければ前置。preamble 無しは逐語渡し。

```jsonc
"security": {
  "model": "auto", "mode": "ask",
  "preamble": [
    "あなたはセキュリティ監査の担当です。OWASP Top 10 を主軸に分析し、",
    "深刻度つきで報告してください。コードは一切変更しません。",
    "",
    "--- 監査対象 ---",
    "{{prompt}}"
  ]
}
```

詳細な仕様(配列連結・`{{prompt}}`・ディープマージ/上書き・`"preamble": ""` で
無効化・トークン消費なしのプレビュー)は設定リファレンスに集約しています:
[`references/configuration.md`](references/configuration.md)。

---

## 環境変数

| 変数                              | 用途 |
|-----------------------------------|------|
| `CURSOR_API_KEY`                  | `agent` ログインセッションが無い場合は必須。ログ出力されません。 |
| `CURSOR_DELEGATE_JOB_ID`          | 自動生成 JOB_ID を上書き(fanout が事前割当に使用)。 |
| `CURSOR_DELEGATE_QUARANTINE_HOOKS`| `0` で `~/.cursor/hooks.json` の退避を無効化(既定 `1`)。 |
| `CURSOR_DELEGATE_TIMEOUT_SEC`     | 590 秒の試行タイムアウトを上書き。 |
| `CURSOR_DELEGATE_DEBUG`           | `1` で詳細な `[cursor][DEBUG]` stderr 診断を有効化(`--debug` と同等)。 |
| `CURSOR_DELEGATE_DRY_RUN`         | `1` で `agent` 呼び出しをスキップし `status=dry_run` サマリを出力(`--dry-run` と同等。debug も含意)。 |
| `CURSOR_DELEGATE_DEBUG_PROMPT`    | `1` で dry-run サマリにプロンプト先頭 200 バイトのプレビューを追加(既定オフ。プロンプトは機微情報を含み得るため)。 |
| `CURSOR_DELEGATE_ALLOW_SYMLINK_STATE`| `1` で `.cursor` / delegate / state がシンボリックリンクであることを許容(既定 `0` で V6 が拒否)。tmpfs リダイレクト用途。 |
| `CURSOR_DELEGATE_SKIP_SANDBOX_CHECK`  | `1` で `~/.cursor` の書き込み可否 pre-flight をスキップ(別手段で書き込み可を保証済みの場合、例: CI バインドマウント)。既定 `0`。 |
| `CURSOR_DELEGATE_LOCAL_PARALLEL`  | `1` で `fanout --local-parallel` を強制。 |
| `CURSOR_DELEGATE_FORCE_CLAUDE`    | `1` で auto-flip(local-parallel)を抑止。 |
| `CURSOR_DELEGATE_FANOUT_MODE`     | 内部用 — local-parallel 時に直列化フラグ書き込みをスキップ。 |
| `CURSOR_DELEGATE_REDACT_RESULT`   | `1` で agent 結果テキストの秘密情報マスクを有効化(stderr は常時マスク)。既定 `0`。 |
| `OMC_VERSION`                     | 直列化フラグ JSON にタグ付け(既定 `"unknown"`)。 |
| `NO_COLOR`                        | `tests/run.sh` の ANSI を無効化。 |

---

## ランタイム配置

プロジェクト相対の成果物:
```
<cwd>/.cursor/delegate/<JOB_ID>.json          — Cursor 生 JSON(監査用)
<cwd>/.cursor/delegate/<JOB_ID>.err           — stderr ログ(監査用)
<cwd>/.cursor/delegate/<JOB_ID>.summary.md    — Claude が読むサマリ
<cwd>/.cursor/delegate/<JOB_ID>.meta.json     — sidecar(task/model/pid/timestamps/...)
<cwd>/.cursor/delegate/<JOB_ID>.dispatch.log  — local-parallel 子の stdout/stderr
<cwd>/.cursor/delegate/fanout-<TS>.json       — fanout プラン
<cwd>/.cursor/delegate/fanout-<TS>.synthesis.md
```

state:
```
<cwd>/.cursor/delegate/state/resolved-config-<JOB_ID>.json
<cwd>/.cursor/delegate/state/hooks-quarantined-<JOB_ID>
<cwd>/.cursor/delegate/state/sessions.jsonl
<cwd>/.cursor/delegate/state/claude-serializes-bash
```

ユーザ / ホーム配下:
```
~/.claude/skills/cursor/config/.cursor.json   — スキル既定ルーティング
~/.cursor.json                                — ユーザ上書き(任意)
~/.cursor/hooks.json.cursor.bak               — quarantine 中の hooks.json バックアップ
~/.cursor/worktrees/<repo>/impl-*/            — implement の隔離 worktree
```

> 成果物が `<cwd>/.cursor/delegate/` 以下にまとまっているのは、Cursor
> ネイティブのプロジェクトファイル(`<cwd>/.cursor/cli.json`、
> `<cwd>/.cursor/worktrees.json`)との衝突を避けるためです。

---

## 不変条件(invariants)

コードと `tests/unit/` で強制される契約:

1. **dispatch stdout 契約** — 1 行目 `JOB_ID=<id>`、最終行が `.summary.md`
   の絶対パス、それ以外は stderr。
2. **JOB ごとの設定スナップショット** — `resolved-config-<JOB_ID>.json`、
   共有パス禁止。
3. **implement の worktree** — `implement` は **常に**
   `--worktree impl-<8hex>` を付ける。v1 では opt-out 不可。
4. **agent 呼び出し** — 全 `agent` 呼び出しは `</dev/null` で stdin を閉じ、
   `timeout --kill-after=5s 590s` で包む。
5. **exit 124 は永続** — タイムアウト時のリトライ禁止(3 × 590s ≈ 30 分の
   ゾンビループを防ぐため)。
6. **コンテキスト衛生** — Claude が読むのは `.summary.md` のみ、生 `.json`
   は監査用途のみ。

---

## exit コード

| code  | 意味 |
|-------|------|
| 0     | 成功 |
| 2     | 環境/バイナリ不在/認証未設定 |
| 3     | モデル未解決、または `create-chat` 出力解析失敗 |
| 4     | 設定解決失敗 |
| 64    | 引数/使用法エラー(EX_USAGE) |
| 77    | テストスキップ(LSB 慣習、`tests/run.sh` で使用) |
| 124   | タイムアウト — 永続、リトライしない |
| 137   | SIGKILL(cancel エスカレーション) |
| 143   | SIGTERM(cancel 初期シグナル) |
| その他 | `agent` からの伝播 |

---

## 診断

**Pre-flight 失敗**(`agent` 呼び出し前に終了):
- `agent` バイナリが `$PATH` に無い → exit 2 + インストール案内
- `jq` 未インストール → exit 2 + インストール案内
- `CURSOR_API_KEY` 空かつ `agent` ログイン状態無し → exit 2
- 解決された `model` が `agent --list-models` に存在しない → exit 3 +
  候補一覧

**リトライ判定**(`cd_classify_exit`):
- `SUCCESS`(0) — 完了
- `TRANSIENT`(明示ホワイトリスト `7 / 28 / 52` = curl 接続/タイムアウト/
  空応答、`429` = レートリミット)— 指数バックオフ(1s → 2s → 4s)、
  `retry.max_attempts`(既定 3)まで
- `PERMANENT`(`2` バイナリ/認証、`3` モデル、`4` 設定、`124` タイムアウト、
  `125`、`126`、`127`、`130`、`137`、`143`)— リトライ禁止
- `UNKNOWN`(その他全部)— PERMANENT 扱い(default-deny / fail-fast)

**ログ**: 全サブコマンドは `cd_log LEVEL "message"`(LEVEL ∈
`INFO | WARN | ERROR`)で stderr に出力。stdout は上記の契約専用。

---

## デバッグ & dry-run

Cursor ジョブの不調(モデル誤り、モード誤り、想定外の worktree、hooks
quarantine の不具合など)を診断するための直交した 2 フラグです。いずれも
stdout の 2 行契約は維持され、追加出力はすべて stderr かサマリ側に入ります。

| フラグ      | 環境変数                    | 効果 |
|-------------|-----------------------------|------|
| `--debug`   | `CURSOR_DELEGATE_DEBUG=1`   | 詳細な `[cursor][DEBUG]` stderr 診断: 環境 + パス、設定レイヤチェーン、解決済み設定の全ダンプ、試行ごとの `child_pid` + 経過 ms、失敗試行の raw stderr 末尾。挙動そのものは不変。 |
| `--dry-run` | `CURSOR_DELEGATE_DRY_RUN=1` | preflight + 設定解決まで実行し、meta と「計画された `agent` コマンド」を含む `status=dry_run` サマリを書き出して exit 0。**`agent` は呼ばず**、**`~/.cursor/hooks.json` の quarantine も行いません**。`--debug` を含意。 |

両フラグは 3 通りの渡し方が可能で、呼び出し箇所に合わせて選べます:

```bash
# 1. エントリポイント経由(サブコマンドの前にフラグ)
/cursor --dry-run implement "src/foo.ts の off-by-one を修正"
/cursor --debug investigate "src/auth.ts を説明して"

# 2. 直接 dispatch — フラグは位置引数の前でも後でも可
bash ~/.claude/skills/cursor/lib/dispatch.sh --dry-run review "src/a.ts を監査"
bash ~/.claude/skills/cursor/lib/dispatch.sh review "src/a.ts を監査" --dry-run

# 3. 環境変数経由(既存の呼び出しをラップしたいとき)
CURSOR_DELEGATE_DEBUG=1 /cursor review "src/a.ts を監査"
```

`CURSOR_DELEGATE_DEBUG_PROMPT=1` を併用すると dry-run サマリにプロンプト先頭
200 バイトのプレビューも含めます(既定オフ — プロンプトは機微情報を含み得る)。

**fanout への伝播**。`--debug` / `--dry-run` は `fanout` の全子 dispatch に
伝播します。仕組みはモードで異なります: **local-parallel** モードでは子が
export 済みの環境変数を直接継承します。一方デフォルトの **claude-driven**
モードでは子が新しい Bash プロセスで起動するため(export は届かない)、
`fanout` が emit する各 dispatch 行に末尾の ` --debug` / ` --dry-run` を
焼き込みます。末尾位置なので read-only の allowlist プレフィックスは保たれ、
`--dry-run` は下流で `--debug` を含意するため付与は片方のみです。

```bash
# fanout が起動する全ジョブを Cursor トークンを消費せずプレビュー
/cursor --dry-run fanout review:src/a.ts security:src/a.ts
```

---

## 例

```bash
# ファイル調査(ショートカット形式)
/cursor investigate "src/auth.ts の rate-limit 実装を調査して"

# レビューとセキュリティ監査を並列
/cursor fanout review:src/auth.ts security:src/auth.ts

# Claude が Bash を直列化する場合に強制でシェル並列
CURSOR_DELEGATE_LOCAL_PARALLEL=1 /cursor fanout review:src/a.ts review:src/b.ts

# マルチターン会話
CHAT_ID=$(/cursor resume --create-chat)
/cursor resume "$CHAT_ID" "さっきの提案を実装プランにして" --task plan

# 長時間 implement ジョブをキャンセル
/cursor status --last 5
/cursor cancel 20260424-080102-ab12cd34

# 自動分割: Cursor がレビュー担当、Claude がアーキテクチャ判断
# (自動トリガまたは /cursor orchestrate で明示起動)

# プロジェクト単位で review モデルを上書き
echo '{"defaults": {"review": {"model": "gpt-5.3-codex-high"}}}' > .cursor.json

# ユニットテスト実行
bash ~/.claude/skills/cursor/tests/run.sh unit
```

---

## 既知の制約

Phase 4 検証項目(A1, V1–V12, F6–F8)は 2026-04-28 時点で全件解決済み。
各項目の詳細は `TODO.md` を参照。

**`--local-parallel` は bash 3.2+ で動作**: セマフォは `wait -n`(bash 4.3+)
を優先し、古い bash では **ポーリングループにフォールバック** します。
したがって macOS stock の `/bin/bash`(3.2)でもアップグレード不要で動きます。
`brew install bash` は任意で、ポーリングをイベント駆動の `wait -n` に
置き換えるだけです(どちらの経路を取ったかはログに出ます)。

### 上流 / 環境依存の注意

- `hooks.json` の headless 起動挙動は **未検証** のため、スキルは既定で
  防御的に quarantine します。`CURSOR_DELEGATE_QUARANTINE_HOOKS=0` で無効化。
- `agent create-chat` の stdout 形式はベストエフォート解析。上流が変わったら
  `resume --create-chat` の更新が必要。
- Bash ツールの 600 秒上限は Claude Code から継承。dispatch は `timeout
  590s` でその内側に収めます。

---

## 関連ドキュメント

- [`SKILL.md`](./SKILL.md) — スキルメタデータ、Claude-driven fanout プロトコル、
  トリガキーワード
- [`TODO.md`](./TODO.md) — 解決済み課題トラッカ(A1, F6–F8, V1–V12)
- [`tests/manual-qa.md`](./tests/manual-qa.md) — 5 件の手動検証ゲート
- [`tests/run.sh`](./tests/run.sh) — unit + integration ランナ
- [Cursor CLI ドキュメント](https://cursor.com/ja/docs/cli/overview)
- [`README.md`](./README.md) — 英語版

---

## 作者

Claude Code の `/oh-my-claudecode` パイプライン
(`deep-dive → ralplan → autopilot`)で 2026-04-27 に構築。3 ウェーブの
executor 実行 + ralplan コンセンサスループ。以降のメンテナンスはユーザ。

---

## 変更履歴

- **タスク別 `preamble`**(2026-06-27)— 同じ `.cursor.json` 内に置けるタスク
  固有プロンプト。`string` または文字列配列(`\n` 連結)。`{{prompt}}` プレース
  ホルダが在ればその位置にユーザープロンプトを差し込み、無ければ `\n\n---\n\n`
  区切りで前置。`preamble` 無しは逐語渡し(後方互換)で、他フィールド同様に
  ディープマージ(`"preamble": ""` で同梱既定を無効化)。読み取り専用レンズ
  (review / investigate / security、従来は argv レベルで完全同一)に既定 preamble
  を同梱、implement / plan は無し。合成は jq で実施(bash 3.2 のバックスラッシュ
  置換を回避)。`--dry-run` + `CURSOR_DELEGATE_DEBUG_PROMPT=1` で合成結果を確認可。
  新規 `test_preamble_injection.sh`、スイート 17/17。
- **設定ファイル統一 + 既定 `auto`**(2026-06-27)— スキル既定設定を
  `config/model.json` → `config/.cursor.json` に改名し 3 層が同一名・同一形に。
  既定モデルは全 task type で `auto`(Cursor がサーバ側で選択)。
- **クロスプラットフォーム対応 + `/cursor-setup`**(2026-06-26)— bash コアを
  3.2 互換・BSD coreutils 許容に強化(stock `/bin/bash` の macOS を第一級対応)。
  ネイティブ Windows より WSL を推奨。新 `cursor-setup` doctor が依存/認証を
  チェックし、読み取り専用の権限 allowlist を生成。
- **Orchestrate プロトコル**(2026-04-28)— Claude 内部の自動委譲機能。
  複数パートのリクエストを委譲基準(D1–D5)とブロッカー(B1–B6)に基づき
  Cursor(`fanout`)と Claude に自動分割。
- **TODO 一括解決(完了)**(2026-04-28)— Phase 4 検証項目 14 件すべて解決。
  A1 mkdir アトミック hooks refcount / V2 chatId バリデーション + `--`
  end-of-options / V3 アンカー付きモデル照合 / V4 dispatch.log キャプチャ /
  V5 秘密情報マスク(`CURSOR_DELEGATE_REDACT_RESULT`)/ V6 symlink ガード /
  V7 `umask 077` / V8 `wait -n` セマフォ(bash 4.3+ 必須)/ V9 設定スキーマ /
  V10 共有テスト fixture / V11 変数名修正 / V12 jq stderr / F6 TTL 表示 /
  F7 zombie ヒント。13/13 ユニットテスト通過。
- **v1.0.0**(2026-04-27)— 初回リリース。task-type ショートカット
  ディスパッチャ、5 サブコマンド、3 層設定優先順位、JOB ごとスナップショット、
  hooks quarantine、claude-driven + local-parallel fanout(自動検知付き)、
  resume / status / cancel。
- **V1 PID drift 修正**(2026-04-27)— `dispatch.sh` が agent 子プロセスの
  実 PID を `meta.json.pid` に記録するよう修正。
- **パス移行**(2026-04-27)— ランタイム成果物を `.omc/cursor/` から
  `.cursor/delegate/` に移動。
- **改名**(2026-04-27)— スキル名 `cursor-delegate` → `cursor`。環境変数と
  関数プレフィックスは未変更(`CURSOR_DELEGATE_*`、`cd_*`)で Cursor
  本体の `CURSOR_*` と衝突回避。
