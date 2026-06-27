#!/usr/bin/env bash
# summarize.sh — render <JOB_ID>.summary.md from raw .json + .meta.json.
#
# Contract:
#   bash summarize.sh <JOB_ID>
#   -> writes .cursor/delegate/<JOB_ID>.summary.md
#   -> prints the absolute summary path on stdout
#
# Context hygiene invariant (spec Principle 3): Claude Reads ONLY the summary.
# The raw .json is audit-only and MUST never be Read into conversation context.

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

if [[ $# -lt 1 ]]; then
  cd_die 64 "usage: summarize.sh <JOB_ID>"
fi

JOB_ID="$1"

cd_require_jq

OUT_DIR="$(cd_output_dir)"
OUT_DIR_ABS="$(cd "${OUT_DIR}" && pwd)"

META="${OUT_DIR}/${JOB_ID}.meta.json"
RAW="${OUT_DIR}/${JOB_ID}.json"
ERR="${OUT_DIR}/${JOB_ID}.err"
SUMMARY="${OUT_DIR}/${JOB_ID}.summary.md"

if [[ ! -f "${META}" ]]; then
  cd_die 4 "meta sidecar missing for job ${JOB_ID}: ${META}"
fi

# Meta-sourced frontmatter (always authoritative — our own data).
TASK_TYPE="$(     jq -r '.task_type      // "unknown"' "${META}")"
MODEL="$(         jq -r '.resolved_model // "unknown"' "${META}")"
MODE="$(          jq -r '.mode           // "none"'    "${META}")"
WORKTREE="$(      jq -r '.worktree       // "none"'    "${META}")"
STARTED_AT="$(    jq -r '.started_at     // "unknown"' "${META}")"
COMPLETED_AT="$(  jq -r '.completed_at   // "unknown"' "${META}")"
DURATION_MS="$(   jq -r '.duration_ms    // 0'         "${META}")"
EXIT_CODE="$(     jq -r '.exit_code      // "null"'    "${META}")"
META_STATUS="$(   jq -r '.status         // "unknown"' "${META}")"
SESSION_ID="$(    jq -r '.session_id     // "none"'    "${META}")"

# Attempt to extract result text from raw JSON; fall back on malformed/missing.
STATUS="${META_STATUS}"
RESULT_TEXT=""
RAW_ERROR=""

if [[ -f "${RAW}" ]] && jq -e . "${RAW}" >/dev/null 2>&1; then
  # Truncate to first ~1500 chars; if we trim, append last 300 chars as TAIL.
  # jq -r emits raw string; head -c is byte-based, which is fine for our budget.
  FULL_RESULT="$(jq -r '.result // empty' "${RAW}" 2>/dev/null || true)"
  if [[ -n "${FULL_RESULT}" ]]; then
    FULL_LEN=${#FULL_RESULT}
    if (( FULL_LEN > 1500 )); then
      HEAD_PART="${FULL_RESULT:0:1500}"
      TAIL_PART="${FULL_RESULT: -300}"
      RESULT_TEXT=$'\n'"${HEAD_PART}"$'\n\n...[truncated; len='"${FULL_LEN}"']...\n\n[TAIL]\n'"${TAIL_PART}"
    else
      RESULT_TEXT=$'\n'"${FULL_RESULT}"
    fi
  fi

  RAW_ERROR="$(jq -r '.error // empty' "${RAW}" 2>/dev/null || true)"
else
  STATUS="malformed"
  # Fall back to last ~50 lines of stderr so the user can diagnose.
  if [[ -f "${ERR}" ]]; then
    RAW_ERROR="$(tail -n 50 "${ERR}" 2>/dev/null || true)"
  fi
fi

# V5: redact secrets from RAW_ERROR (always) and RESULT_TEXT (opt-in).
if [[ -n "${RAW_ERROR}" ]]; then
  RAW_ERROR="$(cd_redact_secrets <<<"${RAW_ERROR}")"
fi
if [[ "${CURSOR_DELEGATE_REDACT_RESULT:-0}" == "1" && -n "${RESULT_TEXT}" ]]; then
  RESULT_TEXT="$(cd_redact_secrets <<<"${RESULT_TEXT}")"
fi

# Absolute paths for artifacts section.
RAW_ABS="${OUT_DIR_ABS}/${JOB_ID}.json"
ERR_ABS="${OUT_DIR_ABS}/${JOB_ID}.err"
META_ABS="${OUT_DIR_ABS}/${JOB_ID}.meta.json"
SUMMARY_ABS="${OUT_DIR_ABS}/${JOB_ID}.summary.md"

# Build summary markdown.
{
  printf -- '---\n'
  printf 'job_id: %s\n'         "${JOB_ID}"
  printf 'task_type: %s\n'      "${TASK_TYPE}"
  printf 'resolved_model: %s\n' "${MODEL}"
  printf 'mode: %s\n'           "${MODE}"
  printf 'worktree: %s\n'       "${WORKTREE}"
  printf 'started_at: %s\n'     "${STARTED_AT}"
  printf 'completed_at: %s\n'   "${COMPLETED_AT}"
  printf 'duration_ms: %s\n'    "${DURATION_MS}"
  printf 'exit_code: %s\n'      "${EXIT_CODE}"
  printf 'status: %s\n'         "${STATUS}"
  printf 'session_id: %s\n'     "${SESSION_ID}"
  printf -- '---\n'
  printf '\n'

  printf '## Summary\n\n'
  if [[ -n "${RESULT_TEXT}" ]]; then
    printf '%s\n' "${RESULT_TEXT}"
  else
    printf '_No result text extracted._\n'
    if [[ "${STATUS}" == "malformed" ]]; then
      printf '\n> Raw Cursor JSON was missing or unparseable. See .err tail below.\n'
    fi
  fi
  printf '\n'

  if [[ -n "${RAW_ERROR}" ]]; then
    printf '## Errors\n\n'
    printf '```\n%s\n```\n\n' "${RAW_ERROR}"
  fi

  printf '## Artifacts\n\n'
  printf -- '- meta: `%s`\n' "${META_ABS}"
  printf -- '- raw json: `%s`\n' "${RAW_ABS}"
  printf -- '- stderr: `%s`\n' "${ERR_ABS}"
} >"${SUMMARY}.tmp"

mv "${SUMMARY}.tmp" "${SUMMARY}"

# Record malformed status into meta so `status` surfaces it.
if [[ "${STATUS}" == "malformed" && "${META_STATUS}" != "malformed" ]]; then
  cd_update_meta "${JOB_ID}" '.status="malformed"|.malformed_json=true' || true
fi

printf '%s\n' "${SUMMARY_ABS}"
