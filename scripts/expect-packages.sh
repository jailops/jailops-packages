#!/bin/sh
# expect-packages.sh SITE_DIR DIST_DIR
#
# Before anything is signed: every package of main/, at the version of its manifest, for every ABI of its manifest, must
# be in the repository that is about to be signed: listed in the baseline's pkgops-index.json (SITE_DIR) or built now
# (DIST_DIR/<ABI>/<name>-<version>.pkg). Nothing is excused: a package that was skipped, or that a build never made,
# stops the publish here and is listed. A package built now that the baseline already holds must have the same bytes
# (a published file is immutable): the two sha256 are printed when they differ.
set -eu
. "$(dirname "$0")/lib.sh"
SITE=${1:?usage: expect-packages.sh SITE_DIR DIST_DIR}
DIST=${2:?usage: expect-packages.sh SITE_DIR DIST_DIR}
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
bad=0
idx=$SITE/pkgops-index.json
for p in $(all_pkgs); do
  v=$(mf_get "$p" version)
  for abi in $(abis_of "$p"); do
    f=$DIST/$abi/$p-$v.pkg
    if [ -f "$f" ] && [ -f "$idx" ]; then
      old=$(jq -r --arg n "$p" --arg v "$v" --arg a "$abi" '.packages[]? | select(.name==$n and .version==$v and .abi==$a) | .sha256' "$idx" | head -n 1)
      new=$(sha256_of "$f")
      if [ -n "$old" ] && [ "$old" != "$new" ]; then
        echo "CHANGED: $p $v $abi is published with sha256 $old and was built now with $new: a published file is immutable" >&2; bad=1
      fi
      continue
    fi
    [ -f "$f" ] && continue
    index_has "$SITE" "$p" "$v" "$abi" && continue
    echo "MISSING: $p $v $abi is neither in the baseline nor built now" >&2; bad=1
  done
done
[ "$bad" = 0 ] && echo "expect-packages: every package of main/ is in the repository to sign" >&2
exit $bad
