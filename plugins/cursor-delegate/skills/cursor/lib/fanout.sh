#!/usr/bin/env bash
# fanout.sh — parallel Cursor CLI dispatch across multiple task:prompt pairs.
#
# Contract:
#   bash fanout.sh <task1>:<prompt1> <task2>:<prompt2> ... [--local-parallel [N]]
#   bash fanout.sh --collect <FANOUT_TS>
#   bash fanout.sh --clear-serialization-flag
#
# task_type: one of implement | review | plan | investigate | security
#
# Modes:
#   Claude-driven (default): emit a FANOUT_PLAN=... machine-readable block to
#     stdout. Claude reads it and fires each dispatch line as a parallel Bash
#     tool call in the same message, then runs the collect command.
#   Local-parallel (--local-parallel [N] | CURSOR_DELEGATE_LOCAL_PARALLEL=1):
#     fanout.sh itself runs dispatch children with `&` + `wait`, bounded by N
#     (default max_fanout from config, falling back to 4). Inline-collects
#     summaries and emits synthesis path as LAST line of stdout.
#
# Stdout contract:
#   Claude-driven mode:
#     FANOUT_PLAN=<path>
#     FANOUT_MODE=claude-driven
#     JOBS=<N>
#     ---DISPATCH-COMMANDS---
#     bash <dispatch_path> <ro_task> '<prompt>' --job-id <jobN>        # read-only
#     CURSOR_DELEGATE_JOB_ID=<jobN> bash <dispatch_path> implement '<prompt>'  # write
#     ...
#     ---END-DISPATCH-COMMANDS---
#     (when invoked with --debug / --dry-run, each emitted line gains a
#      trailing ` --debug` / ` --dry-run` so the flag survives into the fresh
#      Bash process Claude runs it in)
#     FANOUT_COLLECT_CMD=bash <fanout_path> --collect <FANOUT_TS>
#   Local-parallel / collect mode:
#     LAST line: absolute path to .cursor/delegate/fanout-<FANOUT_TS>.synthesis.md
#
# Invariants:
#   - Every job in a fanout gets its OWN per-JOB config snapshot
#     (resolved-config-<JOB_ID>.json) — no shared path. Closes R9.
#   - In local-parallel mode, every background child dispatches with
#     CURSOR_DELEGATE_JOB_ID env pre-set, so JOB_ID parity matches the plan.
#   - Claude-driven mode emits machine-readable plan to stdout ONLY; all other
#     output goes to stderr.
#   - The claude-serializes-bash flag honors 30-day TTL and has a
#     --clear-serialization-flag escape.

set -euo pipefail
umask 077  # V7: artifacts contain secrets-by-proximity; default to user-only mode.

# ------------------------------------------------------------------------------
# Bootstrap.
# ------------------------------------------------------------------------------

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

DISPATCH_SH="${CD_SELF_DIR}/dispatch.sh"
FANOUT_SH="${CD_SELF_DIR}/fanout.sh"
SYNTHESIZE_SH="${CD_SELF_DIR}/synthesize.sh"

# ------------------------------------------------------------------------------
# Usage.
# ------------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage:
  fanout.sh <task1>:<prompt1> <task2>:<prompt2> ... [--local-parallel [N]]
  fanout.sh --collect <FANOUT_TS>
  fanout.sh --clear-serialization-flag
  fanout.sh --help

task_type: implement | review | plan | investigate | security
Prompts may contain colons; only the FIRST ':' delimits task from prompt.

Options:
  --local-parallel [N]   actually run jobs concurrently in this shell,
                         bounded by N (default max_fanout from config or 4).
                         Equivalent to env CURSOR_DELEGATE_LOCAL_PARALLEL=1.
  --collect <FANOUT_TS>  read an already-dispatched fanout plan and produce
                         the synthesis markdown (used by Claude-driven mode).
  --clear-serialization-flag
                         delete the claude-serializes-bash auto-detect flag.

Env overrides:
  CURSOR_DELEGATE_LOCAL_PARALLEL=1   same as --local-parallel (default bound).
  CURSOR_DELEGATE_FORCE_CLAUDE=1     ignore the claude-serializes-bash flag.

Auto-detect: after any fanout, if wall_clock > 1.2 * max(job_duration) in
claude-driven mode (with >=2 jobs), fanout.sh writes
.cursor/delegate/state/claude-serializes-bash (JSON). Subsequent runs
within 30 days of that flag auto-flip to local-parallel unless
CURSOR_DELEGATE_FORCE_CLAUDE=1 is set.
EOF
}

