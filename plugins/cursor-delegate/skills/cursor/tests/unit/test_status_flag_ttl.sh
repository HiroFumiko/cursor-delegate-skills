#!/usr/bin/env bash
# test_status_flag_ttl.sh — F6 regression guard for TTL annotation in status.sh.
#
# Verifies status.sh surfaces expiry date and days-remaining for the
# claude-serializes-bash flag.

set -euo pipefail

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REAL_SKILL_DIR}/tests/fixtures/lib.sh"

STATUS_SH="${REAL_SKILL_DIR}/lib/status.sh"
[[ -f "${STATUS_SH}" ]] || { printf 'SKIP — status.sh not found\n'; exit 77; }
command -v jq >/dev/null 2>&1 || { printf 'SKIP — jq not found\n'; exit 77; }

# Portable "N days ago" ISO timestamp. status.sh itself is GNU/BSD-portable
# (cd_iso_to_epoch / cd_epoch_to_date), so the fixtures must be too: GNU date
# uses `-d @epoch`, BSD/macOS date uses `-r epoch`.
iso_n_days_ago() {
  local days="$1" now epoch
  now="$(date -u +%s)"
  epoch=$(( now - days * 86400 ))
  date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

TMPDIR_TEST="$(mktemp -d -t cd-test-ttl.XXXXXX)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT INT TERM

FAKE_HOME="${TMPDIR_TEST}/home"
FAKE_CWD="${TMPDIR_TEST}/project"
FAKE_BIN="${TMPDIR_TEST}/bin"
setup_fake_home "${FAKE_HOME}"
setup_fake_cwd "${FAKE_CWD}"
install_fake_agent "${FAKE_BIN}"

FAKE_SKILL="${TMPDIR_TEST}/skill"
setup_fake_skill_dir "${FAKE_SKILL}"

cd "${FAKE_CWD}"

# status.sh exits early if no .meta.json files exist; create a dummy job.
OUT_DIR="${FAKE_CWD}/.cursor/delegate"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"${OUT_DIR}/20260101-000000-deadbeef.meta.json" <<EOF
{
  "job_id": "20260101-000000-deadbeef",
  "task_type": "review",
  "resolved_model": "gpt-5.4-high",
  "mode": "ask",
  "worktree": null,
  "session_id": "chat-dummy",
  "pid": 1,
  "started_at": "${NOW_ISO}",
  "completed_at": "${NOW_ISO}",
  "duration_ms": 100,
  "exit_code": 0,
  "status": "completed"
}
EOF

run_status() {
  PATH="${FAKE_BIN}:${PATH}" HOME="${FAKE_HOME}" \
    CURSOR_API_KEY="fake-key" \
    CD_SKILL_CONFIG="${FAKE_SKILL}/config/model.json" \
    CD_USER_CONFIG="${FAKE_HOME}/.cursor.json" \
    bash "${STATUS_SH}" --since 365d 2>&1
}

STATE_DIR="${FAKE_CWD}/.cursor/delegate/state"
FLAG="${STATE_DIR}/claude-serializes-bash"

# ---- Test 1: fresh flag (5 days old) shows "days remaining" ----
FIVE_DAYS_AGO="$(iso_n_days_ago 5)"
jq -n --arg d "${FIVE_DAYS_AGO}" '{detected_at: $d, serialization_ratio: 1.5, sample_size: 2}' >"${FLAG}"

OUTPUT="$(run_status)"
if printf '%s\n' "${OUTPUT}" | grep -q "days remaining"; then
  pass "fresh flag shows 'days remaining'"
else
  fail "fresh flag shows 'days remaining'" "output: $(printf '%s' "${OUTPUT}" | grep -i 'expires' || echo 'no expires line')"
fi

# Verify approximate day count (should be ~25 days remaining, allow ±2).
DAYS_LINE="$(printf '%s\n' "${OUTPUT}" | grep -o '[0-9]* days remaining' | head -1 || true)"
if [[ -n "${DAYS_LINE}" ]]; then
  DAYS_NUM="${DAYS_LINE%% *}"
  if (( DAYS_NUM >= 23 && DAYS_NUM <= 27 )); then
    pass "days remaining ~25 (got ${DAYS_NUM})"
  else
    fail "days remaining ~25" "got ${DAYS_NUM}"
  fi
else
  fail "days remaining number parsed" "no number found"
fi

# ---- Test 2: expired flag (35 days old) shows "EXPIRED" ----
THIRTY_FIVE_AGO="$(iso_n_days_ago 35)"
jq -n --arg d "${THIRTY_FIVE_AGO}" '{detected_at: $d, serialization_ratio: 1.5, sample_size: 2}' >"${FLAG}"

OUTPUT2="$(run_status)"
if printf '%s\n' "${OUTPUT2}" | grep -q "EXPIRED"; then
  pass "expired flag shows 'EXPIRED'"
else
  fail "expired flag shows 'EXPIRED'" "output: $(printf '%s' "${OUTPUT2}" | grep -i 'expires' || echo 'no expires line')"
fi

# ---- Test 3: no flag -> no expires annotation ----
rm -f "${FLAG}"
OUTPUT3="$(run_status)"
if ! printf '%s\n' "${OUTPUT3}" | grep -q "expires:"; then
  pass "no flag -> no expires annotation"
else
  fail "no flag -> no expires annotation" "found 'expires:' without flag file"
fi

fx_summary "test_status_flag_ttl.sh"
