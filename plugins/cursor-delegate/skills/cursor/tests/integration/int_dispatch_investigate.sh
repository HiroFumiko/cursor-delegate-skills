#!/usr/bin/env bash
# int_dispatch_investigate.sh — integration test for investigate task.
# GATED: requires CURSOR_API_KEY.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"

STDOUT="$(bash "${DISPATCH_SH}" investigate "What files are present in the lib/ directory of this skill?")"
LAST_LINE="$(printf '%s\n' "${STDOUT}" | tail -1)"

if [[ -f "${LAST_LINE}" ]]; then
  printf 'PASS: summary.md exists at %s\n' "${LAST_LINE}"
else
  printf 'FAIL: summary.md missing: %s\n' "${LAST_LINE}"
  exit 1
fi

if grep -q 'task_type: investigate' "${LAST_LINE}"; then
  printf 'PASS: summary frontmatter has task_type=investigate\n'
else
  printf 'FAIL: task_type not investigate in summary\n'
  exit 1
fi

printf 'PASS: int_dispatch_investigate.sh all checks passed\n'
exit 0
