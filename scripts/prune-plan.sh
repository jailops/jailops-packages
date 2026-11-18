#!/bin/sh
# prune-plan.sh [--size | --generate SITE_DIR DIST_DIR OUT]
#
# The retention policy of the site (docs/RETENTION.md): only the newest two versions of every package and ABI stay on the
# site (the version clients install and the one before it); every older one leaves it. The publish job applies the policy
# itself in every master run (--generate); nothing is committed and nobody runs anything.
#   (no option)  print what the live site would drop at the next publish and the bytes that frees; writes nothing
#   --size       print the size of the published site (from its index) and stop
#   --generate SITE_DIR DIST_DIR OUT
#                the publish job's step: the plan for the repository about to be signed (the baseline SITE_DIR plus the
#                packages built now in DIST_DIR). OUT is the prune manifest the signing step applies: the committed
#                prune.yaml (explicit extra entries, normally none) plus one entry for every file of the baseline that
#                has a newer version in the repository to sign.
# SITE=URL (default https://pkg.jailops.net), PKGOPS=path of the pkgops binary. Pruning only leaves a file out of the
# site: every published package stays in the archive in GitHub Releases (only `pkgops archive prune`, a separate and
# confirmed step, touches that).
#
# What --generate guarantees:
#   - a version is planned only when a newer version of the same package and ABI is in the repository to sign, so a
#     package never ends without a version (pkgops refuses the newest one too: it needs `force: true`, which is never set here);
#   - only files of the baseline are planned. The baseline was verified against the archive before this step (verify-archive.sh),
#     so every planned file is archived; a version built in this run and already superseded in it stays on the site until
#     the next run, when it is a baseline file;
#   - the plan is deterministic: the same baseline and packages give the same OUT.
set -eu
. "$(dirname "$0")/lib.sh"

SITE=${SITE:-https://pkg.jailops.net}
KEEP=${KEEP:-2}   # the number of versions that stay: one constant (the tests set the variable to try others)
PKGOPS=${PKGOPS:-pkgops}
mode=plan
case "${1:-}" in
--size) mode=size ;;
--generate) mode=generate ;;
"") ;;
*) die "usage: prune-plan.sh [--size | --generate SITE_DIR DIST_DIR OUT]" ;;
esac
case "$KEEP" in ''|*[!0-9]*|0) die "KEEP must be a number of versions, 1 or more (got '$KEEP')" ;; esac
command -v "$PKGOPS" >/dev/null 2>&1 || die "pkgops is not on PATH (set PKGOPS=...)"

what="the newest $KEEP versions of each package are kept"
[ "$KEEP" = 1 ] && what="only the newest version of each package is kept"
reason="outside the retention policy: $what"

if [ "$mode" = size ]; then
  curl -fsS --max-time 60 "$SITE/pkgops-index.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
pk = d["packages"]
tot = sum(p.get("size", 0) for p in pk)
print("%d package files, %.1f MB (GitHub Pages publishes at most about 1 GB)" % (len(pk), tot / 1e6))'
  exit 0
fi

if [ "$mode" = plan ]; then
  cd "$REPO_ROOT"
  "$PKGOPS" prune --plan --from "$SITE" --manifest prune.yaml --keep "$KEEP" -n --by maintainers --reason "$reason"
  exit 0
fi

# ---- --generate
[ $# -eq 4 ] || die "usage: prune-plan.sh --generate SITE_DIR DIST_DIR OUT"
SITE_DIR=$2; DIST_DIR=$3; OUT=$4
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
[ -f "$SITE_DIR/pkgops-index.json" ] || die "$SITE_DIR has no pkgops-index.json: no baseline to plan against"

W=$(mktemp -d "${TMPDIR:-/tmp}/prune-plan.XXXXXX")
trap 'rm -rf "$W"' EXIT

# the repository about to be signed: the baseline and what was built now, assembled unsigned, only for its index
cp -a "$SITE_DIR" "$W/union"
if [ -n "$(find "$DIST_DIR" -name '*.pkg' -print -quit 2>/dev/null)" ]; then
  "$PKGOPS" repo --repo "$W/union" --policy "$REPO_ROOT/pkgops-repo.yaml" "$DIST_DIR" >/dev/null
fi

# the committed prune.yaml is the explicit part (an administrator's exceptional entries); the policy adds to it
if [ -f "$REPO_ROOT/prune.yaml" ]; then cp "$REPO_ROOT/prune.yaml" "$OUT"; else printf 'schema: 1\nentries: []\n' > "$OUT"; fi

# what the policy would take out of the repository to sign, sorted so that the plan is the same every time
"$PKGOPS" prune --plan --from "$W/union" --manifest "$OUT" --keep "$KEEP" -n --by publish --reason "$reason" |
  sed -n 's/^prune  \([^ ]*\) \(.*\)-\([^-]*\)$/\1 \2 \3/p' | sort > "$W/want"

: > "$W/kept"; : > "$W/later"; n=0; bytes=0
while IFS=' ' read -r abi name ver; do
  [ -n "$abi" ] || continue
  size=$(jq -r --arg a "$abi" --arg n "$name" --arg v "$ver" '[.packages[]? | select(.abi==$a and .name==$n and .version==$v) | .size][0] // empty' "$SITE_DIR/pkgops-index.json")
  if [ -z "$size" ]; then
    echo "$abi $name-$ver" >> "$W/later"   # built now and superseded now: not in the baseline, so not yet archived
    continue
  fi
  "$PKGOPS" prune --plan --from "$W/union" --manifest "$OUT" --abi "$abi" --name "$name" --version "$ver" --by publish --reason "$reason" >/dev/null
  echo "prune  $abi $name-$ver ($size bytes)"
  n=$((n + 1)); bytes=$((bytes + size))
done < "$W/want"

if [ -s "$W/later" ]; then
  while IFS= read -r l; do echo "stays this run (built now, not archived yet): $l"; done < "$W/later"
fi
echo "plan: $n file(s), $bytes bytes leave the site; the newest $KEEP versions stay; nothing is deleted from the archive"
