# cursor Manual QA Checklist

Human-verified checks for behaviors that cannot be automated within the test harness.
Run `bash tests/run.sh unit` first. Then work through these items in order.

Record your observation and check the box when confirmed.

---

## MQ-1: AC2 Claude-driven fanout wall-clock

**Maps to**: AC2 / R4
**Why manual**: Requires a live Claude Code session. The Bash tool parallelism is a Claude runtime property — not reproducible deterministically in a shell harness.

### Setup

1. Open a fresh Claude Code session (not inside an existing tool call).
2. Ensure `CURSOR_API_KEY` is set or `agent login` has been run.
3. Have at least two small source files available (e.g., `lib/lib_common.sh` and `lib/dispatch.sh`).

### Execution

In the Claude Code chat, type:

```
/cursor fanout review:lib/lib_common.sh review:lib/dispatch.sh
```

Observe the Bash tool calls Claude emits in response.

### Expected observation

Claude emits **two separate Bash tool calls in the same assistant message** (visible as two `Bash` blocks side-by-side or listed together before any results arrive). Both calls run concurrently — `lib_common.sh` review and `dispatch.sh` review overlap in time.

After both complete, Claude runs a third Bash call (`fanout.sh --collect <FANOUT_TS>`) and then reads the synthesis file.

The wall-clock time reported by Claude (or visible from `started_at`/`completed_at` in each job's `.meta.json`) should be closer to `max(job_A, job_B)` than to `job_A + job_B`.

### Pass criteria

- Two Bash tool calls visible in the same assistant message.
- `wall_clock_ms` in the synthesis frontmatter ≤ `max_duration_ms × 1.2`.
- No error in either job's `summary.md`.

### Fail criteria

- Only one Bash tool call fires at a time (serialized). Wall-clock ≥ `sum(durations) × 1.5`.
- Claude errors out or does not emit two parallel calls.

### Recovery

If serialized, the `claude-serializes-bash` flag should be written automatically after the run (check `.cursor/delegate/state/claude-serializes-bash`). If present:

```bash
# Subsequent fanouts auto-flip to local-parallel. Or force it manually:
CURSOR_DELEGATE_LOCAL_PARALLEL=1 bash lib/fanout.sh review:lib/lib_common.sh review:lib/dispatch.sh
```

---

## MQ-2: AC3 Resume context preservation

**Maps to**: AC3 / R1
**Why manual**: Semantic check on Cursor's response content — whether it genuinely references a prior turn's context is not a bit-pattern assertion.

### Setup

1. Ensure `CURSOR_API_KEY` is set or `agent login` has been run.
2. Have a terminal open in the project root (where `.omc/` will be written).

### Execution

```bash
# Step 1: create a chat.
CHAT=$(bash lib/resume.sh --create-chat)
echo "Chat ID: $CHAT"

# Step 2: establish context.
bash lib/dispatch.sh investigate "My favorite color is purple. Acknowledge this." --resume "$CHAT"

# Step 3: follow-up question.
bash lib/resume.sh "$CHAT" "What is the favorite color I mentioned in our conversation?"
```

Read the last summary file (path printed as the last stdout line of step 3).

### Expected observation

The step-3 summary contains the word "purple" (or equivalent acknowledgment that the model retained the prior message's context).

### Pass criteria

- `grep -i purple <step3-summary.md>` exits 0.
- `sessions.jsonl` has two entries with the same `chat_id`.

### Fail criteria

- Step-3 summary does not mention "purple" — Cursor acted as if the chatId was new.
- `resume.sh --create-chat` failed to parse a chatId (R1 risk: format unconfirmed upstream).

### Recovery

If `--create-chat` fails: run `agent create-chat </dev/null 2>&1` manually, copy the chatId from the output, and pass it directly: `bash lib/resume.sh "$CHAT" "..."`.

If context not preserved: confirm `--resume` flag appears in the `agent` invocation (check `.cursor/delegate/<JOB>.err` for the actual command line).

---

## MQ-3: AC7 Cross-session Skill() invocation

**Maps to**: AC7
**Why manual**: Requires opening a **new** Claude Code session with the skill loaded. Cross-session Skill() behavior cannot be faked in a shell test.

### Setup

1. Confirm `cursor` skill is discoverable: run `/oh-my-claudecode:skill list | grep cursor` (or equivalent) in a Claude Code session — it should appear.
2. Have a source file ready (e.g., `lib/lib_common.sh`).

### Execution

Open a **new** Claude Code session (separate from any ongoing work). In the chat:

```
Skill("cursor", args="dispatch review lib/lib_common.sh")
```

Or equivalently via the slash command:

```
/cursor dispatch review lib/lib_common.sh
```

### Expected observation

- The skill triggers without error.
- A `.cursor/delegate/<JOB_ID>.summary.md` is created.
- The last stdout line from the skill invocation is the absolute path to that summary file (matching `^/.+\.summary\.md$`).
- Claude presents the summary content in the conversation.

### Pass criteria

- `summary.md` exists and has valid frontmatter (all fields present).
- The result is semantically equivalent to running `bash lib/dispatch.sh review lib/lib_common.sh` directly.
- No "skill not found" or "permission denied" error.

### Fail criteria

- Skill not found in new session.
- Different semantics or error compared to direct slash invocation.
- Summary path not returned as last stdout line.

### Recovery

If skill not found: check `~/.claude/skills/cursor/SKILL.md` has correct frontmatter (`level: 4`). Run `/oh-my-claudecode:omc-setup` to refresh skill registry.

---

## MQ-4: Hooks quarantine live round-trip

**Maps to**: R2 (spec A3 mitigation)
**Why manual**: Side-effect on the real `~/.cursor/hooks.json` — cannot be run safely in CI without risk of losing the user's actual hooks file.

### Setup

1. Confirm `~/.cursor/hooks.json` **exists**: `ls -la ~/.cursor/hooks.json`.
2. Make a backup: `cp ~/.cursor/hooks.json /tmp/hooks-backup.json`.
3. Note the file's checksum: `md5sum ~/.cursor/hooks.json` (or `sha256sum`).

### Execution

```bash
# In one terminal, start a dispatch (small review task):
bash lib/dispatch.sh review "describe this file in one sentence" &
DISPATCH_PID=$!

# In a second terminal, immediately check:
sleep 1
ls -la ~/.cursor/
```

After the dispatch completes (or after `wait $DISPATCH_PID`), check again:

```bash
ls -la ~/.cursor/
md5sum ~/.cursor/hooks.json
```

### Expected observation

**During** the dispatch: `~/.cursor/hooks.json` is absent; `~/.cursor/hooks.json.cursor.bak` is present. A sentinel file exists at `.cursor/delegate/state/hooks-quarantined-<JOB_ID>`.

**After** the dispatch completes: `hooks.json` is restored (identical checksum), `.bak` is gone, sentinel is gone.

### Pass criteria

- Mid-run: `hooks.json` absent, `.bak` present, sentinel present.
- Post-run: `hooks.json` restored with identical checksum to pre-run.
- `.bak` absent, sentinel absent.

### Fail criteria

- `hooks.json` still absent after dispatch completes (restore failed).
- `.bak` remains after restore (partial cleanup).
- Sentinel remains (orphaned).

### Recovery

```bash
# Restore manually:
mv ~/.cursor/hooks.json.cursor.bak ~/.cursor/hooks.json

# Remove orphaned sentinels:
rm -f .cursor/delegate/state/hooks-quarantined-*

# Verify hooks.json is intact:
jq . ~/.cursor/hooks.json
```

---

## MQ-5: Local-parallel auto-detect flip

**Maps to**: AC2 / R4
**Why manual**: Requires sequential fanout runs in the same project to observe flag state changes across invocations — a stateful multi-step flow not expressible as a single-shot unit test.

### Setup

1. Clear any existing serialization flag: `bash lib/fanout.sh --clear-serialization-flag`.
2. Confirm flag is gone: `ls .cursor/delegate/state/claude-serializes-bash 2>/dev/null || echo "absent (good)"`.
3. Ensure `CURSOR_API_KEY` is set.

### Execution

**Step 1**: Run a fanout in a context where Claude's Bash tool will serialize (e.g., inside a busy orchestrated session, or simulate by setting `CURSOR_DELEGATE_FORCE_CLAUDE=0` and running a fanout that takes a while):

```bash
# Simulate serialization by running 2 jobs in claude-driven mode
# and observing the wall-clock vs max(durations) in the synthesis file.
bash lib/fanout.sh review:lib/lib_common.sh review:lib/dispatch.sh
# After collection (fanout.sh --collect <FANOUT_TS>), check:
cat .cursor/delegate/state/claude-serializes-bash 2>/dev/null || echo "flag not written"
```

If the flag was written (serialization_ratio > 1.2), proceed to Step 2.

**Step 2**: Run another fanout **without** any flags:

```bash
bash lib/fanout.sh review:lib/lib_common.sh security:lib/dispatch.sh 2>&1 | head -20
```

### Expected observation

**Step 1**: After the collect step, `.cursor/delegate/state/claude-serializes-bash` exists with valid JSON containing `detected_at`, `serialization_ratio > 1.2`, `omc_version` set (possibly "unknown" if `$OMC_VERSION` not exported).

**Step 2**: `fanout.sh` stderr shows the auto-flip warning:
```
[cursor][WARN] claude-serializes-bash flag is active (fresh, <30d)
[cursor][WARN] auto-flipping to --local-parallel mode
```
And the fanout runs in local-parallel mode.

### Pass criteria

- Flag file exists with valid JSON after a serialized claude-driven fanout.
- Subsequent fanout without `--local-parallel` flag auto-flips and logs the warning.
- `bash lib/fanout.sh --clear-serialization-flag` removes the flag cleanly.

### Fail criteria

- Flag not written even after observed serialization (ratio > 1.2 with N >= 2 jobs).
- Second fanout does NOT auto-flip despite fresh flag.
- `--clear-serialization-flag` leaves the file behind.

### Recovery

```bash
# Force local-parallel for a single run without the flag:
CURSOR_DELEGATE_LOCAL_PARALLEL=1 bash lib/fanout.sh review:lib/lib_common.sh security:lib/dispatch.sh

# Reset the flag:
bash lib/fanout.sh --clear-serialization-flag

# Override the auto-flip for one run while keeping the flag:
CURSOR_DELEGATE_FORCE_CLAUDE=1 bash lib/fanout.sh review:lib/lib_common.sh security:lib/dispatch.sh
```

---

*All 5 items confirmed? The plan-done definition for cursor v1.0.0 requires:*
- *`bash tests/run.sh unit` all non-skipped tests pass*
- *`bash tests/run.sh integration` all non-skipped tests pass (with CURSOR_API_KEY)*
- *MQ-1 through MQ-5 above checked off*
