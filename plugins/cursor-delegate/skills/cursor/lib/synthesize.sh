#!/usr/bin/env bash
# synthesize.sh — render fanout-<FANOUT_TS>.synthesis.md from a fanout plan.
#
# Contract:
#   bash synthesize.sh <fanout_plan_path>
#   -> writes .cursor/delegate/fanout-<FANOUT_TS>.synthesis.md
#   -> prints the absolute synthesis path on stdout (LAST line)
#
# Side effects:
#   - Calls maybe_write_serialization_flag (from fanout.sh semantics) when
#     wall_clock > 1.2 * max(duration_ms) with N>=2 jobs — but ONLY when the
#     synthesis is triggered via fanout.sh --collect (claude-driven mode). We
#     infer "claude-driven" when the plan's created_at is much earlier than
#     now (the dispatches ran out-of-process).
#
# Robustness:
#   - Missing <JOB_ID>.summary.md is rendered as [FAILED/MISSING].
#   - Missing <JOB_ID>.meta.json is rendered as [NO-META].

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

if [[ $# -lt 1 ]]; then
  cd_die 64 "usage: synthesize.sh <fanout_plan_path>"
fi

PLAN_PATH="$1"
[[ -f "${PLAN_PATH}" ]] || cd_die 4 "fanout plan not found: ${PLAN_PATH}"

cd_require_jq
if ! jq -e . "${PLAN_PATH}" >/dev/null 2>&1; then
  cd_die 4 "fanout plan is not valid JSON: ${PLAN_PATH}"
fi

OUT_DIR="$(cd_output_dir)"
OUT_DIR_ABS="$(cd "${OUT_DIR}" && pwd)"

FANOUT_TS="$(jq -r '.fanout_ts' "${PLAN_PATH}")"
CREATED_AT="$(jq -r '.created_at' "${PLAN_PATH}")"
JOB_COUNT="$(jq -r '.job_count' "${PLAN_PATH}")"

SYN_PATH="${OUT_DIR}/fanout-${FANOUT_TS}.synthesis.md"
SYN_ABS="${OUT_DIR_ABS}/fanout-${FANOUT_TS}.synthesis.md"

COMPLETED_AT="$(cd_iso_now)"

# Compute wall_clock_ms from plan created_at to now.
plan_epoch_ms() {
  local iso="$1"
  # Seconds via the GNU/BSD-portable helper; keep the milliseconds part when
  # present so we don't lose resolution.
  local frac ms sec
  frac=""
  if [[ "${iso}" == *.* ]]; then
    # e.g. "2026-04-24T06:34:01.123Z"  -> frac="123Z"
    frac="${iso#*.}"
  fi
  sec="$(cd_iso_to_epoch "${iso}")"
  ms=0
  if [[ -n "${frac}" ]]; then
    frac="${frac%Z}"
    # Pad/truncate to 3 digits.
    frac="${frac}000"
    frac="${frac:0:3}"
    # Strip leading zeros safely.
    ms=$((10#${frac}))
  fi
  printf '%s' "$(( sec * 1000 + ms ))"
}

START_MS="$(plan_epoch_ms "${CREATED_AT}")"
END_MS="$(plan_epoch_ms "${COMPLETED_AT}")"
WALL_MS=$(( END_MS - START_MS ))
(( WALL_MS < 0 )) && WALL_MS=0

# Aggregate per-job stats.
TOTAL=0
SUCCEEDED=0
FAILED=0
MAX_DUR_MS=0
SUM_DUR_MS=0

declare -a JOB_BLOCKS=()

ENTRIES="$(jq -c '.jobs[]' "${PLAN_PATH}")"
while IFS= read -r entry; do
  TOTAL=$((TOTAL + 1))

  JOB_ID="$(jq -r '.job_id' <<<"${entry}")"
  TASK_TYPE="$(jq -r '.task_type' <<<"${entry}")"
  PROMPT="$(jq -r '.prompt' <<<"${entry}")"

  META="${OUT_DIR}/${JOB_ID}.meta.json"
  SUMMARY="${OUT_DIR}/${JOB_ID}.summary.md"

  STATUS="unknown"
  EXIT_CODE="?"
  DURATION_MS=0
  MODEL="unknown"

  if [[ -f "${META}" ]] && jq -e . "${META}" >/dev/null 2>&1; then
    STATUS="$(     jq -r '.status          // "unknown"' "${META}")"
    EXIT_CODE="$(  jq -r '.exit_code       // "?"'       "${META}")"
    DURATION_MS="$(jq -r '.duration_ms     // 0'         "${META}")"
    MODEL="$(      jq -r '.resolved_model  // "unknown"' "${META}")"
  else
    STATUS="[NO-META]"
  fi

  if [[ "${STATUS}" == "completed" ]]; then
    SUCCEEDED=$((SUCCEEDED + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  if [[ "${DURATION_MS}" =~ ^[0-9]+$ ]]; then
    SUM_DUR_MS=$((SUM_DUR_MS + DURATION_MS))
    if (( DURATION_MS > MAX_DUR_MS )); then
      MAX_DUR_MS="${DURATION_MS}"
    fi
  fi

  # Build per-job markdown block. Capped prompt for readability.
  PROMPT_TRIM="${PROMPT}"
  if (( ${#PROMPT_TRIM} > 400 )); then
    PROMPT_TRIM="${PROMPT_TRIM:0:400}...[truncated]"
  fi

  # Extract summary body (skip frontmatter) if file exists.
  SUMMARY_EXCERPT=""
  SUMMARY_STATE="ok"
  if [[ -f "${SUMMARY}" ]]; then
    # Drop the leading --- ... --- frontmatter block via awk state machine.
    # Then cap to ~2000 chars to keep synthesis readable.
    body="$(awk '
      BEGIN { infm=0; seen=0 }
      /^---$/ {
        if (!seen) { infm=1; seen=1; next }
        else if (infm) { infm=0; next }
      }
      { if (!infm) print }
    ' "${SUMMARY}" 2>/dev/null || true)"
    if (( ${#body} > 2000 )); then
      SUMMARY_EXCERPT="${body:0:2000}"$'\n\n...[truncated; see '"${SUMMARY}"']'
    else
      SUMMARY_EXCERPT="${body}"
    fi
  else
    SUMMARY_STATE="missing"
    SUMMARY_EXCERPT="_[FAILED/MISSING] no summary file at ${SUMMARY}_"
  fi

  # Compose block.
  block=""
  block+=$'\n'"## Job ${TOTAL}: ${TASK_TYPE} (${JOB_ID})"$'\n\n'
  block+="- **status**: ${STATUS}"$'\n'
  block+="- **exit_code**: ${EXIT_CODE}"$'\n'
  block+="- **model**: ${MODEL}"$'\n'
  block+="- **duration_ms**: ${DURATION_MS}"$'\n'
  block+="- **summary_file**: \`${SUMMARY}\`"$'\n'
  if [[ -f "${OUT_DIR}/${JOB_ID}.dispatch.log" ]]; then
    block+="- **dispatch_log**: \`${OUT_DIR_ABS}/${JOB_ID}.dispatch.log\`"$'\n'
  fi
  block+="- **prompt**: ${PROMPT_TRIM}"$'\n\n'
  if [[ "${SUMMARY_STATE}" == "missing" ]]; then
    block+="${SUMMARY_EXCERPT}"$'\n'
  else
    block+="### Summary"$'\n\n'
    block+="${SUMMARY_EXCERPT}"$'\n'
  fi
  JOB_BLOCKS+=("${block}")
done <<<"${ENTRIES}"

# Speedup ratio = sum/wall. Higher is better (ideal: ≈ N).
SPEEDUP="n/a"
if (( WALL_MS > 0 )); then
  SPEEDUP="$(awk -v s="${SUM_DUR_MS}" -v w="${WALL_MS}" 'BEGIN { printf "%.2f", s/w }')"
fi

# Write synthesis file.
{
  printf -- '---\n'
  printf 'fanout_ts: %s\n'   "${FANOUT_TS}"
  printf 'created_at: %s\n'  "${CREATED_AT}"
  printf 'completed_at: %s\n' "${COMPLETED_AT}"
  printf 'job_count: %s\n'   "${TOTAL}"
  printf 'succeeded: %s\n'   "${SUCCEEDED}"
  printf 'failed: %s\n'      "${FAILED}"
  printf 'wall_clock_ms: %s\n' "${WALL_MS}"
  printf 'max_duration_ms: %s\n' "${MAX_DUR_MS}"
  printf 'sum_duration_ms: %s\n' "${SUM_DUR_MS}"
  printf 'speedup_ratio: %s\n' "${SPEEDUP}"
  printf -- '---\n\n'

  printf '# Fanout Synthesis: %s\n\n' "${FANOUT_TS}"
  printf '- **plan**: `%s`\n' "${PLAN_PATH}"
  printf '- **jobs**: %s total (%s succeeded, %s failed)\n' "${TOTAL}" "${SUCCEEDED}" "${FAILED}"
  printf '- **wall_clock**: %s ms\n' "${WALL_MS}"
  printf '- **max_single_job**: %s ms\n' "${MAX_DUR_MS}"
  printf '- **sum_all_jobs**: %s ms\n' "${SUM_DUR_MS}"
  printf '- **speedup**: %sx (ideal: %s)\n' "${SPEEDUP}" "${TOTAL}"

  # set -u-safe: a zero-job plan leaves JOB_BLOCKS empty, and bash 3.2 (macOS
  # stock) errors on "${empty[@]}" under `set -u`. The ${arr[@]+...} guard
  # expands to nothing when unset/empty.
  for b in ${JOB_BLOCKS[@]+"${JOB_BLOCKS[@]}"}; do
    printf '%s' "${b}"
  done
} >"${SYN_PATH}.tmp"
mv "${SYN_PATH}.tmp" "${SYN_PATH}"

# ------------------------------------------------------------------------------
# Auto-detect: claude-driven serialization flag.
#
# We infer mode from CURSOR_DELEGATE_FANOUT_MODE env if set by the caller
# (fanout.sh local-parallel path sets it to "local-parallel" before calling us).
# Otherwise treat as claude-driven — that's the mode where auto-detection is
# meaningful (local-parallel is already the fallback).
# ------------------------------------------------------------------------------

MODE_HINT="${CURSOR_DELEGATE_FANOUT_MODE:-claude-driven}"

if [[ "${MODE_HINT}" == "claude-driven" && "${TOTAL}" -ge 2 && "${MAX_DUR_MS}" -gt 0 ]]; then
  RATIO="$(awk -v w="${WALL_MS}" -v m="${MAX_DUR_MS}" 'BEGIN { printf "%.4f", w/m }')"
  TRIGGER="$(awk -v r="${RATIO}" 'BEGIN { print (r > 1.2) ? "1" : "0" }')"
  if [[ "${TRIGGER}" == "1" ]]; then
    STATE_DIR="$(cd_state_dir)"
    FLAG="${STATE_DIR}/claude-serializes-bash"
    jq -n \
      --arg detected_at "$(cd_iso_now)" \
      --arg omc_version "${OMC_VERSION:-unknown}" \
      --argjson ratio       "${RATIO}" \
      --argjson sample_size "${TOTAL}" \
      '{
        detected_at: $detected_at,
        omc_version: $omc_version,
        serialization_ratio: $ratio,
        sample_size: $sample_size
      }' >"${FLAG}.tmp"
    mv "${FLAG}.tmp" "${FLAG}"
    cd_log "WARN" "auto-detect: claude-driven fanout serialized (ratio=${RATIO}); wrote ${FLAG}"
    cd_log "WARN" "future fanouts auto-flip to --local-parallel (override: CURSOR_DELEGATE_FORCE_CLAUDE=1)"
  fi
fi

# LAST line of stdout — the synthesis filepath Claude should Read.
printf '%s\n' "${SYN_ABS}"
