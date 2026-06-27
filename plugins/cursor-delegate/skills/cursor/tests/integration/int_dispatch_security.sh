#!/usr/bin/env bash
# int_dispatch_security.sh — integration test for security task.
# GATED: requires CURSOR_API_KEY.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"

STDOUT="$(bash "${DISPATCH_SH}" security "Check lib/dispatch.sh for any shell injection or unsafe variable expansion risks")"
LAST_LINE="$(printf '%s\n' "${STDOUT}" | tail -1)"

if [[ -f "${LAST_LINE}" ]]; then
  printf 'PASS: summary.md exists at %s\n' "${LAST_LINE}"
else
  printf 'FAIL: summary.md missing: %s\n' "${LAST_LINE}"
  exit 1
fi

if grep -q 'task_type: security' "${LAST_LINE}"; then
  printf 'PASS: summary frontmatter has task_type=security\n'
else
  printf 'FAIL: task_type not security in summary\n'
  exit 1
fi

printf 'PASS: int_dispatch_security.sh all checks passed\n'
exit 0
