---
name: cursor
description: Delegate implement / review / plan / investigate / security tasks to Cursor CLI (`agent`) from Claude Code. Auto-orchestrates parallel delegation when multiple independent tasks are detected. Triggers on "cursor", "delegate to cursor", "move to cursor", "cursor-cli", "ask cursor", "cursor orchestrate", or when the user wants to hand off a coding task to Cursor — including Japanese phrasings like 「cursorに委譲」「cursorに渡す」「cursorに調べさせて」「cursorでレビュー」「cursorに聞く」.
argument-hint: "<implement|review|plan|investigate|security|fanout|resume|status|cancel|setup|help> [args] [--debug|--dry-run]"
level: 4
version: 1.0.0
---

# cursor

Run Cursor CLI (`agent`) non-interactively from Claude Code. Five task types
(`implement`, `review`, `plan`, `investigate`, `security`) are dispatched via a
shell wrapper that enforces a **deterministic, config-driven routing contract**:
task type -> model / mode / flags resolved from `config/.cursor.json`.

Claude is the **dispatcher + summarizer**. Cursor is the **executor**. Raw
Cursor output is written to disk for audit; Claude only Reads the rendered
1-page summary to keep context clean.

## Setup & platform support

Run **`/cursor-setup`** once per machine before first use. It detects the OS,
checks every dependency in one pass (no `agent` call / no token cost), and
generates the `~/.claude/settings.json` permission allowlist. Engine:
`bash lib/setup.sh` (also reachable as `/cursor setup` | `/cursor doctor`).

| Platform | Status | Notes |
|----------|--------|-------|
| WSL Ubuntu / native Linux | first-class | `apt-get install -y jq coreutils` |
| macOS | first-class | stock **bash 3.2** is supported (no upgrade needed); `brew install jq coreutils` provides `gtimeout`/`gdate`. The lib auto-detects `gtimeout`/`gdate` and is BSD-`date` tolerant |
| Windows (native) | **unsupported** | no bash + Unix coreutils → use WSL (`wsl --install -d Ubuntu`), run everything inside WSL. Git Bash / Cygwin not officially supported |

Portability is handled in the lib (not by forking per shell): `cd_resolve_timeout_bin`
picks `timeout`/`gtimeout`, `cd_iso_to_epoch`/`cd_epoch_to_date` handle GNU vs BSD
`date`, and `fanout --local-parallel` falls back to a poll loop on bash < 4.3.

## Subcommands

```
/cursor dispatch <task_type> "<prompt>"              # single job (explicit)
/cursor <task_type> "<prompt>"                       # shortcut: dispatch omitted
/cursor fanout  <task1>:<prompt1> <task2>:<prompt2>  # parallel jobs
/cursor resume  <chatId> "<prompt>"                  # continue a chat
/cursor resume  --create-chat                        # allocate a new chatId
/cursor status                                       # recent jobs table
/cursor cancel  <JOB_ID>                             # SIGTERM + SIGKILL
/cursor orchestrate                                  # auto-split & delegate (Claude-internal)
/cursor help | --help | -h                           # usage
/cursor --version                                    # skill version
```

**Task-type shortcut**: when the first arg is one of `implement | review |
plan | investigate | security`, the `dispatch` keyword is implied. These are
equivalent:

```
/cursor dispatch investigate "src/auth.ts を調査して"
/cursor investigate          "src/auth.ts を調査して"
```

