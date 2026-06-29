#!/usr/bin/env bash
# setup.sh — cross-platform readiness doctor + permission-allowlist generator.
#
# This is the engine behind `/cursor-setup` (and `bash cursor.sh setup`). It is
# the ONE place that adapts the skill to the host OS: it detects the environment
# (WSL / Linux / macOS / Windows), checks every runtime dependency in one pass
# (no `agent` invocation, no token spend), and generates the per-environment
# `~/.claude/settings.json` permission allowlist that lets read-only delegation
# run without a confirmation prompt.
#
# IMPORTANT: this script must run on the OLDEST bash we support (macOS stock
# /bin/bash 3.2) because its whole job is to diagnose a not-yet-set-up host.
# Therefore: no ${var^^}, no `wait -n`, no associative arrays, no mapfile.
#
# Contract:
#   bash setup.sh [--check]                    full doctor report + verdict (default)
#   bash setup.sh --print-permissions          print the settings.json allow entries
#   bash setup.sh --apply-permissions          merge allow entries into settings.json
#   bash setup.sh --init-config <scope> [--force]
#                                              seed a ready-to-use .cursor.json
#                                              (copy of shipped defaults) at user
#                                              scope (~/.cursor.json) or project
#                                              scope (<cwd>/.cursor.json)
#   bash setup.sh --help
#
# Exit codes:
#   0  ready (or a non-check mode completed)
#   1  NEEDS SETUP — one or more blocking dependencies missing (--check only)
#   64 bad arguments

set -euo pipefail
umask 077

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_common.sh
source "${CD_SELF_DIR}/lib_common.sh"

SKILL_DIR_ABS="$(cd "${CD_SELF_DIR}/.." && pwd)"
LIB_DIR_ABS="${CD_SELF_DIR}"
SETTINGS_JSON="${HOME}/.claude/settings.json"

# ------------------------------------------------------------------------------
# Usage.
# ------------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: /cursor-setup [--check | --print-permissions | --apply-permissions
                      | --init-config <user|project> [--force]]

  (default)            Run the readiness doctor: detect OS, check every
  --check              dependency, and print a verdict + per-OS fix-it steps.
                       Never invokes `agent` (no token cost).
  --print-permissions  Print the ~/.claude/settings.json permission allowlist
                       entries for THIS install (absolute + ~ path variants).
                       Read-only delegation (review/plan/investigate/security/
                       status/fanout --collect) is allowlisted; implement /
                       cancel / resume are deliberately omitted (still prompt).
  --apply-permissions  Merge those entries into ~/.claude/settings.json
                       (backs up to settings.json.cursor-setup.bak first).
  --init-config <scope> [--force]
                       Seed a ready-to-use .cursor.json (a copy of the shipped
                       defaults) at:
                         user     -> ~/.cursor.json      (every repo, this user)
                         project  -> <cwd>/.cursor.json  (this repo; committable)
                       The file holds real, editable values you can tweak right
                       away. A full copy pins those values, so a field you keep
                       won't track future skill-default updates; delete a field
                       to let it fall back to the default again. Never overwrites
                       an existing file unless --force (prior file backed up to
                       <target>.cursor-setup.bak). Prints "WROTE\t<path>" or
                       "EXISTS\t<path>" to stdout.
  --help               This help.
EOF
}

# ------------------------------------------------------------------------------
# OS detection.
# ------------------------------------------------------------------------------

detect_os() {
  local s
  s="$(uname -s 2>/dev/null || printf 'unknown')"
  case "${s}" in
    Linux)
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf 'wsl'
      else
        printf 'linux'
      fi
      ;;
    Darwin)              printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *)                   printf 'unknown' ;;
  esac
}

# ------------------------------------------------------------------------------
# Result tracking + line printers.
# ------------------------------------------------------------------------------

BLOCKING=0   # count of missing hard-deps
ADVISORY=0   # count of soft warnings

