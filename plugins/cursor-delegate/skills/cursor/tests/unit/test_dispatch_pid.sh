#!/usr/bin/env bash
# test_dispatch_pid.sh — V1 regression guard
#
# Asserts that dispatch.sh records the agent-child PID in meta.json.pid,
# not the dispatch.sh wrapper shell's $$ (the pre-V1 behavior).
#
# Prior to the V1 fix, meta.pid was $$ (wrapper shell), meaning cancel.sh
# SIGTERMed the wrapper instead of the agent child. This test catches any
# regression to that behavior by asserting meta.pid != dispatch.sh invocation PID.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed"
  exit 77
fi

TMPROOT="$(mktemp -d -t cursor-dispatch-pid-XXXXXX)"
trap 'rm -rf "${TMPROOT}"' EXIT

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${SKILL_DIR}/lib/dispatch.sh"

# Build a fake `agent` binary that sleeps briefly so we can observe the live PID,
# then emits minimal JSON so summarize.sh does not choke.
FAKE_BIN="${TMPROOT}/bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/agent" <<'FAKE'
#!/usr/bin/env bash
# Minimal fake agent: sleep 1, then emit a success JSON.
case "${1:-}" in
  --list-models)
    # Support preflight model-list check.
    printf 'composer-2 - Composer 2\ngpt-5.4-high - GPT-5.4 High\n'
    exit 0
    ;;
esac
sleep 1
cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"result":"fake agent output","session_id":"test-session-00000000"}
JSON
FAKE
chmod +x "${FAKE_BIN}/agent"

# Fake HOME so cd_preflight_hooks does not touch the real ~/.cursor/hooks.json.
export HOME="${TMPROOT}/home"
mkdir -p "${HOME}"

# Redirect the skill's resolved config to use this temp area by cding into
# a temp project root with a fresh .omc/ layout.
export PATH="${FAKE_BIN}:${PATH}"
export CURSOR_DELEGATE_QUARANTINE_HOOKS=0   # No hooks file to quarantine
export CURSOR_API_KEY="${CURSOR_API_KEY:-test-fake-key}"
# Use a fake model.json whose models match the fake agent's --list-models output.
FAKE_SKILL_DIR="${TMPROOT}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/model.json" <<'MODELEOF'
{
  "version": 1,
  "defaults": {
    "implement": { "model": "composer-2", "force": true, "worktree": true, "sandbox": "enabled" },
    "review":    { "model": "gpt-5.4-high", "mode": "ask", "sandbox": "enabled" },
    "plan":      { "model": "gpt-5.4-high", "mode": "plan","sandbox": "enabled" },
    "investigate":{"model": "gpt-5.4-high", "mode": "ask", "sandbox": "enabled" },
    "security":  { "model": "gpt-5.4-high", "mode": "ask", "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 1, "initial_delay_ms": 0, "backoff": "none" },
  "timeout_sec": 590
}
MODELEOF
export CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/model.json"
export CD_USER_CONFIG="${HOME}/.cursor.json"
WORKDIR="${TMPROOT}/work"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Run dispatch.sh in background so we can capture its own PID for comparison.
OUT="${TMPROOT}/out.log"
ERR="${TMPROOT}/err.log"
bash "${DISPATCH_SH}" review "test-prompt" >"${OUT}" 2>"${ERR}" &
DISPATCH_PID=$!

# Wait for it to finish (fake agent sleeps 1s; allow generous slack).
if ! wait "${DISPATCH_PID}"; then
  echo "FAIL: dispatch.sh exited non-zero (see ${ERR})"
  sed 's/^/  [err] /' "${ERR}"
  exit 1
fi

# Extract JOB_ID from the first stdout line (contract).
JOB_LINE="$(head -n1 "${OUT}")"
if [[ ! "${JOB_LINE}" =~ ^JOB_ID=([0-9]{8}-[0-9]{6}-[a-f0-9]{8})$ ]]; then
  echo "FAIL: first stdout line did not match JOB_ID= contract: ${JOB_LINE}"
  exit 1
fi
JOB_ID="${BASH_REMATCH[1]}"

META="${WORKDIR}/.cursor/delegate/${JOB_ID}.meta.json"
if [[ ! -f "${META}" ]]; then
  echo "FAIL: meta.json missing at ${META}"
  exit 1
fi

META_PID="$(jq -r '.pid' "${META}")"

# Assertion 1: meta.pid is a positive integer
if ! [[ "${META_PID}" =~ ^[0-9]+$ ]] || (( META_PID <= 1 )); then
  echo "FAIL: meta.pid=${META_PID} is not a valid positive integer"
  exit 1
fi

# Assertion 2 (V1 core): meta.pid must NOT be the dispatch.sh wrapper shell PID.
# In the pre-V1 bug, dispatch.sh recorded $$, which at runtime equals DISPATCH_PID.
if (( META_PID == DISPATCH_PID )); then
  echo "FAIL: V1 regression — meta.pid (${META_PID}) equals dispatch.sh wrapper PID (${DISPATCH_PID})"
  echo "       cancel.sh would SIGTERM the wrapper instead of the agent child"
  exit 1
fi

# Assertion 3: meta.pid is in a plausible range (child PID typically > parent PID on Linux,
# but we stay conservative and just require it to differ from DISPATCH_PID).
echo "PASS: meta.pid=${META_PID} != dispatch_wrapper_pid=${DISPATCH_PID}"
echo "      V1 invariant holds — cancel.sh will target the correct child"
