#!/usr/bin/env bash
# lib_common.sh — shared helpers for cursor skill.
# Source-only; do not execute directly.
#
# Exports:
#   cd_log LEVEL MSG...       — stderr logger with level prefix
#   cd_die EXIT MSG...        — log to stderr and exit with EXIT
#   cd_ts                     — ISO8601 UTC timestamp with ns
#   cd_ts_compact             — "YYYYMMDD-HHMMSS" (sortable) in UTC
#   cd_rand HEX_CHARS         — random lower-hex string of given length
#   cd_gen_job_id             — sortable job id: <YYYYMMDD-HHMMSS>-<8hex>
#   cd_slug TEXT LEN          — slug derived from TEXT, capped at LEN
#   cd_require CMD [HINT]     — assert CMD in PATH, else exit 2 with hint
#   cd_require_jq             — convenience preflight for jq
#   cd_iso_now                — ISO8601 UTC with Z suffix
#   cd_epoch_ms               — milliseconds since epoch
#   cd_state_dir              — path to .cursor/delegate/state (creates if needed)
#   cd_output_dir             — path to .cursor/delegate (creates if needed)
#   cd_resolve_config TASK JOB — deep-merge config chain, snapshot per-JOB, echo path
#   cd_preflight TASK MODEL   — binary / auth / model / dir checks
#   cd_preflight_hooks JOB    — move-aside ~/.cursor/hooks.json if present
#   cd_hooks_restore JOB      — restore hooks.json on exit (trap target)
#   cd_classify_exit CODE     — echo TRANSIENT | PERMANENT | UNKNOWN
#   cd_emit_meta ...          — initial .meta.json sidecar
#   cd_update_meta JOB JQ     — in-place jq edit on meta sidecar
#
# Invariant: every `agent` invocation is stdin </dev/null + `timeout 590s`.
# Invariant: resolved-config snapshot path is PER-JOB_ID (never shared).

set -euo pipefail

# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------

# Absolute dir of the skill (resolved from this file's location).
# BASH_SOURCE[0] == .../cursor/lib/lib_common.sh
CD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD_SKILL_DIR="$(cd "${CD_LIB_DIR}/.." && pwd)"
# Honor pre-existing env vars so tests / wrappers can override paths.
: "${CD_SKILL_CONFIG:=${CD_SKILL_DIR}/config/.cursor.json}"
: "${CD_USER_CONFIG:=${HOME}/.cursor.json}"
: "${CD_PROJECT_CONFIG:=.cursor.json}"   # resolved against PWD at call time
: "${CD_HOOKS_FILE:=${HOME}/.cursor/hooks.json}"
: "${CD_HOOKS_BAK:=${HOME}/.cursor/hooks.json.cursor.bak}"

export CD_LIB_DIR CD_SKILL_DIR CD_SKILL_CONFIG CD_USER_CONFIG CD_PROJECT_CONFIG
export CD_HOOKS_FILE CD_HOOKS_BAK

# ------------------------------------------------------------------------------
# Logging / failure
# ------------------------------------------------------------------------------

cd_log() {
  local level="${1:-INFO}"; shift || true
  printf '[cursor][%s] %s\n' "$level" "$*" >&2
}

# cd_debug MSG...
# Verbose stderr logger. Emits only when CURSOR_DELEGATE_DEBUG=1; otherwise no-op.
# Use for diagnostics that would be noisy in normal runs (config dumps, env
# snapshots, full argv, per-attempt timings).
cd_debug() {
  [[ "${CURSOR_DELEGATE_DEBUG:-0}" == "1" ]] || return 0
  printf '[cursor][DEBUG] %s\n' "$*" >&2
}

# cd_is_debug — predicate (exit 0 iff CURSOR_DELEGATE_DEBUG=1).
cd_is_debug() {
  [[ "${CURSOR_DELEGATE_DEBUG:-0}" == "1" ]]
}