# ------------------------------------------------------------------------------
# Helpers.
# ------------------------------------------------------------------------------

# shell-quote one argument for safe embedding in a dispatch command line.
cd_shquote() {
  local s="${1-}"
  # Wrap in single quotes; escape internal single quotes via '\''.
  # The replacement is built into a variable first: writing the backslashes
  # literally inside the ${//} replacement is parsed DIFFERENTLY by bash 3.2
  # (macOS stock /bin/bash) vs 4.x — on 3.2 the old form emitted broken
  # quoting like 'it\'\\'\'s a test' that failed to round-trip, corrupting
  # fanout dispatch command lines. A variable replacement is inserted verbatim
  # on every bash version.
  local esc="'\\''"
  printf "'%s'" "${s//\'/${esc}}"
}

# Resolve max_fanout from a per-JOB resolved config snapshot (first arg path).
cd_resolve_max_fanout() {
  local cfg="${1:?config path required}"
  local v
  v="$(jq -r '.max_fanout // 4' "${cfg}" 2>/dev/null || printf '4')"
  # Guard against non-numeric or <1.
  if ! [[ "${v}" =~ ^[0-9]+$ ]] || (( v < 1 )); then
    v=4
  fi
  printf '%s' "${v}"
}

# Validate task_type string.
cd_valid_task() {
  case "${1-}" in
    implement|review|plan|investigate|security) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse a task:prompt pair. Sets TASK and PROMPT globals.
cd_parse_pair() {
  local pair="${1:?pair required}"
  if [[ "${pair}" != *:* ]]; then
    cd_die 64 "invalid pair (missing ':' delimiter): ${pair}"
  fi
  TASK="${pair%%:*}"
  PROMPT="${pair#*:}"
  if ! cd_valid_task "${TASK}"; then
    cd_die 64 "invalid task_type in pair: ${TASK} (from: ${pair})"
  fi
  if [[ -z "${PROMPT}" ]]; then
    cd_die 64 "empty prompt in pair: ${pair}"
  fi
}

# ------------------------------------------------------------------------------
# Serialization flag (TODO-F6 partial: 30-day TTL + escape hatch).
# ------------------------------------------------------------------------------

# Path to the flag file.
cd_serialization_flag_path() {
  local state_dir
  state_dir="$(cd_state_dir)"
  printf '%s/claude-serializes-bash' "${state_dir}"
}

# Returns 0 if a fresh (<30d) flag exists AND the force override is NOT set.
cd_should_auto_local_parallel() {
  [[ "${CURSOR_DELEGATE_FORCE_CLAUDE:-0}" == "1" ]] && return 1

  local flag
  flag="$(cd_serialization_flag_path)"
  [[ -f "${flag}" ]] || return 1

  if ! jq -e . "${flag}" >/dev/null 2>&1; then
    cd_log "WARN" "serialization flag is malformed; ignoring: ${flag}"
    return 1
  fi

  local detected_at age_days
  detected_at="$(jq -r '.detected_at // empty' "${flag}")"
  [[ -n "${detected_at}" ]] || return 1

  # Compute age in days (GNU/BSD-portable epoch parse via cd_iso_to_epoch).
  local det_epoch now_epoch
  det_epoch="$(cd_iso_to_epoch "${detected_at}")"
  now_epoch="$(date -u +%s)"
  if (( det_epoch == 0 )); then
    return 1
  fi
  age_days=$(( (now_epoch - det_epoch) / 86400 ))
  if (( age_days > 30 )); then
    cd_log "INFO" "serialization flag is stale (>30d); ignoring"
    return 1
  fi
  return 0
}

# Write/update the serialization flag.
# Args: ratio sample_size
cd_write_serialization_flag() {
  local ratio="${1:?ratio required}"
  local sample_size="${2:?sample_size required}"
  local flag
  flag="$(cd_serialization_flag_path)"

  jq -n \
    --arg detected_at  "$(cd_iso_now)" \
    --arg omc_version  "${OMC_VERSION:-unknown}" \
    --argjson ratio      "${ratio}" \
    --argjson sample_size "${sample_size}" \
    '{
      detected_at: $detected_at,
      omc_version: $omc_version,
      serialization_ratio: $ratio,
      sample_size: $sample_size
    }' >"${flag}.tmp"
  mv "${flag}.tmp" "${flag}"
  cd_log "WARN" "wrote claude-serializes-bash flag (ratio=${ratio}, samples=${sample_size})"
  cd_log "WARN" "future fanouts in this project will auto-flip to --local-parallel"
  cd_log "WARN" "clear with: bash ${FANOUT_SH} --clear-serialization-flag"
}

