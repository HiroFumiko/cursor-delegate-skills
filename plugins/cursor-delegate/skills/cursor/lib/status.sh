#!/usr/bin/env bash
# status.sh — list recent cursor jobs as a table.
#
# Contract:
#   bash status.sh [--last N] [--since <duration>] [--with-pid]
#
# Options:
#   --last N         show at most N rows (default 50)
#   --since DUR      only jobs started within DUR (default 24h)
#                    DUR: <int>{s|m|h|d} (e.g., 30m, 24h, 7d)
#   --with-pid       include raw PID column (default: liveness marker only)
#
# Default output (TODO-F7): PID column shows [RUNNING]/[DONE]/[ZOMBIE]
# liveness markers instead of raw PIDs, reducing context footprint.
#
# Also detects stale hooks-quarantine sentinels (.cursor/delegate/state/
# hooks-quarantined-*) whose job is no longer running, and warns the user.

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: status.sh [--last N] [--since <dur>] [--with-pid]

Options:
  --last N       show at most N rows (default 50)
  --since DUR    only jobs started within DUR (default 24h). DUR: <int>{s|m|h|d}
  --with-pid     include raw PID column (default: liveness marker only)
  -h, --help     show this help
EOF
}

# Parse a duration like "30m", "24h", "7d" into seconds.
parse_duration_sec() {
  local d="${1:-24h}"
  if [[ "${d}" =~ ^([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "${unit}" in
      s) printf '%s' "${n}" ;;
      m) printf '%s' "$((n * 60))" ;;
      h) printf '%s' "$((n * 3600))" ;;
      d) printf '%s' "$((n * 86400))" ;;
    esac
  else
    cd_log "ERROR" "invalid --since duration: ${d}"
    exit 64
  fi
}

# ------------------------------------------------------------------------------
# Args.
# ------------------------------------------------------------------------------

LIMIT=50
SINCE="24h"
WITH_PID=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      LIMIT="$2"
      shift 2
      ;;
    --since)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      SINCE="$2"
      shift 2
      ;;
    --with-pid)
      WITH_PID=1
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

cd_require_jq

OUT_DIR="$(cd_output_dir)"
STATE_DIR="$(cd_state_dir)"

SINCE_SEC="$(parse_duration_sec "${SINCE}")"
NOW_EPOCH="$(date -u +%s)"
CUTOFF_EPOCH=$(( NOW_EPOCH - SINCE_SEC ))

# ------------------------------------------------------------------------------
# Collect meta.json files.
# ------------------------------------------------------------------------------