# cd_is_dry_run — predicate (exit 0 iff CURSOR_DELEGATE_DRY_RUN=1).
cd_is_dry_run() {
  [[ "${CURSOR_DELEGATE_DRY_RUN:-0}" == "1" ]]
}

cd_die() {
  local code="${1:-1}"; shift || true
  cd_log "FATAL" "$*"
  exit "$code"
}

# ------------------------------------------------------------------------------
# Time / IDs
# ------------------------------------------------------------------------------

cd_iso_now() {
  # ISO8601 UTC with Z suffix. Milliseconds when GNU date supports %N.
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

cd_ts() {
  cd_iso_now
}

cd_ts_compact() {
  date -u +"%Y%m%d-%H%M%S"
}

cd_epoch_ms() {
  # Millisecond epoch. Fallback to seconds * 1000 when %N is unsupported.
  local ns
  ns="$(date -u +"%s%N" 2>/dev/null || true)"
  if [[ -n "${ns}" && "${ns}" != *N ]]; then
    printf '%s' "$((ns / 1000000))"
  else
    printf '%s' "$(($(date -u +"%s") * 1000))"
  fi
}

# cd_iso_to_epoch ISO8601 — parse an ISO8601 timestamp to epoch seconds.
# Portable across GNU date (`-d`) and BSD/macOS date (`-j -f`). Prefers `gdate`
# (GNU coreutils on macOS) when present. Prints epoch seconds, or 0 on failure.
# This closes the macOS portability gap: BSD `date` has no `-d` flag, so the
# previous inline `date -u -d "$iso"` calls silently returned 0 there.
cd_iso_to_epoch() {
  local iso="${1:-}"
  [[ -n "${iso}" ]] || { printf '0'; return 0; }

  local dbin="date"
  command -v gdate >/dev/null 2>&1 && dbin="gdate"

  local out
  # GNU date path (gdate everywhere, or GNU date on Linux/WSL).
  if out="$("${dbin}" -u -d "${iso}" +%s 2>/dev/null)" && [[ -n "${out}" ]]; then
    printf '%s' "${out}"
    return 0
  fi
  # BSD/macOS date path: strip fractional seconds + trailing Z, then -j -f parse.
  local base="${iso%%.*}"
  base="${base%Z}"
  if out="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${base}" +%s 2>/dev/null)" && [[ -n "${out}" ]]; then
    printf '%s' "${out}"
    return 0
  fi
  printf '0'
}

# cd_epoch_to_date EPOCH [FMT] — format epoch seconds as a date string.
# FMT defaults to %Y-%m-%d. Portable across GNU (`-d @epoch`) and BSD (`-r`).
cd_epoch_to_date() {
  local epoch="${1:?epoch required}"
  local fmt="${2:-%Y-%m-%d}"
  local dbin="date"
  command -v gdate >/dev/null 2>&1 && dbin="gdate"
  "${dbin}" -u -d "@${epoch}" +"${fmt}" 2>/dev/null \
    || date -u -r "${epoch}" +"${fmt}" 2>/dev/null \
    || printf 'unknown'
}

