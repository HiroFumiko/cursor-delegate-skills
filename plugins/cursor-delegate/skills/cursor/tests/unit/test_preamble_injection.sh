#!/usr/bin/env bash
# test_preamble_injection.sh — per-task `preamble` prompt composition.
#
# dispatch.sh composes the final prompt from defaults.<task>.preamble:
#   - array preamble is joined with newlines
#   - a {{prompt}} placeholder is replaced with the user prompt at that spot
#     (and the literal placeholder must not survive)
#   - a preamble WITHOUT a placeholder is prepended (user prompt still present)
#   - no preamble -> user prompt passed verbatim (backward compatible)
#
# Two observation channels:
#   A. --dry-run + CURSOR_DELEGATE_DEBUG_PROMPT=1 renders the COMPOSED prompt
#      into the summary's "Final prompt preview" fenced block (no real agent run).
#      NB: the dry-run summary ALSO dumps the resolved config (which contains the
#      raw preamble + the literal {{prompt}}), so assertions are scoped to the
#      preview block only — never grep the whole summary file.
#   B. a real (non-dry) run: the fake-agent records `$*`; we assert the composed
#      prompt actually reaches the `agent -- <prompt>` argv.
#
# Requires: jq. Exit 0 = PASS, non-zero = FAIL, 77 = SKIP.

set -euo pipefail

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_preamble_injection.sh — jq not found\n'
  exit 77
fi

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"
FIXTURES_DIR="${REAL_SKILL_DIR}/tests/fixtures"

if [[ ! -f "${DISPATCH_SH}" ]]; then
  printf 'SKIP test_preamble_injection.sh — dispatch.sh not found at %s\n' "${DISPATCH_SH}"
  exit 77
fi

# ---- Temp env ---------------------------------------------------------------

TMPDIR_TEST="$(mktemp -d -t cd-test-preamble.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
mkdir -p "${FAKE_HOME}/.cursor" "${FAKE_BIN}"
mkdir -p "${FAKE_CWD}/.cursor/delegate" "${FAKE_CWD}/.cursor/delegate/state"
cd "${FAKE_CWD}"

# Self-contained skill config with three preamble shapes:
#   review      -> array + {{prompt}} placeholder
#   investigate -> string, NO placeholder (prepend path)
#   plan        -> no preamble (verbatim path)
FAKE_SKILL_DIR="${TMPDIR_TEST}/skill"
mkdir -p "${FAKE_SKILL_DIR}/config"
cat >"${FAKE_SKILL_DIR}/config/.cursor.json" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "good-model", "force": true, "worktree": true },
    "review":      { "model": "good-model", "mode": "ask",
                     "preamble": ["ROLE-REVIEWER-LINE1", "ROLE-REVIEWER-LINE2", "", "{{prompt}}"] },
    "plan":        { "model": "good-model", "mode": "plan" },
    "investigate": { "model": "good-model", "mode": "ask",
                     "preamble": "ROLE-INVESTIGATE-NOPLACEHOLDER" },
    "security":    { "model": "good-model", "mode": "ask" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

cp "${FIXTURES_DIR}/fake-agent.sh" "${FAKE_BIN}/agent"
chmod +x "${FAKE_BIN}/agent"
for b in jq timeout; do
  if command -v "${b}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${b}")" "${FAKE_BIN}/${b}" 2>/dev/null || true
  fi
done

COMMON_ENV=(
  PATH="${FAKE_BIN}:${PATH}"
  HOME="${FAKE_HOME}"
  CURSOR_API_KEY="fake-key"
  FAKE_AGENT_MODELS="good-model"
  CD_SKILL_CONFIG="${FAKE_SKILL_DIR}/config/.cursor.json"
  CD_USER_CONFIG="${FAKE_HOME}/.cursor.json"
  CD_PROJECT_CONFIG=".cursor.json"
)