p_ok()    { printf '  [OK]      %s\n' "$*"; }
p_warn()  { printf '  [WARN]    %s\n' "$*"; ADVISORY=$((ADVISORY + 1)); }
p_cont()  { printf '            %s\n' "$*"; }   # continuation line, not counted
p_miss()  { printf '  [MISSING] %s\n' "$*"; BLOCKING=$((BLOCKING + 1)); }
p_info()  { printf '  [INFO]    %s\n' "$*"; }
section() { printf '\n%s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# Dependency checks (each prints one or more status lines).
# ------------------------------------------------------------------------------

check_shell() {
  local v="${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}"
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
    p_ok "bash ${v} (>= 4.3: full feature set incl. fanout --local-parallel wait -n)"
  else
    p_warn "bash ${v} (< 4.3: works, but fanout --local-parallel uses a poll loop;"
    p_cont "          optional: macOS \`brew install bash\` for the faster path)"
  fi
}

check_agent() {
  if have agent; then
    local ver
    ver="$(agent --version 2>/dev/null | head -1 || true)"
    p_ok "agent (Cursor CLI) found${ver:+: ${ver}}"
  else
    p_miss "agent (Cursor CLI) not on PATH — required to run any delegation"
  fi
}

check_jq() {
  if have jq; then
    p_ok "jq found: $(jq --version 2>/dev/null || printf '?')"
  else
    p_miss "jq not on PATH — required for config merge / meta / summaries"
  fi
}

check_timeout() {
  if cd_resolve_timeout_bin; then
    p_ok "timeout binary: ${CD_TIMEOUT_BIN} (hard 590s budget per job)"
  else
    p_miss "no \`timeout\` or \`gtimeout\` on PATH — required to bound agent runs"
  fi
}

check_date() {
  # status TTL / synthesis wall-clock parse ISO8601 -> epoch. The skill is now
  # GNU/BSD-portable (cd_iso_to_epoch), so this is informational, not blocking.
  if date -u -d "2026-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
    p_ok "date: GNU (\`date -d\` supported)"
  elif have gdate; then
    p_ok "date: BSD, but gdate (GNU coreutils) present — used preferentially"
  else
    p_info "date: BSD/macOS (\`date -d\` unsupported) — skill uses its -j -f / -r fallback"
  fi
}

check_auth() {
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    p_ok "auth: CURSOR_API_KEY is set"
  elif [[ -f "${HOME}/.cursor/session.json" ]] \
    || [[ -f "${HOME}/.cursor/cli-config.json" ]] \
    || [[ -d "${HOME}/.cursor/chats" ]]; then
    p_ok "auth: ~/.cursor session artifacts present (interactive login done)"
  else
    p_miss "auth: no CURSOR_API_KEY and no ~/.cursor session — run \`agent login\`"
  fi
}

check_cursor_writable() {
  if [[ ! -d "${HOME}/.cursor" ]]; then
    p_info "~/.cursor does not exist yet — it is created on first \`agent login\`"
    return 0
  fi
  if ( : >"${HOME}/.cursor/.cursor-delegate-rwtest" ) 2>/dev/null; then
    rm -f "${HOME}/.cursor/.cursor-delegate-rwtest" 2>/dev/null || true
    p_ok "~/.cursor is writable (sessions can persist)"
  else
    p_miss "~/.cursor is NOT writable (Claude Code sandbox?) — see fix-it steps"
  fi
}

# ------------------------------------------------------------------------------
# Per-OS remediation hints.
# ------------------------------------------------------------------------------

print_remediation() {
  local os="$1"
  section "Fix-it steps (${os}):"
  case "${os}" in
    macos)
      cat <<'EOF'
  # install dependencies (jq + GNU coreutils gives gtimeout & gdate):
  brew install jq coreutils
  # install Cursor CLI:
  curl https://cursor.com/install -fsS | bash      # then restart your shell
  # authenticate (one-time):
  agent login           # or: export CURSOR_API_KEY=...
  # OPTIONAL (only for fanout --local-parallel efficiency):
  brew install bash
EOF
      ;;
    linux|wsl)
      cat <<'EOF'
  # install dependencies:
  sudo apt-get update && sudo apt-get install -y jq coreutils
  # install Cursor CLI:
  curl https://cursor.com/install -fsS | bash      # then restart your shell
  # authenticate (one-time):
  agent login           # or: export CURSOR_API_KEY=...
