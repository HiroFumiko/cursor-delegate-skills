#!/usr/bin/env bash
# test_summarize.sh — unit tests for summarize.sh
#
# Covers:
#   1. YAML-ish frontmatter has all required fields sourced from meta.json
#   2. ## Summary section contains (truncated) result text
#   3. ## Artifacts section has absolute paths
#   4. Malformed JSONL case -> status: malformed in frontmatter
#   5. stream-json completed run -> result text from trailing type==result line
#   6. stream-json truncated run (no result line, meta timed_out) ->
#      status stays timed_out + partial assistant text + tool activity
#   7. stream-json truncated run with empty output, meta timed_out ->
#      status stays timed_out (never malformed)
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
  # Regression pin: the .err tail must be rendered under ## Errors.
  if grep -q '## Errors' "${SUMMARY_BAD}" \
    && grep -q 'fatal: crash' "${SUMMARY_BAD}"; then
    pass "malformed JSON: .err tail rendered under ## Errors"
  else
    fail "malformed JSON errors section" "## Errors or err tail missing"
  fi
else
  fail "malformed JSON: summary file created" "file missing: ${SUMMARY_BAD}"
fi

# ---- Test 6: stream-json completed run -> result line wins -------------------

JOB_SJ="test-sum-sj-ok"
META_SJ="${OUT_DIR}/${JOB_SJ}.meta.json"
RAW_SJ="${OUT_DIR}/${JOB_SJ}.json"
ERR_SJ="${OUT_DIR}/${JOB_SJ}.err"
SUMMARY_SJ="${OUT_DIR}/${JOB_SJ}.summary.md"

jq -n \
  --arg job_id "${JOB_SJ}" \
  '{
    job_id:         $job_id,
    task_type:      "review",
    resolved_model: "auto",
    mode:           "ask",
    worktree:       "none",
    session_id:     "sess-stream-ok",
    pid:            42,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:00:03.000Z",
    duration_ms:    3000,
    exit_code:      0,
    status:         "completed"
  }' >"${META_SJ}"

# assistant chatter + tool call + trailing result line (real stream-json shape).
cat >"${RAW_SJ}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PARTIAL-CHATTER-IGNORED"}]},"session_id":"sess-stream-ok"}
{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"shellToolCall":{"args":{"command":"rg foo src"}}},"session_id":"sess-stream-ok"}
{"type":"result","subtype":"success","is_error":false,"result":"FINAL-RESULT-TEXT","session_id":"sess-stream-ok"}
EOF
: >"${ERR_SJ}"

bash "${SUMMARIZE_SH}" "${JOB_SJ}" >/dev/null 2>/dev/null || true

if grep -q 'FINAL-RESULT-TEXT' "${SUMMARY_SJ}" \
  && ! grep -q 'PARTIAL-CHATTER-IGNORED' "${SUMMARY_SJ}" \
  && grep -q '^status: completed$' "${SUMMARY_SJ}"; then
  pass "stream-json completed: result text from result line, status kept"
else
  fail "stream-json completed" "$(head -20 "${SUMMARY_SJ}" 2>/dev/null)"
fi

# ---- Test 7: truncated stream (no result line), meta timed_out ---------------

JOB_TO="test-sum-sj-timeout"
META_TO="${OUT_DIR}/${JOB_TO}.meta.json"
RAW_TO="${OUT_DIR}/${JOB_TO}.json"
ERR_TO="${OUT_DIR}/${JOB_TO}.err"
SUMMARY_TO="${OUT_DIR}/${JOB_TO}.summary.md"

jq -n \
  --arg job_id "${JOB_TO}" \
  '{
    job_id:         $job_id,
    task_type:      "review",
    resolved_model: "auto",
    mode:           "ask",
    worktree:       "none",
    session_id:     "sess-stream-partial",
    pid:            42,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:09:50.000Z",
    duration_ms:    590000,
    exit_code:      124,
    status:         "timed_out"
  }' >"${META_TO}"

# No result line: only assistant progress + tool calls before the cutoff.
# The trailing line is cut mid-event (as a SIGKILLed stream would be) and
# must be skipped without breaking extraction.
cat >"${RAW_TO}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PARTIAL-PROGRESS-ALPHA"}]},"session_id":"sess-stream-partial"}
{"type":"tool_call","subtype":"started","call_id":"c2","tool_call":{"shellToolCall":{"args":{"command":"rg bar src"}}},"session_id":"sess-stream-partial"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PARTIAL-PROGRESS-BETA"}]},"session_id":"sess-stream-partial"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"CUT-MID-EV
EOF
: >"${ERR_TO}"

bash "${SUMMARIZE_SH}" "${JOB_TO}" >/dev/null 2>/dev/null || true

if grep -q '^status: timed_out$' "${SUMMARY_TO}"; then
  pass "truncated stream: status stays timed_out (not malformed)"
else
  fail "truncated stream status" "$(grep '^status:' "${SUMMARY_TO}" 2>/dev/null)"
fi

if grep -q 'PARTIAL-PROGRESS-ALPHA' "${SUMMARY_TO}" \
  && grep -q 'PARTIAL-PROGRESS-BETA' "${SUMMARY_TO}" \
  && grep -q 'Partial result (incomplete)' "${SUMMARY_TO}"; then
  pass "truncated stream: partial assistant text rendered"
else
  fail "truncated stream partial text" "$(grep -A3 '## Summary' "${SUMMARY_TO}" 2>/dev/null | head -10)"
fi

if grep -q 'rg bar src' "${SUMMARY_TO}" \
  && grep -q 'Tool activity before cutoff' "${SUMMARY_TO}"; then
  pass "truncated stream: tool activity listed"
else
  fail "truncated stream tool activity" "$(grep -A5 'Tool activity' "${SUMMARY_TO}" 2>/dev/null | head -8)"
fi

if ! grep -q 'CUT-MID-EV' "${SUMMARY_TO}"; then
  pass "truncated stream: cut-mid-event line skipped"
else
  fail "truncated stream mid-event" "partial event fragment leaked into summary"
fi

# ---- Test 7a: tool summary caps a huge embedded command --------------------

JOB_TC="test-sum-toolcap"
META_TC="${OUT_DIR}/${JOB_TC}.meta.json"
RAW_TC="${OUT_DIR}/${JOB_TC}.json"
SUMMARY_TC="${OUT_DIR}/${JOB_TC}.summary.md"

jq -n \
  --arg job_id "${JOB_TC}" \
  '{
    job_id:         $job_id,
    task_type:      "review",
    resolved_model: "auto",
    mode:           "ask",
    worktree:       "none",
    session_id:     "sess-toolcap",
    pid:            42,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:09:50.000Z",
    duration_ms:    590000,
    exit_code:      124,
    status:         "timed_out"
  }' >"${META_TC}"

