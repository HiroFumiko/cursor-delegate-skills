#!/usr/bin/env bash
# dispatch.sh — single Cursor CLI job invocation.
#
# Contract:
#   bash dispatch.sh <task_type> "<prompt>" [--resume <chatId>]
#
# Stdout contract (canonical, consumed by callers including fanout + Skill()):
#   - FIRST line:  JOB_ID=<id>
#   - LAST  line:  absolute path to .cursor/delegate/<JOB_ID>.summary.md
#   - Everything else -> stderr.
#
# Invariants (do not drift):
#   - stdin `</dev/null` + `timeout 590s` on every agent invocation.
#   - implement ALWAYS gets --worktree impl-<short-id> (no opt-out in v1).
#   - resolved-config snapshot is PER-JOB (resolved-config-<JOB_ID>.json).
#   - Exit 124 is PERMANENT — no retry (cd_classify_exit enforces).
#   - Claude should only Read the .summary.md; raw .json is audit-only.

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

# ------------------------------------------------------------------------------
# Bootstrap shared lib.
# ------------------------------------------------------------------------------

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

# ------------------------------------------------------------------------------
# Arg parsing.
# ------------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: dispatch.sh <task_type> "<prompt>" [--resume <chatId>] [--job-id <id>] [--debug] [--dry-run]

task_type: one of implement | review | plan | investigate | security
prompt:    the natural-language instruction to hand to Cursor.

Options:
  --resume <chatId>   continue a prior Cursor chat session
  --job-id <id>       use this JOB_ID (trailing-flag form of the
                      CURSOR_DELEGATE_JOB_ID env var; fanout uses it for
                      read-only task types)
  --debug             verbose stderr diagnostics (sets CURSOR_DELEGATE_DEBUG=1)
  --dry-run           preflight + config resolve, then print planned `agent`
                      command and exit without invoking it (sets
                      CURSOR_DELEGATE_DRY_RUN=1). Implies --debug.

Env overrides:
  CURSOR_DELEGATE_JOB_ID            use this JOB_ID instead of generating one
                                    (for fanout / resume callers)
  CURSOR_DELEGATE_QUARANTINE_HOOKS  "0" disables hooks.json move-aside (default 1)
  CURSOR_DELEGATE_TIMEOUT_SEC       override timeout (default 590)
  CURSOR_DELEGATE_DEBUG             "1" enables verbose stderr diagnostics
  CURSOR_DELEGATE_DRY_RUN           "1" skips the `agent` call; emits dry-run summary
EOF
}

# Tolerate global meta flags (--debug / --dry-run) appearing BEFORE the
# positional <task_type> <prompt>, mirroring cursor.sh's entrypoint. They are
# ALSO accepted as trailing flags in the loop below (the form fanout emits), so
# both `dispatch.sh --dry-run review "x"` and `dispatch.sh review "x" --dry-run`
# work. --dry-run implies --debug so the preview is always visible.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      export CURSOR_DELEGATE_DEBUG=1
      shift
      ;;
    --dry-run)
      export CURSOR_DELEGATE_DRY_RUN=1
      export CURSOR_DELEGATE_DEBUG=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  usage
  exit 64
fi

TASK_TYPE="$1"; shift
PROMPT="$1";    shift
RESUME_CHAT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      RESUME_CHAT_ID="$2"
      shift 2
      ;;
    --job-id)
      # Trailing-flag form of CURSOR_DELEGATE_JOB_ID. fanout uses this for
      # READ-ONLY task types so the command keeps a leading `bash dispatch.sh
      # <task>` prefix (no `VAR=...` head). Behaves identically to the env var.
      [[ $# -ge 2 ]] || { usage; exit 64; }
      export CURSOR_DELEGATE_JOB_ID="$2"
      shift 2
      ;;
    --debug)
      export CURSOR_DELEGATE_DEBUG=1
      shift
      ;;
    --dry-run)
      export CURSOR_DELEGATE_DRY_RUN=1
      export CURSOR_DELEGATE_DEBUG=1  # dry-run is useless without the preview
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      cd_log "ERROR" "unknown argument: $1"
      usage
      exit 64
      ;;
  esac