shopt -s nullglob
META_FILES=( "${OUT_DIR}"/*.meta.json )
shopt -u nullglob

if (( ${#META_FILES[@]} == 0 )); then
  printf 'No jobs found in %s\n' "${OUT_DIR}"
  exit 0
fi

# Build rows: started_epoch <TAB> tsv-row
# We'll sort by started_epoch desc and then take --last N.
TMP_ROWS="$(mktemp -t cd-status.XXXXXX)"
trap 'rm -f "${TMP_ROWS}"' EXIT INT TERM

for meta in "${META_FILES[@]}"; do
  [[ -f "${meta}" ]] || continue
  if ! jq -e . "${meta}" >/dev/null 2>&1; then
    continue
  fi

  job_id="$(     jq -r '.job_id         // "?"'       "${meta}")"
  task_type="$(  jq -r '.task_type      // "?"'       "${meta}")"
  model="$(      jq -r '.resolved_model // "?"'       "${meta}")"
  status_field="$(jq -r '.status         // "?"'       "${meta}")"
  exit_code="$(  jq -r '.exit_code      // "-"'       "${meta}")"
  duration="$(   jq -r '.duration_ms    // 0'         "${meta}")"
  started_at="$( jq -r '.started_at     // "?"'       "${meta}")"
  pid_field="$(  jq -r '.pid            // 0'         "${meta}")"
  session_id="$( jq -r '.session_id     // "none"'    "${meta}")"

  # Convert started_at to epoch for filtering (GNU/BSD-portable helper).
  started_epoch="$(cd_iso_to_epoch "${started_at}")"
  if (( started_epoch == 0 )); then
    # Can't parse; skip time filter for this row (show it).
    started_epoch="${NOW_EPOCH}"
  fi

  if (( started_epoch < CUTOFF_EPOCH )); then
    continue
  fi

  # Compute liveness marker.
  liveness="[DONE]"
  if [[ "${status_field}" == "running" ]]; then
    if [[ "${pid_field}" =~ ^[0-9]+$ ]] && (( pid_field > 0 )) && kill -0 "${pid_field}" 2>/dev/null; then
      liveness="[RUNNING]"
    else
      liveness="[ZOMBIE]"
    fi
  elif [[ "${status_field}" == "cancelled" ]]; then
    liveness="[CANCELLED]"
  elif [[ "${status_field}" == "failed" || "${status_field}" == "timed_out" || "${status_field}" == "malformed" ]]; then
    # bash 3.2 (macOS stock) has no ${var^^}; use tr for uppercasing.
    liveness="[$(printf '%s' "${status_field}" | tr '[:lower:]' '[:upper:]')]"
  fi

  # Format duration as ms or s.
  if [[ "${duration}" =~ ^[0-9]+$ ]] && (( duration >= 10000 )); then
    dur_fmt="$(awk -v d="${duration}" 'BEGIN { printf "%.1fs", d/1000 }')"
  else
    dur_fmt="${duration}ms"
  fi

  # Trim session id for display.
  if [[ "${session_id}" != "none" && ${#session_id} -gt 12 ]]; then
    session_display="${session_id:0:10}.."
  else
    session_display="${session_id}"
  fi

  if (( WITH_PID )); then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${started_epoch}" \
      "${job_id}" "${task_type}" "${model}" "${started_at}" \
      "${dur_fmt}" "${exit_code}" "${liveness}" "${pid_field}" "${session_display}" \
      >>"${TMP_ROWS}"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${started_epoch}" \
      "${job_id}" "${task_type}" "${model}" "${started_at}" \
      "${dur_fmt}" "${exit_code}" "${liveness}" "${session_display}" \
      >>"${TMP_ROWS}"
  fi
done

# ------------------------------------------------------------------------------
# Render table.
# ------------------------------------------------------------------------------

if (( WITH_PID )); then
  HEADER="JOB_ID\tTASK\tMODEL\tSTARTED\tDURATION\tEXIT\tSTATUS\tPID\tSESSION"
else
  HEADER="JOB_ID\tTASK\tMODEL\tSTARTED\tDURATION\tEXIT\tSTATUS\tSESSION"
fi

# Sort by started_epoch desc, drop the sort key, apply limit.
{
  printf '%b\n' "${HEADER}"
  if [[ -s "${TMP_ROWS}" ]]; then
    sort -t $'\t' -k1,1nr "${TMP_ROWS}" \
      | cut -f2- \
      | head -n "${LIMIT}"
  fi
} | column -t -s $'\t'

# ------------------------------------------------------------------------------
# Stale hooks-quarantine sentinel warnings.
# ------------------------------------------------------------------------------

shopt -s nullglob
SENTINELS=( "${STATE_DIR}"/hooks-quarantined-* )
shopt -u nullglob

if (( ${#SENTINELS[@]} > 0 )); then
  STALE=()
  for s in "${SENTINELS[@]}"; do
    base="$(basename "${s}")"
    sjob="${base#hooks-quarantined-}"
    smeta="${OUT_DIR}/${sjob}.meta.json"
    # Stale if meta exists and status != running, OR meta missing entirely.
    is_stale=0
    if [[ -f "${smeta}" ]] && jq -e . "${smeta}" >/dev/null 2>&1; then
      ss="$(jq -r '.status // "unknown"' "${smeta}")"
      if [[ "${ss}" != "running" ]]; then
        is_stale=1
      fi
    else
      is_stale=1
    fi
    if (( is_stale )); then
      STALE+=("${sjob}")
    fi
  done

  if (( ${#STALE[@]} > 0 )); then
    printf '\n' >&2
    cd_log "WARN" "stale hooks-quarantine sentinels detected (${#STALE[@]}):"
    for j in "${STALE[@]}"; do
      printf '  - %s\n' "${j}" >&2
    done
    cd_log "WARN" "if ~/.cursor/hooks.json is missing, restore manually:"
    cd_log "WARN" "  mv ~/.cursor/hooks.json.cursor.bak ~/.cursor/hooks.json"
    cd_log "WARN" "then remove stale sentinels:"
    for j in "${STALE[@]}"; do
      printf '  rm %s/hooks-quarantined-%s\n' "${STATE_DIR}" "${j}" >&2
    done
    # F7 recovery hint — for jobs that show [ZOMBIE] in the status table:
    cd_log "WARN" "tip: jobs above shown as [ZOMBIE] mean the recorded pid is dead but"
    cd_log "WARN" "     status was never closed; either re-run \`cancel <JOB_ID>\` to"
    cd_log "WARN" "     finalize meta.json, or delete the meta if the job is irrelevant."
  fi
fi

# ------------------------------------------------------------------------------
# Serialization flag notice.
# ------------------------------------------------------------------------------

FLAG="${STATE_DIR}/claude-serializes-bash"
if [[ -f "${FLAG}" ]]; then
  printf '\n' >&2

  # F6: surface 30-day TTL expiry annotation.
  _F6_DETECTED="$(jq -r '.detected_at // empty' "${FLAG}" 2>/dev/null || true)"
  if [[ -n "${_F6_DETECTED}" ]]; then
    _F6_DET_EPOCH="$(cd_iso_to_epoch "${_F6_DETECTED}")"
    _F6_NOW_EPOCH="$(date -u +%s)"
    if (( _F6_DET_EPOCH > 0 )); then
      _F6_EXPIRES_EPOCH=$((_F6_DET_EPOCH + 30 * 86400))
      _F6_DAYS_LEFT=$(( (_F6_EXPIRES_EPOCH - _F6_NOW_EPOCH) / 86400 ))
      _F6_EXPIRES_DATE="$(cd_epoch_to_date "${_F6_EXPIRES_EPOCH}" '%Y-%m-%d')"
      if (( _F6_NOW_EPOCH >= _F6_EXPIRES_EPOCH )); then
        cd_log "INFO" "claude-serializes-bash flag: expires: ${_F6_EXPIRES_DATE} (EXPIRED -- flag will be ignored)"
      else
        cd_log "INFO" "claude-serializes-bash flag: expires: ${_F6_EXPIRES_DATE} (${_F6_DAYS_LEFT} days remaining)"
      fi
    fi
  fi

  cd_log "INFO" "claude-serializes-bash flag is active:"
  jq . "${FLAG}" >&2 2>/dev/null || cat "${FLAG}" >&2
  cd_log "INFO" "clear via: bash ${CD_SELF_DIR}/fanout.sh --clear-serialization-flag"
fi