cd_clear_serialization_flag() {
  local flag
  flag="$(cd_serialization_flag_path)"
  if [[ -f "${flag}" ]]; then
    rm -f "${flag}"
    cd_log "INFO" "cleared serialization flag: ${flag}"
  else
    cd_log "INFO" "no serialization flag to clear"
  fi
}

# ------------------------------------------------------------------------------
# Preparation: generate JOB_IDs, resolve per-JOB configs, write plan JSON.
# ------------------------------------------------------------------------------

# Args: FANOUT_TS, then pair strings.
# Writes .cursor/delegate/fanout-<FANOUT_TS>.json and echoes its path.
fanout_prepare() {
  local fanout_ts="${1:?fanout_ts required}"; shift
  local -a pairs=("$@")

  cd_require_jq

  local out_dir state_dir
  out_dir="$(cd_output_dir)"
  state_dir="$(cd_state_dir)"

  local plan_path="${out_dir}/fanout-${fanout_ts}.json"
  local plan_abs
  plan_abs="$(cd "${out_dir}" && pwd)/fanout-${fanout_ts}.json"

  # Build JSON array of plan entries.
  local tmp="${plan_path}.tmp"
  : >"${tmp}"

  # Start an accumulating array via jq -s with null input.
  local entries_json="[]"

  local idx=0
  for pair in "${pairs[@]}"; do
    cd_parse_pair "${pair}"
    local task="${TASK}"
    local prompt="${PROMPT}"

    local job_id
    job_id="$(cd_gen_job_id)"

    # Per-JOB config snapshot — closes R9 (every fanout job has its own).
    local resolved_cfg
    resolved_cfg="$(cd_resolve_config "${task}" "${job_id}")"

    # Compute expected summary path (absolute).
    local expected_summary="${out_dir}/${job_id}.summary.md"
    local expected_summary_abs
    expected_summary_abs="$(cd "${out_dir}" && pwd)/${job_id}.summary.md"

    # Record entry as JSON, append to entries_json.
    entries_json="$(jq -n \
      --argjson acc "${entries_json}" \
      --arg job_id "${job_id}" \
      --arg task_type "${task}" \
      --arg prompt "${prompt}" \
      --arg resolved_config_path "${resolved_cfg}" \
      --arg expected_summary_path "${expected_summary_abs}" \
      --argjson index "${idx}" \
      '$acc + [{
        index: $index,
        job_id: $job_id,
        task_type: $task_type,
        prompt: $prompt,
        resolved_config_path: $resolved_config_path,
        expected_summary_path: $expected_summary_path
      }]')"

    idx=$((idx + 1))
  done

  jq -n \
    --arg fanout_ts "${fanout_ts}" \
    --arg created_at "$(cd_iso_now)" \
    --argjson jobs "${entries_json}" \
    '{
      fanout_ts: $fanout_ts,
      created_at: $created_at,
      job_count: ($jobs|length),
      jobs: $jobs
    }' >"${tmp}"
  mv "${tmp}" "${plan_path}"

  printf '%s\n' "${plan_abs}"
}

# ------------------------------------------------------------------------------
# Claude-driven emit.
# ------------------------------------------------------------------------------

