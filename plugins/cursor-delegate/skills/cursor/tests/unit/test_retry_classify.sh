#!/usr/bin/env bash
# test_retry_classify.sh — table-driven unit tests for cd_classify_exit.
#
# Critical invariant: exit code 124 MUST be PERMANENT (never retried).
# Retrying a 590s timeout = ~30min zombie cascade.
#
# This test runs WITHOUT jq and WITHOUT any network access.
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"

if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_retry_classify.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"
  exit 77
fi

# Source only the function we need. lib_common.sh uses set -euo pipefail
# internally; we accept that. Provide a throwaway HOME so any mkdir -p
# won't escape the temp space.
TMPDIR_TEST="$(mktemp -d -t cd-test-retry.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM
export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}/.cursor"

# shellcheck source=../../lib/lib_common.sh
source "${LIB_COMMON}"

# ---- Table of expected classifications --------------------------------------
# Format: "<exit_code> <expected_class>"

declare -a CASES=(
  "0    SUCCESS"
  "124  PERMANENT"   # CRITICAL invariant — timeout must NEVER retry
  "2    PERMANENT"
  "3    PERMANENT"
  "7    TRANSIENT"
  "130  PERMANENT"
  "137  PERMANENT"
  "1    UNKNOWN"
)

for case_str in "${CASES[@]}"; do
  # Trim leading whitespace for the read.
  read -r code expected <<< "${case_str}"

  actual="$(cd_classify_exit "${code}")"

  if [[ "${actual}" == "${expected}" ]]; then
    pass "cd_classify_exit ${code} => ${expected}"
  else
    fail "cd_classify_exit ${code}" "expected ${expected}, got ${actual}"
  fi
done

# ---- Extra coverage: all documented PERMANENT codes -------------------------

declare -a PERMANENT_CODES=(2 3 4 124 125 126 127 130 137 143)
for c in "${PERMANENT_CODES[@]}"; do
  result="$(cd_classify_exit "${c}")"
  if [[ "${result}" == "PERMANENT" ]]; then
    pass "documented PERMANENT code ${c} => PERMANENT"
  else
    fail "documented PERMANENT code ${c}" "expected PERMANENT, got ${result}"
  fi
done

# ---- TRANSIENT whitelist ----------------------------------------------------

declare -a TRANSIENT_CODES=(7 28 52 429)
for c in "${TRANSIENT_CODES[@]}"; do
  result="$(cd_classify_exit "${c}")"
  if [[ "${result}" == "TRANSIENT" ]]; then
    pass "transient code ${c} => TRANSIENT"
  else
    fail "transient code ${c}" "expected TRANSIENT, got ${result}"
  fi
done

# ---- Unknown codes default to UNKNOWN (default-deny retry) ------------------

declare -a UNKNOWN_CODES=(1 5 6 10 99 200)
for c in "${UNKNOWN_CODES[@]}"; do
  result="$(cd_classify_exit "${c}")"
  if [[ "${result}" == "UNKNOWN" ]]; then
    pass "unknown code ${c} => UNKNOWN (default-deny)"
  else
    fail "unknown code ${c}" "expected UNKNOWN, got ${result}"
  fi
done

# ---- Summary ----------------------------------------------------------------

printf '\ntest_retry_classify.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
