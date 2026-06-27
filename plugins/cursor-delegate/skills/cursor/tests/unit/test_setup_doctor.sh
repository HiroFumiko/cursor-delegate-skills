#!/usr/bin/env bash
# test_setup_doctor.sh — checks for lib/setup.sh:
#   - OS detection line + verdict logic (READY vs NEEDS SETUP)
#   - permission allowlist: read-only tasks present, write/ambiguous excluded
#   - --apply-permissions merges into settings.json and is idempotent + backed up
#
# Pure bash 3.2-safe; uses shared fixtures. jq-gated (SKIP 77 if absent).

set -euo pipefail

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REAL_SKILL_DIR}/tests/fixtures/lib.sh"

SETUP_SH="${REAL_SKILL_DIR}/lib/setup.sh"
[[ -f "${SETUP_SH}" ]] || { printf 'SKIP — setup.sh not found\n'; exit 77; }
command -v jq >/dev/null 2>&1 || { printf 'SKIP — jq not found\n'; exit 77; }

TMPDIR_TEST="$(mktemp -d -t cd-test-setup.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_BIN}"
install_fake_agent "${FAKE_BIN}"          # agent + jq (+timeout if host has it)

# Guarantee a `timeout` binary exists for check_timeout regardless of host.
if [[ ! -e "${FAKE_BIN}/timeout" ]]; then
  printf '#!/bin/sh\nshift; exec "$@"\n' >"${FAKE_BIN}/timeout"
  chmod +x "${FAKE_BIN}/timeout"
fi

# Run setup.sh with a controlled HOME + fake bin prepended, CURSOR_API_KEY
# always unset so auth is decided solely by ~/.cursor session artifacts.
run_setup() {
  local home="${1:?home required}"; shift
  env -u CURSOR_API_KEY HOME="${home}" PATH="${FAKE_BIN}:${PATH}" \
    bash "${SETUP_SH}" "$@" 2>&1
}

# ---- Test 1: --print-permissions covers all 4 read-only tasks, both forms ----
PERMS="$(run_setup "${FAKE_HOME}" --print-permissions)"
ok=1
for t in review plan investigate security; do
  printf '%s' "${PERMS}" | grep -q "cursor.sh ${t}:"   || ok=0
  printf '%s' "${PERMS}" | grep -q "dispatch.sh ${t}:" || ok=0
done
if [[ ${ok} -eq 1 ]]; then
  pass "perms: 4 read-only tasks via cursor.sh + dispatch.sh"
else
  fail "perms: read-only tasks" "one or more missing"
fi

if printf '%s' "${PERMS}" | grep -q -- "fanout.sh --collect:" \
  && printf '%s' "${PERMS}" | grep -q "setup.sh:" \
  && printf '%s' "${PERMS}" | grep -q "status.sh:"; then
  pass "perms: includes status / fanout --collect / setup"
else
  fail "perms: aux read-only entries" "status/fanout/setup missing"
fi

# ---- Test 2: write/ambiguous task types are NEVER allowlisted ----
if printf '%s' "${PERMS}" | grep -Eq 'implement|cancel\.sh|resume\.sh'; then
  fail "perms: write actions excluded" "found implement/cancel/resume"
else
  pass "perms: implement/cancel/resume NOT allowlisted (still prompt)"
fi

# ---- Test 3: verdict READY when deps + auth (session) present ----
printf '{}' >"${FAKE_HOME}/.cursor/session.json"    # simulate a prior login
set +e
OUT_READY="$(run_setup "${FAKE_HOME}" --check)"; RC_READY=$?
set -e
if [[ ${RC_READY} -eq 0 ]] && printf '%s' "${OUT_READY}" | grep -q "READY"; then
  pass "verdict: READY (exit 0) with session + deps"
else
  fail "verdict READY" "rc=${RC_READY} $(printf '%s' "${OUT_READY}" | grep -i 'verdict\|MISSING' | head -2)"
fi
if printf '%s' "${OUT_READY}" | grep -qE 'detected OS: +(macos|linux|wsl|windows|unknown)'; then
  pass "doctor: prints a recognized detected OS"
else
  fail "doctor OS line" "$(printf '%s' "${OUT_READY}" | grep -i 'detected OS' || echo absent)"
fi

# ---- Test 4: verdict NEEDS SETUP (exit 1) when no auth at all ----
NOAUTH_HOME="${TMPDIR_TEST}/home_noauth"
mkdir -p "${NOAUTH_HOME}"      # no ~/.cursor, no session
set +e
OUT_NS="$(run_setup "${NOAUTH_HOME}" --check)"; RC_NS=$?
set -e
if [[ ${RC_NS} -eq 1 ]] && printf '%s' "${OUT_NS}" | grep -q "NEEDS SETUP"; then
  pass "verdict: NEEDS SETUP (exit 1) when auth missing"
else
  fail "verdict NEEDS SETUP" "rc=${RC_NS}"
fi

