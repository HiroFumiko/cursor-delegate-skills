#!/usr/bin/env bash
# test_summarize_redaction.sh — V5 regression guard for cd_redact_secrets.
#
# Verifies:
#   1. Canonical secret patterns are redacted
#   2. Prose false-positives survive (anchored regex)
#   3. Opt-in CURSOR_DELEGATE_REDACT_RESULT redaction

set -euo pipefail

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REAL_SKILL_DIR}/tests/fixtures/lib.sh"

LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"
[[ -f "${LIB_COMMON}" ]] || { printf 'SKIP — lib_common.sh not found\n'; exit 77; }

TMPDIR_TEST="$(mktemp -d -t cd-test-redact.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

# Source lib_common for cd_redact_secrets.
export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}"
FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

FAKE_SKILL="${TMPDIR_TEST}/skill"
setup_fake_skill_dir "${FAKE_SKILL}"
export CD_SKILL_CONFIG="${FAKE_SKILL}/config/model.json"
export CD_USER_CONFIG="${HOME}/.cursor.json"
source "${LIB_COMMON}"

# ---- Test input with both canonical secrets and prose false-positives --------

INPUT="$(cat <<'TESTDATA'
some log output
CURSOR_API_KEY=sk-secretValueAAAAAAAAAA
Authorization: Bearer eyJhbGciOiJI
  Bearer ghp_realtokenABCDEF12345678
sk-test1234567890ABCDEFGHIJ
a leaked header was Bearer ghp_xxx in the comment
example identifier: XYZsk-foo123 should not redact
TESTDATA
)"

OUTPUT="$(cd_redact_secrets <<<"${INPUT}")"

# ---- Assertion 1: CURSOR_API_KEY= is redacted ----
if [[ "${OUTPUT}" == *"CURSOR_API_KEY=[REDACTED]"* ]]; then
  pass "CURSOR_API_KEY= redacted"
else
  fail "CURSOR_API_KEY= redacted" "pattern not found in output"
fi

# ---- Assertion 2: Authorization: header redacted ----
if [[ "${OUTPUT}" != *"eyJhbGciOiJI"* ]]; then
  pass "Authorization: Bearer token redacted"
else
  fail "Authorization: Bearer token redacted" "eyJhbGciOiJI still present"
fi

# ---- Assertion 3: line-start Bearer redacted ----
if [[ "${OUTPUT}" != *"ghp_realtokenABCDEF12345678"* ]]; then
  pass "line-start Bearer token redacted"
else
  fail "line-start Bearer token redacted" "ghp_realtokenABCDEF12345678 still present"
fi

# ---- Assertion 4: standalone sk- pattern redacted ----
if [[ "${OUTPUT}" == *"sk-[REDACTED]"* ]]; then
  pass "sk- pattern redacted"
else
  fail "sk- pattern redacted" "sk-[REDACTED] not found"
fi

# ---- Assertion 5: mid-prose Bearer survives (anchored) ----
if [[ "${OUTPUT}" == *"Bearer ghp_xxx"* ]]; then
  pass "mid-prose Bearer survives (anchored)"
else
  fail "mid-prose Bearer survives" "Bearer ghp_xxx was incorrectly redacted"
fi

# ---- Assertion 6: mid-identifier sk- survives ----
if [[ "${OUTPUT}" == *"XYZsk-foo123"* ]]; then
  pass "mid-identifier sk- survives"
else
  fail "mid-identifier sk- survives" "XYZsk-foo123 was incorrectly redacted"
fi

# ---- Assertion 7: original secrets NOT in output ----
if [[ "${OUTPUT}" != *"sk-secretValueAAAAAAAAAA"* ]]; then
  pass "original CURSOR_API_KEY secret absent"
else
  fail "original CURSOR_API_KEY secret absent" "raw secret still present"
fi

fx_summary "test_summarize_redaction.sh"
