#!/bin/sh
# split-plan.sh public|private ENTRY...
#
# ENTRY is name or name:abi,abi (scripts/changed.sh --pairs). Prints, on one line, the entries whose package needs no token
# to fetch its source (public: token_env of main/<name>/upstream.yaml is empty) or does (private). The build job runs
# with no secret and builds the public ones; the private ones are built by the master-only job that holds
# JAILOPS_SOURCE_TOKEN (docs/supply-chain.md, "The source token").
set -eu
. "$(dirname "$0")/lib.sh"

kind=${1:-}
case "$kind" in public|private) shift ;; *) die "usage: split-plan.sh public|private ENTRY..." ;; esac

out=
for e in "$@"; do
  p=${e%%:*}
  [ -f "$MAIN/$p/pkgops.yaml" ] || die "no such package: $p"
  if [ -n "$(up_get "$p" token_env)" ]; then want=private; else want=public; fi
  [ "$want" = "$kind" ] && out="$out$e "
done
echo $out
