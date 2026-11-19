#!/bin/sh
# abis.sh [--arch ARCH]
#
# The ABIs the repository serves: the union of the `abis:` lists of every manifest under main/, one per line, sorted,
# without duplicates. The workflows and the update check read the list from here, so FreeBSD 16 reaches them by
# naming FreeBSD:16:amd64 and FreeBSD:16:aarch64 in the manifests (and in pkgops-repo.yaml, which scripts/check-pkgops.sh
# keeps equal to this list).
#
#   --arch ARCH   only the ABIs of that architecture (amd64 or aarch64): one per major, for what needs a single
#                 architecture, such as the comparison of package names with the official catalog
#
# REPO_ROOT may be set to run against another checkout (the tests do).
set -eu
. "$(dirname "$0")/lib.sh"

arch=
case "${1:-}" in
  '') ;;
  --arch) arch=${2:-}; [ -n "$arch" ] || die "usage: abis.sh [--arch ARCH]" ;;
  *) die "usage: abis.sh [--arch ARCH]" ;;
esac

out=$(for p in $(all_pkgs); do abis_of "$p"; done | sort -u)
[ -n "$out" ] || die "no ABI in any manifest under main/"
if [ -n "$arch" ]; then
  out=$(printf '%s\n' "$out" | grep -E ":$arch\$" || true)
  [ -n "$out" ] || die "no ABI for the architecture $arch"
fi
printf '%s\n' "$out"
