#!/usr/bin/env bash
# int_fanout_parallel.sh — integration test for fanout parallel behavior.
#
# Claude-driven mode: this test is a no-op placeholder that prints "MANUAL"
# because timing requires a live Claude Code session to observe parallelism.
#
# --local-parallel mode: assert wall-clock < 45s for 2x jobs that each
# take ~30s of real Cursor work (would be ~60s serial).
#
# Also asserts 2 distinct resolved-config-*.json files are produced.
#
# GATED: requires CURSOR_API_KEY.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FANOUT_SH="${REAL_SKILL_DIR}/lib/fanout.sh"
STATE_DIR=".cursor/delegate/state"
mkdir -p "${STATE_DIR}"

MODE="${CURSOR_DELEGATE_FANOUT_TEST_MODE:-claude-driven}"

if [[ "${MODE}" == "claude-driven" ]]; then
  cat <<'MSG'
MANUAL: Claude-driven fanout wall-clock check requires a live Claude Code session.
See tests/manual-qa.md MQ-1 for the manual procedure.
This test is a placeholder for CI environments.
MSG
  exit 0
fi

# --local-parallel mode actual timing test.
PROMPT1="review:Describe in one sentence what lib_common.sh exports"
PROMPT2="review:Describe in one sentence what dispatch.sh does"

PRE_CONFIG_COUNT="$(ls -1 "${STATE_DIR}"/resolved-config-*.json 2>/dev/null | wc -l || printf '0')"

WALL_START="$(date -u +%s)"
bash "${FANOUT_SH}" --local-parallel 2 "${PROMPT1}" "${PROMPT2}"
WALL_END="$(date -u +%s)"
WALL_SEC=$(( WALL_END - WALL_START ))

printf 'Wall clock: %ss\n' "${WALL_SEC}"

# Assert < 45s wall-clock (2x30s serial would be 60s).
if (( WALL_SEC < 45 )); then
  printf 'PASS: local-parallel wall-clock %ss < 45s\n' "${WALL_SEC}"
else
  printf 'FAIL: local-parallel wall-clock %ss >= 45s (possible serialization)\n' "${WALL_SEC}"
  exit 1
fi

# Assert 2 new resolved-config-*.json files were created.
POST_CONFIG_COUNT="$(ls -1 "${STATE_DIR}"/resolved-config-*.json 2>/dev/null | wc -l || printf '0')"
NEW_CONFIGS=$(( POST_CONFIG_COUNT - PRE_CONFIG_COUNT ))
if (( NEW_CONFIGS >= 2 )); then
  printf 'PASS: %d distinct resolved-config-*.json files created\n' "${NEW_CONFIGS}"
else
  printf 'FAIL: expected >= 2 new resolved-config files, got %d\n' "${NEW_CONFIGS}"
  exit 1
fi

printf 'PASS: int_fanout_parallel.sh all checks passed\n'
exit 0