# run_preview TASK PROMPT -> stdout = body of the "Final prompt preview" block.
# Scoped extraction: print only the FIRST fenced block AFTER the preview header,
# so the later "Resolved config" dump (which contains the raw preamble) cannot
# leak into the assertion.
run_preview() {
  local task="$1" prompt="$2" summary
  summary="$(env "${COMMON_ENV[@]}" CURSOR_DELEGATE_DEBUG_PROMPT=1 \
    bash "${DISPATCH_SH}" --dry-run "${task}" "${prompt}" 2>/dev/null | tail -1)"
  [[ -f "${summary}" ]] || return 1
  awk '
    /^### Final prompt preview/ { f=1; next }
    f && /^```$/ { c++; next }
    f && c==1   { print }
    c==2        { exit }
  ' "${summary}"
}

# =============================================================================
# A — dry-run composed-prompt preview
# =============================================================================

# A1/A2: array preamble joined + {{prompt}} substituted with the user prompt.
P_REVIEW="$(run_preview review "USERTEXT-ALPHA")" || P_REVIEW=""
if [[ -z "${P_REVIEW}" ]]; then
  fail "review: dry-run preview" "no summary / empty preview block"
else
  if printf '%s' "${P_REVIEW}" | grep -q 'ROLE-REVIEWER-LINE1' \
     && printf '%s' "${P_REVIEW}" | grep -q 'ROLE-REVIEWER-LINE2' \
     && printf '%s' "${P_REVIEW}" | grep -q 'USERTEXT-ALPHA'; then
    pass "review: array preamble joined and {{prompt}} substituted"
  else
    fail "review composition" "preview block: ${P_REVIEW}"
  fi
  # A2: the literal placeholder must be consumed (scoped to the preview block).
  if printf '%s' "${P_REVIEW}" | grep -q '{{prompt}}'; then
    fail "review placeholder" "literal {{prompt}} survived in composed prompt"
  else
    pass "review: {{prompt}} placeholder consumed (not left literal)"
  fi
fi

# A3: string preamble WITHOUT placeholder -> prepended; user prompt retained.
P_INV="$(run_preview investigate "USERTEXT-BETA")" || P_INV=""
if [[ -z "${P_INV}" ]]; then
  fail "investigate: dry-run preview" "no summary / empty preview block"
else
  if printf '%s' "${P_INV}" | grep -q 'ROLE-INVESTIGATE-NOPLACEHOLDER' \
     && printf '%s' "${P_INV}" | grep -q 'USERTEXT-BETA'; then
    pass "investigate: no-placeholder preamble prepended, user prompt retained"
  else
    fail "investigate composition" "preview block: ${P_INV}"
  fi
fi

# A4: no preamble -> user prompt verbatim (no ROLE- text leaks in).
P_PLAN="$(run_preview plan "USERTEXT-GAMMA")" || P_PLAN=""
if [[ -z "${P_PLAN}" ]]; then
  fail "plan: dry-run preview" "no summary / empty preview block"
else
  if printf '%s' "${P_PLAN}" | grep -q 'USERTEXT-GAMMA' \
     && ! printf '%s' "${P_PLAN}" | grep -q 'ROLE-'; then
    pass "plan: no preamble -> user prompt verbatim"
  else
    fail "plan verbatim" "preview block: ${P_PLAN}"
  fi
fi

# =============================================================================
# B — real invocation passes the composed prompt to `agent -- <prompt>`
# =============================================================================

REC="${TMPDIR_TEST}/agent-calls.txt"
: >"${REC}"
set +e
env "${COMMON_ENV[@]}" \
  CURSOR_DELEGATE_QUARANTINE_HOOKS="0" \
  FAKE_AGENT_RECORD="${REC}" \
  bash "${DISPATCH_SH}" review "USERTEXT-DELTA" >/dev/null 2>&1
B_EXIT=$?
set -e

if [[ "${B_EXIT}" -eq 0 ]]; then
  pass "review (real): dispatch exits 0"
else
  fail "review real exit" "got ${B_EXIT}"
fi

# The fake-agent records `$*`. The composed prompt carries embedded newlines, so
# the multi-line argv spans several physical lines in the record file; assert on
# the file as a whole. It contains only agent calls (a `--list-models` preflight
# line + the real `-p …` invocation), so ROLE-/USERTEXT- markers can come only
# from the composed prompt that reached the `agent -- <prompt>` argv.
if grep -q -- '-p' "${REC}" \
   && grep -q 'ROLE-REVIEWER-LINE1' "${REC}" \
   && grep -q 'USERTEXT-DELTA' "${REC}"; then
  pass "review (real): composed prompt (preamble + user text) reached agent -- argv"
else
  fail "review real argv" "record: $(cat "${REC}" 2>/dev/null)"
fi

# ---- Summary ----------------------------------------------------------------

printf '\ntest_preamble_injection.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