EOF
      ;;
    windows)
      cat <<'EOF'
  Native Windows is NOT supported (this skill is bash + Unix coreutils).
  Use WSL — it is the smooth, supported path:
    1) In an elevated PowerShell:   wsl --install -d Ubuntu
    2) Reboot, open Ubuntu, then INSIDE WSL:
         sudo apt-get update && sudo apt-get install -y jq coreutils
         curl https://cursor.com/install -fsS | bash
         agent login
    3) Run Claude Code and this skill from inside the WSL shell.
  (Git Bash / Cygwin are not officially supported.)
EOF
      ;;
    *)
      cat <<'EOF'
  Unrecognized OS. This skill needs: bash, jq, a `timeout`/`gtimeout` binary,
  the Cursor CLI (`agent`), and a writable ~/.cursor. Install those, then
  authenticate with `agent login` (or export CURSOR_API_KEY).
EOF
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Permission allowlist generation.
#
# Read-only delegation never edits files, so it is allowlisted to run without a
# confirmation prompt. implement / cancel / resume are DELIBERATELY omitted so
# write/ambiguous actions always prompt. Both invocation forms (cursor.sh and
# dispatch.sh — fanout emits dispatch.sh lines) and both path variants
# (absolute + ~) are emitted so Claude Code prefix-matching catches every shape.
# ------------------------------------------------------------------------------

# Emit newline-separated permission rule strings to stdout.
gen_permission_entries() {
  local -a roots=("${LIB_DIR_ABS}")
  # Add the ~-relative form when the skill lives under $HOME.
  case "${LIB_DIR_ABS}" in
    "${HOME}/"*) roots+=("~${LIB_DIR_ABS#${HOME}}") ;;
  esac

  local root t
  for root in "${roots[@]}"; do
    for t in review plan investigate security; do
      printf 'Bash(bash %s/cursor.sh %s:*)\n'   "${root}" "${t}"
      printf 'Bash(bash %s/dispatch.sh %s:*)\n' "${root}" "${t}"
    done
    printf 'Bash(bash %s/cursor.sh status:*)\n'          "${root}"
    printf 'Bash(bash %s/status.sh:*)\n'                 "${root}"
    printf 'Bash(bash %s/cursor.sh fanout --collect:*)\n' "${root}"
    printf 'Bash(bash %s/fanout.sh --collect:*)\n'       "${root}"
    printf 'Bash(bash %s/cursor.sh setup:*)\n'           "${root}"
    printf 'Bash(bash %s/cursor.sh doctor:*)\n'          "${root}"
    printf 'Bash(bash %s/setup.sh:*)\n'                  "${root}"
  done
}

# JSON array of the entries (requires jq).
permissions_json() {
  cd_require_jq
  gen_permission_entries | jq -R . | jq -s .
}

print_permissions() {
  if have jq; then
    permissions_json
  else
    # jq missing (it's also a checked dep) — emit raw rules so the user can
    # still copy them; --apply-permissions needs jq for the merge.
    cd_log "WARN" "jq not found; printing raw rules (install jq to use --apply-permissions)"
    gen_permission_entries
  fi
}

