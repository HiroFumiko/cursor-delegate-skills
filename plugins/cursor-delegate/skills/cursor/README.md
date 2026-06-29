# cursor — Cursor CLI delegation skill for Claude Code

> Delegate `implement` / `review` / `plan` / `investigate` / `security` jobs from
> Claude Code to the Cursor CLI (`agent`) in non-interactive mode.

**VERSION** v1.0.0 · **AS OF** 2026-04-27

---

## What this is

`cursor` is a Claude Code **skill** that fires Cursor CLI non-interactive jobs
(`agent -p`) on behalf of a Claude session. Claude writes the prompt, this skill
drives the external `agent` binary, and a condensed Markdown summary is
returned for continued conversation. The raw Cursor JSON is kept on disk for
audit only — it never enters Claude's context.

The design is **synchronous-batch by default**: multiple Cursor jobs can run in
parallel when Claude fires several Bash tool calls in one message. A
shell-level `--local-parallel` fallback auto-activates if Claude's runtime
serializes Bash calls.

---

## Quick start

```bash
# 1. one-shot investigation (read-only, no worktree)
/cursor investigate "src/auth.ts の rate-limit 実装を説明して"

# 2. parallel review + security audit
/cursor fanout review:src/auth.ts security:src/auth.ts

# 3. start a chat, continue it later
CHAT_ID=$(/cursor resume --create-chat)
/cursor resume "$CHAT_ID" "今度は実装プランをください" --task plan

# 4. implement task — runs in an isolated Cursor worktree
/cursor implement "add a /healthz endpoint with 200 OK json"
```

---

## Prerequisites & environment setup

The skill is pure Bash. It shells out to four external binaries:
`bash` (macOS stock **3.2** is supported), `jq`, `timeout(1)`, and `agent`
(Cursor CLI).

### Required binaries

| Binary    | Purpose                                            | Pre-flight error if missing |
|-----------|----------------------------------------------------|-----------------------------|
| `bash`    | All `lib/*.sh` scripts — macOS stock **3.2 works**; 4.3+ only speeds up `fanout --local-parallel` | n/a (interpreter) |
| `jq`      | Parse Cursor JSON, merge config, write meta files  | exit 2 with install hint    |
| `timeout` | Wrap every `agent` call in a 590 s hard timeout    | exit 2 with install hint    |
| `agent`   | The Cursor CLI itself                              | exit 2 with install hint    |

### Authentication

One of the following must be in place **before** the first `/cursor` call:

- `CURSOR_API_KEY` env var (preferred for CI / shared workstations).
- A logged-in `agent` session — i.e. one of `~/.cursor/session.json`,
  `~/.cursor/cli-config.json`, or `~/.cursor/chats/` exists.

Pre-flight refuses to start (exit 2) if neither is present.

> **Never** commit `CURSOR_API_KEY` to a project's `.cursor.json`. The skill
> reads it from the env only and never writes it to disk.

### Platform notes

#### Linux

```bash
# Debian / Ubuntu
sudo apt-get install -y bash jq coreutils

# Arch
sudo pacman -S --needed bash jq coreutils

# Cursor CLI — follow upstream installer
curl https://cursor.com/install -fsS | bash
```

`coreutils` ships `timeout(1)`. Most distros include it by default.

#### macOS

macOS bundles **BSD coreutils**, which **does not include `timeout(1)`**, and
its `bash` is stuck at v3.2 (license reasons). The skill runs on that stock
**bash 3.2 as-is** — only `timeout` is genuinely missing, so install GNU
coreutils (updating bash is optional):

```bash
# 1. GNU coreutils (gives you `timeout`, `realpath`, etc.)
brew install coreutils

# 2. Newer Bash — OPTIONAL: only swaps fanout --local-parallel's poll loop for
#    the faster `wait -n`. The skill works on stock bash 3.2 without this.
brew install bash

# 3. jq
brew install jq

# 4. Cursor CLI
brew install --cask cursor          # IDE; bundles `agent`
# or
curl https://cursor.com/install -fsS | bash
```

After `brew install coreutils`, GNU tools are namespaced as `gtimeout`,
`grealpath`, etc. **The skill calls `timeout` (no `g` prefix)**, so add the
GNU bin dir to `PATH` ahead of the BSD versions:

