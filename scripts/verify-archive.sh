#!/bin/sh
# verify-archive.sh ARGS...    `pkgops verify-archive ARGS...`, and a stop when a file that the site no longer serves is not in the
# archive. pkgops lists those files as "gone for good" but does not fail on them; here it does, so that a version leaves the
# site only when the archive in GitHub Releases holds it (docs/RETENTION.md), with one exception: a file recorded in
# retired.yaml (written by scripts/archive-trim.sh when the owner trims the archive) may be gone. Output and exit status are
# pkgops's otherwise.
#   RETIRED_FILE=PATH   the record of retired files (default: retired.yaml in the repository root)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
RETIRED_FILE=${RETIRED_FILE:-$HERE/retired.yaml}
out=$(mktemp "${TMPDIR:-/tmp}/verify-archive.XXXXXX") || exit 1
trap 'rm -f "$out" "$out.gone" "$out.retired"' EXIT
rc=0
pkgops verify-archive "$@" > "$out" 2>&1 || rc=$?
cat "$out"

n=$(sed -n 's/^pruned from Pages and not archived (gone for good): \([0-9][0-9]*\)$/\1/p' "$out" | head -n 1)
if [ "${n:-0}" -gt 0 ]; then
  # the keys pkgops printed under the header ("ABI name-version"), and the keys of retired.yaml
  awk '/^pruned from Pages and not archived \(gone for good\):/ {on=1; next} on && /^   [^ ]/ {sub(/^   /, ""); print; next} on {on=0}' "$out" | sort > "$out.gone"
  : > "$out.retired"
  if [ -f "$RETIRED_FILE" ]; then
    awk '/^  - name:/ {n=$3} /^    version:/ {v=$2} /^    abi:/ {print $2 " " n "-" v}' "$RETIRED_FILE" | sort > "$out.retired"
  fi
  listed=$(wc -l < "$out.gone" | tr -d ' ')
  unlisted=$(comm -23 "$out.gone" "$out.retired")
  if [ "$listed" != "$n" ]; then
    echo "error: pkgops counts $n file(s) gone for good but lists $listed: not read as retired" >&2
    rc=1
  elif [ -n "$unlisted" ]; then
    echo "error: the site no longer serves a file that the archive does not hold, and retired.yaml does not list it:" >&2
    echo "$unlisted" | sed 's/^/  /' >&2
    echo "error: take it out of prune.yaml, or archive it first (retired.yaml is written by scripts/archive-trim.sh only)" >&2
    rc=1
  else
    echo "note: $n file(s) gone from the archive, all recorded in retired.yaml"
  fi
fi
exit $rc
