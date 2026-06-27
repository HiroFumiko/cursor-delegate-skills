#!/usr/bin/env bash
# test_summarize.sh — unit tests for summarize.sh
#
# Covers:
#   1. YAML-ish frontmatter has all required fields sourced from meta.json
#   2. ## Summary section contains (truncated) result text
#   3. ## Artifacts section has absolute paths
#   4. Malformed JSON case -> status: malformed in frontmatter
#
# Requires: jq
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_summarize.sh — jq not found\n'
  exit 77
fi

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUMMARIZE_SH="${REAL_SKILL_DIR}/lib/summarize.sh"

if [[ ! -f "${SUMMARIZE_SH}" ]]; then
  printf 'SKIP test_summarize.sh — summarize.sh not found at %s\n' "${SUMMARIZE_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-summarize.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}/.cursor"

FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

JOB_ID="test-sum-$(date -u +%Y%m%d-%H%M%S)-abcdef12"

OUT_DIR="${FAKE_CWD}/.cursor/delegate"
META="${OUT_DIR}/${JOB_ID}.meta.json"
RAW="${OUT_DIR}/${JOB_ID}.json"
SUMMARY="${OUT_DIR}/${JOB_ID}.summary.md"

STARTED_AT="2026-04-24T06:00:00.000Z"
COMPLETED_AT="2026-04-24T06:00:03.456Z"

# ---- Write fake meta.json ---------------------------------------------------

jq -n \
  --arg job_id        "${JOB_ID}" \
  --arg task_type     "review" \
  --arg model         "gpt-5.4-high" \
  --arg mode          "ask" \
  --arg worktree      "none" \
  --arg session_id    "chat-12345678" \
  --arg started_at    "${STARTED_AT}" \
  --arg completed_at  "${COMPLETED_AT}" \
  '{
    job_id:         $job_id,
    task_type:      $task_type,
    resolved_model: $model,
    mode:           $mode,
    worktree:       $worktree,
    session_id:     $session_id,
    pid:            42,
    started_at:     $started_at,
    completed_at:   $completed_at,
    duration_ms:    3456,
    exit_code:      0,
    status:         "completed"
  }' >"${META}"

# ---- Write fake raw JSON result ---------------------------------------------

jq -n \
  --arg result     "This is the review result. Found no critical issues." \
  --arg session_id "chat-12345678" \
  '{
    result:      $result,
    session_id:  $session_id,
    duration_ms: 3456,
    exit_code:   0
  }' >"${RAW}"

# ---- Run summarize.sh -------------------------------------------------------

SUMMARY_OUT="$(bash "${SUMMARIZE_SH}" "${JOB_ID}")"

if [[ ! -f "${SUMMARY}" ]]; then
  fail "summary file created" "file not found: ${SUMMARY}"
  printf '\ntest_summarize.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
  exit 1
fi

pass "summary file created"

