#!/bin/sh
# commit-verified.sh BRANCH MESSAGE FILE...
#
# Creates BRANCH at the current HEAD and puts the working-tree content of each FILE on it through GitHub's Contents
# API (one commit per file, all with MESSAGE), so the commits come back Verified, which a required_signatures ruleset
# on master asks for once the PR is merged with a merge commit. Needs GH_TOKEN and GITHUB_REPOSITORY (set in Actions).
# If anything fails the branch is deleted again: no stray branch is left behind. UNVERIFIED on GitHub here (the method
# comes from unidoc-aports' commit-verified.sh, which runs in production).
set -eu
BRANCH=${1:?usage: commit-verified.sh BRANCH MESSAGE FILE...}; MESSAGE=${2:?}; shift 2
[ $# -ge 1 ] || { echo "no files" >&2; exit 2; }

base=$(git rev-parse HEAD)
done_ok=
cleanup() {
  [ -n "$done_ok" ] || gh api --method DELETE "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base" >/dev/null
for f in "$@"; do
  sha=$(gh api "repos/$GITHUB_REPOSITORY/contents/$f?ref=$BRANCH" --jq .sha)
  gh api --method PUT "repos/$GITHUB_REPOSITORY/contents/$f" \
    -f message="$MESSAGE" -f content="$(base64 "$f" | tr -d '\n')" -f sha="$sha" -f branch="$BRANCH" >/dev/null
  echo "committed $f on $BRANCH"
done
done_ok=1