done

case "${TASK_TYPE}" in
  implement|review|plan|investigate|security) ;;
  *)
    cd_log "ERROR" "invalid task_type: ${TASK_TYPE}"
    usage
    exit 64
    ;;
esac

# ------------------------------------------------------------------------------
# JOB_ID + dirs.
# ------------------------------------------------------------------------------

JOB_ID="${CURSOR_DELEGATE_JOB_ID:-$(cd_gen_job_id)}"
OUT_DIR="$(cd_output_dir)"
STATE_DIR="$(cd_state_dir)"

RAW_JSON="${OUT_DIR}/${JOB_ID}.json"
RAW_ERR="${OUT_DIR}/${JOB_ID}.err"

# Emit JOB_ID on FIRST line of stdout (contract).
printf 'JOB_ID=%s\n' "${JOB_ID}"

# ------------------------------------------------------------------------------
# Debug snapshot — environment, paths, prompt shape (only when --debug active).
# Kept on stderr so the stdout 2-line contract is unaffected.
# ------------------------------------------------------------------------------

if cd_is_debug; then
  cd_debug "task_type=${TASK_TYPE}  job_id=${JOB_ID}"
  cd_debug "prompt_len=${#PROMPT}  resume_chat_id=${RESUME_CHAT_ID:-<none>}"
  cd_debug "cwd=${PWD}  home=${HOME}"
  cd_debug "skill_dir=${CD_SKILL_DIR}"
  cd_debug "config layers: skill=${CD_SKILL_CONFIG} user=${CD_USER_CONFIG} project=${PWD}/${CD_PROJECT_CONFIG}"
  cd_debug "out_dir=${OUT_DIR}  state_dir=${STATE_DIR}"
  cd_debug "dry_run=${CURSOR_DELEGATE_DRY_RUN:-0}  quarantine_hooks=${CURSOR_DELEGATE_QUARANTINE_HOOKS:-1}  timeout_override=${CURSOR_DELEGATE_TIMEOUT_SEC:-<none>}"
fi

# ------------------------------------------------------------------------------
# Hooks quarantine + trap for restore.
# In dry-run we skip the side-effecting move-aside; nothing real will run.
# ------------------------------------------------------------------------------

if cd_is_dry_run; then
  cd_debug "dry-run: skipping hooks.json quarantine (no side effects)"
else
  cd_preflight_hooks "${JOB_ID}"
  # The trap captures JOB_ID by value because it expands $JOB_ID at trap-install
  # time. Restoring is idempotent and safe on multi-signal delivery. Only
  # installed when we actually quarantined; otherwise a dry-run would
  # erroneously decrement another concurrent job's refcount.
  # shellcheck disable=SC2064
  trap "cd_hooks_restore '${JOB_ID}'" EXIT INT TERM
fi

# ------------------------------------------------------------------------------
# Resolve config (per-JOB snapshot) + derive flags.
# ------------------------------------------------------------------------------

RESOLVED_CONFIG_PATH="$(cd_resolve_config "${TASK_TYPE}" "${JOB_ID}")"
cd_log "INFO" "resolved config snapshot: ${RESOLVED_CONFIG_PATH}"

if cd_is_debug; then
  cd_debug "--- begin resolved config dump ---"
  while IFS= read -r line; do
    cd_debug "  ${line}"
  done < "${RESOLVED_CONFIG_PATH}"
  cd_debug "--- end resolved config dump ---"
fi

