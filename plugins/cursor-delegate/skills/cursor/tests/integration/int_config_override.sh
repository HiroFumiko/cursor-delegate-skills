#!/usr/bin/env bash
# int_config_override.sh — integration test for user-level config override.
#
# Points CD_USER_CONFIG at a temp override file (the ~/.cursor.json layer) with a
# review model override, dispatches a review task, reads the per-JOB
# resolved-config-<JOB>.json, and asserts the override model is present.
#
# Config is user-scoped only — there is no per-project config file — so the
# override is injected via CD_USER_CONFIG (never touching the real ~/.cursor.json).
#
# GATED: requires CURSOR_API_KEY.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"
STATE_DIR=".cursor/delegate/state"
mkdir -p "${STATE_DIR}"

OVERRIDE_MODEL="gpt-5.3-codex-high"
USER_CONFIG="$(mktemp -t cd-int-user-config.XXXXXX)"

# Write the user override to a temp file (never mutates the real ~/.cursor.json).
cat >"${USER_CONFIG}" <<EOF
{
  "defaults": {
    "review": { "model": "${OVERRIDE_MODEL}" }
  }
}
EOF

CLEANUP() {
  rm -f "${USER_CONFIG}"
}
trap CLEANUP EXIT INT TERM

# Dispatch a review task with CD_USER_CONFIG pointed at our temp override;
# capture the first line (JOB_ID=...) to locate the snapshot.
STDOUT="$(CD_USER_CONFIG="${USER_CONFIG}" bash "${DISPATCH_SH}" review "List the exports of lib_common.sh")"
FIRST_LINE="$(printf '%s\n' "${STDOUT}" | head -1)"
JOB_ID="${FIRST_LINE#JOB_ID=}"

if [[ -z "${JOB_ID}" ]]; then
  printf 'FAIL: could not extract JOB_ID from dispatch stdout\n'
  exit 1
fi

RESOLVED_CONFIG="${STATE_DIR}/resolved-config-${JOB_ID}.json"

if [[ ! -f "${RESOLVED_CONFIG}" ]]; then
  printf 'FAIL: resolved-config snapshot not found: %s\n' "${RESOLVED_CONFIG}"
  exit 1
fi

printf 'PASS: resolved-config snapshot found: %s\n' "${RESOLVED_CONFIG}"

# Assert override model is in the snapshot.
ACTUAL_MODEL="$(jq -r '.defaults.review.model // empty' "${RESOLVED_CONFIG}")"
if [[ "${ACTUAL_MODEL}" == "${OVERRIDE_MODEL}" ]]; then
  printf 'PASS: resolved review model = %s (user override applied)\n' "${ACTUAL_MODEL}"
else
  printf 'FAIL: expected review model %s, got %s\n' "${OVERRIDE_MODEL}" "${ACTUAL_MODEL}"
  exit 1
fi

printf 'PASS: int_config_override.sh all checks passed\n'
exit 0
