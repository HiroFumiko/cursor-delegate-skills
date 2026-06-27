#!/usr/bin/env bash
# lib.sh — common test helpers for cursor skill unit tests.
#
# Source this file at the top of each test:
#   REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#   source "${REAL_SKILL_DIR}/tests/fixtures/lib.sh"
#
# Provides:
#   _FX_PASS / _FX_FAIL counters + pass/fail helpers
#   setup_fake_skill_dir DIR     — writes a default model.json
#   setup_fake_home DIR          — creates ~/.cursor skeleton
#   setup_fake_cwd DIR           — creates .cursor/delegate/state
#   install_fake_agent BIN_DIR   — copies fake-agent.sh as BIN_DIR/agent + links jq/timeout
#   fx_summary                   — prints pass/fail counts, exits 1 if any failures

set -euo pipefail

_FX_PASS=0
_FX_FAIL=0

pass() { printf 'PASS: %s\n' "$1"; _FX_PASS=$((_FX_PASS + 1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; _FX_FAIL=$((_FX_FAIL + 1)); }

_FX_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

setup_fake_skill_dir() {
  local dir="${1:?dir required}"
  mkdir -p "${dir}/config"
  cat >"${dir}/config/model.json" <<'EOF'
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
}

setup_fake_home() {
  local dir="${1:?dir required}"
  mkdir -p "${dir}/.cursor"
}

setup_fake_cwd() {
  local dir="${1:?dir required}"
  mkdir -p "${dir}/.cursor/delegate" "${dir}/.cursor/delegate/state"
}

install_fake_agent() {
  local bin_dir="${1:?bin_dir required}"
  mkdir -p "${bin_dir}"
  cp "${_FX_FIXTURES_DIR}/fake-agent.sh" "${bin_dir}/agent"
  chmod +x "${bin_dir}/agent"
  for _fx_b in jq timeout; do
    if command -v "${_fx_b}" >/dev/null 2>&1; then
      ln -sf "$(command -v "${_fx_b}")" "${bin_dir}/${_fx_b}" 2>/dev/null || true
    fi
  done
}

fx_summary() {
  local name="${1:-test}"
  printf '\n%s: %s passed, %s failed\n' "${name}" "${_FX_PASS}" "${_FX_FAIL}"
  if (( _FX_FAIL > 0 )); then
    exit 1
  fi
  exit 0
}
