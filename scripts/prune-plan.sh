#!/bin/sh
# prune-plan.sh [--write] [--size]
#
# The retention policy of the site (docs/RETENTION.md): keep the newest KEEP versions of every package and ABI (default 3: the
# newest and the two before it); everything older goes into prune.yaml, and the next publish leaves it out of the site.
#   (no option)  print the plan and the bytes it frees; writes nothing
#   --write      write the plan into prune.yaml (then review it, commit it in a pull request, let the publish apply it)
#   --size       print the size of the published site (from its index) and stop
# KEEP=N, SITE=URL (default https://pkg.jailops.net), PKGOPS=path of the pkgops binary. Needs network (it reads the published
# index) and pkgops on PATH. It never deletes anything: pruning only leaves a file out of the site; every published
# package stays in the archive in GitHub Releases (only `pkgops archive prune`, a separate and confirmed step, touches that).
set -eu
. "$(dirname "$0")/lib.sh"

SITE=${SITE:-https://pkg.jailops.net}
KEEP=${KEEP:-3}
PKGOPS=${PKGOPS:-pkgops}
mode=plan
case "${1:-}" in
--write) mode=write ;;
--size) mode=size ;;
"") ;;
*) die "usage: prune-plan.sh [--write] [--size]" ;;
esac
case "$KEEP" in ''|*[!0-9]*|0) die "KEEP must be a number of versions, 1 or more (got '$KEEP')" ;; esac
command -v "$PKGOPS" >/dev/null 2>&1 || die "pkgops is not on PATH (set PKGOPS=...)"

if [ "$mode" = size ]; then
  curl -fsS --max-time 60 "$SITE/pkgops-index.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pk = d["packages"]
tot = sum(p.get("size", 0) for p in pk)
print("%d package files, %.1f MB (GitHub Pages publishes at most about 1 GB)" % (len(pk), tot / 1e6))'
  exit 0
fi

flag=-n
[ "$mode" = write ] && flag=
cd "$REPO_ROOT"
# shellcheck disable=SC2086
"$PKGOPS" prune --plan --from "$SITE" --manifest prune.yaml --keep "$KEEP" $flag --by maintainers \
  --reason "outside the retention policy: the newest $KEEP versions of each package are kept"
