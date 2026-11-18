#!/bin/sh
# verify-site.sh SITE_DIR
#
# After the new packages were added: every package in main/ that is ready to build must be on the site, for every ABI,
# at its current version (the guard against a package silently vanishing from the deploy). Packages that are not ready
# are reported, not failed, unless VERIFY_SITE_STRICT=1 (the publish job): then they fail too. With PRUNE_FILE (the prune
# manifest the signing step applied) it also checks that nothing the manifest lists is still on the site. With
# VERIFY_SITE_STRICT=1 it also checks the closure of the dependencies: every dependency with an origin jailops/... of
# every package on the site is on the site for the same ABI, by name (pkg's solver resolves a dependency by name, not by
# the version the package recorded), so a pruned version never leaves a kept package without what it needs.
set -eu
. "$(dirname "$0")/lib.sh"
SITE=${1:?usage: verify-site.sh SITE_DIR}
[ -f "$SITE/pkgops-index.json" ] || die "$SITE has no pkgops-index.json"
bad=0
for p in $(all_pkgs); do
  v=$(mf_get "$p" version)
  for abi in $(abis_of "$p"); do
    if index_has "$SITE" "$p" "$v" "$abi"; then continue; fi
    if [ "${VERIFY_SITE_STRICT:-}" != 1 ] && ! pkg_ready "$p"; then echo "not published (not ready): $p $v $abi: $REASON" >&2; continue; fi
    echo "MISSING from the site: $p $v $abi" >&2; bad=1
  done
done
if [ -n "${PRUNE_FILE:-}" ] && [ -f "$PRUNE_FILE" ]; then
  # entries are written as "- abi: X", "name: Y", "version: Z" (the version comes last of the three)
  sed -e 's/^[[:space:]]*-[[:space:]]*abi:/abi:/' "$PRUNE_FILE" |
    awk '/^[[:space:]]*abi:/{a=$2} /^[[:space:]]*name:/{n=$2} /^[[:space:]]*version:/{v=$2; gsub(/["\x27]/, "", v); print a, n, v}' > "${TMPDIR:-/tmp}/verify-site.$$"
  while IFS=' ' read -r a n v; do
    [ -n "$a" ] || continue
    if index_has "$SITE" "$n" "$v" "$a"; then echo "STILL on the site although the prune manifest lists it: $n $v $a" >&2; bad=1; fi
  done < "${TMPDIR:-/tmp}/verify-site.$$"
  rm -f "${TMPDIR:-/tmp}/verify-site.$$"
fi
if [ "${VERIFY_SITE_STRICT:-}" = 1 ]; then
  command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
  command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH (needed to read the dependencies of the packages)"
  W=$(mktemp -d "${TMPDIR:-/tmp}/verify-site.XXXXXX")
  trap 'rm -rf "$W"' EXIT
  jq -r '.packages[]? | "\(.abi) \(.name)"' "$SITE/pkgops-index.json" | sort -u > "$W/names"
  jq -r '.packages[]? | "\(.abi) \(.name) \(.version) \(.file)"' "$SITE/pkgops-index.json" | sort > "$W/pkgs"
  while IFS=' ' read -r abi name ver file; do
    [ -n "$abi" ] || continue
    if [ ! -f "$SITE/$file" ]; then echo "MISSING file: $name $ver $abi is in the index but $file is not on the site" >&2; bad=1; continue; fi
    pkgops inspect "$SITE/$file" | head -n 1 |
      jq -r '.deps // {} | to_entries[] | select(.value.origin | startswith("jailops/")) | .key' > "$W/deps" || { echo "cannot read the dependencies of $file" >&2; bad=1; continue; }
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      grep -qx -F -e "$abi $dep" "$W/names" || { echo "MISSING dependency: $name $ver $abi needs $dep (origin jailops/...), which is not on the site for that ABI" >&2; bad=1; }
    done < "$W/deps"
  done < "$W/pkgs"
fi
exit $bad
