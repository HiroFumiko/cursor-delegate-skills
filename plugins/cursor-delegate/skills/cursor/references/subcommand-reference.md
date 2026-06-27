# Subcommand Reference — Detailed Documentation

Full option reference, protocol details, and session management for each
`/cursor` subcommand. For the concise synopsis, see SKILL.md § "Subcommands".

## `dispatch` — single job

```
bash lib/dispatch.sh <task_type> "<prompt>" [--resume <chatId>] [--job-id <id>] [--debug] [--dry-run]
```

- `task_type`: `implement | review | plan | investigate | security`
- stdout contract: FIRST line `JOB_ID=<id>`, LAST line absolute summary path
  (preserved even in `--dry-run`).
- `--job-id <id>`: trailing-flag form of `CURSOR_DELEGATE_JOB_ID` (fanout uses
  it for read-only task types).
- `--debug`: verbose `[cursor][DEBUG]` stderr breadcrumbs.
- `--dry-run`: skip the `agent` call; emit a `status=dry_run` summary with the
  planned command. Implies `--debug`. Skips the hooks-quarantine side effect.
- `--debug` / `--dry-run` are accepted **before or after** the positional
  `<task_type> "<prompt>"` (e.g. `dispatch.sh --dry-run review "…"` and
  `dispatch.sh review "…" --dry-run` are equivalent).
- Env: `CURSOR_DELEGATE_JOB_ID`, `CURSOR_DELEGATE_QUARANTINE_HOOKS`,
  `CURSOR_DELEGATE_TIMEOUT_SEC`, `CURSOR_DELEGATE_DEBUG`,
  `CURSOR_DELEGATE_DRY_RUN`, `CURSOR_DELEGATE_DEBUG_PROMPT`.

Example:
```
bash lib/dispatch.sh review "audit src/auth.ts for OWASP issues"
bash lib/dispatch.sh --dry-run review "audit src/auth.ts"   # preview, no agent call
```

## `fanout` — parallel jobs

```
bash lib/fanout.sh <task1>:<prompt1> <task2>:<prompt2> ... [--local-parallel [N]]
bash lib/fanout.sh --collect <FANOUT_TS>
bash lib/fanout.sh --clear-serialization-flag
```

- Default mode emits a machine-readable plan for Claude to fan-out (see
  Claude-driven fanout protocol below).
- `--local-parallel [N]` fans out in-shell using `& + wait`, bounded by N
  (default `max_fanout` from config, falling back to 4).
  Same as env `CURSOR_DELEGATE_LOCAL_PARALLEL=1`.
- `--collect <FANOUT_TS>` reads the dispatched plan and emits the
  `fanout-<FANOUT_TS>.synthesis.md` file; prints its absolute path as the
  LAST line of stdout.
- `--clear-serialization-flag` deletes the auto-detect flag.

Prompts may contain `:`; only the FIRST `:` delimits task_type from prompt.

## `resume` — continue a chat

```
bash lib/resume.sh <chatId> "<prompt>" [--task <task_type>]
bash lib/resume.sh --create-chat
```

- `task_type` defaults to `investigate` (read-only, safest).
- `--create-chat` invokes `agent create-chat` and best-effort parses a chatId
  from its output. Prints the chatId on stdout on success; on parse failure
  dumps the raw `agent` output to stderr and exits 3 (R1: format still
  unconfirmed upstream).
- Every resume turn is logged to `.cursor/delegate/state/sessions.jsonl`
  as an append-only JSONL record.

## `status` — recent jobs table

```
bash lib/status.sh [--last N] [--since <dur>] [--with-pid]
```

- Default window: 24h (`--since 24h`). `<dur>` format: `<int>{s|m|h|d}`.
- Default limit: 50 rows. Override with `--last N`.
- Default PID column: liveness marker (`[RUNNING]` / `[DONE]` / `[ZOMBIE]` /
  `[CANCELLED]` / `[FAILED]` / `[TIMED_OUT]` / `[MALFORMED]`).
  Pass `--with-pid` to additionally see raw PID integers.
- Detects stale `hooks-quarantined-*` sentinels and warns if `~/.cursor/
  hooks.json` may need manual restoration.
- Surfaces the `claude-serializes-bash` flag when present, so users can see
  why fanout is auto-flipping to local-parallel.

## `cancel` — terminate a running job

```
bash lib/cancel.sh <JOB_ID>
```

- Reads `<JOB_ID>.meta.json`, SIGTERMs the pid, waits up to 5s, SIGKILLs if
  still alive. Updates meta with `status=cancelled`, `cancelled_at=<ISO8601>`,
  and `exit_code=143` (SIGTERM) or `137` (SIGKILL).
- Always calls `cd_hooks_restore $JOB_ID` so the hooks-quarantine sentinel
  does not outlive the cancelled job (invariant).
- Idempotent: cancelling a job that already finished exits 0 with a notice.
- Regenerates `<JOB_ID>.summary.md` so `status` reflects the new state.

---

## Claude-driven fanout protocol

Claude-driven fanout is the **default** path for parallel work. It produces
true wall-clock parallelism when Claude's Bash tool dispatches multiple calls
in the same assistant message concurrently.

### Protocol

