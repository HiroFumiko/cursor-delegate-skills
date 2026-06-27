#!/usr/bin/env bash
# test_hooks_quarantine.sh — unit tests for hooks quarantine round-trip:
#   - cd_preflight_hooks + cd_hooks_restore: .bak created, original gone, sentinel present
#   - After restore: hooks.json restored, .bak removed, sentinel gone
#   - Concurrent jobs: preflight JOB1 + JOB2 -> 2 sentinels, 1 .bak
#     restore JOB1 -> .bak still present (JOB2 active), sentinel1 gone
#     restore JOB2 -> restored, all clean
#
# Runs without jq (pure-bash function tests).
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"

if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_hooks_quarantine.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"
  exit 77
fi

# ---- Setup temp HOME --------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-hooks.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

export HOME="${TMPDIR_TEST}/home"
CURSOR_DIR="${HOME}/.cursor"
HOOKS_FILE="${CURSOR_DIR}/hooks.json"
HOOKS_BAK="${CURSOR_DIR}/hooks.json.cursor.bak"
mkdir -p "${CURSOR_DIR}"

FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "review": { "model": "gpt-5.4-high", "mode": "ask", "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000 },
  "timeout_sec": 590
}
EOF

export CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
export CD_USER_CONFIG="${HOME}/.cursor.json"
export CD_PROJECT_CONFIG=".cursor.json"
export CURSOR_DELEGATE_QUARANTINE_HOOKS="1"

# shellcheck source=../../lib/lib_common.sh
source "${LIB_COMMON}"

# Override the path variables that lib_common set from BASH_SOURCE.
CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
CD_HOOKS_FILE="${HOOKS_FILE}"
CD_HOOKS_BAK="${HOOKS_BAK}"

STATE_DIR="$(cd_state_dir)"

# Use fixed job IDs — avoids cd_rand's tr|head SIGPIPE under pipefail.
JOB1="job1-aabbccdd"
JOB_A="jobA-11223344"
JOB_B="jobB-55667788"
JOB_SKIP="jobskip-99aabbcc"

# ---- Test 1: preflight_hooks moves hooks.json aside + creates sentinel ------

# Write a fake hooks.json.
printf '{"hooks":"fake"}' >"${HOOKS_FILE}"
cd_preflight_hooks "${JOB1}"

SENTINEL1="${STATE_DIR}/hooks-quarantined-${JOB1}"

if [[ ! -f "${HOOKS_FILE}" ]]; then
  pass "preflight_hooks: hooks.json moved aside (no longer present)"
else
  fail "preflight_hooks: hooks.json should be gone" "still exists: ${HOOKS_FILE}"
fi

if [[ -f "${HOOKS_BAK}" ]]; then
  pass "preflight_hooks: .bak file created"
else
  fail "preflight_hooks: .bak file created" "missing: ${HOOKS_BAK}"
fi

if [[ -f "${SENTINEL1}" ]]; then
  pass "preflight_hooks: sentinel file created for JOB1"
else
  fail "preflight_hooks: sentinel for JOB1" "missing: ${SENTINEL1}"
fi

# ---- Test 2: restore undoes quarantine --------------------------------------

cd_hooks_restore "${JOB1}"

if [[ -f "${HOOKS_FILE}" ]]; then
  pass "hooks_restore: hooks.json restored"
else
  fail "hooks_restore: hooks.json not restored" "missing: ${HOOKS_FILE}"
fi

if [[ ! -f "${HOOKS_BAK}" ]]; then
  pass "hooks_restore: .bak removed after restore"
else
  fail "hooks_restore: .bak should be gone" "still exists: ${HOOKS_BAK}"
fi

if [[ ! -f "${SENTINEL1}" ]]; then
  pass "hooks_restore: sentinel1 removed"
else
  fail "hooks_restore: sentinel1 should be gone" "still exists: ${SENTINEL1}"
fi

# ---- Test 3: concurrent jobs - sibling case ---------------------------------
# preflight JOB1 + JOB2 -> 2 sentinels, 1 .bak

# Re-create hooks.json.
printf '{"hooks":"fake-v2"}' >"${HOOKS_FILE}"

SENTINEL_A="${STATE_DIR}/hooks-quarantined-${JOB_A}"
SENTINEL_B="${STATE_DIR}/hooks-quarantined-${JOB_B}"

cd_preflight_hooks "${JOB_A}"
cd_preflight_hooks "${JOB_B}"

SENTINEL_COUNT="$(ls -1 "${STATE_DIR}"/hooks-quarantined-* 2>/dev/null | wc -l | tr -d ' \n' || printf '0')"
SENTINEL_COUNT="${SENTINEL_COUNT//[[:space:]]/}"
[[ -z "${SENTINEL_COUNT}" ]] && SENTINEL_COUNT="0"

