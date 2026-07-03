#!/usr/bin/env bash
# test_launch.sh — self-contained unit tests for cursor-ide/lib/launch.sh.
# No network, no real GUI: a fake `cursor` stub records its argv to a file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH="${HERE}/../../lib/launch.sh"

pass=0
fail=0
ok()   { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (assert: $2)"; fi; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t cursor-ide)"
trap 'rm -rf "${WORK}"' EXIT

# --- fake `cursor` on PATH: append argv to $CURSOR_LOG, exit 0 ---------------
FAKEBIN="${WORK}/bin"
mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/cursor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURSOR_LOG}"
exit 0
EOF
chmod +x "${FAKEBIN}/cursor"

export CURSOR_LOG="${WORK}/cursor.log"
PATH_WITH="${FAKEBIN}:${PATH}"

# 1) explicit dir → LAUNCHED with the absolute path, and cursor saw it
: > "${CURSOR_LOG}"
TARGET="${WORK}/proj"; mkdir -p "${TARGET}"
out="$(PATH="${PATH_WITH}" bash "${LAUNCH}" "${TARGET}" 2>/dev/null)"
check "explicit dir → LAUNCHED line"      '[[ "${out}" == LAUNCHED*"${TARGET}" ]]'
check "explicit dir → cursor got the path" 'grep -qF "${TARGET}" "${CURSOR_LOG}"'

# 2) no arg → defaults to CWD
: > "${CURSOR_LOG}"
out="$(cd "${TARGET}" && PATH="${PATH_WITH}" bash "${LAUNCH}" 2>/dev/null)"
check "no arg → defaults to cwd"          '[[ "${out}" == LAUNCHED*"${TARGET}" ]]'

# 3) --new-window forwards --new-window to cursor
: > "${CURSOR_LOG}"
PATH="${PATH_WITH}" bash "${LAUNCH}" -n "${TARGET}" >/dev/null 2>&1
check "-n → cursor gets --new-window"      'grep -qF -- "--new-window" "${CURSOR_LOG}"'

# 4) --dry-run prints DRY_RUN and does NOT invoke cursor
: > "${CURSOR_LOG}"
out="$(PATH="${PATH_WITH}" bash "${LAUNCH}" --dry-run "${TARGET}" 2>/dev/null)"
check "--dry-run → DRY_RUN line"          '[[ "${out}" == DRY_RUN*cursor* ]]'
check "--dry-run → cursor NOT invoked"    '[[ ! -s "${CURSOR_LOG}" ]]'

# 5) missing path without --mkdir → non-zero, no launch
: > "${CURSOR_LOG}"
MISSING="${WORK}/nope"
PATH="${PATH_WITH}" bash "${LAUNCH}" "${MISSING}" >/dev/null 2>&1; rc=$?
check "missing path → non-zero exit"      '[[ "${rc}" -ne 0 ]]'
check "missing path → cursor NOT invoked" '[[ ! -s "${CURSOR_LOG}" ]]'

# 6) --mkdir creates the dir then launches it
: > "${CURSOR_LOG}"
NEWDIR="${WORK}/fresh/child"
out="$(PATH="${PATH_WITH}" bash "${LAUNCH}" --mkdir "${NEWDIR}" 2>/dev/null)"
check "--mkdir → directory created"       '[[ -d "${NEWDIR}" ]]'
check "--mkdir → LAUNCHED the new dir"    '[[ "${out}" == LAUNCHED*"${NEWDIR}" ]]'

# 7) cursor missing from PATH → exit 2 with an install hint on stderr
: > "${CURSOR_LOG}"
err="$(PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "${LAUNCH}" "${TARGET}" 2>&1 1>/dev/null)"; rc=$?
check "no cursor → exit 2"                '[[ "${rc}" -eq 2 ]]'
check "no cursor → prints install hint"   'printf "%s" "${err}" | grep -qiE "cursor.com|not found in PATH"'

# --- summary -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