# Args: plan_path
emit_claude_driven() {
  local plan_path="${1:?plan_path required}"
  local fanout_ts job_count
  fanout_ts="$(jq -r '.fanout_ts' "${plan_path}")"
  job_count="$(jq -r '.job_count' "${plan_path}")"

  # All stdout here is the machine-readable contract. Logs already went to stderr.
  printf 'FANOUT_PLAN=%s\n' "${plan_path}"
  printf 'FANOUT_MODE=claude-driven\n'
  printf 'JOBS=%s\n' "${job_count}"
  printf -- '---DISPATCH-COMMANDS---\n'

  # Emission form depends on the task type:
  #   - READ-ONLY (review|plan|investigate|security): the JOB_ID rides on a
  #     trailing `--job-id <id>` flag so the command keeps a leading
  #     `bash <dispatch_path> <task>` prefix that Claude Code allowlist rules
  #     can match — these tasks never edit files, so they run unattended.
  #   - implement: keeps the `CURSOR_DELEGATE_JOB_ID=<id> bash ...` env-prefix
  #     form. The leading assignment intentionally defeats prefix matching, so
  #     a write task still hits a permission prompt.
  #
  # Debug / dry-run forwarding: in claude-driven mode Claude runs each emitted
  # line in a FRESH Bash process, so the CURSOR_DELEGATE_DEBUG / _DRY_RUN env
  # vars exported into THIS process do NOT survive into them — we must bake the
  # flags into the command strings. (Local-parallel needs no such forwarding:
  # its children inherit the exported env directly.) `--dry-run` implies
  # `--debug` downstream, so the dry-run flag alone suffices. Both flags are
  # appended as a trailing suffix, preserving the allowlist-matchable
  # `bash <dispatch_path> <ro_task>` prefix on read-only lines.
  local fwd_flags=""
  if cd_is_dry_run; then
    fwd_flags=" --dry-run"
  elif cd_is_debug; then
    fwd_flags=" --debug"
  fi

  # Use jq to iterate in stable order.
  local entries
  entries="$(jq -c '.jobs[]' "${plan_path}")"
  while IFS= read -r entry; do
    local job_id task prompt qprompt
    job_id="$(jq -r '.job_id' <<<"${entry}")"
    task="$(jq -r '.task_type' <<<"${entry}")"
    prompt="$(jq -r '.prompt' <<<"${entry}")"
    qprompt="$(cd_shquote "${prompt}")"
    case "${task}" in
      review|plan|investigate|security)
        printf 'bash %s %s %s --job-id %s%s\n' \
          "${DISPATCH_SH}" "${task}" "${qprompt}" "${job_id}" "${fwd_flags}"
        ;;
      *)
        printf 'CURSOR_DELEGATE_JOB_ID=%s bash %s %s %s%s\n' \
          "${job_id}" "${DISPATCH_SH}" "${task}" "${qprompt}" "${fwd_flags}"
        ;;
    esac
  done <<<"${entries}"

  printf -- '---END-DISPATCH-COMMANDS---\n'
  printf 'FANOUT_COLLECT_CMD=bash %s --collect %s\n' "${FANOUT_SH}" "${fanout_ts}"
}

# ------------------------------------------------------------------------------
# Local-parallel execution.
# ------------------------------------------------------------------------------

