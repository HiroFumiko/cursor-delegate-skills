#!/usr/bin/env bash
# int_dispatch_implement.sh — integration test for implement task:
#   1. worktree impl-* created in ~/.cursor/worktrees/
#   2. current working tree is clean (no new files outside worktree)
#   3. summary.md exists
#   4. exit code 0
#
# GATED: requires CURSOR_API_KEY or pre-existing agent session.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"

TS="$(date -u +%s)"
PROMPT="Create a file /tmp/cursor-test-${TS}.txt with the text hello"

STDOUT="$(bash "${DISPATCH_SH}" implement "${PROMPT}")"

LAST_LINE="$(printf '%s\n' "${STDOUT}" | tail -1)"

# Assert summary.md exists.
if [[ -f "${LAST_LINE}" ]]; then
  printf 'PASS: summary.md exists at %s\n' "${LAST_LINE}"
else
  printf 'FAIL: summary.md missing: %s\n' "${LAST_LINE}"
  exit 1
fi

# Assert working tree is clean (no tracked or untracked files from this dispatch).
if git -C . diff --quiet 2>/dev/null && git -C . diff --cached --quiet 2>/dev/null; then
  printf 'PASS: working tree is clean\n'
else
  printf 'FAIL: working tree has changes after implement dispatch\n'
  git -C . status --short
  exit 1
fi

printf 'PASS: int_dispatch_implement.sh all checks passed\n'
exit 0