# Verify returned path is absolute.
if [[ "${SUMMARY_OUT}" == /* ]]; then
  pass "summarize.sh stdout is absolute path"
else
  fail "summarize.sh stdout is absolute path" "got: ${SUMMARY_OUT}"
fi

CONTENT="$(cat "${SUMMARY}")"

# ---- Test 2: required frontmatter fields ------------------------------------

check_frontmatter() {
  local field="$1" expected_substr="$2"
  # Frontmatter is between first --- and second ---.
  local fm
  fm="$(awk '/^---$/{n++; if(n==2)exit} n==1 && !/^---$/{print}' "${SUMMARY}")"
  if printf '%s\n' "${fm}" | grep -q "^${field}:"; then
    local val
    val="$(printf '%s\n' "${fm}" | grep "^${field}:" | sed "s/^${field}: *//")"
    if [[ -n "${expected_substr}" ]]; then
      if [[ "${val}" == *"${expected_substr}"* ]]; then
        pass "frontmatter ${field} contains '${expected_substr}'"
      else
        fail "frontmatter ${field}" "expected '${expected_substr}', got '${val}'"
      fi
    else
      pass "frontmatter has ${field} field"
    fi
  else
    fail "frontmatter missing field: ${field}" ""
  fi
}

check_frontmatter "task_type"     "review"
check_frontmatter "resolved_model" "gpt-5.4-high"
check_frontmatter "mode"          "ask"
check_frontmatter "worktree"      "none"
check_frontmatter "started_at"    "2026-04-24"
check_frontmatter "completed_at"  "2026-04-24"
check_frontmatter "duration_ms"   "3456"
check_frontmatter "exit_code"     "0"
check_frontmatter "status"        "completed"
check_frontmatter "session_id"    "chat-12345678"

# ---- Test 3: ## Summary section contains result text -----------------------

if printf '%s\n' "${CONTENT}" | grep -q '## Summary'; then
  pass "## Summary section present"
else
  fail "## Summary section" "not found in summary.md"
fi

if printf '%s\n' "${CONTENT}" | grep -q "review result"; then
  pass "## Summary contains result text"
else
  fail "## Summary contains result text" "text not found in summary"
fi

# ---- Test 4: ## Artifacts section has absolute paths -----------------------

if printf '%s\n' "${CONTENT}" | grep -q '## Artifacts'; then
  pass "## Artifacts section present"
else
  fail "## Artifacts section" "not found in summary.md"
fi

# Each artifact path should be absolute (start with /).
ARTIFACT_PATHS="$(printf '%s\n' "${CONTENT}" | grep -E '^- (meta|raw json|stderr): `/' || true)"
ARTIFACT_COUNT="$(printf '%s\n' "${ARTIFACT_PATHS}" | grep -c '`/' || true)"
if (( ARTIFACT_COUNT >= 3 )); then
  pass "## Artifacts has 3 absolute paths"
else
  fail "## Artifacts absolute paths" "found only ${ARTIFACT_COUNT}, expected >= 3"
fi

# ---- Test 5: Malformed JSON -> status: malformed ----------------------------

JOB_BAD="test-sum-bad-$(cd_rand 8 2>/dev/null || printf 'xxxxxxxx')"
META_BAD="${OUT_DIR}/${JOB_BAD}.meta.json"
RAW_BAD="${OUT_DIR}/${JOB_BAD}.json"
ERR_BAD="${OUT_DIR}/${JOB_BAD}.err"
SUMMARY_BAD="${OUT_DIR}/${JOB_BAD}.summary.md"

# Write valid meta.
jq -n \
  --arg job_id     "${JOB_BAD}" \
  '{
    job_id:         $job_id,
    task_type:      "plan",
    resolved_model: "gpt-5.4-high",
    mode:           "plan",
    worktree:       null,
    session_id:     null,
    pid:            0,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:00:01.000Z",
    duration_ms:    1000,
    exit_code:      1,
    status:         "failed"
  }' >"${META_BAD}"

# Write INVALID JSON as raw output.
printf 'not-valid-json{{{' >"${RAW_BAD}"
printf 'some error output\nfatal: crash\n' >"${ERR_BAD}"

bash "${SUMMARIZE_SH}" "${JOB_BAD}" >/dev/null 2>/dev/null || true

if [[ -f "${SUMMARY_BAD}" ]]; then
  pass "malformed JSON: summary file still created"
  FM_BAD="$(awk '/^---$/{n++; if(n==2)exit} n==1 && !/^---$/{print}' "${SUMMARY_BAD}")"
  STATUS_BAD="$(printf '%s\n' "${FM_BAD}" | grep '^status:' | sed 's/^status: *//' || true)"
  if [[ "${STATUS_BAD}" == "malformed" ]]; then
    pass "malformed JSON: frontmatter status=malformed"
  else
    fail "malformed JSON frontmatter status" "expected malformed, got '${STATUS_BAD}'"
  fi
else
  fail "malformed JSON: summary file created" "file missing: ${SUMMARY_BAD}"
fi

# ---- Helper: cd_rand may not be available outside a sourced lib_common ------
# We sourced lib_common earlier indirectly via SUMMARIZE_SH's subprocess;
# define a fallback here for our own use above.
cd_rand() { tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "${1:-8}"; }

# ---- Summary ----------------------------------------------------------------

printf '\ntest_summarize.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
