#!/usr/bin/env bash
#
# publish-main.sh — regenerate the distribution branch (main) as a clean
# snapshot of the source branch (develop), with test/dev-only files stripped.
#
# Why a snapshot instead of a merge: `.gitignore` only affects untracked files,
# so once tests are committed on develop they cannot be auto-ignored on main.
# Rebuilding main as a snapshot each run means it never accumulates the excluded
# files and never hits modify/delete merge conflicts. develop stays the single
# source of truth.
#
# How it works: a throwaway index (GIT_INDEX_FILE) is loaded from develop's
# committed tree, the excluded paths are removed from that index, the resulting
# tree is committed onto main. Your checked-out develop working tree is never
# touched.
#
# Usage:
#   scripts/publish-main.sh            # build main locally from develop
#   scripts/publish-main.sh --push     # ...and push main to origin
#
# Env overrides: SRC_BRANCH (default develop), DEST_BRANCH (main), REMOTE (origin)

set -euo pipefail

SRC_BRANCH="${SRC_BRANCH:-develop}"
DEST_BRANCH="${DEST_BRANCH:-main}"
REMOTE="${REMOTE:-origin}"
PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

# --- Paths kept out of the published (main) branch ---------------------------
# Edit this list to change what stays develop-only. Paths are repo-root
# relative; a directory strips everything under it.
EXCLUDES=(
  "plugins/cursor-delegate/skills/cursor/tests"
  "plugins/cursor-delegate/skills/cursor/TODO.md"
  "plugins/cursor-delegate/skills/cursor/references/maintainers.md"
  "scripts"
)

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

git rev-parse --verify --quiet "$SRC_BRANCH" >/dev/null || {
  echo "error: source branch '$SRC_BRANCH' not found" >&2; exit 1; }

SRC_SHA="$(git rev-parse --short "$SRC_BRANCH")"

# --- Build tree = develop's tree minus excludes, via a throwaway index -------
TMP_INDEX="$(mktemp -t publish-main.XXXXXX)"
trap 'rm -f "$TMP_INDEX"' EXIT
export GIT_INDEX_FILE="$TMP_INDEX"

git read-tree "$SRC_BRANCH"
git rm -r -f --cached --quiet --ignore-unmatch -- "${EXCLUDES[@]}"
NEW_TREE="$(git write-tree)"

unset GIT_INDEX_FILE   # back to the real index for everything below

# --- Commit the tree onto main (snapshot; parent = previous main if any) -----
MSG="Publish ${SRC_BRANCH}@${SRC_SHA} (strip tests + dev-only files)"
if git rev-parse --verify --quiet "$DEST_BRANCH" >/dev/null; then
  NEW_COMMIT="$(git commit-tree "$NEW_TREE" -p "$DEST_BRANCH" -m "$MSG")"
else
  NEW_COMMIT="$(git commit-tree "$NEW_TREE" -m "$MSG")"
fi
git update-ref "refs/heads/$DEST_BRANCH" "$NEW_COMMIT"

echo "✓ ${DEST_BRANCH} -> $(git rev-parse --short "$DEST_BRANCH")  (snapshot of ${SRC_BRANCH}@${SRC_SHA})"

# --- Self-check: every exclude must be absent from the published tree --------
leak=0
for p in "${EXCLUDES[@]}"; do
  if [ -n "$(git ls-tree -r --name-only "$DEST_BRANCH" -- "$p")" ]; then
    echo "  ! still present in ${DEST_BRANCH}: $p" >&2; leak=1
  fi
done
if [ "$leak" -ne 0 ]; then
  echo "error: exclude leak detected — main NOT clean" >&2; exit 1
fi
echo "✓ excludes verified absent from ${DEST_BRANCH}"

if [ "$PUSH" -eq 1 ]; then
  git push "$REMOTE" "$DEST_BRANCH"
  echo "✓ pushed ${DEST_BRANCH} to ${REMOTE}"
else
  echo "next: git push ${REMOTE} ${DEST_BRANCH}"
fi