```bash
# ~/.zshrc or ~/.bash_profile
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"   # Apple Silicon
export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"      # Intel
```

Verify:
```bash
which timeout && timeout --version | head -1
# /opt/homebrew/opt/coreutils/libexec/gnubin/timeout
# timeout (GNU coreutils) 9.x
```

#### Windows

Claude Code itself runs natively on Windows, but **this skill requires a POSIX
shell plus Unix coreutils, so native Windows is not supported** — use WSL.

**WSL2 (Ubuntu / Debian) is the supported path.** Treat the WSL distro as a
Linux machine and follow the Linux instructions above. Run Claude Code from
inside WSL so the skill resolves `~/.claude/skills/cursor/` correctly; Cursor
CLI for Linux installs cleanly inside WSL.

```bash
# In an elevated PowerShell:
wsl --install -d Ubuntu
# Reboot, open Ubuntu, then INSIDE WSL:
sudo apt-get update && sudo apt-get install -y jq coreutils
curl https://cursor.com/install -fsS | bash
agent login
```

> **Git Bash / Cygwin are not officially supported.** They may partially work,
> but path handling, file-mode bits, and the `timeout` wrap are untested there —
> use WSL.

**Notes when running under WSL:**
- `~/.cursor/worktrees/<repo>/impl-*/` paths use forward slashes inside WSL but
  may surface as `\\wsl$\...` from Windows-side tooling — keep `implement`
  diff-review inside WSL or Cursor itself.
- The 590 s `timeout` wrap matters: do not run the skill from a shell that
  imposes its own shorter idle timeout (some corporate Windows terminals do).
- On a shared workstation, `umask 077` tightens the file-mode bits the skill
  writes.

### One-time verification

After setup, run the unit tests — they stub `agent` so no API key is needed:

```bash
bash ~/.claude/skills/cursor/tests/run.sh unit
```

All non-skipped tests should pass in under 5 seconds. Tests gated on `jq`
will exit 77 (skipped) if you forgot to install it.

---

## Installation (team distribution)

The skill is a self-contained directory under `~/.claude/skills/cursor/`.
For team sharing, three patterns work:

1. **Vendor into a shared dotfiles repo.** Each teammate symlinks
   `~/.claude/skills/cursor/` → `<dotfiles>/claude/skills/cursor/`. Simplest;
   updates land via `git pull`.

2. **Per-project copy.** Drop the directory into a repo's `.claude/skills/`
   subfolder. Claude Code picks it up project-locally. Use this when the
   skill's behavior should diverge per project.

3. **Plugin / marketplace install.** If your team uses
   `oh-my-claudecode` or a similar plugin loader, package this directory as
   a plugin and install via the loader's mechanism.

After install, confirm the slash command resolves:

```
/cursor --version
# cursor v1.0.0
```