Task types are **never inferred from free text** — the user (or Claude on the
user's behalf) must name one of the five. Unknown first arg → usage + exit 64.

### Entry point

All invocations route through `lib/cursor.sh` which re-execs the correct
subcommand script with its native contract preserved. Claude's `Skill()` calls
and direct shell users both use the same path:

```
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor/lib/cursor.sh <args...>
```

## Task routing matrix (spec C3 — defaults, editable in `config/.cursor.json`)

The shipped default model is **`auto`** for every task type — Cursor's "Auto"
picks a model server-side (`agent --model auto`; `auto` is a valid entry in
`agent --list-models`). Override per task in any config layer.

| task_type    | model | mode | force | worktree | sandbox   | preamble |
|--------------|-------|------|-------|----------|-----------|----------|
| implement    | auto  | —    | true  | **true** | enabled   | —        |
| review       | auto  | ask  | false | false    | enabled   | ✓        |
| plan         | auto  | plan | false | false    | enabled   | —        |
| investigate  | auto  | ask  | false | false    | enabled   | ✓        |
| security     | auto  | ask  | false | false    | enabled   | ✓        |

The read-only lenses are otherwise identical (`model: auto`, `mode: ask`); their
**`preamble`** — task-specific text combined with the user prompt (via a
`{{prompt}}` placeholder or prepended) — is what differentiates them. Tasks
without a `preamble` pass the prompt verbatim.

Config precedence (deep-merge, last wins):
`config/.cursor.json` < `~/.cursor.json` < `<cwd>/.cursor.json`. The resolved
config is snapshotted **per JOB_ID** to
`.cursor/delegate/state/resolved-config-<JOB_ID>.json` — no shared file, no
TOCTOU between concurrent jobs.

**Full schema, merge semantics, and the complete `preamble` mechanics live in
[references/configuration.md](references/configuration.md)** (the single source
of truth — this table is just the at-a-glance summary).

## Dispatch stdout contract

`dispatch.sh` emits a **strict 2-line contract** on stdout. All log / diagnostic
output is on stderr.

- **FIRST line**: `JOB_ID=<id>` — machine-parseable, let callers pair outputs.
- **LAST line**: an **absolute** path to `.cursor/delegate/<JOB_ID>.summary.md` —
  the file Claude is expected to Read.

Internal callers (fanout synthesis, `Skill("cursor", ...)`) key off the
**last line**. Do not try to parse the raw Cursor JSON — that is audit-only.

### What Claude should Read

- **Read**: `<JOB_ID>.summary.md` (frontmatter + 1-page summary, capped body).
- **Never Read**: `<JOB_ID>.json` (full Cursor payload; stays on disk for audit
  and debugging). Reading the raw JSON will pollute context with Cursor's
  internal fields and defeats the whole point of this skill.

## Runtime layout

```
.cursor/delegate/
├── <JOB_ID>.json          # raw Cursor --output-format json (audit only)
├── <JOB_ID>.err           # stderr capture
├── <JOB_ID>.meta.json     # dispatch sidecar (task_type, model, timestamps, pid, exit)
└── <JOB_ID>.summary.md    # 1-page summary — the only file Claude Reads

.cursor/delegate/state/
├── resolved-config-<JOB_ID>.json   # per-job config snapshot
└── hooks-quarantined-<JOB_ID>      # sentinel if ~/.cursor/hooks.json was moved aside
```

## Invariants (core contracts — do not drift)

1. dispatch.sh stdout: first line `JOB_ID=<id>`, last line absolute summary
   filepath, everything else goes to stderr.
2. `resolved-config-<JOB_ID>.json` path — never a shared well-known name.
3. `implement` **always** appends `--worktree impl-<short-id>`. No opt-out in v1.
4. Every `agent` invocation runs under `timeout 590s agent ... </dev/null` — the
   600s Bash tool ceiling is the hard budget; stdin is explicitly closed to
   rule out interactive prompt hangs.
5. Exit code **124 is PERMANENT** — never retried. Retrying a 590s timeout
   would compound into a ~30-minute zombie loop.
6. The raw `.json` is an **audit artifact**. Claude Reads only `.summary.md`.

## Pre-flight checks (spec C7)

Before any `agent` invocation:
- `agent` in PATH (exit 2 with install hint otherwise).
- `jq` in PATH (exit 2 with install hint).
- `timeout` in PATH.
- resolved model present in `agent --list-models` (exit 3 with candidate list).
- `CURSOR_API_KEY` env set **or** `~/.cursor/session.json` / `cli-config.json`
  / `chats/` present (exit 2 with login instructions otherwise).
- Output dirs created (`mkdir -p .cursor/delegate .cursor/delegate/state`).
- Hooks quarantine: if `~/.cursor/hooks.json` exists, move to
  `~/.cursor/hooks.json.cursor.bak` + drop sentinel; `trap`-based
  restore on EXIT/INT/TERM. (Spec R2 mitigation — the `hooks.json` file's
  `beforeShellExecution` hook is unverified under headless `-p` mode.)

## Retry policy (spec C7)

- `cd_classify_exit`:
  - `TRANSIENT` (whitelist): 7, 28, 52, 429 → exponential backoff (1s / 2s / 4s).
  - `PERMANENT` (hard fail, no retry): 2 (binary/auth), 3 (model), 4 (config),
    124 (timeout), 125, 126, 127, 130, 137, 143.
  - `UNKNOWN` → treated as PERMANENT (default-deny retry).
- `max_attempts=3` from `config/.cursor.json` (editable).

## Env overrides

| var                                | effect                                                 |
|------------------------------------|--------------------------------------------------------|
| `CURSOR_DELEGATE_JOB_ID`           | use given JOB_ID (fanout / resume use this)           |
| `CURSOR_DELEGATE_QUARANTINE_HOOKS` | "0" disables hooks.json move-aside (default "1")       |
| `CURSOR_DELEGATE_TIMEOUT_SEC`      | override `timeout` seconds (default from .cursor.json) |
| `CURSOR_DELEGATE_DEBUG`            | "1" enables verbose stderr diagnostics (same as `--debug`) |
| `CURSOR_DELEGATE_DRY_RUN`          | "1" skips the `agent` invocation (same as `--dry-run`) |
| `CURSOR_DELEGATE_DEBUG_PROMPT`     | "1" includes a 200-byte prompt head in the dry-run summary |

## Debug mode

Two orthogonal flags help when diagnosing why Cursor jobs misbehave (wrong
model, bad mode, unexpected worktree, hook quarantine flake, etc.) — both
work with `/cursor <subcommand>`, direct `bash lib/cursor.sh` invocations, and
direct `bash lib/dispatch.sh` calls (accepted either before or after the
positional `<task> "<prompt>"`).

They also propagate through fanout into every child dispatch. The mechanism
differs by fanout mode: in **local-parallel** mode the children inherit the
exported `CURSOR_DELEGATE_DEBUG` / `CURSOR_DELEGATE_DRY_RUN` env vars directly;
in the default **claude-driven** mode the children run in fresh Bash processes
that the env export can't reach, so `fanout` bakes a trailing `--debug` /
`--dry-run` onto each emitted dispatch line instead (`--dry-run` implies
`--debug` downstream, so only one flag is appended).

| Flag        | Env var                     | Effect |
|-------------|-----------------------------|--------|
| `--debug`   | `CURSOR_DELEGATE_DEBUG=1`   | Verbose `[cursor][DEBUG]` stderr breadcrumbs: env + paths, config-layer chain, full resolved-config JSON dump, per-attempt `child_pid` + elapsed ms, raw stderr tail on any failed attempt. Behavior is otherwise unchanged. |
| `--dry-run` | `CURSOR_DELEGATE_DRY_RUN=1` | Runs preflight + config resolve, writes meta + a `status=dry_run` summary file with the planned `agent` command, then exits 0 **without invoking `agent`** and **without quarantining `~/.cursor/hooks.json`**. Implies `--debug`. |

### Stdout contract is preserved

Both modes keep the 2-line stdout contract intact (first line `JOB_ID=<id>`,
last line absolute summary filepath). All diagnostics are on stderr. Callers
(fanout synthesis, `Skill("cursor", ...)`) can Read the summary as usual.

### Examples

```bash
# Verbose investigation run
/cursor --debug investigate "src/auth.ts のロジックを説明して"

# Preview the resolved command without spending Cursor tokens
/cursor --dry-run implement "fix the off-by-one in src/foo.ts"

# Same, via direct dispatch
bash ${CLAUDE_PLUGIN_ROOT}/skills/cursor/lib/dispatch.sh --dry-run review "audit src/a.ts"

# Propagates through fanout
/cursor --debug fanout review:src/a.ts security:src/a.ts
```

### Dry-run summary shape

```yaml
---
job_id: <id>
task_type: investigate
resolved_model: auto
mode: ask
status: dry_run
exit_code: 0
---

## Dry run
### Planned command       # full `agent` argv (prompt elided to byte-length)
### Resolved config       # task defaults from the per-JOB snapshot
## Artifacts              # path to meta sidecar
```

Set `CURSOR_DELEGATE_DEBUG_PROMPT=1` to also include the first 200 bytes of
the prompt in the dry-run summary (off by default — prompts can be sensitive).

## Subcommand scripts

All subcommands are plain bash scripts under `lib/`. Each prints `--help`
on stderr when run with `-h`. For detailed per-subcommand options, flags,
and session management, see [references/subcommand-reference.md](references/subcommand-reference.md).

## Claude-driven fanout protocol

Fanout is the **default** parallel path. When Claude runs
`bash lib/fanout.sh <pair1> <pair2> ...`, the script emits a
machine-readable stdout block:

```
FANOUT_PLAN=<path>
FANOUT_MODE=claude-driven
JOBS=<N>
---DISPATCH-COMMANDS---
bash <dispatch.sh> <ro_task> '<prompt>' --job-id <id1>                 # read-only
CURSOR_DELEGATE_JOB_ID=<id2> bash <dispatch.sh> implement '<prompt>'   # write
---END-DISPATCH-COMMANDS---
FANOUT_COLLECT_CMD=bash <fanout.sh> --collect <TS>
```

Read-only task types (`review | plan | investigate | security`) carry the
JOB_ID on a trailing `--job-id` flag so the command keeps a
`bash <dispatch.sh> <task>` prefix that Claude Code allowlist rules can match
(see **Permissions**). `implement` keeps the `CURSOR_DELEGATE_JOB_ID=<id>
bash ...` env-prefix form, whose leading assignment intentionally defeats
prefix matching so a write task still hits a permission prompt.

When `fanout` is invoked with `--debug` / `--dry-run`, each emitted dispatch
line gains a trailing ` --debug` / ` --dry-run` so the flag survives into the
fresh Bash process Claude runs it in (the trailing position preserves the
read-only allowlist prefix). See **Debug mode** for the full rationale.

**Behavioral rule**: Claude MUST fire each dispatch line as a **separate
parallel Bash tool call in one assistant message**. After all dispatches
return, run `FANOUT_COLLECT_CMD`, then `Read` the synthesis path it prints on
its last stdout line.

Auto-detection flips to `--local-parallel` when serialization is observed.
For the full protocol walkthrough, worked example, auto-detection details,
and local-parallel fallback, see [references/subcommand-reference.md](references/subcommand-reference.md).

## Orchestrate — automatic delegation to Cursor

`/cursor orchestrate` is a Claude-internal protocol, not a bash subcommand.
When Claude identifies multiple independent tasks during a conversation, it
evaluates each against Cursor's delegation criteria and splits work between
itself and Cursor automatically.

### Trigger conditions (Claude SHOULD consider orchestrating when)

- The user's request decomposes into 2+ independent sub-tasks
- At least one sub-task maps cleanly to review / security / investigate / plan
- The sub-tasks target identifiable files or directories
- Claude would otherwise run them sequentially

Claude MAY orchestrate proactively (without `/cursor orchestrate` being typed)
when all trigger conditions are met. When uncertain, Claude states the proposed
split and asks before delegating.

### Delegation criteria

A sub-task is **Cursor-delegable** when ALL of the following hold:

| # | Criterion | Why |
|---|-----------|-----|
| D1 | **Self-contained** — the prompt + codebase is sufficient | Cursor has no access to Claude's conversation history |
| D2 | **Standard task type** — maps to `review \| security \| investigate \| plan \| implement` | Cursor only understands these 5 modes |
| D3 | **File-scoped** — targets specific files, dirs, or grep-able patterns | Cursor performs best with focused scope |
| D4 | **Independent** — no dependency on other sub-tasks' results | Cursor tasks run in parallel, can't chain |
| D5 | **No Claude Code tools needed** — doesn't require web search, MCP, git ops, Agent spawning | Cursor has none of these |

A sub-task is **NOT delegable** when ANY of the following hold:

| # | Blocker | Example |
|---|---------|---------|
| B1 | **Requires conversation context** | "先ほどの議論を踏まえて…", "上で見つけたバグを…" |
| B2 | **Multi-file refactoring with cross-references** | rename a type used in 30 files (Cursor lacks cross-file rename intelligence) |
| B3 | **Depends on another task's output** | "review the changes from the implement task" |
| B4 | **Needs interactive dialogue** | ambiguous spec requiring clarification |
| B5 | **Requires integration of external data** | "check the API docs and then review" |
| B6 | **Architecture / design decisions** | Cursor follows instructions, doesn't make strategic calls |

For the full execution protocol (5-step decompose → classify → present →
execute → integrate), Cursor strengths/weaknesses map, worked examples,
and anti-patterns, see [references/orchestrate-protocol.md](references/orchestrate-protocol.md).

## Permissions

Read-only delegation never edits files or writes to external services, so it
is configured to run **without a confirmation prompt**. Write delegation stays
gated.

| Task type | Edits files? | Confirmation |
|-----------|--------------|--------------|
| `review` / `plan` / `investigate` / `security` | no | **none** (allowlisted) |
| `status`, `fanout --collect` | no (read/aggregate) | **none** (allowlisted) |
| `implement` | yes (worktree) | **prompts** |
| `cancel`, `resume` | mutates / unknown task type | **prompts** |

This is enforced by `permissions.allow` rules in `~/.claude/settings.json` that
match the read-only command prefixes for both invocation forms — `bash
${CLAUDE_PLUGIN_ROOT}/skills/cursor/lib/cursor.sh <ro_task> …` and `bash …/dispatch.sh
<ro_task> …` (and the `~` / absolute path variants). The allowlist deliberately
omits `implement`; combined with fanout keeping `implement` on the
`CURSOR_DELEGATE_JOB_ID=<id> bash …` env-prefix form (whose leading assignment
breaks prefix matching), a write task can never be auto-approved by these rules.

To extend or audit these rules, edit the `permissions.allow` array in
`~/.claude/settings.json` (entries are prefixed `Bash(bash …/cursor.sh review:*)`
etc.).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `exit 2` before any agent call | `agent`, `jq`, or `timeout` not on PATH; or no auth | Install missing binary; set `CURSOR_API_KEY` or run `agent login` |
| `exit 2` — `~/.cursor is not writable` | Claude Code Bash sandbox makes `~/.cursor/` read-only (WSL2 / `sandbox.enabled=true`) | Add `~/.cursor` to `sandbox.filesystem.allowWrite` in `~/.claude/settings.json`, or set `CURSOR_DELEGATE_SKIP_SANDBOX_CHECK=1` if you've allowlisted by another mechanism |
| `exit 3` — model not found | Resolved model absent from `agent --list-models` | Check `config/.cursor.json` or a `~/.cursor.json` / project `.cursor.json` override |
| `exit 4` — config error | Malformed JSON in one of the 3 config layers | Run `jq . <file>` on each layer to find the parse error |
| `exit 124` — timeout | Job exceeded 590 s hard limit | Break prompt into smaller scope; never retry (permanent) |
| Fanout runs sequentially | Claude runtime serializes Bash calls | Set `CURSOR_DELEGATE_LOCAL_PARALLEL=1` or wait for auto-detect flip |
| `[ZOMBIE]` in status | Process gone but meta not updated | `cancel <JOB_ID>` to clean up; check if hooks.json needs restore |
| Hooks not restored | Crash before EXIT trap fires | Manually `mv ~/.cursor/hooks.json.cursor.bak ~/.cursor/hooks.json` |
| `WARN cannot quarantine ... (read-only fs?)` | `~/.cursor/hooks.json` not writable; quarantine is now non-fatal | Skill proceeds without quarantine. Move-aside `hooks.json` manually if it interferes, or extend sandbox allowlist as above |

## Out of scope (v1)

- Automated merge of `--worktree` outputs (that is the user's / cursor-merge's job).
- True async / next-turn collect (v2 — sync batch only here).
- Task-type auto-inference (user always specifies).
- Cursor-side hooks / MCP management (pre-existing user concern).

## Claude-Internal Invocation

`Skill("cursor", args="dispatch <task> \"<prompt>\"")` produces the
same result as `/cursor dispatch <task> "<prompt>"`. The **last line**
of stdout is always the absolute path to the summary file — internal callers
should Read that path, not parse raw output.

```python
# From another skill (e.g., ralph reviewer):
Skill("cursor", args='dispatch review "audit src/auth.ts for OWASP"')
# Last stdout line -> /abs/path/to/<JOB_ID>.summary.md
# Read that file to get the 1-page summary.

Skill("cursor", args='fanout review:src/a.ts security:src/a.ts')
# Returns machine-readable fanout plan (Claude-driven) or synthesis path
# (local-parallel). Last stdout line -> synthesis path.
```

Internal callers must **never** try to parse the raw Cursor JSON — that file
is audit-only. Always key off the **last stdout line**.

## Testing

Quick check (no network, stub `agent`, ~5 s): `bash tests/run.sh unit`.
Full harness — integration tests, CI flags (`NO_COLOR` / `VERBOSE`), the
manual-QA checklist, and the v1 "done" definition — is maintainer-facing and
lives in [references/maintainers.md](references/maintainers.md).