apply_permissions() {
  cd_require_jq
  local add
  add="$(permissions_json)"

  mkdir -p "$(dirname "${SETTINGS_JSON}")"

  local base="{}"
  if [[ -f "${SETTINGS_JSON}" ]]; then
    if ! jq -e . "${SETTINGS_JSON}" >/dev/null 2>&1; then
      cd_die 4 "settings.json is not valid JSON: ${SETTINGS_JSON} (fix or move it first)"
    fi
    cp "${SETTINGS_JSON}" "${SETTINGS_JSON}.cursor-setup.bak"
    cd_log "INFO" "backed up existing settings to ${SETTINGS_JSON}.cursor-setup.bak"
    base="$(cat "${SETTINGS_JSON}")"
  fi

  printf '%s' "${base}" | jq --argjson add "${add}" '
    .permissions = (.permissions // {})
    | .permissions.allow = ((.permissions.allow // []) + $add | unique)
  ' >"${SETTINGS_JSON}.tmp"
  mv "${SETTINGS_JSON}.tmp" "${SETTINGS_JSON}"
  chmod 600 "${SETTINGS_JSON}" 2>/dev/null || true

  local n
  n="$(printf '%s' "${add}" | jq 'length')"
  cd_log "INFO" "merged ${n} read-only allow rules into ${SETTINGS_JSON} (deduped)"
  cd_log "INFO" "implement / cancel / resume were NOT allowlisted — they still prompt"
}

# ------------------------------------------------------------------------------
# Config seed (--init-config).
#
# Writes a ready-to-use `.cursor.json` at user scope (~/.cursor.json) or project
# scope (<cwd>/.cursor.json) by copying the shipped skill default
# (config/.cursor.json) verbatim. The generated file therefore holds real,
# editable values (models, modes, preambles) the user can tweak immediately —
# not an empty stub that looks configured but does nothing until edited.
#
# Tradeoff: a full copy PINS every value into the override layer, so a field the
# user keeps no longer tracks future skill-default improvements (marketplace
# updates overwrite layer 1, never these override files). Deleting a field from
# the override re-enables default tracking for it; users who instead want a
# marketplace-safe file that records only intentional diffs can empty `defaults`.
#
# Safety: never clobbers an existing file unless --force; with --force the prior
# file is backed up to <target>.cursor-setup.bak first. Emits a machine-readable
# "WROTE\t<path>" or "EXISTS\t<path>" line to stdout so the caller knows the
# outcome without reparsing logs.
# ------------------------------------------------------------------------------

init_config() {
  local scope="${1:-}"
  local force="${2:-0}"
  local target

  case "${scope}" in
    user)    target="${HOME}/.cursor.json" ;;
    project) target="${PWD}/.cursor.json" ;;
    *)
      cd_log "ERROR" "--init-config needs a scope: 'user' (~/.cursor.json) or 'project' (<cwd>/.cursor.json)"
      exit 64
      ;;
  esac

  # user and project scope collapse to the same file when cwd is $HOME.
  if [[ "${scope}" == "project" && "${PWD}" == "${HOME}" ]]; then
    cd_log "WARN" "cwd is your home directory — project scope == user scope (both ${target})"
  fi

  if [[ -e "${target}" && "${force}" != "1" ]]; then
    cd_log "WARN" "config already exists: ${target}"
    cd_log "WARN" "re-run with --force to overwrite (the existing file is backed up first)"
    printf 'EXISTS\t%s\n' "${target}"
    return 0
  fi

  if [[ -e "${target}" ]]; then
    cp "${target}" "${target}.cursor-setup.bak"
    cd_log "INFO" "backed up existing config to ${target}.cursor-setup.bak"
  fi

  # Seed the file with a FULL COPY of the shipped skill default so it is usable
  # the moment it is written — real, editable values (models, modes, preambles)
  # the user can tweak immediately, not an empty stub that looks configured but
  # does nothing until edited. The shipped default is guaranteed valid strict
  # JSON (the runtime loader rejects it otherwise), so a verbatim copy is always
  # itself a valid `.cursor.json`.
  if [[ ! -f "${CD_SKILL_CONFIG}" ]]; then
    cd_log "ERROR" "skill default config not found: ${CD_SKILL_CONFIG} (broken install?)"
    exit 70
  fi
  cp "${CD_SKILL_CONFIG}" "${target}.tmp"
  mv "${target}.tmp" "${target}"
  chmod 644 "${target}" 2>/dev/null || true   # no secrets ever live here; keep it readable/committable
  cd_log "INFO" "wrote ${scope}-scope config (copy of the shipped defaults): ${target}"
  cd_log "INFO" "it is ready to use as-is — edit the values in place to customize."
  cd_log "INFO" "note: a full copy PINS these values, so a field you keep won't track"
  cd_log "INFO" "      future skill-default updates; delete a field to fall back to the default."
  cd_log "INFO" "annotated reference: skills/cursor/config/.cursor.example.json"
  cd_log "INFO" "schema + examples: skills/cursor/references/configuration.md"
  printf 'WROTE\t%s\n' "${target}"
}