cd_rand() {
  local len="${1:-8}"
  # Prefer /dev/urandom for portability; fall back to $RANDOM if needed.
  # `|| true` absorbs SIGPIPE (exit 141) from `tr` when `head` closes early
  # under `set -eo pipefail`.
  if [[ -r /dev/urandom ]]; then
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "${len}" || true
  else
    local out=""
    while [[ ${#out} -lt ${len} ]]; do
      out="${out}$(printf '%x' "${RANDOM}")"
    done
    printf '%s' "${out:0:${len}}"
  fi
}

cd_gen_job_id() {
  printf '%s-%s' "$(cd_ts_compact)" "$(cd_rand 8)"
}

cd_slug() {
  local text="${1:-}"
  local len="${2:-16}"
  # Lowercase alnum slug; collapse other chars to '-'; trim leading/trailing '-'.
  printf '%s' "${text}" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9' '-' \
    | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' \
    | head -c "${len}"
}

# ------------------------------------------------------------------------------
# Binary / tool requirements
# ------------------------------------------------------------------------------

cd_require() {
  local bin="$1"
  local hint="${2:-}"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    cd_log "ERROR" "required binary not found in PATH: ${bin}"
    if [[ -n "${hint}" ]]; then
      cd_log "ERROR" "${hint}"
    fi
    exit 2
  fi
}

cd_require_jq() {
  cd_require "jq" "install jq: https://stedolan.github.io/jq/ (apt-get install jq | brew install jq)"
}

# cd_resolve_timeout_bin — resolve a GNU-coreutils `timeout` binary into
# CD_TIMEOUT_BIN (exported). macOS ships none by default; `brew install
# coreutils` provides `gtimeout`. Prefer `timeout`, fall back to `gtimeout`.
# Returns non-zero (without exiting) when neither is found, so callers decide.
cd_resolve_timeout_bin() {
  if [[ -n "${CD_TIMEOUT_BIN:-}" ]]; then
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    CD_TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    CD_TIMEOUT_BIN="gtimeout"
  else
    return 1
  fi
  export CD_TIMEOUT_BIN
  return 0
}

# ------------------------------------------------------------------------------
# Runtime dirs (project-relative to CWD)
# ------------------------------------------------------------------------------

cd_state_dir() {
  local d=".cursor/delegate/state"
  cd_check_symlink_guard ".cursor" "${d%/state}" "${d}"
  mkdir -p "${d}"
  printf '%s\n' "${d}"
}

cd_output_dir() {
  local d=".cursor/delegate"
  cd_check_symlink_guard ".cursor" "${d}"
  mkdir -p "${d}"
  printf '%s\n' "${d}"
}

# V6 symlink guard. Refuses to operate on a symlinked .cursor / .cursor/delegate /
# .cursor/delegate/state path unless CURSOR_DELEGATE_ALLOW_SYMLINK_STATE=1 is set
# (legitimate tmpfs-redirect use case). Each path arg is checked individually.
cd_check_symlink_guard() {
  local p
  for p in "$@"; do
    if [[ -L "${p}" ]]; then
      if [[ "${CURSOR_DELEGATE_ALLOW_SYMLINK_STATE:-0}" == "1" ]]; then
        cd_log "WARN" "symlinked state path allowed via CURSOR_DELEGATE_ALLOW_SYMLINK_STATE=1: ${p}"
      else
        cd_die 2 "refusing symlinked state path: ${p} (set CURSOR_DELEGATE_ALLOW_SYMLINK_STATE=1 to override for tmpfs use)"
      fi
    fi
  done
}

# ------------------------------------------------------------------------------
# Config resolution — per-JOB_ID snapshot (never shared; closes TOCTOU).
# ------------------------------------------------------------------------------

# Usage: cd_resolve_config TASK_TYPE JOB_ID
# Writes merged config JSON to .cursor/delegate/state/resolved-config-<JOB_ID>.json
# and prints the absolute path to stdout.
cd_resolve_config() {
  local task_type="${1:?task_type required}"
  local job_id="${2:?job_id required}"

  cd_require_jq

  if [[ ! -f "${CD_SKILL_CONFIG}" ]]; then
    cd_die 4 "skill default config missing: ${CD_SKILL_CONFIG}"
  fi
  if ! jq -e . "${CD_SKILL_CONFIG}" >/dev/null 2>&1; then
    cd_die 4 "skill default config is not valid JSON: ${CD_SKILL_CONFIG}"
  fi

  # Build array of config layers: skill -> user -> project (lowest to highest precedence).
  local -a layers=("${CD_SKILL_CONFIG}")
  if [[ -f "${CD_USER_CONFIG}" ]]; then
    if ! jq -e . "${CD_USER_CONFIG}" >/dev/null 2>&1; then
      cd_die 4 "user config is not valid JSON: ${CD_USER_CONFIG}"
    fi
    layers+=("${CD_USER_CONFIG}")
  fi
  local proj_abs="${PWD}/${CD_PROJECT_CONFIG}"
  if [[ -f "${proj_abs}" ]]; then
    if ! jq -e . "${proj_abs}" >/dev/null 2>&1; then
      cd_die 4 "project config is not valid JSON: ${proj_abs}"
    fi
    layers+=("${proj_abs}")
  fi

  local state_dir out abs
  state_dir="$(cd_state_dir)"
  out="${state_dir}/resolved-config-${job_id}.json"

  # Deep-merge with jq: reduce later layers into the first. `* ` is recursive merge.
  #   [a, b, c] -> a * b * c  (later wins on leaf collisions)
  jq -s 'reduce .[] as $x ({}; . * $x)' "${layers[@]}" >"${out}.tmp"
  mv "${out}.tmp" "${out}"
  chmod 600 "${out}" 2>/dev/null || true

  # Sanity check: requested task_type must resolve.
  if ! jq -e --arg t "${task_type}" '.defaults[$t]' "${out}" >/dev/null 2>&1; then
    cd_die 4 "task_type '${task_type}' not found in resolved config (${out})"
  fi

  abs="$(cd "$(dirname "${out}")" && pwd)/$(basename "${out}")"
  printf '%s\n' "${abs}"
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

# cd_preflight TASK_TYPE MODEL
# - binary (agent, jq, timeout)
# - model is known to `agent --list-models`
# - auth: CURSOR_API_KEY set OR ~/.cursor has login-ish marker
# - output dirs exist
cd_preflight() {
  local task_type="${1:?task_type required}"
  local model="${2:?model required}"

  cd_require "agent" "install Cursor CLI (\`agent\`); see https://cursor.com/cli"
  cd_require_jq
  # `timeout` (GNU coreutils) or `gtimeout` (macOS Homebrew coreutils).
  if ! cd_resolve_timeout_bin; then
    cd_log "ERROR" "no \`timeout\` or \`gtimeout\` found in PATH"
    cd_log "ERROR" "Linux/WSL: apt-get install coreutils"
    cd_log "ERROR" "macOS:     brew install coreutils (provides gtimeout)"
    exit 2
  fi

  # Sandbox writability gate. The `agent` CLI persists chat/session data under
  # ~/.cursor/{chats,cli-config.json,…}; if that tree is read-only the run will
  # fail mid-stream with confusing errors. Detect early and emit a one-shot
  # actionable hint. Override with CURSOR_DELEGATE_SKIP_SANDBOX_CHECK=1 for
  # callers that have proven writability another way (e.g. CI bind-mounts).
  if [[ "${CURSOR_DELEGATE_SKIP_SANDBOX_CHECK:-0}" != "1" ]]; then
    if [[ -d "${HOME}/.cursor" ]] && ! ( : >"${HOME}/.cursor/.cursor-delegate-rwtest" ) 2>/dev/null; then
      cd_log "ERROR" "~/.cursor is not writable — cursor skill cannot persist sessions"
      cd_log "ERROR" "likely cause: Claude Code Bash sandbox (settings.json sandbox.enabled=true)"
      cd_log "ERROR" "fix: extend the writable allowlist in ~/.claude/settings.json:"
      cd_log "ERROR" "  \"sandbox\": { \"filesystem\": { \"allowWrite\": [\"~/.cursor\"] } }"
      cd_log "ERROR" "or run with CURSOR_DELEGATE_SKIP_SANDBOX_CHECK=1 to bypass this check"
      exit 2
    fi
    rm -f "${HOME}/.cursor/.cursor-delegate-rwtest" 2>/dev/null || true
  fi

  # Ensure output + state dirs exist.
  cd_output_dir >/dev/null
  cd_state_dir  >/dev/null

  # Model must be known.
  # `agent --list-models` can emit free-form lines; we grep case-sensitive exact-word.
  local models
  if ! models="$(agent --list-models 2>/dev/null)"; then
    cd_die 3 "failed to list models via \`agent --list-models\`; is the binary healthy?"
  fi
  # V3: shape pre-validation (reject argument-injection-style names) + strict
  # anchored match. The previous substring fallback (`grep -Fq`) was dropped
  # because it spuriously matched `composer-2` against `composer-2-preview`.
  # We anchor at line-start + word-boundary to handle `agent --list-models`
  # output formats: bare names (`composer-2`) and "name - description" lines
  # (`composer-2 - Composer 2`).
  if ! [[ "${model}" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
    cd_die 3 "model name has invalid shape: '${model}' (allowed: A-Za-z0-9._:/-)"
  fi
  # Escape `.` (the only regex metacharacter the shape validator allows
  # through). All other shape-allowed characters [A-Za-z0-9_:/-] are
  # non-special in extended regex.
  local model_re="${model//./\\.}"
  if ! grep -Eq '^'"${model_re}"'($|[[:space:]])' <<<"${models}"; then
    cd_log "ERROR" "model '${model}' not found in \`agent --list-models\`"
    cd_log "ERROR" "available (head -20):"
    printf '%s\n' "${models}" | head -20 >&2
    exit 3
  fi

  # Auth: CURSOR_API_KEY env OR existing session artifacts under ~/.cursor.
  if [[ -z "${CURSOR_API_KEY:-}" ]]; then
    # Heuristic: any of these suggests an interactive login has happened.
    if [[ ! -d "${HOME}/.cursor" ]] \
      || { [[ ! -f "${HOME}/.cursor/session.json" ]] \
        && [[ ! -f "${HOME}/.cursor/cli-config.json" ]] \
        && [[ ! -d "${HOME}/.cursor/chats" ]]; }; then
      cd_log "ERROR" "no CURSOR_API_KEY and no ~/.cursor session artifacts detected"
      cd_log "ERROR" "export CURSOR_API_KEY=... or run \`agent login\` interactively first"
      exit 2
    fi
  fi

  # Silence unused-var warnings in strict mode; task_type may be used by future checks.
  : "${task_type}"
}

# ------------------------------------------------------------------------------
# Hooks quarantine (spec R2 mitigation)
# ------------------------------------------------------------------------------

# A1: mkdir-based atomic lock for hooks-quarantine refcount.
# POSIX-atomic on all supported FS (ext4/btrfs/APFS/NTFS-via-DrvFs/MSYS2).
_cd_hooks_lock_acquire() {
  local lockdir="${1:?lockdir required}"
  local _hq_attempts=0
  while ! mkdir "${lockdir}" 2>/dev/null; do
    _hq_attempts=$((_hq_attempts + 1))
    if (( _hq_attempts >= 100 )); then
      cd_log "WARN" "hooks lock acquire timed out (5s); proceeding without lock"
      return 1
    fi
    sleep 0.05
  done
  return 0
}

_cd_hooks_lock_release() {
  rmdir "${1}" 2>/dev/null || true
}

# cd_preflight_hooks JOB_ID
# If ~/.cursor/hooks.json exists, move it aside to <file>.cursor.bak and
# drop a per-job sentinel + increment refcount under mkdir-based lock.
cd_preflight_hooks() {
  local job_id="${1:?job_id required}"
  local state_dir
  state_dir="$(cd_state_dir)"
  local sentinel="${state_dir}/hooks-quarantined-${job_id}"
  local refcount_file="${state_dir}/hooks-refcount"
  local lockdir="${state_dir}/hooks-refcount.lockdir"

  if [[ "${CURSOR_DELEGATE_QUARANTINE_HOOKS:-1}" == "0" ]]; then
    return 0
  fi

  _cd_hooks_lock_acquire "${lockdir}" || true

  local count=0
  if [[ -f "${refcount_file}" ]]; then
    count="$(cat "${refcount_file}" 2>/dev/null || printf '0')"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  fi

  if (( count == 0 )); then
    if [[ -f "${CD_HOOKS_FILE}" ]]; then
      if mv "${CD_HOOKS_FILE}" "${CD_HOOKS_BAK}" 2>/dev/null; then
        cd_log "INFO" "quarantined hooks.json -> $(basename "${CD_HOOKS_BAK}")"
      else
        # Read-only ~/.cursor (e.g. Claude Code sandbox). Skip quarantine and
        # proceed without bumping refcount/sentinel — the restore path is a
        # no-op in this case.
        cd_log "WARN" "cannot quarantine ${CD_HOOKS_FILE} (read-only fs?); proceeding without quarantine"
        _cd_hooks_lock_release "${lockdir}"
        return 0
      fi
    fi
  fi

  count=$((count + 1))
  printf '%s\n' "${count}" >"${refcount_file}"
  : >"${sentinel}"

  _cd_hooks_lock_release "${lockdir}"
}

# cd_hooks_restore JOB_ID
# Decrement refcount under mkdir-based lock. When refcount reaches 0, restore
# hooks.json from .bak. Sentinels removed for status.sh visibility.
# Safe to call multiple times (idempotent).
cd_hooks_restore() {
  local job_id="${1:-}"
  [[ -z "${job_id}" ]] && return 0

  local state_dir
  state_dir="$(cd_state_dir 2>/dev/null || printf '.cursor/delegate/state')"
  local sentinel="${state_dir}/hooks-quarantined-${job_id}"
  local refcount_file="${state_dir}/hooks-refcount"
  local lockdir="${state_dir}/hooks-refcount.lockdir"

  _cd_hooks_lock_acquire "${lockdir}" || true

  rm -f "${sentinel}" 2>/dev/null || true

  local count=0
  if [[ -f "${refcount_file}" ]]; then
    count="$(cat "${refcount_file}" 2>/dev/null || printf '0')"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  fi
  count=$((count - 1))
  (( count < 0 )) && count=0

  if (( count == 0 )); then
    rm -f "${refcount_file}" 2>/dev/null || true
    if [[ -f "${CD_HOOKS_BAK}" && ! -f "${CD_HOOKS_FILE}" ]]; then
      mv "${CD_HOOKS_BAK}" "${CD_HOOKS_FILE}" 2>/dev/null || true
      cd_log "INFO" "restored hooks.json from backup"
    fi
  else
    printf '%s\n' "${count}" >"${refcount_file}"
  fi

  _cd_hooks_lock_release "${lockdir}"
}

# ------------------------------------------------------------------------------
# Exit classification
# ------------------------------------------------------------------------------

# cd_classify_exit CODE
# Echoes one of: TRANSIENT | PERMANENT | UNKNOWN
#
# Invariant (critical): 124 (timeout SIGTERM) is PERMANENT.
# Retrying a 590s timeout becomes a ~30min zombie loop; fail fast instead.
cd_classify_exit() {
  local code="${1:?exit code required}"
  case "${code}" in
    0)   printf '%s\n' "SUCCESS" ;;
    # Transient (explicit whitelist only):
    7|28|52) printf '%s\n' "TRANSIENT" ;;      # curl connect / timeout / empty reply
    429)     printf '%s\n' "TRANSIENT" ;;       # (some CLIs surface 429 directly)
    # Permanent (never retry):
    2)   printf '%s\n' "PERMANENT" ;;   # binary/auth error from cd_require
    3)   printf '%s\n' "PERMANENT" ;;   # model unresolved
    4)   printf '%s\n' "PERMANENT" ;;   # malformed config / task unknown
    124) printf '%s\n' "PERMANENT" ;;   # timeout(1) SIGTERM — critical invariant
    125) printf '%s\n' "PERMANENT" ;;   # timeout(1) itself failed
    126|127) printf '%s\n' "PERMANENT" ;; # exec failure
    130) printf '%s\n' "PERMANENT" ;;   # SIGINT (user cancelled)
    137) printf '%s\n' "PERMANENT" ;;   # SIGKILL / OOM
    143) printf '%s\n' "PERMANENT" ;;   # SIGTERM
    *)   printf '%s\n' "UNKNOWN"   ;;   # default-deny: treat as permanent at call site
  esac
}

