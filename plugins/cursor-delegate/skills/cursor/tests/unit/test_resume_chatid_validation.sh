#!/usr/bin/env bash
# test_resume_chatid_validation.sh — V2 regression guard for chatId validation.
#
# Verifies resume.sh rejects invalid chatIds with exit 64.

set -euo pipefail

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REAL_SKILL_DIR}/tests/fixtures/lib.sh"

RESUME_SH="${REAL_SKILL_DIR}/lib/resume.sh"
[[ -f "${RESUME_SH}" ]] || { printf 'SKIP — resume.sh not found\n'; exit 77; }
command -v jq >/dev/null 2>&1 || { printf 'SKIP — jq not found\n'; exit 77; }

TMPDIR_TEST="$(mktemp -d -t cd-test-chatid.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
setup_fake_home "${FAKE_HOME}"
setup_fake_cwd "${FAKE_CWD}"
install_fake_agent "${FAKE_BIN}"

FAKE_SKILL="${TMPDIR_TEST}/skill"
setup_fake_skill_dir "${FAKE_SKILL}"

cd "${FAKE_CWD}"

run_resume() {
  local chat_id="$1" prompt="$2"
  PATH="${FAKE_BIN}:${PATH}" HOME="${FAKE_HOME}" \
    CURSOR_API_KEY="fake-key" \
    CURSOR_DELEGATE_QUARANTINE_HOOKS=0 \
    CD_SKILL_CONFIG="${FAKE_SKILL}/config/model.json" \
    CD_USER_CONFIG="${FAKE_HOME}/.cursor.json" \
    bash "${RESUME_SH}" "${chat_id}" "${prompt}" 2>/dev/null
}

# ---- Test 1: leading dash rejected ----
set +e
run_resume "-evil" "test prompt"
EC=$?
set -e
if [[ "${EC}" -eq 64 ]]; then
  pass "leading dash chatId -> exit 64"
else
  fail "leading dash chatId -> exit 64" "got exit ${EC}"
fi

# ---- Test 2: semicolon rejected ----
set +e
run_resume "abc;rm -rf /" "test prompt"
EC=$?
set -e
if [[ "${EC}" -eq 64 ]]; then
  pass "semicolon in chatId -> exit 64"
else
  fail "semicolon in chatId -> exit 64" "got exit ${EC}"
fi

# ---- Test 3: space rejected ----
set +e
run_resume "abc def" "test prompt"
EC=$?
set -e
if [[ "${EC}" -eq 64 ]]; then
  pass "space in chatId -> exit 64"
else
  fail "space in chatId -> exit 64" "got exit ${EC}"
fi

# ---- Test 4: valid chatId passes validation (may fail later on agent, but not 64) ----
set +e
run_resume "abc-123_def.456" "test prompt"
EC=$?
set -e
if [[ "${EC}" -ne 64 ]]; then
  pass "valid chatId passes validation (exit ${EC}, not 64)"
else
  fail "valid chatId passes validation" "got exit 64 (rejected by validator)"
fi

fx_summary "test_resume_chatid_validation.sh"
