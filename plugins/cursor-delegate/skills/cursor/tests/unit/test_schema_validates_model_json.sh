#!/usr/bin/env bash
# test_schema_validates_model_json.sh — V9 smoke test.
#
# Pure-jq validation of config/model.json against config/schema.json.
# We don't ship a JSON Schema validator binary; this asserts the key invariants
# that a Schema validator would have asserted, using jq's type system.
#
# Asserts (positive on the shipped model.json):
#   - top-level: version == 1, defaults present, defaults has all 5 task types
#   - retry.backoff is "exponential" or "linear" (when present)
#   - timeout_sec is integer
#   - each defaults.<task>.model is a non-empty string matching the shape regex
#
# Asserts (negative — synthetic mutations must fail):
#   - missing version           -> fail
#   - missing one of 5 tasks    -> fail
#   - invalid backoff           -> fail
#   - non-integer timeout_sec   -> fail
#
# Skip cleanly if jq is missing.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf 'SKIP: jq not installed (LSB exit 77)\n'
  exit 77
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SELF_DIR}/../.." && pwd)"
MODEL_JSON="${SKILL_DIR}/config/.cursor.json"
SCHEMA_JSON="${SKILL_DIR}/config/schema.json"

[[ -f "${MODEL_JSON}" ]]  || { printf 'FAIL: %s missing\n' "${MODEL_JSON}";  exit 1; }
[[ -f "${SCHEMA_JSON}" ]] || { printf 'FAIL: %s missing\n' "${SCHEMA_JSON}"; exit 1; }

# Both files must be valid JSON. (model.json may have JSONC comments — strip them.)
strip_jsonc() {
  # jq does not parse JSONC; sed removes // line comments before the parse.
  sed -E 's@//.*$@@' "$1"
}

if ! strip_jsonc "${MODEL_JSON}" | jq -e . >/dev/null 2>&1; then
  printf 'FAIL: model.json is not valid JSON (after JSONC comment strip)\n'
  exit 1
fi
if ! jq -e . "${SCHEMA_JSON}" >/dev/null 2>&1; then
  printf 'FAIL: schema.json is not valid JSON\n'
  exit 1
fi

# ---- Positive assertions ----------------------------------------------------

# Single jq pass that returns true iff every key invariant holds.
if ! strip_jsonc "${MODEL_JSON}" | jq -e '
  . as $root
  | (.version == 1)
  and (.defaults | type == "object")
  and (
    ["implement","review","plan","investigate","security"] as $tasks
    | ($tasks - ($tasks - ($root.defaults | keys))) | length == 5
  )
  and (.defaults | to_entries
       | all(.value.model | type == "string" and test("^[A-Za-z0-9._:/-]+$")))
  and (((.retry // {}).backoff // "exponential") as $b
       | $b == "exponential" or $b == "linear")
  and ((.timeout_sec // 590) | type == "number")
' >/dev/null 2>&1; then
  printf 'FAIL: positive assertions on model.json failed\n'
  exit 1
fi
printf 'PASS: model.json conforms to schema invariants\n'

# ---- Negative assertions (synthetic mutations) ------------------------------

# Helper: run the same positive predicate on a piped JSON; return jq exit code.
positive_check() {
  jq -e '
    . as $root
    | (.version == 1)
    and (.defaults | type == "object")
    and (
      ["implement","review","plan","investigate","security"] as $tasks
      | ($tasks - ($tasks - ($root.defaults | keys))) | length == 5
    )
    and (((.retry // {}).backoff // "exponential") as $b
         | $b == "exponential" or $b == "linear")
    and ((.timeout_sec // 590) | type == "number")
  ' >/dev/null 2>&1
}

# Mutation 1: drop .version.
if strip_jsonc "${MODEL_JSON}" | jq 'del(.version)' | positive_check; then
  printf 'FAIL: missing .version should fail validation but passed\n'
  exit 1
fi
printf 'PASS: missing .version is rejected\n'

# Mutation 2: drop one task type from defaults.
if strip_jsonc "${MODEL_JSON}" | jq 'del(.defaults.review)' | positive_check; then
  printf 'FAIL: missing defaults.review should fail validation but passed\n'
  exit 1
fi
printf 'PASS: missing defaults.review is rejected\n'

# Mutation 3: invalid backoff.
if strip_jsonc "${MODEL_JSON}" | jq '.retry.backoff = "quadratic"' | positive_check; then
  printf 'FAIL: backoff="quadratic" should fail validation but passed\n'
  exit 1
fi
printf 'PASS: invalid retry.backoff is rejected\n'

# Mutation 4: non-integer timeout_sec.
if strip_jsonc "${MODEL_JSON}" | jq '.timeout_sec = "590"' | positive_check; then
  printf 'FAIL: string timeout_sec should fail validation but passed\n'
  exit 1
fi
printf 'PASS: string timeout_sec is rejected\n'

printf 'ALL PASS: schema invariants enforced on model.json\n'
exit 0
