#!/usr/bin/env bash
# test_config_merge.sh — unit test for cd_resolve_config:
#   - per-JOB snapshot naming
#   - project > user > skill-default precedence
#
# Requires: jq
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_config_merge.sh — jq not found\n'
  exit 77
fi

# ---- Resolve REAL_SKILL_DIR BEFORE any cd -----------------------------------
# Must happen before cd "${FAKE_CWD}" so dirname "${BASH_SOURCE[0]}" resolves
# relative to the real filesystem, not the fake project directory.
REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"

if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_config_merge.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"
  exit 77
fi

# ---- Setup temp environment -------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-config-merge.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

# Fake HOME so CD_USER_CONFIG and CD_HOOKS_FILE resolve under our tmpdir.
export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}/.cursor"

# Fake CWD inside tmpdir (for project config + .omc dirs).
FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_CWD}"
cd "${FAKE_CWD}"

# Fake skill config directory (CD_SKILL_DIR override via path structure).
FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"

# Write skill-level model.json (lowest precedence).
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "composer-2",   "force": true,  "worktree": true,  "sandbox": "enabled" },
    "review":      { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" },
    "plan":        { "model": "gpt-5.4-high", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

# Write user-level override (mid precedence): overrides review model.
cat >"${HOME}/.cursor.json" <<'EOF'
{
  "defaults": {
    "review": { "model": "user-override-model" }
  }
}
EOF

# Write project-level override (highest precedence): overrides review model again.
cat >"${FAKE_CWD}/.cursor.json" <<'EOF'
{
  "defaults": {
    "review": { "model": "project-override-model" }
  }
}
EOF

# ---- Source lib_common.sh with patched CD_SKILL_DIR -------------------------

# Patch CD_SKILL_CONFIG to point at our fake config before sourcing.
# We override by setting the var before sourcing; lib_common.sh uses BASH_SOURCE
# to compute CD_SKILL_DIR, so we re-assign after sourcing.
# shellcheck source=../../lib/lib_common.sh
source "${LIB_COMMON}"

# Override the config path to use our fake skill config.
CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
CD_USER_CONFIG="${HOME}/.cursor.json"
CD_PROJECT_CONFIG=".cursor.json"
export CD_SKILL_CONFIG CD_USER_CONFIG CD_PROJECT_CONFIG

# ---- Test 1: per-JOB snapshot naming ----------------------------------------

JOB_ID="test-job-$(cd_rand 8)"
SNAP_PATH="$(cd_resolve_config review "${JOB_ID}")"

EXPECTED_FILENAME="resolved-config-${JOB_ID}.json"
if [[ "$(basename "${SNAP_PATH}")" == "${EXPECTED_FILENAME}" ]]; then
  pass "snapshot filename contains JOB_ID (${EXPECTED_FILENAME})"
else
  fail "snapshot filename" "expected ${EXPECTED_FILENAME}, got $(basename "${SNAP_PATH}")"
fi

if [[ -f "${SNAP_PATH}" ]]; then
  pass "snapshot file exists at returned path"
else
  fail "snapshot file exists" "path not found: ${SNAP_PATH}"
fi

# ---- Test 2: project override wins over user override -----------------------

REVIEW_MODEL="$(jq -r '.defaults.review.model' "${SNAP_PATH}")"
if [[ "${REVIEW_MODEL}" == "project-override-model" ]]; then
  pass "project override wins (review.model = project-override-model)"
else
  fail "project override wins" "got: ${REVIEW_MODEL}"
fi

# ---- Test 3: user override visible when project does NOT override -----------

# Create a new project config that does NOT override security.
cat >"${FAKE_CWD}/.cursor.json" <<'EOF'
{
  "defaults": {
    "review": { "model": "project-override-model" }
  }
}
EOF

# User config overrides security model.
cat >"${HOME}/.cursor.json" <<'EOF'
{
  "defaults": {
    "security": { "model": "user-security-model" }
  }
}
EOF

JOB2="test-job2-$(cd_rand 8)"
SNAP2="$(cd_resolve_config security "${JOB2}")"

SEC_MODEL="$(jq -r '.defaults.security.model' "${SNAP2}")"
if [[ "${SEC_MODEL}" == "user-security-model" ]]; then
  pass "user override wins when no project override (security.model = user-security-model)"
else
  fail "user override visible" "got: ${SEC_MODEL}"
fi

# ---- Test 4: skill default wins when no user/project override ---------------

# Empty user and project configs.
echo '{}' >"${HOME}/.cursor.json"
echo '{}' >"${FAKE_CWD}/.cursor.json"

JOB3="test-job3-$(cd_rand 8)"
SNAP3="$(cd_resolve_config implement "${JOB3}")"

IMPL_MODEL="$(jq -r '.defaults.implement.model' "${SNAP3}")"
if [[ "${IMPL_MODEL}" == "composer-2" ]]; then
  pass "skill default wins when no overrides (implement.model = composer-2)"
else
  fail "skill default wins" "got: ${IMPL_MODEL}"
fi

# ---- Test 5: two JOBs get independent snapshots (no TOCTOU / shared path) ---

JOB_A="jobA-$(cd_rand 8)"
JOB_B="jobB-$(cd_rand 8)"
SNAP_A="$(cd_resolve_config review "${JOB_A}")"
SNAP_B="$(cd_resolve_config review "${JOB_B}")"

if [[ "${SNAP_A}" != "${SNAP_B}" ]]; then
  pass "two jobs produce independent snapshot paths"
else
  fail "independent snapshots" "both jobs returned same path: ${SNAP_A}"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_config_merge.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