# Extract per-task route values. `// empty` means "no default string"; jq prints
# empty for missing optional fields so we can test with -z.
MODEL="$(     jq -r --arg t "${TASK_TYPE}" '.defaults[$t].model          // empty' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
MODE="$(      jq -r --arg t "${TASK_TYPE}" '.defaults[$t].mode           // empty' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
FORCE="$(     jq -r --arg t "${TASK_TYPE}" '.defaults[$t].force          // false' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
WT_FLAG="$(   jq -r --arg t "${TASK_TYPE}" '.defaults[$t].worktree       // false' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
SANDBOX="$(   jq -r --arg t "${TASK_TYPE}" '.defaults[$t].sandbox        // "enabled"' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
MAX_ATTEMPTS="$(jq -r '.retry.max_attempts     // 3'    "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
INIT_DELAY_MS="$(jq -r '.retry.initial_delay_ms // 1000' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"
TIMEOUT_SEC="${CURSOR_DELEGATE_TIMEOUT_SEC:-$(jq -r '.timeout_sec // 590' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)}"

if [[ -z "${MODEL}" ]]; then
  cd_die 4 "resolved config has no model for task_type=${TASK_TYPE}"
fi

# ------------------------------------------------------------------------------
# Compose the final prompt.
# An optional per-task `preamble` (string OR array-of-strings, joined with
# newlines) is combined with the user prompt:
#   - if the preamble contains a `{{prompt}}` placeholder, the user prompt is
#     substituted there (lets the preamble wrap before AND after);
#   - otherwise the preamble is prepended with a `\n\n---\n\n` separator.
# No preamble -> the user prompt is passed through verbatim (backward compatible).
# Composition is done in jq (not bash parameter expansion) so arbitrary prompt
# text — backslashes, quotes — is handled safely on bash 3.2.
# ------------------------------------------------------------------------------

FULL_PROMPT="$(jq -r --arg t "${TASK_TYPE}" --arg prompt "${PROMPT}" '
  (.defaults[$t].preamble) as $praw
  | (if   ($praw | type) == "array"  then ($praw | join("\n"))
     elif ($praw | type) == "string" then $praw
     else "" end) as $pre
  | if   ($pre | length) == 0                 then $prompt
    elif ($pre | test("\\{\\{prompt\\}\\}"))  then ($pre | gsub("\\{\\{prompt\\}\\}"; $prompt))
    else $pre + "\n\n---\n\n" + $prompt
    end
' "${RESOLVED_CONFIG_PATH}" 2>/dev/null)"

# Fallback: never send an empty prompt by mistake. If jq emitted nothing (parse
# error, or both preamble and prompt empty), fall back to the raw user prompt —
# exactly the pre-preamble behavior.
if [[ -z "${FULL_PROMPT}" ]]; then
  FULL_PROMPT="${PROMPT}"
fi

if cd_is_debug; then
  if [[ "${FULL_PROMPT}" != "${PROMPT}" ]]; then
    cd_debug "prompt composed with preamble (full_len=${#FULL_PROMPT}, user_len=${#PROMPT})"
  else
    cd_debug "no preamble for task_type=${TASK_TYPE} (prompt passed verbatim)"
  fi
fi

# ------------------------------------------------------------------------------
# Preflight (runs after config so we know which model to validate).
# ------------------------------------------------------------------------------

cd_preflight "${TASK_TYPE}" "${MODEL}"

# ------------------------------------------------------------------------------
# Worktree name (implement-only, mandatory invariant).
# ------------------------------------------------------------------------------

WORKTREE_NAME=""
if [[ "${TASK_TYPE}" == "implement" ]]; then
  # Always use --worktree for implement. The suffix is short+stable so the
  # resulting path is human-friendly (impl-<8hex-random-slice-of-JOB_ID>).
  WORKTREE_NAME="impl-${JOB_ID##*-}"
elif [[ "${WT_FLAG}" == "true" ]]; then
  # Respect config if a non-implement task explicitly opts in.
  WORKTREE_NAME="wt-${JOB_ID##*-}"
fi

# ------------------------------------------------------------------------------
# Build agent arg array.
# ------------------------------------------------------------------------------

AGENT_ARGS=(-p --model "${MODEL}" --output-format json --trust --sandbox "${SANDBOX}")

if [[ -n "${MODE}" && "${MODE}" != "null" ]]; then
  AGENT_ARGS+=(--mode "${MODE}")
fi

if [[ "${FORCE}" == "true" ]]; then
  AGENT_ARGS+=(--force)
fi

