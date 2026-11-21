#!/usr/bin/env bash
# Commit a results directory to the ci-results branch under runs/<run>-<name>/ and latest/<name>/.
#   publish-results.sh <dir> <name>
set -euo pipefail
SRC="$(cd "$1" && pwd)"; NAME="$2"
REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}"
W=$(mktemp -d)
cd "$W"
git init -q && git config user.name ci && git config user.email ci@users.noreply.github.com
for attempt in 1 2 3 4 5; do
  rm -rf ./* .git/index 2>/dev/null || true
  if git fetch -q --depth 1 "$REPO" ci-results 2>/dev/null; then git checkout -q -f FETCH_HEAD; else git checkout -q --orphan ci-results; fi
  D="runs/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}-${NAME}"
  mkdir -p "$D" "latest"
  cp -R "$SRC/." "$D/"
  rm -rf "latest/$NAME" && cp -R "$SRC" "latest/$NAME"
  echo "${GITHUB_SHA} ${GITHUB_RUN_ID}" > "latest/$NAME/COMMIT"
  # Keep the branch small: only the last 30 run folders.
  ls -d runs/* 2>/dev/null | sort -t- -k1,1n | head -n -30 | xargs -r git rm -rq --ignore-unmatch || true
  git add -A && git commit -qm "results ${NAME} ${GITHUB_RUN_ID}" || true
  git push -q "$REPO" HEAD:refs/heads/ci-results && exit 0
  sleep $((attempt * 3))
done
exit 1
