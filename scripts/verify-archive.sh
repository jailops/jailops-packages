#!/bin/sh
# verify-archive.sh ARGS...    `pkgops verify-archive ARGS...`, and a stop when a file that prune.yaml leaves out of the site is not
# in the archive. pkgops lists those files as "gone for good" but does not fail on them; here it does, so that a version leaves
# the site only when the archive in GitHub Releases holds it (docs/RETENTION.md). Output and exit status are pkgops's otherwise.
set -u
out=$(mktemp "${TMPDIR:-/tmp}/verify-archive.XXXXXX") || exit 1
trap 'rm -f "$out"' EXIT
rc=0
pkgops verify-archive "$@" > "$out" 2>&1 || rc=$?
cat "$out"
if grep -Eq 'gone for good\): [1-9]' "$out"; then
  echo "error: prune.yaml leaves out of the site a file that the archive does not hold: take it out of prune.yaml, or archive it first" >&2
  rc=1
fi
exit $rc
