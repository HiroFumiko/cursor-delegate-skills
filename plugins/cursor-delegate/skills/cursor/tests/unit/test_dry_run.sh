#!/usr/bin/env bash
# test_dry_run.sh — unit tests for dispatch.sh --dry-run / --debug behavior.
#
# Covers:
#   --dry-run:
#     - exits 0 and keeps the 2-line stdout contract (JOB_ID first, summary last)
#     - summary file carries `status: dry_run` + the planned command block
#     - the real `agent` invocation is SKIPPED (only --list-models preflight runs)
#     - ~/.cursor/hooks.json is NOT quarantined (no side effects in dry-run)
#     - `--dry-run` implies `--debug` (stderr has [cursor][DEBUG] breadcrumbs)
#   --debug (without dry-run):
#     - emits [cursor][DEBUG] breadcrumbs on stderr
#     - the real `agent` invocation DOES happen (regression guard)
#
# Uses the shared fake-agent fixture with FAKE_AGENT_RECORD to observe whether
# the real `agent` call fired.
# Requires: jq
# Exit 0 = PASS, non-zero = FAIL, 77 = SKIP.

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_dry_run.sh — jq not found\n'
  exit 77
fi

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"
FIXTURES_DIR="${REAL_SKILL_DIR}/tests/fixtures"

if [[ ! -f "${DISPATCH_SH}" ]]; then
  printf 'SKIP test_dry_run.sh — dispatch.sh not found at %s\n' "${DISPATCH_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-dry-run.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_CWD}" "${FAKE_BIN}"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

# Fake model.json (self-contained; model never validated against a real CLI).
FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "composer-2",   "force": true, "worktree": true, "sandbox": "enabled" },
    "review":      { "model": "good-model",   "mode": "ask", "sandbox": "enabled" },
    "plan":        { "model": "good-model",   "mode": "plan","sandbox": "enabled" },
    "investigate": { "model": "good-model",   "mode": "ask", "sandbox": "enabled" },
    "security":    { "model": "good-model",   "mode": "ask", "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

# Install the shared fake-agent (records every invocation to RECORD_FILE).
cp "${FIXTURES_DIR}/fake-agent.sh" "${FAKE_BIN}/agent"
chmod +x "${FAKE_BIN}/agent"
for b in jq timeout; do
  if command -v "${b}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${b}")" "${FAKE_BIN}/${b}" 2>/dev/null || true
  fi
done

# Common env shared by both runs.
COMMON_ENV=(
  PATH="${FAKE_BIN}:${PATH}"
  HOME="${FAKE_HOME}"
  CURSOR_API_KEY="fake-key"
  FAKE_AGENT_MODELS="good-model"$'\n'"composer-2"
  CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
  CD_USER_CONFIG="${FAKE_HOME}/.cursor.json"
  CD_PROJECT_CONFIG=".cursor.json"
)

# =============================================================================
# Part A — --dry-run
# =============================================================================

# Pre-place a hooks.json so we can prove dry-run does NOT quarantine it.
# (Quarantine is left ENABLED — default — so the test asserts dry-run's skip,
# not the QUARANTINE_HOOKS=0 escape hatch.)
printf '{"version":1,"hooks":{}}\n' >"${FAKE_HOME}/.cursor/hooks.json"

DRY_RECORD="${TMPDIR_TEST}/agent-calls-dry.txt"
: >"${DRY_RECORD}"

DRY_STDOUT="${TMPDIR_TEST}/dry.stdout"
DRY_STDERR="${TMPDIR_TEST}/dry.stderr"

set +e
env "${COMMON_ENV[@]}" FAKE_AGENT_RECORD="${DRY_RECORD}" \
  bash "${DISPATCH_SH}" --dry-run review "dry run contract probe" \
  >"${DRY_STDOUT}" 2>"${DRY_STDERR}"
DRY_EXIT=$?
set -e

# A1: exit 0
if [[ "${DRY_EXIT}" -eq 0 ]]; then
  pass "dry-run: dispatch exits 0"
else
  fail "dry-run exit" "got ${DRY_EXIT}; stderr: $(tail -3 "${DRY_STDERR}" 2>/dev/null)"
fi

# A2: FIRST line is JOB_ID=<id>
DRY_FIRST="$(head -1 "${DRY_STDOUT}")"
if printf '%s\n' "${DRY_FIRST}" | grep -Eq '^JOB_ID=[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$'; then
  pass "dry-run: FIRST stdout line is JOB_ID=<id>"
else
  fail "dry-run FIRST line" "got '${DRY_FIRST}'"
