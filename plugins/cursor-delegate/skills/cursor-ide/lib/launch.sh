#!/usr/bin/env bash
# launch.sh — open the Cursor IDE (GUI editor) at a target path.
#
# Part of the `cursor-ide` skill. This is DISTINCT from the `cursor` delegation
# skill: it invokes the GUI launcher `cursor <path>` (a VS Code-family CLI),
# NOT the `agent` / `cursor-agent` binary the delegation skill drives.
#
# Contract:
#   stdout — one machine-readable line: `LAUNCHED\t<abspath>` (or `DRY_RUN\t<cmd>`)
#   stderr — all human-facing logs / hints
# Exit codes: 0 ok · 2 `cursor` not on PATH · 64 bad usage · 66 path missing ·
#             73 mkdir failed · <rc> propagated from a failing `cursor` launch.
set -euo pipefail

log() { printf '[cursor-ide][%s] %s\n' "${1}" "${2}" >&2; }
die() { log "FATAL" "${2:-}"; exit "${1}"; }

usage() {
  cat >&2 <<'EOF'
Usage: launch.sh [-n|--new-window] [-r|--reuse-window] [--mkdir] [--dry-run] [PATH]

Opens the Cursor IDE (GUI) at PATH (a directory or file).
PATH defaults to the current directory when omitted.

  -n, --new-window     force a new window
  -r, --reuse-window   open in the most recently active window
      --mkdir          create PATH (as a directory) if it does not exist
      --dry-run        print the resolved `cursor` command without launching
  -h, --help           show this help
EOF
}

# --- parse args ---------------------------------------------------------------
new_window=0
reuse_window=0
do_mkdir=0
dry_run=0
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--new-window)   new_window=1 ;;
    -r|--reuse-window) reuse_window=1 ;;
    --mkdir)           do_mkdir=1 ;;
    --dry-run)         dry_run=1 ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; target="${1:-}"; break ;;
    -*)                usage; die 64 "unknown option: $1" ;;
    *)                 target="$1" ;;
  esac
  shift || true
done

# --- OS detection (only used for install hints) -------------------------------
detect_os() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) printf 'mac' ;;
    Linux)
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf 'wsl'
      else
        printf 'linux'
      fi ;;
    *) printf 'other' ;;
  esac
}

install_hint() {
  case "$(detect_os)" in
    mac)
      log "ERROR" "Install the Cursor app from https://cursor.com, then inside Cursor run"
      log "ERROR" "  Cmd+Shift+P → \"Shell Command: Install 'cursor' command in PATH\""
      log "ERROR" "and restart your shell so \`cursor\` is on PATH." ;;
    linux)
      log "ERROR" "Install the Cursor app from https://cursor.com (the .AppImage / .deb ships"
      log "ERROR" "the \`cursor\` launcher). Put its bin dir on PATH, then restart your shell." ;;
    wsl)
      log "ERROR" "In WSL, \`cursor\` comes from Cursor on Windows + WSL integration:"
      log "ERROR" "  1) Install Cursor on Windows from https://cursor.com"
      log "ERROR" "  2) Ensure \`cursor\` resolves inside WSL (Windows PATH interop, or Cursor's"
      log "ERROR" "     \"Install 'cursor' command\"), then restart your shell." ;;
    *)
      log "ERROR" "Install Cursor from https://cursor.com and ensure \`cursor\` is on PATH." ;;
  esac
}

# --- preflight: `cursor` on PATH ----------------------------------------------
if ! command -v cursor >/dev/null 2>&1; then
  log "ERROR" "\`cursor\` (the Cursor IDE launcher) was not found in PATH."
  install_hint
  exit 2
fi

# --- resolve target path ------------------------------------------------------
[[ -n "${target}" ]] || target="${PWD}"

# expand a leading ~ (Claude usually passes an absolute path, but be forgiving)
case "${target}" in
  "~")   target="${HOME}" ;;
  "~/"*) target="${HOME}/${target#\~/}" ;;
esac

if [[ ! -e "${target}" ]]; then
  if [[ "${do_mkdir}" == "1" ]]; then
    mkdir -p -- "${target}" || die 73 "could not create directory: ${target}"
    log "INFO" "created directory: ${target}"
  else
    die 66 "path does not exist: ${target} (pass --mkdir to create it, or check the path)"
  fi
fi

# absolutize (dir → cd/pwd; file → absolutize parent, re-append basename)
if [[ -d "${target}" ]]; then
  target="$(cd -- "${target}" && pwd)"
else
  _parent="$(cd -- "$(dirname -- "${target}")" && pwd)"
  target="${_parent}/$(basename -- "${target}")"
fi

# --- build `cursor` argv ------------------------------------------------------
cursor_args=()
[[ "${new_window}"   == "1" ]] && cursor_args+=("--new-window")
[[ "${reuse_window}" == "1" ]] && cursor_args+=("--reuse-window")
cursor_args+=("${target}")

if [[ "${dry_run}" == "1" ]]; then
  log "INFO" "dry-run: would launch → cursor ${cursor_args[*]}"
  printf 'DRY_RUN\tcursor %s\n' "${cursor_args[*]}"
  exit 0
fi

# --- launch (the GUI CLI returns immediately) ---------------------------------
if cursor "${cursor_args[@]}"; then
  log "INFO" "opened Cursor at: ${target}"
  printf 'LAUNCHED\t%s\n' "${target}"
else
  rc=$?
  die "${rc}" "\`cursor\` exited with code ${rc} while opening: ${target}"
fi