if [[ -n "${WORKTREE_NAME}" ]]; then
  AGENT_ARGS+=(--worktree "${WORKTREE_NAME}")
fi

if [[ -n "${RESUME_CHAT_ID}" ]]; then
  AGENT_ARGS+=(--resume "${RESUME_CHAT_ID}")
fi

# ------------------------------------------------------------------------------
# Emit initial meta sidecar (status=running).
# ------------------------------------------------------------------------------

STARTED_AT="$(cd_iso_now)"
STARTED_MS="$(cd_epoch_ms)"

META_PATH="$(cd_emit_meta \
  "${JOB_ID}" \
  "${TASK_TYPE}" \
  "${MODEL}" \
  "${MODE:-null}" \
  "${WORKTREE_NAME:-null}" \
  "${RESUME_CHAT_ID:-null}" \
  "0" \
  "${STARTED_AT}")"

cd_log "INFO" "meta sidecar: ${META_PATH}"
cd_log "INFO" "agent args: ${AGENT_ARGS[*]}"

# Record resolved config path + retry policy into meta for audit.
cd_update_meta "${JOB_ID}" \
  "$(printf '.resolved_config_path=%s | .max_attempts=%s | .timeout_sec=%s' \
      "$(jq -Rn --arg p "${RESOLVED_CONFIG_PATH}" '$p')" \
      "${MAX_ATTEMPTS}" \
      "${TIMEOUT_SEC}")"

# ------------------------------------------------------------------------------
# Dry-run short-circuit.
# Skip the `agent` invocation entirely. Emit a status=dry_run summary file so
# the stdout 2-line contract (JOB_ID first, summary path last) still holds.
# ------------------------------------------------------------------------------

