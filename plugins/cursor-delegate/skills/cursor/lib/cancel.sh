#!/usr/bin/env bash
# cancel.sh — cancel a running cursor job.
#
# Contract:
#   bash cancel.sh <JOB_ID>
#
# Behavior:
#   1. Read <JOB_ID>.meta.json. Missing -> exit 4 with clear error.
#   2. If status != running, exit 0 with "already finished" notice (idempotent).
#   3. Extract pid. Send SIGTERM. Wait up to 5s. If still alive, send SIGKILL.
#   4. Update meta.json: status=cancelled, cancelled_at=<ISO8601>,
#      exit_code=143 (SIGTERM) or 137 (SIGKILL).
#   5. Call cd_hooks_restore $JOB_ID to release the hooks-quarantine sentinel.
#   6. Regenerate summary.md so `status` reflects the cancelled state.

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

SUMMARIZE_SH="${CD_SELF_DIR}/summarize.sh"

usage() {
  cat >&2 <<'EOF'
Usage: cancel.sh <JOB_ID>

Exits:
  0  — cancelled successfully OR job already finished (idempotent)
  4  — meta.json missing / unparseable
  64 — bad arguments
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

JOB_ID="$1"

cd_require_jq

OUT_DIR="$(cd_output_dir)"
META="${OUT_DIR}/${JOB_ID}.meta.json"

if [[ ! -f "${META}" ]]; then
  cd_die 4 "meta.json not found for job ${JOB_ID}: ${META}"
fi
if ! jq -e . "${META}" >/dev/null 2>&1; then
  cd_die 4 "meta.json is malformed for job ${JOB_ID}: ${META}"
fi

STATUS="$(jq -r '.status // "unknown"' "${META}")"
PID="$(   jq -r '.pid    // 0'         "${META}")"

if [[ "${STATUS}" != "running" ]]; then
  cd_log "INFO" "job ${JOB_ID} already finished (status=${STATUS}); nothing to cancel"
  exit 0
fi

if ! [[ "${PID}" =~ ^[0-9]+$ ]] || (( PID <= 1 )); then
  cd_log "WARN" "job ${JOB_ID} has invalid pid=${PID}; marking cancelled without signaling"
  cd_update_meta "${JOB_ID}" \
    "$(printf '.status="cancelled"|.cancelled_at=%s|.exit_code=143' \
        "$(jq -Rn --arg v "$(cd_iso_now)" '$v')")"
  cd_hooks_restore "${JOB_ID}"
  bash "${SUMMARIZE_SH}" "${JOB_ID}" >/dev/null || true
  exit 0
fi

# ------------------------------------------------------------------------------
# Signal the process.
# ------------------------------------------------------------------------------

EXIT_SIG=143  # default assume SIGTERM was enough

if ! kill -0 "${PID}" 2>/dev/null; then
  cd_log "INFO" "pid ${PID} for job ${JOB_ID} is no longer live (race with natural completion)"
  # Still mark cancelled — user's intent was to cancel. Idempotent.
else
  cd_log "INFO" "sending SIGTERM to pid ${PID} (job ${JOB_ID})"
  kill -TERM "${PID}" 2>/dev/null || true

  # Wait up to 5s for graceful exit.
  for _ in 1 2 3 4 5; do
    if ! kill -0 "${PID}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "${PID}" 2>/dev/null; then
    cd_log "WARN" "pid ${PID} still alive after 5s; sending SIGKILL"
    kill -KILL "${PID}" 2>/dev/null || true
    EXIT_SIG=137

    # Short post-SIGKILL settle.
    for _ in 1 2; do
      if ! kill -0 "${PID}" 2>/dev/null; then
        break
      fi
      sleep 1
    done

    if kill -0 "${PID}" 2>/dev/null; then
      cd_log "ERROR" "pid ${PID} survived SIGKILL — marking cancelled but process may be a zombie"
    fi
  fi
fi

# ------------------------------------------------------------------------------
# Update meta.
# ------------------------------------------------------------------------------

cd_update_meta "${JOB_ID}" \
  "$(printf '.status="cancelled"|.cancelled_at=%s|.exit_code=%s|.completed_at=%s' \
      "$(jq -Rn --arg v "$(cd_iso_now)" '$v')" \
      "${EXIT_SIG}" \
      "$(jq -Rn --arg v "$(cd_iso_now)" '$v')")"

# ------------------------------------------------------------------------------
# Release hooks quarantine sentinel.
# ------------------------------------------------------------------------------

cd_hooks_restore "${JOB_ID}"

# ------------------------------------------------------------------------------
# Regenerate summary so `status` sees the cancelled state.
# ------------------------------------------------------------------------------

if ! bash "${SUMMARIZE_SH}" "${JOB_ID}" >/dev/null; then
  cd_log "WARN" "summarize.sh failed for cancelled job ${JOB_ID}; meta is still authoritative"
fi

cd_log "INFO" "cancelled job ${JOB_ID} (exit_code=${EXIT_SIG})"
exit 0
