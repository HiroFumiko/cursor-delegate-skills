#!/usr/bin/env bash
# test_fanout_parse.sh — unit tests for fanout.sh helper functions:
#   - cd_parse_pair: only first ':' delimits task from prompt
#   - cd_valid_task: accepts 5 valid types, rejects "foo"
#   - cd_shquote: escapes single quotes
#
# This test runs WITHOUT jq dependency (pure-bash function tests).
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"
FANOUT_SH="${REAL_SKILL_DIR}/lib/fanout.sh"

if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_fanout_parse.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"
  exit 77
fi

if [[ ! -f "${FANOUT_SH}" ]]; then
  printf 'SKIP test_fanout_parse.sh — fanout.sh not found at %s\n' "${FANOUT_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-fanout-parse.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}/.cursor"

FAKE_CWD="${TMPDIR_TEST}/project"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

# Provide a minimal model.json so cd_state_dir/cd_output_dir work if called.
FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "composer-2",   "force": true, "worktree": true, "sandbox": "enabled" },
    "review":      { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" },
    "plan":        { "model": "gpt-5.4-high", "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "gpt-5.4-high", "mode": "ask",  "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

# Source lib_common first (required by fanout.sh functions).
export CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
export CD_USER_CONFIG="${HOME}/.cursor.json"
export CD_PROJECT_CONFIG=".cursor.json"

# shellcheck source=../../lib/lib_common.sh
source "${LIB_COMMON}"
CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"

# Source only the three helper functions from fanout.sh, not the main()
# entrypoint.  fanout.sh ends with `main "$@"` which would exit 64 if sourced
# directly.  We extract just the functions we need via awk into a temp file.
_FANOUT_HELPERS="${TMPDIR_TEST}/fanout_helpers.sh"
awk '
  # Print shebang + set line from fanout.sh header
  /^set -euo pipefail/ { print; next }
  # Capture these three function definitions
  /^cd_shquote\(\)|^cd_valid_task\(\)|^cd_parse_pair\(\)/ { capture=1 }
  capture { print }
  # End capture at closing brace on its own line
  capture && /^\}$/ { capture=0 }
' "${FANOUT_SH}" > "${_FANOUT_HELPERS}"
# shellcheck source=/dev/null
source "${_FANOUT_HELPERS}"

# ---- Test 1: cd_parse_pair - basic case -------------------------------------

TASK=""; PROMPT=""
cd_parse_pair "review:file.ts:42 audit this"

if [[ "${TASK}" == "review" ]]; then
  pass "cd_parse_pair: task = 'review'"
else
  fail "cd_parse_pair basic task" "expected 'review', got '${TASK}'"
fi

# Critical: only first ':' delimits; rest belongs to prompt.
if [[ "${PROMPT}" == "file.ts:42 audit this" ]]; then
  pass "cd_parse_pair: prompt = 'file.ts:42 audit this' (colons preserved)"
else
  fail "cd_parse_pair colons in prompt" "expected 'file.ts:42 audit this', got '${PROMPT}'"
fi

# ---- Test 2: cd_parse_pair - simple case (no extra colons) ------------------

TASK=""; PROMPT=""
cd_parse_pair "security:check auth module"

if [[ "${TASK}" == "security" && "${PROMPT}" == "check auth module" ]]; then
  pass "cd_parse_pair: simple pair (no extra colons)"
else
  fail "cd_parse_pair simple" "task='${TASK}' prompt='${PROMPT}'"
fi

# ---- Test 3: cd_parse_pair - multiple colons in prompt ----------------------

TASK=""; PROMPT=""
cd_parse_pair "implement:fix src/a.ts:10 and src/b.ts:20"

if [[ "${TASK}" == "implement" && "${PROMPT}" == "fix src/a.ts:10 and src/b.ts:20" ]]; then
  pass "cd_parse_pair: multiple colons in prompt preserved"
else
  fail "cd_parse_pair multiple colons" "task='${TASK}' prompt='${PROMPT}'"
fi

# ---- Test 4: cd_parse_pair - invalid task -> exits non-zero ----------------

set +e
(
  TASK=""; PROMPT=""
  cd_parse_pair "foo:some prompt" 2>/dev/null
)
EC=$?
set -e

if (( EC != 0 )); then
  pass "cd_parse_pair: invalid task_type exits non-zero"
else
  fail "cd_parse_pair invalid task" "expected non-zero exit, got 0"
fi

# ---- Test 5: cd_parse_pair - missing ':' -> exits non-zero -----------------

set +e
(
  TASK=""; PROMPT=""
  cd_parse_pair "review-no-colon" 2>/dev/null
)
EC=$?
set -e

if (( EC != 0 )); then
  pass "cd_parse_pair: missing ':' exits non-zero"
else
  fail "cd_parse_pair missing colon" "expected non-zero exit, got 0"
fi

# ---- Test 6: cd_valid_task - all 5 valid types ------------------------------

for t in implement review plan investigate security; do
  if cd_valid_task "${t}"; then
    pass "cd_valid_task: '${t}' accepted"
  else
    fail "cd_valid_task: '${t}' should be accepted"
  fi
done

# ---- Test 7: cd_valid_task - invalid types rejected -------------------------

for t in foo "" "REVIEW" "impl" "implementit" "sec"; do
  if ! cd_valid_task "${t}"; then
    pass "cd_valid_task: '${t}' rejected"
  else
    fail "cd_valid_task: '${t}' should be rejected" "returned 0"
  fi
done

# ---- Test 8: cd_shquote - no special characters -----------------------------

QUOTED="$(cd_shquote "hello world")"
if [[ "${QUOTED}" == "'hello world'" ]]; then
  pass "cd_shquote: simple string wrapped in single quotes"
else
  fail "cd_shquote simple" "expected \"'hello world'\", got '${QUOTED}'"
fi

# ---- Tests 9-11: cd_shquote round-trips quotes / backslashes ---------------
#
# bash 3.2 (macOS stock /bin/bash) mis-parses a literal ' inside any $(...) and
# aborts with "unexpected EOF" — so we never write an apostrophe (or '...' /
# "...'...") literally inside a command substitution. Inputs are built from the
# ${sq} (single quote) and ${bs} (backslash) vars; the eval round-trip runs via
# the top-level rt() helper whose '%s' lives in a function body, not in $().
sq=\'
bs=\\
rt() { eval "printf '%s' $1"; }

# Test 9: single quote  (it's a test)
IN="it${sq}s a test"
Q="$(cd_shquote "${IN}")"
GOT="$(rt "${Q}")"
if [[ "${GOT}" == "${IN}" ]]; then
  pass "cd_shquote: single quote escaped (round-trip)"
else
  fail "cd_shquote single quote" "got [${GOT}] expected [${IN}]"
fi

# Test 10: multiple single quotes  (don't stop can't stop)
IN="don${sq}t stop can${sq}t stop"
Q="$(cd_shquote "${IN}")"
GOT="$(rt "${Q}")"
if [[ "${GOT}" == "${IN}" ]]; then
  pass "cd_shquote: multiple single quotes escaped (round-trip)"
else
  fail "cd_shquote multiple single quotes" "got [${GOT}] expected [${IN}]"
fi

# Test 11: embedded backslash  (path\to\file)
IN="path${bs}to${bs}file"
Q="$(cd_shquote "${IN}")"
GOT="$(rt "${Q}")"
if [[ "${GOT}" == "${IN}" ]]; then
  pass "cd_shquote: backslash preserved (round-trip)"
else
  fail "cd_shquote backslash" "got [${GOT}] expected [${IN}]"
fi

# ---- Test 12: cd_shquote - empty string -------------------------------------

QUOTED="$(cd_shquote "")"
if [[ "${QUOTED}" == "''" ]]; then
  pass "cd_shquote: empty string -> ''"
else
  fail "cd_shquote empty string" "expected \"''\", got '${QUOTED}'"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_fanout_parse.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