# Args: plan_path parallel_bound
# Runs all jobs with bounded concurrency via & + wait + active-job count.
run_local_parallel() {
  local plan_path="${1:?plan_path required}"
  local bound="${2:?bound required}"

  if ! [[ "${bound}" =~ ^[0-9]+$ ]] || (( bound < 1 )); then
    bound=4
  fi

  # V8 + bash 3.2 compat: prefer event-driven `wait -n` (bash 4.3+, avoids the
  # poll sleep), but fall back to a poll-loop semaphore on older bash so macOS
  # stock /bin/bash (3.2) still works. Either way `jobs -rp` is the source of
  # truth for the live-child count, so the bound is honored in both paths.
  local have_wait_n=0
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    have_wait_n=1
  else
    cd_log "INFO" "bash ${BASH_VERSION:-?} < 4.3: using poll-loop semaphore"
    cd_log "INFO" "  (install bash 4.3+ for wait -n efficiency: macOS \`brew install bash\`)"
  fi

  cd_log "INFO" "local-parallel mode: bound=${bound} (wait_n=${have_wait_n})"

  # V4: compute output dir for dispatch.log capture.
  local _out_dir_abs
  _out_dir_abs="$(cd "$(cd_output_dir)" && pwd)"
  cd_log "WARN" "audit-only artifacts written unredacted: ${_out_dir_abs}/<JOB_ID>.err and ${_out_dir_abs}/<JOB_ID>.dispatch.log"
  cd_log "WARN" "  -- read by humans during debugging, never by Claude (which reads .summary.md only)"
  cd_log "WARN" "  -- redacted view of CLI errors lives in <JOB_ID>.summary.md (see V5)"

  # Collect entries.
  local -a job_ids=()
  local -a tasks=()
  local -a prompts=()

  local entries
  entries="$(jq -c '.jobs[]' "${plan_path}")"
  while IFS= read -r entry; do
    job_ids+=("$(jq -r '.job_id'    <<<"${entry}")")
    tasks+=(  "$(jq -r '.task_type' <<<"${entry}")")
    prompts+=("$(jq -r '.prompt'    <<<"${entry}")")
  done <<<"${entries}"

  local total=${#job_ids[@]}
  cd_log "INFO" "dispatching ${total} jobs"

  local i
  for (( i=0; i<total; i++ )); do
    # Block until a concurrency slot frees up. `jobs -rp` lists live background
    # PIDs; trim macOS `wc` leading spaces. wait_n path blocks event-driven,
    # poll path sleeps — both honor `bound`.
    while (( $(jobs -rp 2>/dev/null | wc -l | tr -d ' ') >= bound )); do
      if (( have_wait_n )); then
        wait -n 2>/dev/null || true
      else
        sleep 0.2
      fi
    done

    local jid="${job_ids[$i]}"
    local tsk="${tasks[$i]}"
    local prm="${prompts[$i]}"

    cd_log "INFO" "  spawn [${i}] job_id=${jid} task=${tsk}"

    # V4: capture dispatch stdout/stderr to per-job .dispatch.log.
    (
      CURSOR_DELEGATE_JOB_ID="${jid}" \
        bash "${DISPATCH_SH}" "${tsk}" "${prm}" \
        >"${_out_dir_abs}/${jid}.dispatch.log" 2>&1 || true
    ) &
  done

  wait
  cd_log "INFO" "all ${total} jobs finished (local-parallel)"
}

# ------------------------------------------------------------------------------
# Auto-detect: inspect per-job durations vs wall-clock.
# ------------------------------------------------------------------------------

# Args: plan_path wall_ms mode_label
# Writes the claude-serializes-bash flag if mode is claude-driven and
# wall_clock > 1.2 * max(durations) with N>=2.
maybe_write_serialization_flag() {
  local plan_path="${1:?plan_path required}"
  local wall_ms="${2:?wall_ms required}"
  local mode="${3:?mode required}"

  [[ "${mode}" == "claude-driven" ]] || return 0

  local out_dir
  out_dir="$(cd_output_dir)"

  # Collect each job's duration_ms from its meta.json.
  local max_dur=0
  local n=0
  local entries
  entries="$(jq -c '.jobs[]' "${plan_path}")"
  while IFS= read -r entry; do
    local jid meta dur
    jid="$(jq -r '.job_id' <<<"${entry}")"
    meta="${out_dir}/${jid}.meta.json"
    [[ -f "${meta}" ]] || continue
    dur="$(jq -r '.duration_ms // 0' "${meta}")"
    [[ "${dur}" =~ ^[0-9]+$ ]] || dur=0
    if (( dur > max_dur )); then
      max_dur="${dur}"
    fi
    n=$((n + 1))
  done <<<"${entries}"

  if (( n < 2 || max_dur == 0 )); then
    return 0
  fi

  # ratio = wall_ms / max_dur, as float.
  local ratio
  ratio="$(awk -v w="${wall_ms}" -v m="${max_dur}" 'BEGIN { printf "%.4f", w/m }')"
  cd_log "INFO" "auto-detect: wall=${wall_ms}ms max=${max_dur}ms ratio=${ratio} samples=${n}"

  # Compare ratio > 1.2 in awk (bash can't do floats).
  local trigger
  trigger="$(awk -v r="${ratio}" 'BEGIN { print (r > 1.2) ? "1" : "0" }')"
  if [[ "${trigger}" == "1" ]]; then
    cd_write_serialization_flag "${ratio}" "${n}"
  fi
}

# ------------------------------------------------------------------------------
# Collect / synthesize.
# ------------------------------------------------------------------------------

# Args: fanout_ts
# Reads plan, collects all summaries + metas, writes synthesis markdown,
# prints synthesis absolute path as LAST line of stdout.
do_collect() {
  local fanout_ts="${1:?fanout_ts required}"

  cd_require_jq

  local out_dir
  out_dir="$(cd_output_dir)"
  local plan_path="${out_dir}/fanout-${fanout_ts}.json"

  if [[ ! -f "${plan_path}" ]]; then
    cd_die 4 "fanout plan not found: ${plan_path}"
  fi

  # Delegate to synthesize.sh for the actual markdown rendering.
  local syn_path
  syn_path="$(bash "${SYNTHESIZE_SH}" "${plan_path}")"

  # Last line of stdout is the synthesis path (mirrors dispatch.sh contract).
  printf '%s\n' "${syn_path}"
}

# ------------------------------------------------------------------------------
# Main.
# ------------------------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 64
  fi

  # Mode flags parsed up front. (jq check deferred until we know we need it,
  # so --help and --clear-serialization-flag don't require jq.)
  local mode_local_parallel=0
  local parallel_bound=""
  local do_clear=0
  local collect_ts=""
  local -a pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local-parallel)
        mode_local_parallel=1
        # Optional numeric bound.
        if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
          parallel_bound="$2"
          shift 2
        else
          shift
        fi
        ;;
      --collect)
        [[ $# -ge 2 ]] || { usage; exit 64; }
        collect_ts="$2"
        shift 2
        ;;
      --clear-serialization-flag)
        do_clear=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        cd_log "ERROR" "unknown flag: $1"
        usage
        exit 64
        ;;
      *)
        pairs+=("$1")
        shift
        ;;
    esac
  done

  if (( do_clear )); then
    cd_clear_serialization_flag
    exit 0
  fi

  if [[ -n "${collect_ts}" ]]; then
    do_collect "${collect_ts}"
    exit 0
  fi

  if [[ ${#pairs[@]} -eq 0 ]]; then
    cd_log "ERROR" "no task:prompt pairs given"
    usage
    exit 64
  fi

  # Real work ahead — now require jq.
  cd_require_jq

  # Env-var equivalent to --local-parallel.
  if [[ "${CURSOR_DELEGATE_LOCAL_PARALLEL:-0}" == "1" ]]; then
    mode_local_parallel=1
  fi

  # Auto-detect: if flag fresh AND we're in claude-driven mode AND no force,
  # auto-flip to local-parallel and warn.
  if (( ! mode_local_parallel )); then
    if cd_should_auto_local_parallel; then
      cd_log "WARN" "claude-serializes-bash flag is active (fresh, <30d)"
      cd_log "WARN" "auto-flipping to --local-parallel mode"
      cd_log "WARN" "override with CURSOR_DELEGATE_FORCE_CLAUDE=1 or clear via --clear-serialization-flag"
      mode_local_parallel=1
    fi
  fi

  # Prepare plan (per-JOB configs + plan JSON).
  local fanout_ts
  fanout_ts="$(cd_ts_compact)"
  local plan_path
  plan_path="$(fanout_prepare "${fanout_ts}" "${pairs[@]}")"
  cd_log "INFO" "fanout plan: ${plan_path}"

  # Resolve parallel_bound from first job's config if not set.
  if [[ -z "${parallel_bound}" ]]; then
    local first_cfg
    first_cfg="$(jq -r '.jobs[0].resolved_config_path' "${plan_path}")"
    if [[ -f "${first_cfg}" ]]; then
      parallel_bound="$(cd_resolve_max_fanout "${first_cfg}")"
    else
      parallel_bound=4
    fi
  fi

  if (( mode_local_parallel )); then
    # Execute + collect + auto-detect inline.
    local wall_start_ms wall_end_ms wall_ms
    wall_start_ms="$(cd_epoch_ms)"
    run_local_parallel "${plan_path}" "${parallel_bound}"
    wall_end_ms="$(cd_epoch_ms)"
    wall_ms=$((wall_end_ms - wall_start_ms))
    cd_log "INFO" "local-parallel wall_clock=${wall_ms}ms"

    # Auto-detect only fires in claude-driven mode (local-parallel is the
    # fallback; recording serialization from local-parallel doesn't make sense).
    # Still, for symmetry/audit, we could record local-parallel ratio — but
    # the contract says only claude-driven triggers the flag. Skip.

    # Inline collect. Pass mode hint so synthesize.sh does NOT write the
    # claude-serializes-bash flag (that's claude-driven only).
    local syn_path
    syn_path="$(CURSOR_DELEGATE_FANOUT_MODE=local-parallel bash "${SYNTHESIZE_SH}" "${plan_path}")"
    printf '%s\n' "${syn_path}"
  else
    # Claude-driven: emit plan + dispatch lines + collect command.
    # We cannot measure wall_clock here because the dispatches haven't run
    # yet — Claude will fire them as parallel tool calls, then call --collect.
    # The --collect path writes the serialization flag based on wall_ms measured
    # by comparing plan.created_at to synthesis.completed_at.
    emit_claude_driven "${plan_path}"
  fi
}

main "$@"
