#!/usr/bin/env bash
# test_preflight.sh — unit tests for cd_preflight:
#   - missing binary -> exit 2
#   - binary OK but model not in --list-models -> exit 3
#   - all OK -> exit 0
#
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"

if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_preflight.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"
  exit 77
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_preflight.sh — jq not found\n'
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-preflight.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_CWD}" "${FAKE_BIN}"
cd "${FAKE_CWD}"

# Create .omc dirs so cd_output_dir / cd_state_dir succeed without agent.
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"

# Fake model.json for config resolution (needed by sourcing lib_common).
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

# Helper: run cd_preflight in a subprocess with a controlled PATH and HOME.
run_preflight() {
  local task="$1" model="$2"
  local extra_path="${3:-}"
  local fake_home="${4:-${FAKE_HOME}}"
  local cursor_api="${5:-}"

  # Build a tiny sourcing script that sets up the env and calls cd_preflight.
  local script
  script="$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="${fake_home}"
${cursor_api:+export CURSOR_API_KEY="${cursor_api}"}
export CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
export CD_USER_CONFIG="${fake_home}/.cursor.json"
export CD_PROJECT_CONFIG=".cursor.json"
source "${LIB_COMMON}"
CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
cd_preflight "${task}" "${model}"
EOF
  )"
  if [[ -n "${extra_path}" ]]; then
    # Build a PATH that uses extra_path first, then system dirs MINUS those
    # containing an `agent` binary. Prevents the real agent from leaking through.
    local _rp_path="${extra_path}"
    local _rp_oldifs="${IFS}"
    IFS=':'
    for _rp_d in ${PATH}; do
      [[ -x "${_rp_d}/agent" ]] || _rp_path="${_rp_path}:${_rp_d}"
    done
    IFS="${_rp_oldifs}"
    PATH="${_rp_path}" bash -c "${script}"
  else
    bash -c "${script}"
  fi
}

# ---- Test 1: missing agent binary -> exit 2 ---------------------------------

# Use a PATH that has jq + timeout but NOT agent.
NOAGENT_BIN="${TMPDIR_TEST}/noagent"
mkdir -p "${NOAGENT_BIN}"

# Copy/link jq and timeout so they're available.
for b in jq timeout; do
  if command -v "${b}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${b}")" "${NOAGENT_BIN}/${b}" 2>/dev/null || cp "$(command -v "${b}")" "${NOAGENT_BIN}/${b}"
  fi
done

set +e
run_preflight review good-model "${NOAGENT_BIN}" "${FAKE_HOME}" 2>/dev/null
EC=$?
set -e

if [[ "${EC}" -eq 2 ]]; then
  pass "missing agent -> exit 2"
else
  fail "missing agent -> exit 2" "got exit ${EC}"
fi

# ---- Test 2: agent present but --list-models misses the model -> exit 3 -----

# Stub agent: exits 0, outputs one known model but NOT our requested model.
cat >"${FAKE_BIN}/agent" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-models" ]]; then
  printf 'only-model-here\nsome-other-model\n'
  exit 0
fi
exit 0
STUB
chmod +x "${FAKE_BIN}/agent"

# Also need jq and timeout in the fake bin.
for b in jq timeout; do
  if command -v "${b}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${b}")" "${FAKE_BIN}/${b}" 2>/dev/null || cp "$(command -v "${b}")" "${FAKE_BIN}/${b}"
  fi
done

# Use CURSOR_API_KEY to bypass auth check; model "nonexistent-model" not in list.
set +e
run_preflight review nonexistent-model "${FAKE_BIN}" "${FAKE_HOME}" "fake-key" 2>/dev/null
EC=$?
set -e

if [[ "${EC}" -eq 3 ]]; then
  pass "--list-models misses model -> exit 3"
else
  fail "--list-models misses model -> exit 3" "got exit ${EC}"
fi

# ---- Test 3: all OK -> exit 0 -----------------------------------------------

# Stub agent: --list-models returns "good-model".
cat >"${FAKE_BIN}/agent" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-models" ]]; then
  printf 'good-model\ncomposer-2\n'
  exit 0
fi
exit 0
STUB
chmod +x "${FAKE_BIN}/agent"

set +e
run_preflight review good-model "${FAKE_BIN}" "${FAKE_HOME}" "fake-key" 2>/dev/null
EC=$?
set -e

if [[ "${EC}" -eq 0 ]]; then
  pass "all OK -> exit 0"
else
  fail "all OK -> exit 0" "got exit ${EC}"
fi

# ---- Test 4: no CURSOR_API_KEY and no ~/.cursor artifacts -> exit 2 ---------

# Create a fresh fake home with NO .cursor directory at all.
EMPTY_HOME="${TMPDIR_TEST}/empty-home"
mkdir -p "${EMPTY_HOME}"

# Ensure CURSOR_API_KEY is NOT set for this test.
unset CURSOR_API_KEY 2>/dev/null || true

set +e
(
  unset CURSOR_API_KEY 2>/dev/null || true
  PATH="${FAKE_BIN}:${PATH}" HOME="${EMPTY_HOME}" \
  CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json" \
  CD_USER_CONFIG="${EMPTY_HOME}/.cursor.json" \
  bash -c "source '${LIB_COMMON}'; CD_SKILL_CONFIG='${FAKE_SKILL_DIR}/config/model.json'; cd_preflight review good-model"
) 2>/dev/null
EC=$?
set -e

if [[ "${EC}" -eq 2 ]]; then
  pass "no auth artifacts -> exit 2"
else
  fail "no auth artifacts -> exit 2" "got exit ${EC}"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_preflight.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