if [[ "${SENTINEL_COUNT}" -eq 2 ]]; then
  pass "concurrent preflight: 2 sentinels created"
else
  fail "concurrent preflight: 2 sentinels" "found ${SENTINEL_COUNT}"
fi

if [[ -f "${HOOKS_BAK}" ]]; then
  pass "concurrent preflight: 1 .bak exists"
else
  fail "concurrent preflight: .bak missing"
fi

if [[ ! -f "${HOOKS_FILE}" ]]; then
  pass "concurrent preflight: hooks.json moved aside"
else
  fail "concurrent preflight: hooks.json still present"
fi

# ---- Test 4: restore JOB_A while JOB_B still active ------------------------
# -> .bak still present (JOB_B needs it), sentinel_A gone

cd_hooks_restore "${JOB_A}"

if [[ ! -f "${SENTINEL_A}" ]]; then
  pass "restore JOB_A: sentinel_A removed"
else
  fail "restore JOB_A: sentinel_A should be gone" "still: ${SENTINEL_A}"
fi

if [[ -f "${SENTINEL_B}" ]]; then
  pass "restore JOB_A: sentinel_B still present (JOB_B active)"
else
  fail "restore JOB_A: sentinel_B should still exist"
fi

if [[ -f "${HOOKS_BAK}" ]]; then
  pass "restore JOB_A: .bak still present (JOB_B active, not yet restored)"
else
  fail "restore JOB_A: .bak should remain while JOB_B active"
fi

if [[ ! -f "${HOOKS_FILE}" ]]; then
  pass "restore JOB_A: hooks.json NOT restored yet (JOB_B still active)"
else
  fail "restore JOB_A: hooks.json should NOT be restored while JOB_B active"
fi

# ---- Test 5: restore JOB_B -> file restored, all clean ----------------------

cd_hooks_restore "${JOB_B}"

if [[ -f "${HOOKS_FILE}" ]]; then
  pass "restore JOB_B: hooks.json finally restored"
else
  fail "restore JOB_B: hooks.json not restored"
fi

if [[ ! -f "${HOOKS_BAK}" ]]; then
  pass "restore JOB_B: .bak removed"
else
  fail "restore JOB_B: .bak should be gone"
fi

if [[ ! -f "${SENTINEL_A}" && ! -f "${SENTINEL_B}" ]]; then
  pass "restore JOB_B: all sentinels gone"
else
  fail "restore JOB_B: sentinels remain"
fi

REMAINING_COUNT="$(ls -1 "${STATE_DIR}"/hooks-quarantined-* 2>/dev/null | wc -l | tr -d ' \n' || printf '0')"
REMAINING_COUNT="${REMAINING_COUNT//[[:space:]]/}"
[[ -z "${REMAINING_COUNT}" ]] && REMAINING_COUNT="0"
if [[ "${REMAINING_COUNT}" -eq 0 ]]; then
  pass "restore JOB_B: zero sentinel files remain"
else
  fail "restore JOB_B: expected 0 sentinel files, found ${REMAINING_COUNT}"
fi

# ---- Test 6: restore is idempotent (calling twice is safe) ------------------

HOOKS_CONTENT="$(cat "${HOOKS_FILE}" 2>/dev/null || echo '')"

cd_hooks_restore "${JOB_B}"  # second call — should be a no-op

if [[ -f "${HOOKS_FILE}" ]]; then
  NEW_CONTENT="$(cat "${HOOKS_FILE}" 2>/dev/null || echo '')"
  if [[ "${HOOKS_CONTENT}" == "${NEW_CONTENT}" ]]; then
    pass "restore idempotent: second restore does not corrupt hooks.json"
  else
    fail "restore idempotent: hooks.json content changed on second restore"
  fi
else
  fail "restore idempotent: hooks.json should still exist after second restore"
fi

# ---- Test 7: QUARANTINE_HOOKS=0 disables quarantine -------------------------

printf '{"hooks":"skip-test"}' >"${HOOKS_FILE}"
CURSOR_DELEGATE_QUARANTINE_HOOKS=0 cd_preflight_hooks "${JOB_SKIP}"

if [[ -f "${HOOKS_FILE}" ]]; then
  pass "QUARANTINE_HOOKS=0: hooks.json left in place"
else
  fail "QUARANTINE_HOOKS=0: hooks.json should not be moved"
fi

SENTINEL_SKIP="${STATE_DIR}/hooks-quarantined-${JOB_SKIP}"
if [[ ! -f "${SENTINEL_SKIP}" ]]; then
  pass "QUARANTINE_HOOKS=0: no sentinel created"
else
  fail "QUARANTINE_HOOKS=0: no sentinel should be created"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_hooks_quarantine.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
