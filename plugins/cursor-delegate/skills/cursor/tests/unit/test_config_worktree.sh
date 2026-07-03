#!/usr/bin/env bash
# test_config_worktree.sh — unit test for git-aware project-config discovery:
#   - a main-checkout-root config is found from a linked git worktree (even when
#     the file is untracked / absent from the worktree tree)
#   - a worktree-root config overrides the main-root config on collision
#   - CURSOR_DELEGATE_PROJECT_CONFIG (explicit override) wins over discovery
#   - a non-git dir falls back to $PWD/.cursor.json (pre-git behavior, unchanged)
#   - a plain checkout at its root de-dupes to a single project layer
#   - git being unavailable degrades softly to the $PWD fallback (never dies)
#
# Requires: jq, git
# Exit 0 = PASS, non-zero = FAIL, 77 = SKIP
set -euo pipefail

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s — %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP test_config_worktree.sh — jq not found\n'; exit 77
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'SKIP test_config_worktree.sh — git not found\n'; exit 77
fi

# ---- Resolve REAL_SKILL_DIR BEFORE any cd -----------------------------------
# dirname "${BASH_SOURCE[0]}" must resolve against the real filesystem, not a
# fake project dir we cd into later.
REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_COMMON="${REAL_SKILL_DIR}/lib/lib_common.sh"
if [[ ! -f "${LIB_COMMON}" ]]; then
  printf 'SKIP test_config_worktree.sh — lib_common.sh not found at %s\n' "${LIB_COMMON}"; exit 77
fi

# ---- Temp environment -------------------------------------------------------
TMPDIR_TEST="$(mktemp -d -t cd-test-config-wt.XXXXXX)"
cleanup() {
  git -C "${REPO}" worktree remove --force "${WT}" 2>/dev/null || true
  rm -rf "${TMPDIR_TEST}"
}
trap cleanup EXIT INT TERM

# Fake HOME so the user layer is inert and does not shadow our assertions.
export HOME="${TMPDIR_TEST}/home"
mkdir -p "${HOME}/.cursor"
echo '{}' >"${HOME}/.cursor.json"

# Fake skill default config (lowest precedence); review.model = SKILL-DEFAULT.
FAKE_SKILL_CONFIG="${TMPDIR_TEST}/skill-config.json"
cat >"${FAKE_SKILL_CONFIG}" <<'EOF'
{
  "version": 1,
  "defaults": {
    "implement":   { "model": "composer-2",    "force": true, "worktree": true, "sandbox": "enabled" },
    "review":      { "model": "SKILL-DEFAULT",  "mode": "ask",  "sandbox": "enabled" },
    "plan":        { "model": "SKILL-DEFAULT",  "mode": "plan", "sandbox": "enabled" },
    "investigate": { "model": "SKILL-DEFAULT",  "mode": "ask",  "sandbox": "enabled" },
    "security":    { "model": "SKILL-DEFAULT",  "mode": "ask",  "sandbox": "enabled" }
  },
  "retry": { "max_attempts": 3, "initial_delay_ms": 1000, "backoff": "exponential" },
  "timeout_sec": 590
}
EOF

# ---- Build a git repo + a linked worktree -----------------------------------
REPO="${TMPDIR_TEST}/repo"
WT="${TMPDIR_TEST}/wt"
mkdir -p "${REPO}"
git -C "${REPO}" init -q
git -C "${REPO}" config user.email test@example.com
git -C "${REPO}" config user.name  test
: >"${REPO}/README"
git -C "${REPO}" add README
git -C "${REPO}" commit -qm init
git -C "${REPO}" worktree add -q "${WT}" -b wt

# main-checkout-root config, deliberately UNTRACKED (never git-added) — this is
# the crux: it exists only in the main checkout, not in the worktree tree.
cat >"${REPO}/.cursor.json" <<'EOF'
{ "defaults": { "review": { "model": "ROOT-WINS" } } }
EOF

# ---- Source lib + point the skill layer at our fake config ------------------
# shellcheck source=../../lib/lib_common.sh
source "${LIB_COMMON}"
CD_SKILL_CONFIG="${FAKE_SKILL_CONFIG}"
CD_USER_CONFIG="${HOME}/.cursor.json"
CD_PROJECT_CONFIG=".cursor.json"
export CD_SKILL_CONFIG CD_USER_CONFIG CD_PROJECT_CONFIG

# ---- Case A: main-only root config discovered from the worktree -------------
cd "${WT}"
SNAP_A="$(cd_resolve_config review "jobA-$(cd_rand 6)")"
MODEL_A="$(jq -r '.defaults.review.model' "${SNAP_A}")"
if [[ "${MODEL_A}" == "ROOT-WINS" ]]; then
  pass "worktree discovers main-checkout-root config (review.model = ROOT-WINS)"
