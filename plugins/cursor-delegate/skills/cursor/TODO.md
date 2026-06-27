# cursor — Post-Approval TODOs

These items were deferred from the initial implementation (v1.0.0) and flagged
during the Ralplan review. They are tracked here for the next maintainer.

| ID  | Source           | Grade  | Scope                  | Action                                                                                                                                                                                             | Status |
|-----|------------------|--------|------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| A1  | lib_common.sh comment (TODO-A1) | Medium | `cd_preflight_hooks` / `cd_hooks_restore` | Tighten concurrent hooks-quarantine handshake with refcount or `flock`-based sentinel counting. Current behavior: overlapping jobs share a single `.bak`; last restorer moves it back. Safe but non-atomic at the sentinel-count boundary. Proposed: use `flock` or an atomic counter file under `$STATE_DIR/hooks-refcount`. | open |
| F6  | Plan ADR §Follow-ups | Low    | `status.sh` / `fanout.sh` | Apply a 30-day TTL to the `claude-serializes-bash` flag in `status.sh` output (surface expiry date). Currently the TTL is checked only in `cd_should_auto_local_parallel`; `status.sh` prints the raw flag JSON without expiry annotation. | open |
| F7  | Plan ADR §Follow-ups | Low    | `status.sh`            | PID column refinement: currently shows liveness markers `[RUNNING]`/`[DONE]`/`[ZOMBIE]`/`[CANCELLED]` etc. Plan note says this is the target behavior (TODO-F7). Verify the column header reads `STATUS` (not `PID`) when `--with-pid` is not passed, and add a `[ZOMBIE]` recovery hint to the stale-sentinel warning block. | open |
| F8  | Plan ADR §Follow-ups | Low    | `cancel.sh`            | After SIGKILL, re-run `summarize.sh` on the cancelled job so `status` reflects the updated `status=cancelled` and `exit_code=137`. Currently `cancel.sh` updates `.meta.json` but does not regenerate `.summary.md`. Add a `bash summarize.sh "$JOB_ID"` call at the end of `cancel.sh` (after meta update). | **done in cancel.sh:136** |

## Phase 4 Validation Findings (2026-04-27)

Added post-ship after the autopilot Phase 4 validation trio (architect / security-reviewer / code-reviewer). Prioritized by cross-lane convergence.