# One tool_call whose command embeds a 5KB heredoc-like blob.
BIG_CMD="do-stuff $(printf 'Z%.0s' $(seq 1 5000))"
jq -c -R -s -n --arg cmd "${BIG_CMD}" \
  '[{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PROG"}]},"session_id":"s"},
    {"type":"tool_call","subtype":"started","call_id":"c","tool_call":{"shellToolCall":{"args":{"command": $cmd}}},"session_id":"s"}]
   | .[]' >"${RAW_TC}"

bash "${SUMMARIZE_SH}" "${JOB_TC}" >/dev/null 2>/dev/null || true

TOOL_BYTES="$(awk '/^### Tool activity/{f=1;next} /^## [^#]/{f=0} f' "${SUMMARY_TC}" | wc -c | tr -d ' ')"
if [[ "${TOOL_BYTES}" -lt 2000 ]] && grep -q 'do-stuff' "${SUMMARY_TC}"; then
  pass "tool activity: huge command capped (${TOOL_BYTES}B)"
else
  fail "tool activity cap" "tool section is ${TOOL_BYTES}B"
fi

# ---- Test 7b: single-event stream + timed_out -> partial path, not legacy --

JOB_TS="test-sum-single-event"
META_TS="${OUT_DIR}/${JOB_TS}.meta.json"
RAW_TS="${OUT_DIR}/${JOB_TS}.json"
SUMMARY_TS="${OUT_DIR}/${JOB_TS}.summary.md"

jq -n \
  --arg job_id "${JOB_TS}" \
  '{
    job_id:         $job_id,
    task_type:      "review",
    resolved_model: "auto",
    mode:           "ask",
    worktree:       "none",
    session_id:     "sess-single",
    pid:            42,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:09:50.000Z",
    duration_ms:    590000,
    exit_code:      124,
    status:         "timed_out"
  }' >"${META_TS}"

printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"SINGLE-EVENT-PARTIAL"}]},"session_id":"sess-single"}\n' >"${RAW_TS}"

bash "${SUMMARIZE_SH}" "${JOB_TS}" >/dev/null 2>/dev/null || true

if grep -q '^status: timed_out$' "${SUMMARY_TS}" \
  && grep -q 'SINGLE-EVENT-PARTIAL' "${SUMMARY_TS}"; then
  pass "single-event stream: partial text kept, status timed_out"
else
  fail "single-event stream" "$(grep -E '^status:|SINGLE' "${SUMMARY_TS}" 2>/dev/null)"
fi

# ---- Test 8: empty raw output, meta timed_out -> stays timed_out ------------

JOB_TE="test-sum-empty-timeout"
META_TE="${OUT_DIR}/${JOB_TE}.meta.json"
RAW_TE="${OUT_DIR}/${JOB_TE}.json"
SUMMARY_TE="${OUT_DIR}/${JOB_TE}.summary.md"

jq -n \
  --arg job_id "${JOB_TE}" \
  '{
    job_id:         $job_id,
    task_type:      "review",
    resolved_model: "auto",
    mode:           "ask",
    worktree:       "none",
    session_id:     null,
    pid:            42,
    started_at:     "2026-04-24T06:00:00.000Z",
    completed_at:   "2026-04-24T06:09:50.000Z",
    duration_ms:    590000,
    exit_code:      124,
    status:         "timed_out"
  }' >"${META_TE}"
: >"${RAW_TE}"

bash "${SUMMARIZE_SH}" "${JOB_TE}" >/dev/null 2>/dev/null || true

if grep -q '^status: timed_out$' "${SUMMARY_TE}"; then
  pass "empty output + timed_out meta: status stays timed_out"
else
  fail "empty output timed_out status" "$(grep '^status:' "${SUMMARY_TE}" 2>/dev/null)"
fi
# We sourced lib_common earlier indirectly via SUMMARIZE_SH's subprocess;
# define a fallback here for our own use above.
cd_rand() { tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "${1:-8}"; }

# ---- Summary ----------------------------------------------------------------

printf '\ntest_summarize.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