fi

# A3: exactly 2 stdout lines (contract preserved)
DRY_LINES="$(wc -l <"${DRY_STDOUT}")"; DRY_LINES="${DRY_LINES// /}"
if [[ "${DRY_LINES}" -eq 2 ]]; then
  pass "dry-run: stdout has exactly 2 lines"
else
  fail "dry-run stdout line count" "expected 2, got ${DRY_LINES}"
fi

# A4: LAST line is an absolute .summary.md path that exists
DRY_LAST="$(tail -1 "${DRY_STDOUT}")"
if [[ "${DRY_LAST}" == /* && "${DRY_LAST}" == *.summary.md && -f "${DRY_LAST}" ]]; then
  pass "dry-run: LAST line is an existing absolute .summary.md path"
else
  fail "dry-run summary path" "got '${DRY_LAST}'"
fi

# A5: summary carries status: dry_run + planned command
if [[ -f "${DRY_LAST}" ]] && grep -q '^status: dry_run$' "${DRY_LAST}"; then
  pass "dry-run: summary frontmatter has status: dry_run"
else
  fail "dry-run summary status" "status: dry_run not found in ${DRY_LAST}"
fi
if [[ -f "${DRY_LAST}" ]] && grep -q 'Planned command' "${DRY_LAST}"; then
  pass "dry-run: summary includes the planned command block"
else
  fail "dry-run planned command" "'Planned command' not found in ${DRY_LAST}"
fi

# A6: real `agent` call was SKIPPED — record has the --list-models preflight
#     but NOT the `-p ...` invocation.
if grep -q -- '--list-models' "${DRY_RECORD}"; then
  pass "dry-run: preflight ran (--list-models recorded)"
else
  fail "dry-run preflight" "no --list-models in record"
fi
if grep -q -- '-p' "${DRY_RECORD}"; then
  fail "dry-run skips agent" "real 'agent -p' invocation was recorded (should be skipped)"
else
  pass "dry-run: real 'agent -p' invocation was skipped"
fi

# A7: hooks.json NOT quarantined (still in place, no .bak)
if [[ -f "${FAKE_HOME}/.cursor/hooks.json" && ! -f "${FAKE_HOME}/.cursor/hooks.json.cursor.bak" ]]; then
  pass "dry-run: ~/.cursor/hooks.json left untouched (no quarantine)"
else
  fail "dry-run hooks quarantine" "hooks.json moved or .bak created"
fi

# A8: --dry-run implies --debug (breadcrumbs present)
if grep -q '\[cursor\]\[DEBUG\]' "${DRY_STDERR}"; then
  pass "dry-run: implies --debug ([cursor][DEBUG] breadcrumbs on stderr)"
else
  fail "dry-run implies debug" "no [cursor][DEBUG] lines on stderr"
fi

# =============================================================================
# Part B — --debug (real invocation still happens)
# =============================================================================

DBG_RECORD="${TMPDIR_TEST}/agent-calls-debug.txt"
: >"${DBG_RECORD}"

DBG_STDOUT="${TMPDIR_TEST}/dbg.stdout"
DBG_STDERR="${TMPDIR_TEST}/dbg.stderr"

set +e
env "${COMMON_ENV[@]}" \
  CURSOR_DELEGATE_QUARANTINE_HOOKS="0" \
  FAKE_AGENT_RECORD="${DBG_RECORD}" \
  bash "${DISPATCH_SH}" --debug review "debug breadcrumb probe" \
  >"${DBG_STDOUT}" 2>"${DBG_STDERR}"
DBG_EXIT=$?
set -e

# B1: exit 0
if [[ "${DBG_EXIT}" -eq 0 ]]; then
  pass "debug: dispatch exits 0"
else
  fail "debug exit" "got ${DBG_EXIT}; stderr: $(tail -3 "${DBG_STDERR}" 2>/dev/null)"
fi

# B2: [cursor][DEBUG] breadcrumbs present
if grep -q '\[cursor\]\[DEBUG\]' "${DBG_STDERR}"; then
  pass "debug: [cursor][DEBUG] breadcrumbs on stderr"
else
  fail "debug breadcrumbs" "no [cursor][DEBUG] lines on stderr"
fi

# B3: real agent invocation DID happen (regression guard vs dry-run)
if grep -q -- '-p' "${DBG_RECORD}"; then
  pass "debug: real 'agent -p' invocation happened (not a dry-run)"
else
  fail "debug real invocation" "no 'agent -p' recorded"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_dry_run.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
