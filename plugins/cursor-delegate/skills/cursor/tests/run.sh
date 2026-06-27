#!/usr/bin/env bash
# run.sh — cursor test runner.
#
# Usage:
#   bash tests/run.sh unit         run all tests/unit/*.sh
#   bash tests/run.sh integration  run all tests/integration/*.sh (CURSOR_API_KEY gated)
#   bash tests/run.sh all          unit then integration
#
# Exit code: 0 only if all non-skipped tests pass.
#
# Color: disable with NO_COLOR=1 or when stdout is not a terminal.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${SELF_DIR}/unit"
INT_DIR="${SELF_DIR}/integration"

# ---- Color support ----------------------------------------------------------

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ---- Helpers ----------------------------------------------------------------

print_header() {
  printf '\n%b%b=== %s ===%b\n' "${BOLD}" "${CYAN}" "$1" "${RESET}"
}

print_result() {
  local status="$1" name="$2" detail="${3:-}"
  case "${status}" in
    PASS) printf '%bPASS%b  %s\n'              "${GREEN}" "${RESET}" "${name}" ;;
    FAIL) printf '%bFAIL%b  %s%s\n'            "${RED}"   "${RESET}" "${name}" \
                 "${detail:+ — ${detail}}" ;;
    SKIP) printf '%bSKIP%b  %s%s\n'            "${YELLOW}" "${RESET}" "${name}" \
                 "${detail:+ (${detail})}" ;;
  esac
}

# ---- Run one test file -------------------------------------------------------
# Returns via globals: RUN_PASS RUN_FAIL RUN_SKIP (incremented)

RUN_PASS=0
RUN_FAIL=0
RUN_SKIP=0

run_test() {
  local script="$1"
  local name
  name="$(basename "${script}" .sh)"

  # Syntax check first.
  if ! bash -n "${script}" 2>/tmp/cd-run-syntax-$$.err; then
    print_result FAIL "${name}" "syntax error: $(cat /tmp/cd-run-syntax-$$.err)"
    rm -f /tmp/cd-run-syntax-$$.err
    RUN_FAIL=$((RUN_FAIL + 1))
    return
  fi
  rm -f /tmp/cd-run-syntax-$$.err

  local out_file
  out_file="$(mktemp -t cd-run-output.XXXXXX)"

  set +e
  bash "${script}" >"${out_file}" 2>&1
  local ec=$?
  set -e

  local out
  out="$(cat "${out_file}")"
  rm -f "${out_file}"

  if [[ "${ec}" -eq 77 ]]; then
    # Convention: exit 77 = SKIP.
    local skip_reason
    skip_reason="$(printf '%s\n' "${out}" | grep '^SKIP' | head -1 || true)"
    print_result SKIP "${name}" "${skip_reason#SKIP }"
    RUN_SKIP=$((RUN_SKIP + 1))
  elif [[ "${ec}" -eq 0 ]]; then
    print_result PASS "${name}"
    # Print test-internal PASS/FAIL lines at verbose indent.
    if [[ -n "${VERBOSE:-}" ]]; then
      printf '%s\n' "${out}" | sed 's/^/    /'
    fi
    RUN_PASS=$((RUN_PASS + 1))
  else
    print_result FAIL "${name}" "exit ${ec}"
    # Always print output on failure.
    printf '%s\n' "${out}" | sed 's/^/    /' >&2
    RUN_FAIL=$((RUN_FAIL + 1))
  fi
}

# ---- Unit suite -------------------------------------------------------------

run_unit() {
  print_header "Unit Tests"

  # Check jq availability once; warn if missing.
  if ! command -v jq >/dev/null 2>&1; then
    printf '%bWARN%b jq not found — tests needing jq will be skipped (exit 77)\n' \
      "${YELLOW}" "${RESET}"
  fi

  shopt -s nullglob
  local scripts=( "${UNIT_DIR}"/*.sh )
  shopt -u nullglob

  if (( ${#scripts[@]} == 0 )); then
    printf 'No unit tests found in %s\n' "${UNIT_DIR}"
    return
  fi

  for s in "${scripts[@]}"; do
    run_test "${s}"
  done
}

# ---- Integration suite ------------------------------------------------------

run_integration() {
  print_header "Integration Tests"

  if [[ -z "${CURSOR_API_KEY:-}" ]]; then
    printf '%bSKIP%b  All integration tests require CURSOR_API_KEY (not set)\n' \
      "${YELLOW}" "${RESET}"
    return
  fi

  shopt -s nullglob
  local scripts=( "${INT_DIR}"/*.sh )
  shopt -u nullglob

  if (( ${#scripts[@]} == 0 )); then
    printf 'No integration tests found in %s\n' "${INT_DIR}"
    return
  fi

  for s in "${scripts[@]}"; do
    run_test "${s}"
  done
}

# ---- Summary ----------------------------------------------------------------

print_summary() {
  local total=$(( RUN_PASS + RUN_FAIL + RUN_SKIP ))
  printf '\n%b%b--- Summary ---%b\n' "${BOLD}" "${CYAN}" "${RESET}"
  printf 'Total:   %s\n' "${total}"
  printf '%bPass%b:    %s\n' "${GREEN}" "${RESET}" "${RUN_PASS}"
  printf '%bFail%b:    %s\n' "${RED}"   "${RESET}" "${RUN_FAIL}"
  printf '%bSkip%b:    %s\n' "${YELLOW}" "${RESET}" "${RUN_SKIP}"

  if (( RUN_FAIL > 0 )); then
    printf '\n%b%bRESULT: FAILED (%s/%s non-skipped tests failed)%b\n' \
      "${BOLD}" "${RED}" "${RUN_FAIL}" "$(( total - RUN_SKIP ))" "${RESET}"
  else
    printf '\n%b%bRESULT: PASSED (%s/%s non-skipped tests passed)%b\n' \
      "${BOLD}" "${GREEN}" "${RUN_PASS}" "$(( total - RUN_SKIP ))" "${RESET}"
  fi

  # Always surface manual-qa.md location.
  local qa_path="${SELF_DIR}/manual-qa.md"
  if [[ -f "${qa_path}" ]]; then
    printf '\n%bManual QA checklist (AC2/AC3/AC7 human-verified):%b\n  %s\n' \
      "${CYAN}" "${RESET}" "${qa_path}"
  fi
}

# ---- Main -------------------------------------------------------------------

MODE="${1:-all}"

case "${MODE}" in
  unit)
    run_unit
    print_summary
    ;;
  integration)
    run_integration
    print_summary
    ;;
  all)
    run_unit
    run_integration
    print_summary
    ;;
  -h|--help)
    cat <<'EOF'
Usage: bash tests/run.sh [unit|integration|all]

  unit         Run all unit tests (no network, no CURSOR_API_KEY required)
  integration  Run integration tests (requires CURSOR_API_KEY)
  all          Run unit then integration (default)

Env:
  NO_COLOR=1       disable color output
  VERBOSE=1        show per-assertion output even on PASS
  CURSOR_API_KEY   required for integration tests
EOF
    exit 0
    ;;
  *)
    printf 'Unknown mode: %s\nUsage: bash run.sh [unit|integration|all]\n' "${MODE}" >&2
    exit 64
    ;;
esac

if (( RUN_FAIL > 0 )); then
  exit 1
fi
exit 0