| ID  | Source                                       | Grade    | Scope              | Action | Status |
|-----|----------------------------------------------|----------|--------------------|--------|--------|
| V1  | Architect #6 + Code-review R-06/R-07 (convergent) | **High** | `dispatch.sh:222-231`, `cancel.sh:87`, `status.sh:147` | `dispatch.sh` records `$$` (wrapper shell PID) in `meta.json.pid` instead of the `agent` child PID. Consequence: `cancel.sh` SIGTERMs the wrapper (which may not propagate through `timeout(1)` reliably) and `status.sh` liveness reflects wrapper pid, not agent. Fix: background agent invocation, capture `$!`, write to meta. | **done (2026-04-27)** — timeout wrapper backgrounded; `$!` captured and persisted to meta BEFORE `wait`. `timeout(1)` forwards SIGTERM/SIGKILL to agent child. cancel.sh / status.sh unchanged — they read `.pid` from meta and automatically benefit. Regression guard: `tests/unit/test_dispatch_pid.sh` asserts meta.pid ≠ dispatch-wrapper PID. |
| V2  | Security S1 + S2 (MEDIUM)                    | Medium   | `dispatch.sh:223`, `resume.sh:155-205` | Argument-injection via leading-dash in user-supplied `PROMPT` or `chatId`. Array quoting prevents shell injection but not CLI-flag misinterpretation by `agent`. Fix: validate chatId against `^[A-Za-z0-9._-]+$` (reject leading `-`); insert `--` end-of-options marker before user prompt/args if `agent` supports it. | open |
| V3  | Security S5 + Code-review R-03 (convergent) | Medium   | `lib_common.sh:237-243` | `cd_preflight` model validation does exact-match (`grep -Fxq`) OR substring-match (`grep -Fq`) fallback. Substring can spuriously match `composer-2` vs `composer-2-preview`. Fix: drop the `-Fq` fallback, or anchor with `grep -E '^'"$model"'(\s|$)'`. Also validate MODEL shape before use (`^[A-Za-z0-9._:/-]+$`). | open |
| V4  | Code-review R-08                             | Medium   | `fanout.sh:385`     | Local-parallel mode redirects child dispatch stdout/stderr to `/dev/null`, throwing away the `JOB_ID=<id>` first-line + summary path last-line contract. Fix: redirect to `.cursor/delegate/<JOB_ID>.dispatch.log`. | open |
| V5  | Security S6                                  | Low      | `dispatch.sh:224`, `summarize.sh:58-76` | No key/secret redaction on `.err` contents piped into Claude-readable `.summary.md`. If `agent` ever echoes `CURSOR_API_KEY` or `Authorization` header in error trace, it enters Claude context. Fix: redact lines matching `CURSOR_API_KEY=\S+`, `Authorization:\s*\S+`, `Bearer\s+\S+`, `sk-[A-Za-z0-9]{20,}` before writing summary. | open |
| V6  | Security S4                                  | Low      | `lib_common.sh:145-155` | `cd_state_dir` / `cd_output_dir` call `mkdir -p` without `test -L` check. Attacker with project dir write access could pre-create `.cursor/delegate/state` as symlink to `~/.ssh`. Fix: `[[ -L "$d" ]] && cd_die 2 "refusing symlinked state dir"`. | open |
| V7  | Security S12                                 | Low      | Global              | No `umask 077` set on entry scripts. `meta.json` / `summary.md` / `resolved-config-*.json` inherit user umask; in loose-umask systems may be group-readable. Fix: `umask 077` at top of each entry script (dispatch, fanout, resume, status, cancel). | open |
| V8  | Security S11                                 | Low      | `fanout.sh:370`     | Semaphore busy-loop (`jobs -rp \| wc -l` with 200ms sleep) is brittle and may miscount children in subshells. Fix: use `wait -n` (bash 4.3+) for event-driven slot release. | open |
| V9  | Architect minor                              | Low      | `config/` directory | Plan §P1 listed `config/schema.json` as scaffold artifact; only `config/model.json` exists. Acceptable per ADR (jq-time validation), but scaffold completeness not matched. Fix: add minimal JSON Schema for `model.json` shape. | open |
| V10 | Architect minor + plan §P6                   | Low      | `tests/fixtures/`   | Empty — plan called for shared `tests/fixtures/fake-agent` stub; each unit test inlines its own stub in `TMPDIR_TEST/bin/agent`. Fix: extract common stub into `tests/fixtures/fake-agent.sh` + `tests/fixtures/lib.sh` helpers. | open |
| V11 | Code-review R-01                             | Low      | `synthesize.sh:140-147` | Variable named `local_body` at top-level scope (not inside function); misleading since `local` isn't applicable. Rename to `body` or refactor into a function. | open |
| V12 | Code-review R-02                             | Low      | `dispatch.sh:270-274` | jq stderr may leak into `SESSION_ID` via command substitution on malformed JSON. Add `2>/dev/null` to the jq call inside `$(...)`. | open |

**Ship posture**: All Phase 4 reviewers returned APPROVE-tier verdicts with follow-ups. **V1 (PID drift) is the only item that represents a real correctness gap** (cancel semantics weaker than SKILL.md advertises); recommend fixing before any real reliance on `/cursor cancel`. V2–V4 are medium-severity defense-in-depth. V5–V12 are nice-to-have polish.

## 2026-04-28 cleanup batch (partial — agent rate-limited)

The /deep-dive → /ralplan → /autopilot pipeline reached consensus (planner v2 + Architect APPROVE-FOR-V2 + Critic APPROVE) on 2026-04-28. Agent dispatch hit rate limit mid-Phase 2; the inline Claude session shipped the highest-value subset and queued the rest. Plan and reviews are persisted at `.omc/plans/ralplan-todo-cleanup-{planner,architect,critic}.md`.