# ------------------------------------------------------------------------------
# Secret redaction (V5)
# ------------------------------------------------------------------------------

# cd_redact_secrets — stdin filter that replaces common secret patterns.
# Applied to RAW_ERROR in summarize.sh by default; opt-in for RESULT_TEXT
# via CURSOR_DELEGATE_REDACT_RESULT=1.
cd_redact_secrets() {
  sed -E \
    -e 's/^([[:space:]]*[Aa]uthorization:[[:space:]]*).+$/\1[REDACTED]/' \
    -e 's/(^|[[:space:]]:[[:space:]]*|^[[:space:]]*)Bearer[[:space:]]+[^[:space:]]+/\1Bearer [REDACTED]/g' \
    -e 's/(^|[[:space:]])(CURSOR_API_KEY=)[^[:space:]]*/\1\2[REDACTED]/g' \
    -e 's/(^|[^A-Za-z0-9])sk-[A-Za-z0-9]{20,}/\1sk-[REDACTED]/g'
}

# ------------------------------------------------------------------------------
# Meta sidecar helpers
# ------------------------------------------------------------------------------

# cd_emit_meta JOB_ID TASK_TYPE MODEL MODE WORKTREE SESSION_ID PID STARTED_AT
# Writes .cursor/delegate/<JOB_ID>.meta.json with status=running.
# Arguments may be "null" strings for unset optional fields (mode/worktree/session_id).
cd_emit_meta() {
  local job_id="${1:?job_id required}"
  local task_type="${2:?task_type required}"
  local model="${3:?model required}"
  local mode="${4:-null}"
  local worktree="${5:-null}"
  local session_id="${6:-null}"
  local pid="${7:-0}"
  local started_at="${8:-$(cd_iso_now)}"

  cd_require_jq

  local out_dir meta
  out_dir="$(cd_output_dir)"
  meta="${out_dir}/${job_id}.meta.json"

  jq -n \
    --arg job_id      "${job_id}" \
    --arg task_type   "${task_type}" \
    --arg model       "${model}" \
    --arg mode        "${mode}" \
    --arg worktree    "${worktree}" \
    --arg session_id  "${session_id}" \
    --arg started_at  "${started_at}" \
    --argjson pid     "${pid}" \
    '{
      job_id:       $job_id,
      task_type:    $task_type,
      resolved_model: $model,
      mode:         (if $mode == "null" then null else $mode end),
      worktree:     (if $worktree == "null" then null else $worktree end),
      session_id:   (if $session_id == "null" then null else $session_id end),
      pid:          $pid,
      started_at:   $started_at,
      completed_at: null,
      exit_code:    null,
      status:       "running"
    }' >"${meta}"
  chmod 600 "${meta}" 2>/dev/null || true

  printf '%s\n' "${meta}"
}

# cd_update_meta JOB_ID JQ_FILTER
# Applies JQ_FILTER to the meta file in place. JQ_FILTER receives the current
# object as "."; typical usage: cd_update_meta "$JOB" '.exit_code=0|.status="completed"'
cd_update_meta() {
  local job_id="${1:?job_id required}"
  local filter="${2:?jq filter required}"

  cd_require_jq

  local out_dir meta
  out_dir="$(cd_output_dir)"
  meta="${out_dir}/${job_id}.meta.json"
  [[ -f "${meta}" ]] || cd_die 4 "meta sidecar missing for job ${job_id}"

  jq "${filter}" "${meta}" >"${meta}.tmp"
  mv "${meta}.tmp" "${meta}"
  chmod 600 "${meta}" 2>/dev/null || true
}