1. Claude runs `bash lib/fanout.sh <pair1> <pair2> ...` once.
2. `fanout.sh` prepares N per-JOB config snapshots and writes a fanout plan at
   `.cursor/delegate/fanout-<FANOUT_TS>.json`, then emits a
   **machine-readable stdout block**:

   ```
   FANOUT_PLAN=<abs-plan-path>
   FANOUT_MODE=claude-driven
   JOBS=<N>
   ---DISPATCH-COMMANDS---
   bash <dispatch.sh> <ro_task> '<prompt>' --job-id <job_id_1>          # read-only
   CURSOR_DELEGATE_JOB_ID=<job_id_2> bash <dispatch.sh> implement '<prompt>'  # write
   ...
   ---END-DISPATCH-COMMANDS---
   FANOUT_COLLECT_CMD=bash <fanout.sh> --collect <FANOUT_TS>
   ```

   The emission form is **task-type dependent**: read-only task types
   (`review | plan | investigate | security`) carry the JOB_ID on a trailing
   `--job-id` flag so the line keeps a `bash <dispatch.sh> <task>` prefix that
   Claude Code allowlist rules can auto-approve; `implement` keeps the
   `CURSOR_DELEGATE_JOB_ID=<id> bash …` env-prefix form whose leading
   assignment intentionally defeats prefix matching (so a write task still
   prompts). When `fanout` was invoked with `--debug` / `--dry-run`, each
   emitted line additionally gains a trailing ` --debug` / ` --dry-run` (the
   env export can't reach the fresh Bash process Claude runs the line in).
   Every `cd_log` line goes to stderr — stdout is strictly the contract above.
3. Claude parses the block. In **one assistant message**, Claude emits each
   dispatch line verbatim as a **separate parallel Bash tool call**. All N
   calls share the same message, which is what lets Claude Code run them
   concurrently.
4. After all N dispatches return (each one prints its own `JOB_ID=` first and
   summary path last — the standard dispatch contract), Claude runs
   `FANOUT_COLLECT_CMD` as the next tool call.
5. `fanout.sh --collect <FANOUT_TS>` (which delegates to `synthesize.sh`)
   reads each job's `<JOB_ID>.summary.md` + `.meta.json`, writes
   `fanout-<FANOUT_TS>.synthesis.md`, and prints its absolute path as the
   **LAST line of stdout** (mirroring dispatch's single-job contract).
6. Claude `Read`s the synthesis file — it's the only file it needs for the
   combined summary.

### Example (2 jobs)

```
$ bash lib/fanout.sh review:src/a.ts security:src/a.ts
FANOUT_PLAN=/abs/.cursor/delegate/fanout-20260424-070000.json
FANOUT_MODE=claude-driven
JOBS=2
---DISPATCH-COMMANDS---
bash /abs/lib/dispatch.sh review 'src/a.ts' --job-id 20260424-070000-aaaaaaaa
bash /abs/lib/dispatch.sh security 'src/a.ts' --job-id 20260424-070000-bbbbbbbb
---END-DISPATCH-COMMANDS---
FANOUT_COLLECT_CMD=bash /abs/lib/fanout.sh --collect 20260424-070000
```

(Both jobs above are read-only, so both use the trailing `--job-id` form. An
`implement` job would instead appear as
`CURSOR_DELEGATE_JOB_ID=<id> bash /abs/lib/dispatch.sh implement '<prompt>'`.)

Claude then, in one message, sends:
- Bash 1: `bash /abs/lib/dispatch.sh review 'src/a.ts' --job-id 20260424-070000-aaaaaaaa`
- Bash 2: `bash /abs/lib/dispatch.sh security 'src/a.ts' --job-id 20260424-070000-bbbbbbbb`

And in the next message:
- Bash 3: `bash /abs/lib/fanout.sh --collect 20260424-070000`
- Read: `<synthesis path returned by Bash 3>`

### Auto-detection of serialization

If Claude's Bash tool ends up serializing parallel calls (implementation
detail, observable as `wall_clock > 1.2 * max(duration_ms)` with N ≥ 2),
`synthesize.sh` writes `.cursor/delegate/state/claude-serializes-bash`:

```json
{
  "detected_at": "<ISO8601>",
  "omc_version": "<env OMC_VERSION or 'unknown'>",
  "serialization_ratio": 1.87,
  "sample_size": 2
}
```

Subsequent `fanout` runs within **30 days** of that flag auto-flip to
`--local-parallel` mode (fanout.sh logs a warning on each such run).
Override with:

- `CURSOR_DELEGATE_FORCE_CLAUDE=1` — ignore the flag for this run.
- `bash lib/fanout.sh --clear-serialization-flag` — delete the flag.

### Local-parallel fallback

`bash lib/fanout.sh --local-parallel [N] <pairs...>` runs all dispatches in
the current shell via `& + wait`, bounded by N (default from `max_fanout`,
falling back to 4). Each child inherits `CURSOR_DELEGATE_JOB_ID` so the plan's
JOB_ID parity is preserved. This mode does **not** write the
`claude-serializes-bash` flag (it's the fallback, not the measurement).

---

## Session management

Cursor CLI supports chat continuation via `agent --resume <chatId>`. Obtain
a chatId with the Cursor CLI (outside this skill) or via
`bash lib/resume.sh --create-chat` (best-effort parse; R1).

### Resume flow

1. Create a chat:
   ```
   CHAT=$(bash lib/resume.sh --create-chat)
   ```
   or run `agent create-chat` manually and copy the id.
2. Dispatch the first turn (optional — `resume` can be the first turn too):
   ```
   bash lib/dispatch.sh investigate "list files in src/" --resume "$CHAT"
   ```
3. Continue with `resume` for subsequent turns:
   ```
   bash lib/resume.sh "$CHAT" "now focus on the auth module"
   ```

Each call records `{job_id, chat_id, task_type, timestamp}` to
`.cursor/delegate/state/sessions.jsonl` (append-only — no lock needed
because each writer emits a single short line).

The `--task` flag overrides the default `investigate` task for the resumed
turn. Use `--task review` (read-only) or `--task plan` freely; use
`--task implement` only when you want the resumed chat to modify files
(implement ALWAYS adds `--worktree impl-<short-id>` per the dispatch invariant).
