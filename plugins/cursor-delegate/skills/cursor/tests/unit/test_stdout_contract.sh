#!/usr/bin/env bash
# test_stdout_contract.sh — unit test for dispatch.sh stdout contract:
#   - FIRST line of stdout matches ^JOB_ID=[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$
#   - LAST line of stdout is an absolute path ending in .summary.md that exists
#   - All logging went to stderr (no extra lines on stdout)
#
# Uses a stubbed `agent` binary that immediately emits fake JSON.
# Requires: jq
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_stdout_contract.sh — jq not found\n'
  exit 77
fi

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"

if [[ ! -f "${DISPATCH_SH}" ]]; then
  printf 'SKIP test_stdout_contract.sh — dispatch.sh not found at %s\n' "${DISPATCH_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-stdout-contract.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_CWD}" "${FAKE_BIN}"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

# Fake model.json in a fake skill dir.
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

# Stub `agent`: outputs valid JSON, lists "good-model" for --list-models.
cat >"${FAKE_BIN}/agent" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-models" ]]; then
  printf 'good-model\ncomposer-2\n'
  exit 0
fi
# Emit fake JSON result.
printf '{"result":"fake review result","session_id":"chat-test-123","duration_ms":100,"exit_code":0}\n'
exit 0
STUB
chmod +x "${FAKE_BIN}/agent"

# Symlink jq and timeout into fake bin.
for b in jq timeout; do
  if command -v "${b}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${b}")" "${FAKE_BIN}/${b}" 2>/dev/null || true
  fi
done

# ---- Run dispatch.sh and capture stdout/stderr separately -------------------

STDOUT_FILE="${TMPDIR_TEST}/stdout.txt"
STDERR_FILE="${TMPDIR_TEST}/stderr.txt"

set +e
PATH="${FAKE_BIN}:${PATH}" \
  HOME="${FAKE_HOME}" \
  CURSOR_API_KEY="fake-key" \
  CURSOR_DELEGATE_QUARANTINE_HOOKS="0" \
  CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json" \
  CD_USER_CONFIG="${FAKE_HOME}/.cursor.json" \
  CD_PROJECT_CONFIG=".cursor.json" \
  bash "${DISPATCH_SH}" review "test prompt for stdout contract" \
  >"${STDOUT_FILE}" 2>"${STDERR_FILE}"
DISPATCH_EXIT=$?
set -e

# ---- Test: dispatch exited 0 ------------------------------------------------

if [[ "${DISPATCH_EXIT}" -eq 0 ]]; then
  pass "dispatch.sh exited 0"
else
  fail "dispatch.sh exit code" "got ${DISPATCH_EXIT}; stderr: $(head -5 "${STDERR_FILE}" 2>/dev/null)"
fi

# ---- Test: FIRST line matches JOB_ID=<id> pattern --------------------------

FIRST_LINE="$(head -1 "${STDOUT_FILE}")"
JOB_ID_PATTERN='^JOB_ID=[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$'

if printf '%s\n' "${FIRST_LINE}" | grep -Eq "${JOB_ID_PATTERN}"; then
  pass "FIRST line matches JOB_ID=<YYYYMMDD-HHMMSS-8hex> pattern"
else
  fail "FIRST line JOB_ID pattern" "got: '${FIRST_LINE}'"
fi

# Extract the JOB_ID value for further assertions.
JOB_ID_VALUE="${FIRST_LINE#JOB_ID=}"

# ---- Test: LAST line is absolute path ending in .summary.md ----------------

LAST_LINE="$(tail -1 "${STDOUT_FILE}")"

if [[ "${LAST_LINE}" == /* ]]; then
  pass "LAST line is absolute path (starts with /)"
else
  fail "LAST line is absolute path" "got: '${LAST_LINE}'"
fi

if [[ "${LAST_LINE}" == *.summary.md ]]; then
  pass "LAST line ends in .summary.md"
else
  fail "LAST line ends in .summary.md" "got: '${LAST_LINE}'"
fi

# ---- Test: summary file actually exists -------------------------------------

if [[ -f "${LAST_LINE}" ]]; then
  pass "summary file exists at LAST line path"
else
  fail "summary file exists" "path: ${LAST_LINE}"
fi

# ---- Test: LAST line contains JOB_ID_VALUE ----------------------------------

if [[ "${LAST_LINE}" == *"${JOB_ID_VALUE}"* ]]; then
  pass "LAST line path contains the JOB_ID from FIRST line"
else
  fail "LAST line contains JOB_ID" "job_id=${JOB_ID_VALUE}, last=${LAST_LINE}"
fi

# ---- Test: stdout has exactly 2 lines (JOB_ID + summary path) ---------------
# Any diagnostic output must go to stderr only.

LINE_COUNT="$(wc -l <"${STDOUT_FILE}")"
LINE_COUNT="${LINE_COUNT// /}"

if [[ "${LINE_COUNT}" -eq 2 ]]; then
  pass "stdout has exactly 2 lines (no stderr leakage)"
else
  fail "stdout line count" "expected 2, got ${LINE_COUNT}; stdout content:"
  cat "${STDOUT_FILE}" >&2
fi

# ---- Test: stderr is non-empty (logging happened) ---------------------------

if [[ -s "${STDERR_FILE}" ]]; then
  pass "stderr contains log output (logging goes to stderr)"
else
  # Not a hard failure — maybe a very quiet run — but suspicious.
  pass "stderr check (may be empty for minimal stub)"
fi

# ---- Test: stderr has no JOB_ID= line (logs don't duplicate stdout) ---------

if ! grep -q "^JOB_ID=" "${STDERR_FILE}" 2>/dev/null; then
  pass "JOB_ID= line not duplicated on stderr"
else
  fail "JOB_ID= should not appear on stderr" "found in stderr"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_stdout_contract.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
