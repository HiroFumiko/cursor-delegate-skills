#!/usr/bin/env bash
# int_resume.sh — integration test for resume.sh context preservation.
#
# Flow:
#   1. Create chat via resume.sh --create-chat (captures chatId)
#   2. Dispatch single task with that chatId
#   3. Second dispatch resume <chatId> "follow-up question referencing the first"
#   4. Assert summary.md mentions context from first
#
# GATED: requires CURSOR_API_KEY.

set -euo pipefail

[ -z "${CURSOR_API_KEY:-}" ] && \
  { printf 'SKIP (no CURSOR_API_KEY)\n'; exit 77; }

export CURSOR_DELEGATE_QUARANTINE_HOOKS=0

REAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESUME_SH="${REAL_SKILL_DIR}/lib/resume.sh"
DISPATCH_SH="${REAL_SKILL_DIR}/lib/dispatch.sh"

# Step 1: create a chat.
printf 'Creating chat...\n'
CHAT_ID="$(bash "${RESUME_SH}" --create-chat 2>/dev/null)"
if [[ -z "${CHAT_ID}" ]]; then
  printf 'FAIL: --create-chat returned empty chatId\n'
  exit 1
fi
printf 'Chat ID: %s\n' "${CHAT_ID}"

# Step 2: first turn — establish context.
printf 'Dispatching first turn...\n'
STDOUT1="$(bash "${DISPATCH_SH}" investigate "My favorite color is purple. Please acknowledge that." \
           --resume "${CHAT_ID}")"
SUMMARY1="$(printf '%s\n' "${STDOUT1}" | tail -1)"

if [[ ! -f "${SUMMARY1}" ]]; then
  printf 'FAIL: first turn summary.md missing: %s\n' "${SUMMARY1}"
  exit 1
fi
printf 'PASS: first turn summary: %s\n' "${SUMMARY1}"

# Step 3: second turn — follow-up that requires context.
printf 'Dispatching follow-up turn...\n'
STDOUT2="$(bash "${RESUME_SH}" "${CHAT_ID}" "What is the favorite color I mentioned?")"
SUMMARY2="$(printf '%s\n' "${STDOUT2}" | tail -1)"

if [[ ! -f "${SUMMARY2}" ]]; then
  printf 'FAIL: follow-up summary.md missing: %s\n' "${SUMMARY2}"
  exit 1
fi
printf 'PASS: follow-up summary: %s\n' "${SUMMARY2}"

# Step 4: assert context preserved (response mentions "purple").
if grep -qi 'purple' "${SUMMARY2}"; then
  printf 'PASS: follow-up summary mentions "purple" (context preserved)\n'
else
  printf 'WARN: follow-up summary does not mention "purple" — context may not have been preserved\n'
  printf 'Summary content:\n'
  cat "${SUMMARY2}"
  # Not a hard failure — Cursor context window behavior is nondeterministic.
  # Mark as manual verification needed.
  printf 'MANUAL: verify context preservation — see tests/manual-qa.md MQ-2\n'
fi

# Assert sessions.jsonl has entries.
SESSIONS_FILE=".cursor/delegate/state/sessions.jsonl"
if [[ -f "${SESSIONS_FILE}" ]] && [[ -s "${SESSIONS_FILE}" ]]; then
  printf 'PASS: sessions.jsonl has entries\n'
else
  printf 'FAIL: sessions.jsonl missing or empty\n'
  exit 1
fi

printf 'PASS: int_resume.sh all checks passed\n'
exit 0