else
  fail "Case A main-root discovery" "expected ROOT-WINS, got ${MODEL_A}"
fi

# ---- Case B: worktree-root config overrides main-root on collision ----------
cat >"${WT}/.cursor.json" <<'EOF'
{ "defaults": { "review": { "model": "WORKTREE-WINS" } } }
EOF
SNAP_B="$(cd_resolve_config review "jobB-$(cd_rand 6)")"
MODEL_B="$(jq -r '.defaults.review.model' "${SNAP_B}")"
if [[ "${MODEL_B}" == "WORKTREE-WINS" ]]; then
  pass "worktree-root overrides main-root (review.model = WORKTREE-WINS)"
else
  fail "Case B worktree override" "expected WORKTREE-WINS, got ${MODEL_B}"
fi

# ---- Case C: CURSOR_DELEGATE_PROJECT_CONFIG wins over all discovery ----------
EXPLICIT="${TMPDIR_TEST}/explicit.json"
cat >"${EXPLICIT}" <<'EOF'
{ "defaults": { "review": { "model": "ENV-WINS" } } }
EOF
SNAP_C="$(CURSOR_DELEGATE_PROJECT_CONFIG="${EXPLICIT}" cd_resolve_config review "jobC-$(cd_rand 6)")"
MODEL_C="$(jq -r '.defaults.review.model' "${SNAP_C}")"
if [[ "${MODEL_C}" == "ENV-WINS" ]]; then
  pass "explicit CURSOR_DELEGATE_PROJECT_CONFIG wins (review.model = ENV-WINS)"
else
  fail "Case C explicit override" "expected ENV-WINS, got ${MODEL_C}"
fi

# ---- Case D: non-git dir falls back to \$PWD/.cursor.json --------------------
NOGIT="${TMPDIR_TEST}/nogit"
mkdir -p "${NOGIT}"
cat >"${NOGIT}/.cursor.json" <<'EOF'
{ "defaults": { "review": { "model": "PWD-ONLY" } } }
EOF
cd "${NOGIT}"
if [[ -z "$(cd_git_main_root)" ]]; then
  pass "cd_git_main_root is empty outside a work tree"
else
  fail "Case D non-git main_root" "expected empty, got $(cd_git_main_root)"
fi
SNAP_D="$(cd_resolve_config review "jobD-$(cd_rand 6)")"
MODEL_D="$(jq -r '.defaults.review.model' "${SNAP_D}")"
if [[ "${MODEL_D}" == "PWD-ONLY" ]]; then
  pass "non-git dir falls back to \$PWD/.cursor.json (review.model = PWD-ONLY)"
else
  fail "Case D non-git fallback" "expected PWD-ONLY, got ${MODEL_D}"
fi

# ---- Case E: plain checkout at its root de-dupes to one project layer --------
SOLO="${TMPDIR_TEST}/solo"
mkdir -p "${SOLO}"
git -C "${SOLO}" init -q
cat >"${SOLO}/.cursor.json" <<'EOF'
{ "defaults": { "review": { "model": "SOLO" } } }
EOF
cd "${SOLO}"
N_SOLO="$(cd_project_config_candidates | wc -l | tr -d ' ')"
if [[ "${N_SOLO}" == "1" ]]; then
  pass "plain checkout de-dupes main==worktree==\$PWD to a single project layer"
else
  fail "Case E dedup" "expected 1 candidate, got ${N_SOLO}"
fi

# ---- Case F: git unavailable degrades softly to the \$PWD fallback -----------
# Shadow `git` with a failing shell function; the guarded helpers must yield
# empty roots and NOT abort, leaving only the $PWD candidate.
cd "${WT}"
F_OUT="$(
  git() { return 127; }
  cd_git_main_root
  echo "---"
  cd_project_config_candidates | wc -l | tr -d ' '
)"
F_MAIN="${F_OUT%%---*}"
F_COUNT="${F_OUT##*---}"
F_MAIN="$(printf '%s' "${F_MAIN}" | tr -d '[:space:]')"
F_COUNT="$(printf '%s' "${F_COUNT}" | tr -d '[:space:]')"
if [[ -z "${F_MAIN}" && "${F_COUNT}" == "1" ]]; then
  pass "git-unavailable degrades softly (empty main_root, single \$PWD candidate)"
else
  fail "Case F soft git dependency" "main_root=[${F_MAIN}] candidate_count=${F_COUNT}"
fi

# ---- Summary ----------------------------------------------------------------
printf '\ntest_config_worktree.sh: %s passed, %s failed\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then exit 1; fi
exit 0