# ------------------------------------------------------------------------------
# Doctor report.
# ------------------------------------------------------------------------------

run_check() {
  local os shell_name
  os="$(detect_os)"
  shell_name="$(basename "${SHELL:-?}" 2>/dev/null || printf '?')"

  printf '=== cursor skill — setup doctor ===\n'
  printf 'detected OS:    %s\n' "${os}"
  printf 'login shell:    %s\n' "${shell_name}"
  printf 'skill dir:      %s\n' "${SKILL_DIR_ABS}"

  section "Dependencies:"
  check_shell
  check_agent
  check_jq
  check_timeout
  check_date
  check_auth
  check_cursor_writable

  section "Permissions (read-only auto-approval):"
  if [[ -f "${SETTINGS_JSON}" ]] && have jq \
    && jq -e '(.permissions.allow // []) | any(test("cursor\\.sh (review|plan|investigate|security)"))' \
         "${SETTINGS_JSON}" >/dev/null 2>&1; then
    p_ok "settings.json already contains cursor read-only allow rules"
  else
    p_warn "no cursor allow rules in ${SETTINGS_JSON}"
    p_cont "  read-only delegation will PROMPT until you run: /cursor-setup --apply-permissions"
    p_cont "  (preview first with: /cursor-setup --print-permissions)"
  fi

  # Verdict.
  printf '\n=== Verdict ===\n'
  if (( BLOCKING == 0 )); then
    printf 'READY ✓  — all hard dependencies present'
    if (( ADVISORY > 0 )); then
      printf ' (%s advisory note(s) above)' "${ADVISORY}"
    fi
    printf '\n'
    if [[ "${os}" == "windows" ]]; then
      print_remediation "${os}"
    fi
    return 0
  fi

  printf 'NEEDS SETUP ✗  — %s blocking item(s) above\n' "${BLOCKING}"
  print_remediation "${os}"
  return 1
}

# ------------------------------------------------------------------------------
# Main.
# ------------------------------------------------------------------------------

MODE="check"
INIT_SCOPE=""
INIT_FORCE=0
case "${1:-}" in
  ""|--check)          MODE="check" ;;
  --print-permissions) MODE="print" ;;
  --apply-permissions) MODE="apply" ;;
  --init-config)
    MODE="init"
    shift
    INIT_SCOPE="${1:-}"
    [[ $# -gt 0 ]] && shift   # consume the scope token (if present)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force) INIT_FORCE=1 ;;
        *)
          cd_log "ERROR" "unknown argument for --init-config: $1"
          usage
          exit 64
          ;;
      esac
      shift
    done
    ;;
  -h|--help)           usage; exit 0 ;;
  *)
    cd_log "ERROR" "unknown argument: $1"
    usage
    exit 64
    ;;
esac

case "${MODE}" in
  check) run_check ;;            # exit code from run_check (0 ready / 1 needs setup)
  print) print_permissions ;;
  apply) apply_permissions ;;
  init)  init_config "${INIT_SCOPE}" "${INIT_FORCE}" ;;
esac
