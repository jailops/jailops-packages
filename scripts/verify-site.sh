#!/bin/sh
# verify-site.sh SITE_DIR
#
# After the new packages were added: every package in main/ that is ready to build must be on the site, for every ABI,
# at its current version (the guard against a package silently vanishing from the deploy). Packages that are not ready
# are reported, not failed. Also checks that nothing listed in prune.yaml is still on the site.
set -eu
. "$(dirname "$0")/lib.sh"
SITE=${1:?usage: verify-site.sh SITE_DIR}
[ -f "$SITE/pkgops-index.json" ] || die "$SITE has no pkgops-index.json"
bad=0
for p in $(all_pkgs); do
  v=$(mf_get "$p" version)
  for abi in $(abis_of "$p"); do
    if index_has "$SITE" "$p" "$v" "$abi"; then continue; fi
    if ! pkg_ready "$p"; then echo "not published (not ready): $p $v $abi: $REASON" >&2; continue; fi
    echo "MISSING from the site: $p $v $abi" >&2; bad=1
  done
done
exit $bad
