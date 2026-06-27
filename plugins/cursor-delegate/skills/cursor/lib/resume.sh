#!/usr/bin/env bash
# resume.sh — continue a prior Cursor chat session.
#
# Contract:
#   bash resume.sh <chatId> "<prompt>" [--task <task_type>]
#   bash resume.sh --create-chat
#
# task_type defaults to 'investigate' (read-only, safest). Override via --task.
#
# Stdout contract (when dispatching):
#   FIRST line: JOB_ID=<id>
#   LAST  line: absolute path to <JOB_ID>.summary.md
#   (inherited from dispatch.sh — resume.sh delegates execution)
#
# --create-chat mode:
#   Best-effort: runs `agent create-chat` and tries to parse a chatId from the
#   output using a lenient regex. If parse succeeds, prints the chatId on
#   stdout. If not, prints an explanatory error on stderr + the raw output for
#   manual inspection, and exits non-zero. R1 (spec): stdout format is the main
#   risk here, so we are tolerant and transparent on failure.
#
# Session log:
#   Appends one JSON line per resumed turn to
#   .cursor/delegate/state/sessions.jsonl (append-only, no lock needed).

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

DISPATCH_SH="${CD_SELF_DIR}/dispatch.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  resume.sh <chatId> "<prompt>" [--task <task_type>]
  resume.sh --create-chat
  resume.sh --help

task_type: implement | review | plan | investigate | security
           (default: investigate — the safest read-only option)

--create-chat: invoke `agent create-chat` and echo the parsed chatId.
               This is best-effort (stdout format is an open risk, R1).
               On parse failure, the raw output is shown and exit is non-zero.
EOF
}

# Append a session record to sessions.jsonl.
# Args: job_id chat_id task_type
cd_record_session() {
  local job_id="${1:?job_id required}"
  local chat_id="${2:?chat_id required}"
  local task_type="${3:?task_type required}"

  local state_dir log
  state_dir="$(cd_state_dir)"
  log="${state_dir}/sessions.jsonl"

  cd_require_jq
  local line
  line="$(jq -cn \
    --arg job_id "${job_id}" \
    --arg chat_id "${chat_id}" \
    --arg task_type "${task_type}" \
    --arg timestamp "$(cd_iso_now)" \
    '{
      job_id: $job_id,
      chat_id: $chat_id,
      task_type: $task_type,
      timestamp: $timestamp
    }')"
  # Single-writer appends are atomic on POSIX for small lines (<PIPE_BUF).
  printf '%s\n' "${line}" >>"${log}"
}

# --create-chat: run `agent create-chat` and try to parse a chatId.
# Printed chatId goes to stdout. Parse diagnostics go to stderr.
do_create_chat() {
  cd_require "agent" "install Cursor CLI (\`agent\`); see https://cursor.com/cli"

  local raw
  if ! raw="$(agent create-chat </dev/null 2>&1)"; then
    cd_log "ERROR" "\`agent create-chat\` exited non-zero. Raw output:"
    printf '%s\n' "${raw}" >&2
    exit 3
  fi

  local chat_id=""

  # 1) If output parses as JSON, try .chatId / .chat_id / .id / .session_id.
  if command -v jq >/dev/null 2>&1 && jq -e . <<<"${raw}" >/dev/null 2>&1; then
    for key in chatId chat_id id session_id; do
      local v
      v="$(jq -r --arg k "${key}" '.[$k] // empty' <<<"${raw}" 2>/dev/null || true)"
      if [[ -n "${v}" && "${v}" != "null" ]]; then
        chat_id="${v}"
        break
      fi
    done
  fi

  # 2) Fall back to regex-scanning: look for a 16+-char hex/uuid-ish token.
  if [[ -z "${chat_id}" ]]; then
    # Patterns tried, most specific first:
    #   - classic UUID: 8-4-4-4-12 hex
    #   - lower-hex run >= 16 chars (e.g., Cursor's shortened ids)
    local candidate
    candidate="$(grep -Eo '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' <<<"${raw}" | head -1 || true)"
    if [[ -z "${candidate}" ]]; then
      candidate="$(grep -Eo '[a-f0-9]{16,}' <<<"${raw}" | head -1 || true)"
    fi
    chat_id="${candidate}"
  fi

  if [[ -z "${chat_id}" ]]; then
    cd_log "ERROR" "could not parse chatId from \`agent create-chat\` output."
    cd_log "ERROR" "raw output follows (pipe it through your own parser if needed):"
    printf '%s\n' "${raw}" >&2
    exit 3
  fi

  cd_log "INFO" "parsed chatId: ${chat_id}"
  # ONLY the chatId on stdout, so callers can `CHAT=$(resume.sh --create-chat)`.
  printf '%s\n' "${chat_id}"
}

# ------------------------------------------------------------------------------
# Main.
# ------------------------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 64
  fi

  # --create-chat subcommand (no positional chat/prompt).
  if [[ "$1" == "--create-chat" ]]; then
    do_create_chat
    exit 0
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ $# -lt 2 ]]; then
    usage
    exit 64
  fi

  local chat_id="$1"; shift
  local prompt="$1";  shift
  local task_type="investigate"

  # V2: reject chatIds with invalid characters or leading dashes.
  if ! [[ "${chat_id}" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "${chat_id}" == -* ]]; then
    cd_die 64 "invalid chatId: must match ^[A-Za-z0-9._-]+\$ and not start with '-'"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        [[ $# -ge 2 ]] || { usage; exit 64; }
        task_type="$2"
        shift 2
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

  case "${task_type}" in
    implement|review|plan|investigate|security) ;;
    *)
      cd_log "ERROR" "invalid task_type: ${task_type}"
      usage
      exit 64
      ;;
  esac

  if [[ -z "${chat_id}" ]]; then
    cd_log "ERROR" "chat_id is empty"
    usage
    exit 64
  fi

  # Pre-assign JOB_ID so we can record the mapping even if dispatch fails.
  local job_id
  job_id="${CURSOR_DELEGATE_JOB_ID:-$(cd_gen_job_id)}"
  export CURSOR_DELEGATE_JOB_ID="${job_id}"

  cd_record_session "${job_id}" "${chat_id}" "${task_type}"

  cd_log "INFO" "resume: job_id=${job_id} chat_id=${chat_id} task=${task_type}"

  # Delegate to dispatch.sh — it will honor CURSOR_DELEGATE_JOB_ID and forward
  # --resume to the agent invocation. We pass the chatId via dispatch's
  # --resume flag.
  exec bash "${DISPATCH_SH}" "${task_type}" "${prompt}" --resume "${chat_id}"
}

main "$@"