| ID  | Status | Resolving change |
|-----|--------|------------------|
| V3  | **done** | `lib/lib_common.sh` cd_preflight: shape pre-validation (`^[A-Za-z0-9._:/-]+$`) + anchored `grep -Eq '^${model}($\|[[:space:]])'`; substring fallback dropped. Handles both bare and `name - description` `agent --list-models` formats. |
| V6  | **done** | `lib/lib_common.sh` cd_state_dir / cd_output_dir: `cd_check_symlink_guard` refuses symlinked `.cursor` / delegate / state with soft-fail override `CURSOR_DELEGATE_ALLOW_SYMLINK_STATE=1`. |
| V7  | **done** | `umask 077` at top of `dispatch.sh`, `fanout.sh`, `resume.sh`, `status.sh`, `cancel.sh`, `synthesize.sh`, `summarize.sh`. `chmod 600` after every meta write in `lib_common.sh` (cd_resolve_config:200, cd_emit_meta:402, cd_update_meta:422) — closes WSL2 DrvFs `mv`-mode-propagation gap. File-mode regression test deferred. |
| V9  | **done** | `config/schema.json` (draft-07) + `tests/unit/test_schema_validates_model_json.sh` (pure-jq smoke test, no Python dep). 5 assertions: positive + 4 synthetic mutations. PASSING. |
| V11 | **done** | `lib/synthesize.sh:140-151`: `local_body` → `body` (the variable was at top scope, `local` keyword inapplicable). |
| V12 | **done** | `lib/dispatch.sh:121-128`: `2>/dev/null` added to all 8 jq config-extraction calls. (Spec scope was 270-274, already had `2>/dev/null`. Extension to 121-128 ratified under spec line 108 <30 LoC exception per Critic R3.) |
| F7  | **done** | `lib/status.sh`: `[ZOMBIE]` recovery hint added to stale-sentinel warning block (cancel.sh re-run advice). Column-header regression-pin test deferred. |
| —   | side-fix | `lib/lib_common.sh:40-46`: env-var defaults (`: "${VAR:=...}"`) so callers can override `CD_SKILL_CONFIG` / `CD_USER_CONFIG` / `CD_HOOKS_FILE` / `CD_HOOKS_BAK` (was unconditionally overwriting — broke testability). Surfaced by re-running unit suite. |
| —   | side-fix | `config/model.json`: removed leading JSONC comment so `jq -e .` parses (cd_resolve_config invariant). |
| A1  | **done** | `lib/lib_common.sh`: mkdir-based atomic refcount for hooks-quarantine. `_cd_hooks_lock_acquire()` uses `mkdir` POSIX-atomic lock with 5s timeout (100 × 50ms). `cd_preflight_hooks` and `cd_hooks_restore` now lock → read refcount → operate → unlock. |
| V2  | **done** | `lib/resume.sh`: chatId regex `^[A-Za-z0-9._-]+$` + leading-dash rejection → exit 64. `lib/dispatch.sh`: `--` end-of-options marker before `${PROMPT}`. Regression guard: `tests/unit/test_resume_chatid_validation.sh` (4 assertions). |
| V4  | **done** | `lib/fanout.sh`: local-parallel children redirect stdout/stderr to `${OUT_DIR_ABS}/${jid}.dispatch.log`. `lib/synthesize.sh`: dispatch_log path surfaced in per-job synthesis block. Audit-channel warning emitted at fanout start. |
| V5  | **done** | `lib/lib_common.sh`: `cd_redact_secrets()` with anchored sed patterns for CURSOR_API_KEY, Authorization headers, line-start Bearer tokens, standalone sk- keys. `lib/summarize.sh`: applied to RAW_ERROR (always) + RESULT_TEXT (opt-in via `CURSOR_DELEGATE_REDACT_RESULT=1`). Regression guard: `tests/unit/test_summarize_redaction.sh` (7 assertions including prose false-positive survival). |
| V8  | **done** | `lib/fanout.sh`: replaced busy-loop semaphore (`jobs -rp | wc -l` + sleep 0.2) with `wait -n` event-driven slot release. Bash 4.3+ version guard with per-platform hints (macOS Homebrew, Git Bash, WSL2). |
| V10 | **done** | `tests/fixtures/fake-agent.sh` (parameterizable stub via env: FAKE_AGENT_MODELS, FAKE_AGENT_RESULT, FAKE_AGENT_SLEEP, FAKE_AGENT_EXIT, FAKE_AGENT_RECORD) + `tests/fixtures/lib.sh` (shared helpers: pass/fail counters, setup_fake_skill_dir, setup_fake_home, setup_fake_cwd, install_fake_agent, fx_summary). New and existing tests refactored to use shared fixtures. |
| F6  | **done** | `lib/status.sh`: 30-day TTL annotation before flag JSON dump. Computes `expires_epoch = det_epoch + 30*86400`, shows "N days remaining" or "EXPIRED". Uses GNU `date -d` with BSD `date -r` fallback. Regression guard: `tests/unit/test_status_flag_ttl.sh` (4 assertions). |