Project-level overrides can live in `<repo>/.cursor.json` and ship with the
codebase (see [Configuration](#configuration)).

---

## Subcommands

### `dispatch` — single job

```
/cursor dispatch <task_type> "<prompt>" [--resume <chatId>]
/cursor <task_type> "<prompt>"                # shortcut: dispatch implied
```

Runs exactly one Cursor invocation. Writes a meta sidecar, raw JSON, stderr
log, and Markdown summary under `.cursor/delegate/`.

**Stdout contract (strict, 2 lines):**
- **First line**: `JOB_ID=<YYYYMMDD-HHMMSS-8hex>`
- **Last line**: absolute path to `<JOB_ID>.summary.md`
- All logs → **stderr**.

`<task_type>` ∈ `implement | review | plan | investigate | security`.
Task types are never inferred from free text — the caller must name one.

### `fanout` — N parallel jobs

```
/cursor fanout <task1>:<prompt1> <task2>:<prompt2> [...] [--local-parallel [N]]
/cursor fanout --collect <FANOUT_TS>
/cursor fanout --clear-serialization-flag
```

Default mode (**claude-driven**): emit a machine-readable plan that Claude
fires as N parallel Bash tool calls. After all dispatches return, run
`--collect <FANOUT_TS>` to synthesize results.

> Only the **first `:`** delimits task and prompt — prompts may contain colons
> (e.g. `review:src/file.ts:42 please audit lines 30-50`).

Options:
- `--local-parallel [N]` — run dispatches as shell background jobs with
  `& wait` semaphore. Bounded by `max_fanout` (default 4).
- `--collect <FANOUT_TS>` — synthesize per-job summaries into
  `fanout-<TS>.synthesis.md`.
- `--clear-serialization-flag` — delete the auto-detect flag.

**Auto-detect**: if a claude-driven fanout shows
`wall_clock > 1.2 × max(duration_ms)` with N ≥ 2, a JSON flag is written under
`.cursor/delegate/state/claude-serializes-bash`. Subsequent fanouts honor it
(30-day TTL + `omc_version` match) and auto-flip to `--local-parallel`.

### `resume` — continue a chat

```
/cursor resume <chatId> "<prompt>" [--task <task_type>]
/cursor resume --create-chat
```

`resume <chatId>` invokes dispatch with `--resume <chatId>`, preserving
Cursor-side session context. Each call appends to `sessions.jsonl`:

```json
{"job_id":"...","chat_id":"...","task_type":"...","timestamp":"..."}
```

`--create-chat` calls `agent create-chat` and best-effort parses the chatId
(JSON `.chatId` / `.chat_id` / `.id` / `.session_id`, then UUID regex, then
16+-char hex). Emits the chatId on stdout, or exits 3 with raw output on
parse failure.

`--task <type>` defaults to `investigate` (read-only, safest).

### `status` — recent jobs table

```
/cursor status [--last N] [--since <dur>] [--with-pid]
```

Lists jobs from `.cursor/delegate/*.meta.json` sorted by `started_at` desc.

Default columns: `JOB_ID TASK MODEL STARTED DURATION EXIT STATUS SESSION`.
Liveness markers: `[RUNNING] / [DONE] / [ZOMBIE] / [CANCELLED] / [FAILED] /
[TIMED_OUT] / [MALFORMED]`.

Also warns about stale `hooks-quarantined-*` sentinels whose owning jobs
have terminated without restoring `~/.cursor/hooks.json`.

### `cancel` — terminate a running job

```
/cursor cancel <JOB_ID>
```

`SIGTERM` the job's PID (from meta.json), wait ≤ 5 s, then `SIGKILL` if alive.
Updates meta with `status: "cancelled"`, `cancelled_at`, and `exit_code`
(`143` SIGTERM / `137` SIGKILL). Restores hooks-quarantine. Idempotent on
already-finished jobs.

### `orchestrate` — auto-split & delegate

```
/cursor orchestrate
```

A Claude-internal protocol that automatically decomposes a multi-part request
into Cursor-delegable and Claude-handled sub-tasks. When Claude identifies 2+
independent sub-tasks where at least one maps to a standard task type
(`review` / `security` / `investigate` / `plan` / `implement`), it evaluates
each against delegation criteria and splits work accordingly.

**Delegation criteria** (all must hold): self-contained prompt, standard task
type, file-scoped targets, independent of other tasks, no Claude Code tools
needed.

**Blockers** (any one disqualifies): requires conversation context, cross-file
refactoring, depends on another task's output, needs interactive dialogue,
requires external data, involves architecture decisions.

Delegable tasks go to Cursor via `fanout`; the rest Claude handles directly.
Results are integrated into a unified response. Claude may orchestrate
proactively when all trigger conditions are met.

See [`SKILL.md`](./SKILL.md) § "Orchestrate" for the full criteria tables,
execution protocol, and examples.

### `help` · `--version`

```
/cursor help | --help | -h
/cursor --version
```

---

## Task types

Exactly five, never inferred from free text:

| task_type    | default model | default mode | force | worktree (mandatory) | sandbox |
|--------------|---------------|-------------:|------:|:--------------------:|---------|
| implement    | auto          | —            | true  | **yes**              | enabled |
| review       | auto          | ask          | false | no                   | enabled |
| plan         | auto          | plan         | false | no                   | enabled |
| investigate  | auto          | ask          | false | no                   | enabled |
| security     | auto          | ask          | false | no                   | enabled |

The shipped default is **`auto`** for every task type (Cursor's "Auto" picks the
model server-side). Override per task in any config layer to pin a specific model.

**`implement` always receives `--worktree impl-<8hex>`** (invariant #3). The
Cursor worktree lives at `~/.cursor/worktrees/<repo>/impl-*/` and is **never
merged automatically** — the caller reviews the diff and decides.

---

## Configuration

### File precedence (deep-merged, last wins)

1. `~/.claude/skills/cursor/config/.cursor.json` — skill default
2. `~/.cursor.json` — user override
3. `<cwd>/.cursor.json` — project override

All three layers share the same `.cursor.json` shape (deep-merged, last wins).

The merged result is snapshotted **per JOB_ID** to
`.cursor/delegate/state/resolved-config-<JOB_ID>.json` at invocation time —
no shared path, no cross-job TOCTOU.

### Schema (`.cursor.json`)

```jsonc
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "auto", "force": true,  "worktree": true,  "sandbox": "enabled" },
    "review":      { "model": "auto", "mode": "ask",  "sandbox": "enabled",
                     "preamble": ["You are a code reviewer…", "{{prompt}}"] },
    "plan":        { "model": "auto", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "auto", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "auto", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry":       { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590,
  "max_fanout":  4
}
```

Project override example (`<repo>/.cursor.json`):
```json
{"defaults": {"review": {"model": "gpt-5.3-codex-high"}}}
```

A fully annotated, copy-pasteable reference of every field lives in
[`config/.cursor.example.json`](config/.cursor.example.json) — strip its `//`
comments and keep only the keys you want to override. Or generate a ready-to-use
config automatically: `bash lib/setup.sh --init-config user|project` writes a
copy of the shipped defaults you can edit in place (a full copy pins those
values, so delete any field you'd rather keep tracking the skill default).

The default `auto` lets Cursor pick. To pin a model, use a name from
`agent --list-models` (which also lists `auto` itself).

### Per-task prompt (`preamble`)

Each `defaults.<task>` may carry an optional **`preamble`** — task-specific text
combined with the user prompt. It is what differentiates the read-only lenses
(`review` / `investigate` / `security` ship default preambles; `implement` /
`plan` ship none). A `string` or array-of-strings; a `{{prompt}}` placeholder
marks where the user prompt is inserted (else it is prepended); no preamble →
verbatim.

```jsonc
"security": {
  "model": "auto", "mode": "ask",
  "preamble": [
    "You run the security audit. Analyze the target centered on the OWASP Top 10,",
    "and report findings with severity. Do not modify any code.",
    "{{prompt}}"
  ]
}
```

Full mechanics (array-join, `{{prompt}}`, deep-merge/override, `"preamble": ""`
to disable, token-free preview) are in the canonical config reference:
[`references/configuration.md`](references/configuration.md).

---

## Environment variables

| Variable                          | Purpose |
|-----------------------------------|---------|
| `CURSOR_API_KEY`                  | Required unless `agent login` session exists. Never logged. |
| `CURSOR_DELEGATE_JOB_ID`          | Override the auto-generated JOB_ID (used by fanout to pre-assign IDs). |
| `CURSOR_DELEGATE_QUARANTINE_HOOKS`| `0` disables the `~/.cursor/hooks.json` move-aside dance (default `1`). |
| `CURSOR_DELEGATE_TIMEOUT_SEC`     | Override the 590 s per-attempt timeout. |
| `CURSOR_DELEGATE_DEBUG`           | `1` enables verbose `[cursor][DEBUG]` stderr breadcrumbs (same as `--debug`). |
| `CURSOR_DELEGATE_DRY_RUN`         | `1` skips the `agent` call and emits a `status=dry_run` summary (same as `--dry-run`; implies debug). |
| `CURSOR_DELEGATE_DEBUG_PROMPT`    | `1` adds a 200-byte prompt-head preview to the dry-run summary (off by default — prompts can be sensitive). |
| `CURSOR_DELEGATE_ALLOW_SYMLINK_STATE`| `1` allows `.cursor` / delegate / state to be a symlink (default `0` → V6 hard-fails). Use for tmpfs redirection. |
| `CURSOR_DELEGATE_SKIP_SANDBOX_CHECK`  | `1` skips the `~/.cursor` writability pre-flight (use when writability is guaranteed another way, e.g. CI bind-mounts). Default `0`. |
| `CURSOR_DELEGATE_LOCAL_PARALLEL`  | `1` forces `fanout --local-parallel` mode. |
| `CURSOR_DELEGATE_FORCE_CLAUDE`    | `1` disables auto-flip to local-parallel even when the flag is set. |
| `CURSOR_DELEGATE_FANOUT_MODE`     | Internal — lets `synthesize.sh` skip the flag write in local-parallel. |
| `CURSOR_DELEGATE_REDACT_RESULT`   | `1` enables secret redaction on agent result text (in addition to stderr, which is always redacted). Default `0`. |
| `OMC_VERSION`                     | Tagged into the serialization-flag JSON (default `"unknown"`). |
| `NO_COLOR`                        | Disables ANSI in `tests/run.sh`. |

---

## Runtime layout

Project-relative artifacts:
```
<cwd>/.cursor/delegate/<JOB_ID>.json          — raw Cursor JSON (audit)
<cwd>/.cursor/delegate/<JOB_ID>.err           — stderr log (audit)
<cwd>/.cursor/delegate/<JOB_ID>.summary.md    — Claude-readable summary
<cwd>/.cursor/delegate/<JOB_ID>.meta.json     — sidecar (task/model/pid/timestamps/...)
<cwd>/.cursor/delegate/<JOB_ID>.dispatch.log  — local-parallel child stdout/stderr
<cwd>/.cursor/delegate/fanout-<TS>.json       — fanout plan
<cwd>/.cursor/delegate/fanout-<TS>.synthesis.md
```

State:
```
<cwd>/.cursor/delegate/state/resolved-config-<JOB_ID>.json
<cwd>/.cursor/delegate/state/hooks-quarantined-<JOB_ID>
<cwd>/.cursor/delegate/state/sessions.jsonl
<cwd>/.cursor/delegate/state/claude-serializes-bash
```

User / home-scoped:
```
~/.claude/skills/cursor/config/.cursor.json   — skill-default routing
~/.cursor.json                                — user override (optional)
~/.cursor/hooks.json.cursor.bak               — Cursor hooks.json backup during quarantine
~/.cursor/worktrees/<repo>/impl-*/            — implement-task isolated worktree
```

> The skill's artifacts live under `<cwd>/.cursor/delegate/` — a subdirectory
> reserved to avoid collision with Cursor-native project files
> (`<cwd>/.cursor/cli.json`, `<cwd>/.cursor/worktrees.json`).

---

## Invariants

These contracts are enforced in code and in `tests/unit/`:

1. **Dispatch stdout contract** — `JOB_ID=<id>` first line, absolute
   `.summary.md` path last, all logs on stderr.
2. **Per-JOB config snapshot** — `resolved-config-<JOB_ID>.json`; no shared
   path.
3. **Implement worktree** — `implement` task type **always** gets
   `--worktree impl-<8hex>`. No opt-out in v1.
4. **Agent invocation** — every `agent` call uses `</dev/null` for stdin and
   is wrapped in `timeout --kill-after=5s 590s`.
5. **Exit 124 = PERMANENT** — retry-on-timeout is forbidden (3 × 590 s ≈ 30
   min zombie loop otherwise).
6. **Context hygiene** — Claude reads only `.summary.md`; raw `.json` is
   audit-only.

---

## Exit codes

| Code  | Meaning |
|-------|---------|
| 0     | Success |
| 2     | Environment / binary missing / auth not configured |
| 3     | Model unresolved, or `create-chat` parse failure |
| 4     | Config resolution failed |
| 64    | Argument / usage error (EX_USAGE) |
| 77    | Skipped test (LSB convention; used by `tests/run.sh`) |
| 124   | Timeout — permanent, no retry |
| 137   | SIGKILL (cancel escalation) |
| 143   | SIGTERM (cancel initial signal) |
| other | Propagated from `agent` |

---

## Diagnostics

**Pre-flight failures** exit before any `agent` invocation:
- `agent` binary not on `$PATH` → exit 2 with install hint.
- `jq` not installed → exit 2 with install hint.
- `CURSOR_API_KEY` empty and no `agent` login state → exit 2.
- Resolved `model` not present in `agent --list-models` → exit 3 with
  available-models listing.

**Retry classification** (`cd_classify_exit`):
- `SUCCESS` (0) — done.
- `TRANSIENT` (explicit whitelist `7 / 28 / 52` — curl connect / timeout /
  empty-reply — and `429` rate-limit) — exponential backoff (1 s → 2 s → 4 s),
  up to `retry.max_attempts` (default 3).
- `PERMANENT` (`2` binary/auth, `3` model, `4` config, `124` timeout, `125`,
  `126`, `127`, `130`, `137`, `143`) — never retry.
- `UNKNOWN` (everything else) — treated as PERMANENT (default-deny / fail-fast).

**Logs**: every subcommand writes to stderr via `cd_log LEVEL "message"` where
LEVEL ∈ `INFO | WARN | ERROR`. Stdout is reserved for the data contracts
above.

---

## Debug & dry-run

Two orthogonal flags help diagnose why a Cursor job misbehaves (wrong model,
bad mode, unexpected worktree, hook-quarantine flake). Both keep the 2-line
stdout contract intact — all extra output goes to stderr or into the summary.

| Flag        | Env var                     | Effect |
|-------------|-----------------------------|--------|
| `--debug`   | `CURSOR_DELEGATE_DEBUG=1`   | Verbose `[cursor][DEBUG]` stderr breadcrumbs: env + paths, config-layer chain, full resolved-config dump, per-attempt `child_pid` + elapsed ms, and the raw stderr tail of any failed attempt. Behavior is otherwise unchanged. |
| `--dry-run` | `CURSOR_DELEGATE_DRY_RUN=1` | Runs preflight + config resolve, writes meta + a `status=dry_run` summary containing the planned `agent` command, then exits 0 **without invoking `agent`** and **without quarantining `~/.cursor/hooks.json`**. Implies `--debug`. |

Both flags work three ways, so you can use whichever fits the call site:

```bash
# 1. via the entrypoint (flag before the subcommand)
/cursor --dry-run implement "fix the off-by-one in src/foo.ts"
/cursor --debug investigate "explain src/auth.ts"

# 2. via direct dispatch — flag accepted BEFORE or AFTER the positional args
bash ~/.claude/skills/cursor/lib/dispatch.sh --dry-run review "audit src/a.ts"
bash ~/.claude/skills/cursor/lib/dispatch.sh review "audit src/a.ts" --dry-run

# 3. via env var (handy for wrapping an existing call)
CURSOR_DELEGATE_DEBUG=1 /cursor review "audit src/a.ts"
```

`CURSOR_DELEGATE_DEBUG_PROMPT=1` additionally embeds the first 200 bytes of the
prompt in the dry-run summary (off by default — prompts can be sensitive).

**Fanout propagation.** `--debug` / `--dry-run` flow into every child dispatch
of a `fanout`. In **local-parallel** mode the children inherit the exported env
vars directly; in the default **claude-driven** mode the children run in fresh
Bash processes (the env export can't reach them), so `fanout` appends a trailing
` --debug` / ` --dry-run` to each emitted dispatch line instead. The trailing
position preserves the read-only allowlist prefix; `--dry-run` implies `--debug`
downstream so only one flag is appended.

```bash
# Preview every job a fanout would run, without spending Cursor tokens
/cursor --dry-run fanout review:src/a.ts security:src/a.ts
```

---

## Examples

```bash
# Investigate a file (shortcut form)
/cursor investigate "src/auth.ts の rate-limit 実装を調査して"

# Code review and security audit in parallel
/cursor fanout review:src/auth.ts security:src/auth.ts

# Force shell-level parallel if Claude serializes Bash calls
CURSOR_DELEGATE_LOCAL_PARALLEL=1 /cursor fanout review:src/a.ts review:src/b.ts

# Multi-turn conversation
CHAT_ID=$(/cursor resume --create-chat)
/cursor resume "$CHAT_ID" "さっきの提案を実装プランにして" --task plan

# Cancel a long-running implement job
/cursor status --last 5
/cursor cancel 20260424-080102-ab12cd34

# Auto-split: Cursor handles reviews, Claude handles architecture
# (triggered automatically or via /cursor orchestrate)

# Project-level review-model override
echo '{"defaults": {"review": {"model": "gpt-5.3-codex-high"}}}' > .cursor.json

# Run unit tests
bash ~/.claude/skills/cursor/tests/run.sh unit
```

---

## Known limitations

All Phase 4 validation items (A1, V1–V12, F6–F8) are resolved as of
2026-04-28. See `TODO.md` for per-item details.

**`--local-parallel` runs on bash 3.2+**: the semaphore prefers `wait -n`
(bash 4.3+) and **falls back to a poll loop** on older bash, so macOS stock
`/bin/bash` (3.2) works without an upgrade. `brew install bash` is optional and
only swaps the poll loop for the event-driven `wait -n` (it logs which path it
took).

### Upstream / environmental caveats

- `hooks.json` headless firing behavior is **not verified**; the skill
  defensively quarantines by default. Set
  `CURSOR_DELEGATE_QUARANTINE_HOOKS=0` to disable.
- `agent create-chat` stdout format is parsed best-effort.
- Bash tool's 600 s ceiling is inherited from Claude Code — dispatch uses
  `timeout 590s` to stay within.

---

## See also

- [`SKILL.md`](./SKILL.md) — skill metadata, Claude-driven fanout protocol,
  trigger keywords
- [`TODO.md`](./TODO.md) — resolved issues tracker (A1, F6–F8, V1–V12)
- [`tests/manual-qa.md`](./tests/manual-qa.md) — 5 human-verified gates
- [`tests/run.sh`](./tests/run.sh) — unit + integration runner
- [Cursor CLI docs](https://cursor.com/ja/docs/cli/overview)
- [`README_ja.md`](./README_ja.md) — Japanese version of this file

---

## Authors

Built by the Claude Code `/oh-my-claudecode` pipeline
(`deep-dive → ralplan → autopilot`) on 2026-04-27, in a 3-wave executor run
plus a ralplan consensus loop. Post-ship maintenance by the user.

---

## Changelog

- **Per-task `preamble`** (2026-06-27) — optional task-specific prompt kept in
  the same `.cursor.json`. A `string` or array-of-strings (joined with `\n`); a
  `{{prompt}}` placeholder marks where the user prompt is inserted, otherwise the
  preamble is prepended with a `\n\n---\n\n` separator. No `preamble` → user
  prompt passes verbatim (backward compatible); deep-merges like every other
  field (`"preamble": ""` disables a shipped default). Ships default preambles
  for the read-only lenses (review / investigate / security) — previously
  byte-identical at the `agent` argv level — while implement / plan ship none.
  Composed in jq (bash-3.2-safe, no parameter-expansion backslash hazard);
  preview with `--dry-run` + `CURSOR_DELEGATE_DEBUG_PROMPT=1`. New
  `test_preamble_injection.sh`; suite 17/17.
- **Config unification + `auto` default** (2026-06-27) — skill-default config
  renamed `config/model.json` → `config/.cursor.json` so all 3 layers share one
  name/shape; default model set to `auto` (Cursor picks server-side) for every
  task type.
- **Cross-platform hardening + `/cursor-setup`** (2026-06-26) — bash core made
  3.2- and BSD-coreutils-tolerant (macOS first-class on stock `/bin/bash`); WSL
  recommended over native Windows. New `cursor-setup` doctor checks deps / auth
  and generates the read-only permission allowlist.
- **Orchestrate protocol** (2026-04-28) — Claude-internal auto-delegation
  that splits multi-part requests between Cursor (`fanout`) and Claude based
  on delegation criteria (D1–D5) and blockers (B1–B6).
- **TODO cleanup (complete)** (2026-04-28) — all 14 Phase 4 items resolved:
  A1 mkdir-atomic hooks refcount, V2 chatId validation + `--` end-of-options,
  V3 anchored model match, V4 dispatch.log capture, V5 secret redaction
  (`CURSOR_DELEGATE_REDACT_RESULT`), V6 symlink guard, V7 `umask 077`,
  V8 `wait -n` semaphore (bash 4.3+), V9 config schema, V10 shared test
  fixtures, V11 variable rename, V12 jq stderr, F6 TTL annotation, F7 zombie
  hint. 13/13 unit tests passing.
- **v1.0.0** (2026-04-27) — initial release. Task-type shortcut dispatcher,
  5 subcommands, 3-layer config precedence, per-JOB snapshot, hooks
  quarantine, claude-driven + local-parallel fanout with auto-detect, resume
  / status / cancel.
- **V1 PID drift fix** (2026-04-27) — `dispatch.sh` records the real
  agent-child PID in `meta.json.pid`.
- **Path migration** (2026-04-27) — runtime artifacts moved from
  `.omc/cursor/` to `.cursor/delegate/`.
- **Rename** (2026-04-27) — `cursor-delegate` → `cursor`. Env vars and
  function prefix unchanged (`CURSOR_DELEGATE_*`, `cd_*`).
