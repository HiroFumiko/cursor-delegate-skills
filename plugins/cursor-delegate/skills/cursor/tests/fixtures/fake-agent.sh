#!/usr/bin/env bash
# fake-agent.sh — parameterizable stub for `agent` CLI.
#
# Install into a test's FAKE_BIN via:
#   cp tests/fixtures/fake-agent.sh "${FAKE_BIN}/agent" && chmod +x "${FAKE_BIN}/agent"
# Or use install_fake_agent from tests/fixtures/lib.sh.
#
# Env controls:
#   FAKE_AGENT_RECORD   if set to a file path, append "$@" as one line
#   FAKE_AGENT_STDIN_RECORD  if set to a file path, stdin is captured there
#     (real invocation only — the --list-models preflight exits before this
#     point, so preflight never consumes dispatch's own stdin).

if [[ -n "${FAKE_AGENT_RECORD:-}" ]]; then
  printf '%s\n' "$*" >>"${FAKE_AGENT_RECORD}"
fi

case "${1:-}" in
  --list-models)
    if [[ -n "${FAKE_AGENT_MODELS:-}" ]]; then
      printf '%s\n' "${FAKE_AGENT_MODELS}"
    else
      printf 'composer-2\ngood-model\ngpt-5.4-high\n'
    fi
    exit 0
    ;;
esac
# Capture piped prompt stdin (real invocation only — preflight exits above).
if [[ -n "${FAKE_AGENT_STDIN_RECORD:-}" ]] && [[ ! -t 0 ]]; then
  cat >"${FAKE_AGENT_STDIN_RECORD}"
fi

if [[ "${FAKE_AGENT_SLEEP:-0}" != "0" ]]; then
  sleep "${FAKE_AGENT_SLEEP}"
fi

if [[ -n "${FAKE_AGENT_RESULT:-}" ]]; then
  printf '%s\n' "${FAKE_AGENT_RESULT}"
else
  cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"duration_ms":100,"result":"fake agent output","session_id":"test-session-00000000"}
JSON
fi

exit "${FAKE_AGENT_EXIT:-0}"