**Full unit-test result (2026-04-28, post-completion)**: 13 PASS / 0 FAIL / 0 SKIP. All 14 TODO items resolved. Pre-existing test bugs (test_dispatch_pid model mismatch, test_config_merge path resolution, test_preflight PATH leak) fixed as side-effects of V10 fixture extraction and env-var override work.

## 2026-06-26 cross-platform (WSL → macOS/Windows) hardening + `/cursor-setup`

The skill was built on WSL Ubuntu (bash 4+, GNU coreutils) and broke on macOS
(stock bash 3.2, BSD `date`/no `timeout`). Decision: Windows native is
unsupported (recommend WSL); macOS is made first-class by hardening the bash
core to 3.2 + BSD tolerance (no per-shell rewrite). Added a slim `/cursor-setup`
doctor that adapts per OS and wires the permission allowlist.

| Area | Change |
|------|--------|
| `lib_common.sh` | `cd_iso_to_epoch` / `cd_epoch_to_date` (GNU `-d` / BSD `-j -f` / `-r`, prefer `gdate`); `cd_resolve_timeout_bin` (`timeout`→`gtimeout`); `cd_preflight` accepts either timeout binary. |
| `dispatch.sh` | uses `${CD_TIMEOUT_BIN}` for real run + dry-run preview. |
| `status.sh` | `${var^^}`→`tr` (bash-3.2); epoch parse/format via the portable helpers. |
| `fanout.sh` | `wait -n` gated to bash ≥4.3 with poll-loop fallback (3.2-safe local-parallel); serialization-flag date parse via helper. |
| `synthesize.sh` | `plan_epoch_ms` via `cd_iso_to_epoch`; `set -u`-safe `${JOB_BLOCKS[@]+…}` guard. |
| **`cd_shquote` (real bug)** | On bash 3.2 the `${//}` literal-backslash replacement emitted broken quoting (`'it\'\\'\'s a test'`) that failed to round-trip → **corrupted fanout dispatch command lines on macOS**. Fixed via variable-built replacement (`esc="'\\''"`); verified round-trips on 3.2. |
| `lib/setup.sh` (new) | OS detect (WSL/Linux/macOS/Windows) + one-pass dep check (no `agent` call) + per-OS fix-it steps + permission allowlist gen/apply. bash-3.2-safe. |
| `cursor.sh` | `setup`/`doctor` route. |
| `skills/cursor-setup/SKILL.md` (new) | `/cursor-setup` launcher + protocol. |
| `SKILL.md` | "Setup & platform support" section. |
| tests | new `test_setup_doctor.sh`; 4 pre-existing test files made bash-3.2-safe (`test_fanout_parse` / `test_fanout_debug_forward` `$()`-quote & empty-array traps, `test_summarize_redaction` heredoc apostrophe, `test_status_flag_ttl` GNU-date fixture → portable). |

**Full unit-test result (2026-06-26, on macOS /bin/bash 3.2.57)**: 16 PASS / 0 FAIL / 0 SKIP.

## 2026-06-27 config-file unification + `auto` default model

Two config-ergonomics changes requested after the cross-platform work.

**1. Unify the config filename to `.cursor.json` across all 3 layers.**
The skill default was `config/model.json` while user/project overrides were
`.cursor.json` — inconsistent. Renamed the skill default to **`config/.cursor.json`**
so every layer shares one name + shape (deep-merge precedence unchanged:
`config/.cursor.json` < `~/.cursor.json` < `<cwd>/.cursor.json`).

