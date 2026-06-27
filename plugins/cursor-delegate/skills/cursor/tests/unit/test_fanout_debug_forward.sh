#!/usr/bin/env bash
# test_fanout_debug_forward.sh — unit test for fanout.sh claude-driven emit
# forwarding of --debug / --dry-run into the emitted DISPATCH-COMMANDS.
#
# In claude-driven mode the emitted lines run in FRESH Bash processes, so the
# CURSOR_DELEGATE_DEBUG / _DRY_RUN env vars exported into fanout.sh do NOT
# survive into them. emit_claude_driven() must therefore bake the flags into
# the command strings. This test pins that behavior.
#
# Covers:
#   - CURSOR_DELEGATE_DEBUG=1   → every emitted line gains a trailing ` --debug`
#   - CURSOR_DELEGATE_DRY_RUN=1 → every emitted line gains a trailing ` --dry-run`
#     (dry-run wins over debug; it implies --debug downstream)
#   - neither set              → no --debug / --dry-run appears (regression guard)
#   - read-only lines keep the allowlist-matchable `bash <dispatch.sh> <task>`
#     prefix (no leading env assignment); implement keeps the env-prefix form
#
# claude-driven emit resolves config (needs jq) but never invokes `agent`,
# so no fake agent / CURSOR_API_KEY is required.
# Requires: jq
# Exit 0 = PASS, non-zero = FAIL, 77 = SKIP.

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_fanout_debug_forward.sh — jq not found\n'
  exit 77
fi

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FANOUT_SH="${REAL_SKILL_DIR}/lib/fanout.sh"

if [[ ! -f "${FANOUT_SH}" ]]; then
  printf 'SKIP test_fanout_debug_forward.sh — fanout.sh not found at %s\n' "${FANOUT_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-fanout-dbg.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "composer-2", "force": true, "worktree": true, "sandbox": "enabled" },
    "review":      { "model": "good-model", "mode": "ask",  "sandbox": "enabled" },
    "plan":        { "model": "good-model", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "good-model", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "good-model", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

COMMON_ENV=(
  HOME="${FAKE_HOME}"
  CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
  CD_USER_CONFIG="${FAKE_HOME}/.cursor.json"
  CD_PROJECT_CONFIG=".cursor.json"
  CURSOR_DELEGATE_FORCE_CLAUDE=1   # never auto-flip to local-parallel
)

# Run fanout in claude-driven mode and print only the DISPATCH-COMMANDS block.
# Extra leading "VAR=VAL" tokens are passed through to `env`.
emit_block() {
  local -a extra_env=()
  while [[ "${1:-}" == *=* ]]; do extra_env+=("$1"); shift; done
  # set -u-safe empty-array expansion (bash 3.2 errors on "${empty[@]}").
  env "${COMMON_ENV[@]}" ${extra_env[@]+"${extra_env[@]}"} \
    bash "${FANOUT_SH}" review:fileA.ts implement:fileB.ts 2>/dev/null \
    | sed -n '/^---DISPATCH-COMMANDS---$/,/^---END-DISPATCH-COMMANDS---$/p' \
    | grep -v -- '---DISPATCH-COMMANDS---\|---END-DISPATCH-COMMANDS---'
}

# =============================================================================
# Case 1 — CURSOR_DELEGATE_DEBUG=1 → trailing ` --debug` on every line
# =============================================================================

BLOCK_DEBUG="$(emit_block CURSOR_DELEGATE_DEBUG=1)"

RO_LINE="$(printf '%s\n' "${BLOCK_DEBUG}" | grep ' review ' || true)"
IMPL_LINE="$(printf '%s\n' "${BLOCK_DEBUG}" | grep ' implement ' || true)"

# 1a: read-only line keeps `bash .../dispatch.sh review` prefix (allowlist)
if [[ "${RO_LINE}" == bash\ *dispatch.sh\ review\ * ]]; then
  pass "debug: read-only line keeps 'bash …/dispatch.sh review' prefix"
else
  fail "debug read-only prefix" "got '${RO_LINE}'"
fi

# 1b: read-only line ends with --debug
if [[ "${RO_LINE}" == *' --debug' ]]; then
  pass "debug: read-only line forwards trailing --debug"
else
  fail "debug read-only forward" "got '${RO_LINE}'"
fi

# 1c: implement line keeps env-prefix form AND forwards --debug
if [[ "${IMPL_LINE}" == CURSOR_DELEGATE_JOB_ID=*\ bash\ *dispatch.sh\ implement\ * ]]; then
  pass "debug: implement line keeps CURSOR_DELEGATE_JOB_ID= env-prefix form"
else
  fail "debug implement prefix" "got '${IMPL_LINE}'"
fi
if [[ "${IMPL_LINE}" == *' --debug' ]]; then
  pass "debug: implement line forwards trailing --debug"
else
  fail "debug implement forward" "got '${IMPL_LINE}'"
fi

# =============================================================================
# Case 2 — CURSOR_DELEGATE_DRY_RUN=1 → trailing ` --dry-run` (wins over debug)
# =============================================================================

BLOCK_DRY="$(emit_block CURSOR_DELEGATE_DRY_RUN=1 CURSOR_DELEGATE_DEBUG=1)"
RO_DRY="$(printf '%s\n' "${BLOCK_DRY}" | grep ' review ' || true)"

if [[ "${RO_DRY}" == *' --dry-run' ]]; then
  pass "dry-run: emitted line forwards trailing --dry-run"
else
  fail "dry-run forward" "got '${RO_DRY}'"
fi
# dry-run implies debug downstream, so we should NOT double-append --debug.
if [[ "${RO_DRY}" != *'--debug'* ]]; then
  pass "dry-run: does not also append redundant --debug"
else
  fail "dry-run no redundant debug" "got '${RO_DRY}'"
fi

# =============================================================================
# Case 3 — neither flag → no forwarding (regression guard)
# =============================================================================

BLOCK_PLAIN="$(emit_block)"

if [[ -n "${BLOCK_PLAIN}" ]]; then
  pass "plain: DISPATCH-COMMANDS block is non-empty"
else
  fail "plain block" "no dispatch commands emitted"
fi
if [[ "${BLOCK_PLAIN}" != *'--debug'* && "${BLOCK_PLAIN}" != *'--dry-run'* ]]; then
  pass "plain: no --debug / --dry-run appended when neither flag set"
else
  fail "plain no forward" "unexpected debug/dry-run flag in: ${BLOCK_PLAIN}"
fi
# read-only line still carries --job-id (unchanged baseline contract)
if printf '%s\n' "${BLOCK_PLAIN}" | grep ' review ' | grep -q -- '--job-id'; then
  pass "plain: read-only line still carries --job-id"
else
  fail "plain --job-id" "read-only line missing --job-id"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_fanout_debug_forward.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