if cd_is_dry_run; then
  cd_log "INFO" "dry-run: skipping agent invocation"

  DRY_COMPLETED_AT="$(cd_iso_now)"
  cd_update_meta "${JOB_ID}" \
    "$(printf '.completed_at=%s | .status=%s | .exit_code=%s | .duration_ms=%s | .dry_run=true' \
        "$(jq -Rn --arg v "${DRY_COMPLETED_AT}" '$v')" \
        "$(jq -Rn --arg v "dry_run" '$v')" \
        "0" \
        "0")"

  SUMMARY_PATH_DR="${OUT_DIR}/${JOB_ID}.summary.md"

  # Render the planned argv with each piece on its own line for readability.
  # PROMPT is intentionally kept out of the rendered argv (it can be large /
  # sensitive); the prompt-length is shown instead, plus a head preview gated
  # on CURSOR_DELEGATE_DEBUG_PROMPT=1.
  PROMPT_PREVIEW=""
  if [[ "${CURSOR_DELEGATE_DEBUG_PROMPT:-0}" == "1" ]]; then
    PROMPT_PREVIEW="${FULL_PROMPT:0:200}"
    if (( ${#FULL_PROMPT} > 200 )); then
      PROMPT_PREVIEW="${PROMPT_PREVIEW}…(truncated; total len=${#FULL_PROMPT})"
    fi
  fi

  {
    printf -- '---\n'
    printf 'job_id: %s\n'         "${JOB_ID}"
    printf 'task_type: %s\n'      "${TASK_TYPE}"
    printf 'resolved_model: %s\n' "${MODEL}"
    printf 'mode: %s\n'           "${MODE:-none}"
    printf 'worktree: %s\n'       "${WORKTREE_NAME:-none}"
    printf 'started_at: %s\n'     "${STARTED_AT}"
    printf 'completed_at: %s\n'   "${DRY_COMPLETED_AT}"
    printf 'duration_ms: 0\n'
    printf 'exit_code: 0\n'
    printf 'status: dry_run\n'
    printf 'session_id: %s\n'     "${RESUME_CHAT_ID:-none}"
    printf -- '---\n\n'
    printf '## Dry run\n\n'
    printf '_No `agent` invocation occurred. The block below shows the command '
    printf 'that **would** have run._\n\n'
    printf '### Planned command\n\n'
    printf '```\n'
    printf '%s --kill-after=5s %ss \\\n' "${CD_TIMEOUT_BIN:-timeout}" "${TIMEOUT_SEC}"
    printf '  agent'
    for a in "${AGENT_ARGS[@]}"; do
      printf ' \\\n    %q' "${a}"
    done
    printf ' \\\n    -- <prompt: %s bytes>\n' "${#FULL_PROMPT}"
    printf '```\n\n'
    if [[ -n "${PROMPT_PREVIEW}" ]]; then
      printf '### Final prompt preview — preamble + user prompt (CURSOR_DELEGATE_DEBUG_PROMPT=1)\n\n'
      printf '```\n%s\n```\n\n' "${PROMPT_PREVIEW}"
    fi
    printf '### Resolved config\n\n'
    printf -- '- snapshot: `%s`\n' "${RESOLVED_CONFIG_PATH}"
    printf -- '- task defaults:\n'
    printf '```json\n'
    jq --arg t "${TASK_TYPE}" '.defaults[$t]' "${RESOLVED_CONFIG_PATH}" 2>/dev/null || printf '{}\n'
    printf '```\n\n'
    printf '## Artifacts\n\n'
    printf -- '- meta: `%s`\n' "${META_PATH}"
  } >"${SUMMARY_PATH_DR}.tmp"
  mv "${SUMMARY_PATH_DR}.tmp" "${SUMMARY_PATH_DR}"
  chmod 600 "${SUMMARY_PATH_DR}" 2>/dev/null || true

  SUMMARY_PATH_ABS="$(cd "${OUT_DIR}" && pwd)/${JOB_ID}.summary.md"
  # LAST line of stdout — contract holds in dry-run too.
  printf '%s\n' "${SUMMARY_PATH_ABS}"
  exit 0
fi

# ------------------------------------------------------------------------------
# Retry loop with classify-then-decide.
# ------------------------------------------------------------------------------

EXIT_CODE=0
ATTEMPT=0
DELAY_MS="${INIT_DELAY_MS}"
LAST_STATUS="failed"

while : ; do
  ATTEMPT=$((ATTEMPT + 1))
  cd_log "INFO" "attempt ${ATTEMPT}/${MAX_ATTEMPTS} — invoking agent (timeout ${TIMEOUT_SEC}s)"

  # Truncate the raw outputs at each attempt so the final pair reflects the
  # last try. (Retries are rare and we preserve state in meta/logs anyway.)
  : >"${RAW_JSON}"
  : >"${RAW_ERR}"

  set +e
  # V1 fix: background the timeout wrapper so we can capture the real child PID
  # (timeout(1) forwards SIGTERM/SIGKILL to its agent child), persist it to meta
  # BEFORE waiting so cancel.sh / status.sh can act on a live pid, then wait.
  "${CD_TIMEOUT_BIN:-timeout}" --kill-after=5s "${TIMEOUT_SEC}s" \
    agent "${AGENT_ARGS[@]}" -- "${FULL_PROMPT}" \
    </dev/null >"${RAW_JSON}" 2>"${RAW_ERR}" &
  CHILD_PID=$!

  # Persist the live child PID before blocking on wait. cancel.sh sends SIGTERM
  # to this pid; timeout(1) forwards it to the agent child and exits with 143.
  cd_update_meta "${JOB_ID}" \
    "$(printf '.attempts=%s | .pid=%s' "${ATTEMPT}" "${CHILD_PID}")"

  ATTEMPT_STARTED_MS="$(cd_epoch_ms)"
  cd_debug "attempt ${ATTEMPT} child_pid=${CHILD_PID} timeout=${TIMEOUT_SEC}s"

  wait "${CHILD_PID}"
  EXIT_CODE=$?
  set -e

  ATTEMPT_ELAPSED_MS=$(( $(cd_epoch_ms) - ATTEMPT_STARTED_MS ))
  cd_debug "attempt ${ATTEMPT} exit=${EXIT_CODE} elapsed_ms=${ATTEMPT_ELAPSED_MS}"

  cd_update_meta "${JOB_ID}" \
    "$(printf '.last_exit=%s' "${EXIT_CODE}")"

  if [[ "${EXIT_CODE}" -eq 0 ]]; then
    LAST_STATUS="completed"
    break
  fi

  CLASS="$(cd_classify_exit "${EXIT_CODE}")"
  cd_log "WARN" "agent exit=${EXIT_CODE} class=${CLASS}"

  if cd_is_debug && [[ -s "${RAW_ERR}" ]]; then
    cd_debug "--- raw stderr tail (attempt ${ATTEMPT}, last 20 lines) ---"
    tail -n 20 "${RAW_ERR}" 2>/dev/null | while IFS= read -r line; do
      cd_debug "  ${line}"
    done
    cd_debug "--- end raw stderr tail ---"
  fi

  # Timeout (124) is always terminal per invariant.
  if [[ "${EXIT_CODE}" -eq 124 ]]; then
    LAST_STATUS="timed_out"
    break
  fi

  # Only explicitly TRANSIENT codes retry; UNKNOWN defaults to permanent.
  if [[ "${CLASS}" != "TRANSIENT" ]]; then
    LAST_STATUS="failed"
    break
  fi

  if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
    cd_log "WARN" "exhausted ${MAX_ATTEMPTS} retry attempts"
    LAST_STATUS="failed"
    break
  fi

  cd_log "INFO" "transient failure, backing off ${DELAY_MS}ms before retry"
  # sleep accepts fractional seconds on GNU coreutils.
  sleep "$(awk -v ms="${DELAY_MS}" 'BEGIN { printf "%.3f", ms/1000 }')"
  DELAY_MS=$((DELAY_MS * 2))
done

COMPLETED_AT="$(cd_iso_now)"
COMPLETED_MS="$(cd_epoch_ms)"
DURATION_MS=$((COMPLETED_MS - STARTED_MS))

# Pull session_id out of raw JSON if present/valid (best-effort).
SESSION_ID=""
if jq -e . "${RAW_JSON}" >/dev/null 2>&1; then
  SESSION_ID="$(jq -r '.session_id // .chatId // empty' "${RAW_JSON}" 2>/dev/null || true)"
fi
[[ -n "${RESUME_CHAT_ID}" && -z "${SESSION_ID}" ]] && SESSION_ID="${RESUME_CHAT_ID}"

# ------------------------------------------------------------------------------
# Final meta update.
# ------------------------------------------------------------------------------

cd_update_meta "${JOB_ID}" \
  "$(printf '.completed_at=%s | .exit_code=%s | .status=%s | .duration_ms=%s | .session_id=%s' \
      "$(jq -Rn --arg v "${COMPLETED_AT}" '$v')" \
      "${EXIT_CODE}" \
      "$(jq -Rn --arg v "${LAST_STATUS}" '$v')" \
      "${DURATION_MS}" \
      "$(jq -Rn --arg v "${SESSION_ID}" 'if ($v|length)==0 then null else $v end')")"

# ------------------------------------------------------------------------------
# Summarize (P3).
# ------------------------------------------------------------------------------

SUMMARY_PATH=""
if ! SUMMARY_PATH="$(bash "${CD_SELF_DIR}/summarize.sh" "${JOB_ID}")"; then
  cd_log "ERROR" "summarize.sh failed for job ${JOB_ID}"
  # Fall back to synthesizing a path even on summarize failure so callers get
  # something to Read. summarize.sh is responsible for writing a degraded file.
  SUMMARY_PATH="$(cd "${OUT_DIR}" && pwd)/${JOB_ID}.summary.md"
fi

# Normalise to absolute path.
case "${SUMMARY_PATH}" in
  /*) ;;
  *)  SUMMARY_PATH="$(cd "$(dirname "${SUMMARY_PATH}")" && pwd)/$(basename "${SUMMARY_PATH}")" ;;
esac

# LAST line of stdout (contract) — the summary filepath Claude should Read.
printf '%s\n' "${SUMMARY_PATH}"

# Exit with the underlying agent code so supervisors see the real signal.
exit "${EXIT_CODE}"
