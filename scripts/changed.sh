#!/bin/sh
# changed.sh BASE HEAD [SITE_DIR]
#
# Prints (one line, space separated) the packages to build:
#   - every package whose files under main/ differ between BASE and HEAD, and
#   - every package whose current version is missing from SITE_DIR/pkgops-index.json for one of its ABIs
#     (a baseline fetched with scripts/baseline.sh): that is what makes a first run, a manual re-run after a failed
#     deploy and a restore from the archive build exactly what the site lacks, and nothing else.
# When BASE is empty, all zeros or unknown to git (new branch, force push) nothing can be diffed: with a SITE_DIR the
# index decides alone, without one every package is printed.
# Unchanged packages are NOT rebuilt: their files come from the baseline.
set -eu
. "$(dirname "$0")/lib.sh"

BASE=${1:-}; HEAD=${2:-HEAD}; SITE=${3:-}
all=$(all_pkgs | tr '\n' ' ')
out=" "
add() { case "$out" in *" $1 "*) ;; *) out="$out$1 " ;; esac; }

have_base=
if [ -n "$BASE" ] && [ "$BASE" != 0000000000000000000000000000000000000000 ] &&
   git -C "$REPO_ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null; then have_base=1; fi

if [ -n "$have_base" ]; then
  for f in $(git -C "$REPO_ROOT" diff --name-only "$BASE" "$HEAD" -- main/); do
    p=${f#main/}; p=${p%%/*}
    case " $all " in *" $p "*) add "$p" ;; esac   # a deleted package directory is not built
  done
elif [ -z "$SITE" ]; then
  for p in $all; do add "$p"; done
fi

if [ -n "$SITE" ]; then
  for p in $all; do
    v=$(mf_get "$p" version)
    for abi in $(abis_of "$p"); do
      index_has "$SITE" "$p" "$v" "$abi" || { add "$p"; break; }
    done
  done
fi

echo $out
