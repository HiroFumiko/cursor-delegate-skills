#!/usr/bin/env bash
# cursor.sh — unified entry-point dispatcher for the cursor skill.
#
# Routes all subcommands through one script so that:
#   - Claude (via Skill()) and shell users have one canonical entry
#   - Task-type shortcut works: `/cursor investigate "..."` == `/cursor dispatch investigate "..."`
#   - New subcommands land in one place instead of scattered help text
#
# Contract:
#   bash cursor.sh <subcommand> [args...]
#
# Valid subcommands:
#   dispatch <task_type> "<prompt>" [--resume <chatId>]
#   fanout   <task>:<prompt> [<task>:<prompt>...] [--local-parallel [N]] [--collect <TS>] [--clear-serialization-flag]
#   resume   <chatId> "<prompt>" [--task <task_type>]
#   resume   --create-chat
#   status   [--last N] [--since <dur>] [--with-pid]
#   cancel   <JOB_ID>
#
# Task-type shortcuts (implicit `dispatch`):
#   implement|review|plan|investigate|security "<prompt>" [--resume <chatId>]
#
# Meta flags:
#   -h | --help | help     show this help
#   --version              print skill version

set -euo pipefail

CD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_VERSION="v1.0.0"

usage() {
  cat <<'EOF'
Usage: /cursor <subcommand> [args...]

Subcommands:
  dispatch <task> "<prompt>" [--resume <id>]   Run one job (explicit form)
  fanout   <task>:<prompt> ...                 Run multiple jobs in parallel
  resume   <chatId> "<prompt>" [--task <t>]    Continue a Cursor chat
  resume   --create-chat                       Allocate a new chatId (best-effort)
  status   [--last N] [--since <d>] [--with-pid]
                                               List recent jobs (default 24h)
  cancel   <JOB_ID>                            SIGTERM -> (5s) -> SIGKILL
  setup    [--print-permissions|--apply-permissions|--init-config <user|project>]
                                               Cross-platform readiness doctor +
                                               ready-to-use .cursor.json seed
                                               (copy of shipped defaults)
                                               (alias: doctor). See /cursor-setup.

Task-type shortcuts (omit `dispatch`):
  /cursor implement   "<prompt>"   ==  /cursor dispatch implement   "<prompt>"
  /cursor review      "<prompt>"   ==  /cursor dispatch review      "<prompt>"
  /cursor plan        "<prompt>"   ==  /cursor dispatch plan        "<prompt>"
  /cursor investigate "<prompt>"   ==  /cursor dispatch investigate "<prompt>"
  /cursor security    "<prompt>"   ==  /cursor dispatch security    "<prompt>"

Meta:
  -h | --help | help     Show this help
  --version              Print skill version
  --debug                Verbose stderr diagnostics (sets CURSOR_DELEGATE_DEBUG=1)
  --dry-run              Print the planned `agent` command and exit without
                         invoking it (sets CURSOR_DELEGATE_DRY_RUN=1). Implies
                         --debug.

Examples:
  /cursor investigate "src/auth.ts のロジックを説明して"
  /cursor fanout review:src/a.ts security:src/a.ts
  /cursor resume abc123def456 "フォロー質問"
  /cursor status --last 10

Config: ~/.claude/skills/cursor/config/.cursor.json (skill default, editable)
       Override via ~/.cursor.json (user) or <cwd>/.cursor.json (project)
       All three layers use the same .cursor.json shape (deep-merged).
EOF
}

# Task-type shortcut detection: first arg is one of the 5 known task_types.
is_task_type() {
  case "$1" in
    implement|review|plan|investigate|security) return 0 ;;
    *) return 1 ;;
  esac
}

# Route to the correct subcommand script.
route() {
  local sub="$1"; shift
  case "${sub}" in
    dispatch)
      exec bash "${CD_SELF_DIR}/dispatch.sh" "$@"
      ;;
    fanout)
      exec bash "${CD_SELF_DIR}/fanout.sh" "$@"
      ;;
    resume)
      exec bash "${CD_SELF_DIR}/resume.sh" "$@"
      ;;
    status)
      exec bash "${CD_SELF_DIR}/status.sh" "$@"
      ;;
    cancel)
      exec bash "${CD_SELF_DIR}/cancel.sh" "$@"
      ;;
    setup|doctor)
      exec bash "${CD_SELF_DIR}/setup.sh" "$@"
      ;;
    *)
      printf 'cursor: unknown subcommand: %s\n\n' "${sub}" >&2
      usage >&2
      exit 64
      ;;
  esac
}

# --- main ---

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

# Consume global meta flags (--debug / --dry-run) that may appear before the
# subcommand. They map to env vars so they propagate through `exec` to the
# downstream subcommand scripts (and through fanout into per-job dispatches).
# --dry-run implies --debug so the dry-run preview is always visible.
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

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

case "$1" in
  -h|--help|help)
    usage
    exit 0
    ;;
  --version)
    printf 'cursor skill %s\n' "${SKILL_VERSION}"
    exit 0
    ;;
esac

# Task-type shortcut: `/cursor investigate "..."` -> dispatch.sh investigate "..."
if is_task_type "$1"; then
  exec bash "${CD_SELF_DIR}/dispatch.sh" "$@"
fi

# Explicit subcommand routing.
route "$@"