| Scope | Change |
|-------|--------|
| `lib/lib_common.sh` | `CD_SKILL_CONFIG` default → `config/.cursor.json`. |
| `lib/cursor.sh` | help `Config:` line. |
| `config/schema.json` | title/description. |
| `tests/unit/test_schema_validates_model_json.sh` | validates `config/.cursor.json`. |
| docs | `SKILL.md`, `README.md`, `README_ja.md` path refs + schema headers. |
| (note) | test fixtures still write a local `config/model.json` and set `CD_SKILL_CONFIG` explicitly — internal fake name, not user-facing; left as-is. |

**2. Default model → `auto` for all 5 task types.**
`auto` is a real entry in `agent --list-models` (`auto - Auto (current)`) and
`agent --model auto` is valid, so it passes `cd_preflight`'s anchored
list-models check with **no special-casing**. Verified end-to-end via
`dispatch.sh --dry-run review` → exit 0, `resolved_model: auto`, planned argv
`--model auto`. Routing-matrix tables + schema examples in SKILL.md / README×2
updated to `auto`; the stale `agent --model list` hint corrected to
`agent --list-models`.

**Unit-test result (2026-06-27)**: 16 PASS / 0 FAIL / 0 SKIP (macOS bash 3.2).
Old `config/model.json` removed by the user after the rename.

## 2026-06-27 per-task `preamble` (customizable prompt in the same config file)

**Problem.** `review` / `investigate` / `security` were byte-for-byte identical
at the `agent` argv level (`model: auto`, `mode: ask`, no force/worktree) — names
only, no specialized prompt. Requested: keep customizable per-lens prompts **in
the same `.cursor.json`**, not a separate file.

**Design.** Added an optional **`preamble`** field to each `defaults.<task>`.
`agent` has no system-prompt flag (prompt is one positional arg; `generate-rule`
is unrelated), so injection is necessarily *prepend-to-user-prompt*.

- **Type:** `string` **or** array-of-strings (joined with `\n` — readable
  multi-line authoring in JSON).
- **`{{prompt}}` placeholder:** present → user prompt substituted there (wrap
  before/after); absent → preamble prepended with `\n\n---\n\n`.
- **Absent → verbatim:** no `preamble` means the user prompt passes unchanged
  (fully backward compatible).
- **3-layer deep-merge:** `preamble` follows the existing `reduce . * $x` merge;
  a deeper layer **replaces** it. Disable a shipped default with `"preamble": ""`.

Composition is done **in jq** (`gsub`/`join`), not bash parameter expansion —
deliberately, to dodge the bash-3.2 backslash-replacement class of bug already
hit in `cd_shquote`. A `[[ -z "${FULL_PROMPT}" ]] → PROMPT` guard ensures an
empty/failed compose never sends an empty prompt.

**Per the user's choice (既定preamble同梱):** shipped default preambles for the 3
read-only lenses (review/investigate/security, all using `{{prompt}}`); implement
and plan keep none.

| Scope | Change |
|-------|--------|
| `config/.cursor.json` | review/investigate/security gained array `preamble`s ending in `{{prompt}}`. |
| `lib/dispatch.sh` | new `FULL_PROMPT` jq-compose block after MODEL resolve; `agent … -- "${FULL_PROMPT}"`; dry-run preview/byte-count + heading now reflect the composed prompt. |
| `config/schema.json` | `taskRoute.preamble` = `oneOf[string, array<string>]` (+ description). |
| `tests/unit/test_preamble_injection.sh` | NEW — array-join + `{{prompt}}` substitution + placeholder-consumed + no-placeholder-prepend + verbatim-when-absent (via `--dry-run`/`CURSOR_DELEGATE_DEBUG_PROMPT=1` preview block) **and** the real `agent -- <prompt>` argv (fake-agent record). |
| docs | `SKILL.md` routing matrix (+preamble column & note), `README.md` / `README_ja.md` "Per-task prompt" section. |

**Verification (2026-06-27)**: full unit suite **17 PASS / 0 FAIL / 0 SKIP**
(macOS bash 3.2; was 16, +1 new). End-to-end compose on the shipped
`security.preamble` confirmed: `{{prompt}}` consumed, user prompt lands under
`--- 監査対象 ---`. Preview without token cost: `--dry-run` +
`CURSOR_DELEGATE_DEBUG_PROMPT=1` → summary "Final prompt preview" block.