# ---- Test 5: --apply-permissions merges + is idempotent + backs up ----
SETTINGS="${FAKE_HOME}/.claude/settings.json"
run_setup "${FAKE_HOME}" --apply-permissions >/dev/null
N1="$(jq '.permissions.allow | length' "${SETTINGS}")"
run_setup "${FAKE_HOME}" --apply-permissions >/dev/null
N2="$(jq '.permissions.allow | length' "${SETTINGS}")"
if [[ "${N1}" == "${N2}" ]] && (( N1 > 0 )); then
  pass "apply: merged ${N1} rules, idempotent on re-run"
else
  fail "apply idempotent" "N1=${N1} N2=${N2}"
fi
if [[ -f "${SETTINGS}.cursor-setup.bak" ]]; then
  pass "apply: backed up settings.json before second merge"
else
  fail "apply backup" "no .cursor-setup.bak"
fi

# ---- Test 6: --init-config user writes a MINIMAL override scaffold ----
# Minimal scaffold = {"version":1,"defaults":{}}: valid JSON, empty defaults so
# it is a no-op on the deep-merge (the skill default fully applies).
ICFG_HOME="${TMPDIR_TEST}/home_initcfg"
mkdir -p "${ICFG_HOME}"
set +e
OUT_IC="$(run_setup "${ICFG_HOME}" --init-config user)"; RC_IC=$?
set -e
USER_CFG="${ICFG_HOME}/.cursor.json"
if [[ ${RC_IC} -eq 0 ]] \
  && printf '%s' "${OUT_IC}" | grep -q "WROTE" \
  && [[ -f "${USER_CFG}" ]] \
  && jq -e '.version == 1 and (.defaults | length == 0)' "${USER_CFG}" >/dev/null 2>&1; then
  pass "init-config user: wrote minimal override scaffold ~/.cursor.json (WROTE)"
else
  fail "init-config user" "rc=${RC_IC} out=$(printf '%s' "${OUT_IC}" | tail -1)"
fi

# ---- Test 7: re-run without --force does NOT clobber (EXISTS, content intact) ----
printf '{"version":1,"defaults":{"sentinel":true}}' >"${USER_CFG}"   # mark the file
set +e
OUT_NOCLOB="$(run_setup "${ICFG_HOME}" --init-config user)"; RC_NOCLOB=$?
set -e
if [[ ${RC_NOCLOB} -eq 0 ]] \
  && printf '%s' "${OUT_NOCLOB}" | grep -q "EXISTS" \
  && jq -e '.defaults.sentinel == true' "${USER_CFG}" >/dev/null 2>&1; then
  pass "init-config: existing file preserved without --force (EXISTS)"
else
  fail "init-config no-clobber" "rc=${RC_NOCLOB} out=$(printf '%s' "${OUT_NOCLOB}" | tail -1)"
fi

# ---- Test 8: --force overwrites + backs up the prior file ----
set +e
OUT_FORCE="$(run_setup "${ICFG_HOME}" --init-config user --force)"; RC_FORCE=$?
set -e
if [[ ${RC_FORCE} -eq 0 ]] \
  && printf '%s' "${OUT_FORCE}" | grep -q "WROTE" \
  && [[ -f "${USER_CFG}.cursor-setup.bak" ]] \
  && jq -e '.defaults.sentinel == true' "${USER_CFG}.cursor-setup.bak" >/dev/null 2>&1 \
  && jq -e '.version == 1 and (.defaults | length == 0)' "${USER_CFG}" >/dev/null 2>&1; then
  pass "init-config --force: overwrote with scaffold + backed up prior file"
else
  fail "init-config --force" "rc=${RC_FORCE} out=$(printf '%s' "${OUT_FORCE}" | tail -1)"
fi

# ---- Test 9: project scope writes <cwd>/.cursor.json ----
PROJ_DIR="${TMPDIR_TEST}/proj"
mkdir -p "${PROJ_DIR}"
set +e
OUT_PROJ="$( cd "${PROJ_DIR}" && env -u CURSOR_API_KEY HOME="${ICFG_HOME}" PATH="${FAKE_BIN}:${PATH}" \
  bash "${SETUP_SH}" --init-config project 2>&1 )"; RC_PROJ=$?
set -e
if [[ ${RC_PROJ} -eq 0 ]] \
  && printf '%s' "${OUT_PROJ}" | grep -q "WROTE" \
  && [[ -f "${PROJ_DIR}/.cursor.json" ]]; then
  pass "init-config project: wrote <cwd>/.cursor.json"
else
  fail "init-config project" "rc=${RC_PROJ} out=$(printf '%s' "${OUT_PROJ}" | tail -1)"
fi

# ---- Test 10: missing / bad scope is a usage error (exit 64) ----
set +e
run_setup "${ICFG_HOME}" --init-config >/dev/null 2>&1; RC_NOSCOPE=$?
run_setup "${ICFG_HOME}" --init-config bogus >/dev/null 2>&1; RC_BADSCOPE=$?
set -e
if [[ ${RC_NOSCOPE} -eq 64 && ${RC_BADSCOPE} -eq 64 ]]; then
  pass "init-config: missing/bad scope -> exit 64"
else
  fail "init-config scope guard" "noscope=${RC_NOSCOPE} badscope=${RC_BADSCOPE}"
fi

fx_summary "test_setup_doctor.sh"
