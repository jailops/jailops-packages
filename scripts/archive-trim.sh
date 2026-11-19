#!/bin/sh
# archive-trim.sh --keep N [--apply]
#
# Trims the archive in GitHub Releases (docs/RETENTION.md, "Trimming the archive"): the oldest versions of every package beyond the
# newest N leave the archive. The archive has no known size limit; this is the tool for the day it needs one, not a schedule.
# No workflow runs it. Without --apply it prints the plan and changes nothing.
#
#   --keep N    the newest N versions of every package stay (N is 1 or more)
#   --apply     delete those releases with `gh release delete` and record every retired file in retired.yaml
#
#   REPO=OWNER/REPO   the repository whose Releases hold the archive (default jailops/jailops-packages)
#   SITE=URL|DIR      the published site, or a directory with its pkgops-index.json (default https://pkg.jailops.net)
#   GH=gh             the GitHub CLI (authenticated: `gh auth status`)
#   RETIRED_FILE=PATH the record (default retired.yaml in the repository root); commit it with the trim
#
# A release `pkg-NAME-VERSION` is planned only when:
#   - it is not one of the newest N versions of the package (versions known from the site's index, its `pruned` list and the
#     archive, ordered like pkg orders them: epoch, dotted numbers, revision),
#   - the site does not serve it (every version on the site is kept, whatever its age),
#   - the site's index knows it (a release that the index does not mention is not touched).
# The tool stops without changing anything when the site and the archive disagree: a version the index lists on the site or
# under `pruned` that has no release in the archive and is not in retired.yaml. With --apply it also runs
# scripts/verify-archive.sh against the live site first (set ARCHIVE_VERIFY=true to skip it, the tests do).
# Every deleted file is recorded in retired.yaml (name, version, ABI, sha256, size, date) before the release is deleted, and
# scripts/verify-archive.sh accepts "gone for good" exactly for the files recorded there.
set -eu
. "$(dirname "$0")/lib.sh"

REPO=${REPO:-jailops/jailops-packages}
SITE=${SITE:-https://pkg.jailops.net}
GH=${GH:-gh}
RETIRED_FILE=${RETIRED_FILE:-$REPO_ROOT/retired.yaml}
keep=; apply=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) [ $# -ge 2 ] || die "--keep needs a number"; keep=$2; shift ;;
  --apply) apply=1 ;;
  *) die "usage: archive-trim.sh --keep N [--apply]" ;;
  esac
  shift
done
case "$keep" in ''|*[!0-9]*|0) die "--keep N is required, N is 1 or more (got '${keep:-}')" ;; esac
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
command -v "$GH" >/dev/null 2>&1 || die "$GH (the GitHub CLI) is not on PATH"

W=$(mktemp -d "${TMPDIR:-/tmp}/archive-trim.XXXXXX"); trap 'rm -rf "$W"' EXIT
case "$SITE" in
http://*|https://*) curl -fsS --max-time 60 "$SITE/pkgops-index.json" > "$W/index.json" || die "cannot fetch $SITE/pkgops-index.json" ;;
*) [ -f "$SITE/pkgops-index.json" ] || die "$SITE has no pkgops-index.json"; cp "$SITE/pkgops-index.json" "$W/index.json" ;;
esac
"$GH" release list --repo "$REPO" --limit 1000 --json tagName > "$W/releases.json" || die "cannot list the releases of $REPO (gh auth status?)"

python3 - "$W/index.json" "$W/releases.json" "$keep" "$RETIRED_FILE" "${RETIRED_DATE:-$(date -u +%Y-%m-%d)}" "$W/plan.tsv" "$W/retired.new" "$W/plan.txt" <<'PY' || exit 1
import json, os, re, sys

index_p, rel_p, keep, retired_p, today, plan_p, new_p, txt_p = sys.argv[1:9]
keep = int(keep)

def vkey(v):
    """pkg order: [epoch,] dotted version [_revision]; refuses what it cannot read."""
    m = re.fullmatch(r"([0-9A-Za-z.+~]+?)(?:_([0-9]+))?(?:,([0-9]+))?", v)
    if not m:
        sys.exit("error: version '%s' is not in the pkg grammar this tool reads: stopping" % v)
    parts = []
    for p in re.split(r"\.", m.group(1)):
        parts.append((0, int(p), "") if p.isdigit() else (1, 0, p))
    return (int(m.group(3) or 0), parts, int(m.group(2) or 0))

ix = json.load(open(index_p))
live = ix.get("packages", [])
pruned = ix.get("pruned", [])
tags = [r["tagName"] for r in json.load(open(rel_p))]

retired = set()
if os.path.exists(retired_p):
    n = v = None
    for line in open(retired_p):
        m = re.match(r"\s+- name:\s*(\S+)", line)
        if m: n = m.group(1)
        m = re.match(r"\s+version:\s*(\S+)", line)
        if m: v = m.group(1)
        if re.match(r"\s+abi:\s*\S+", line) and n and v:
            retired.add((n, v))

names = sorted({p["name"] for p in live} | {p["name"] for p in pruned})
on_site = {(p["name"], p["version"]) for p in live}
known = {}                     # (name, version) -> entries of the index (every ABI)
for p in live + pruned:
    known.setdefault((p["name"], p["version"]), []).append(p)

archived = {}                  # name -> versions that have a release
for name in names:
    pre = "pkg-%s-" % name
    for t in tags:
        if t.startswith(pre) and t[len(pre):][:1].isdigit():
            archived.setdefault(name, set()).add(t[len(pre):])

# the site and the archive must agree before anything is deleted
missing = sorted("%s-%s" % k for k in known if k[1] not in archived.get(k[0], set()) and k not in retired)
if missing:
    sys.stderr.write("error: the site's index lists a version that has no release in the archive and is not in retired.yaml:\n")
    for m in missing: sys.stderr.write("  %s\n" % m)
    sys.stderr.write("error: the site and the archive disagree: nothing is changed (scripts/verify-archive.sh says which files)\n")
    sys.exit(1)

plan = []
for name in names:
    # the order and the newest N come from the versions the index knows: a release the index does not mention never pushes a known one out of the newest N
    versions = sorted({v for (n, v) in known if n == name}, key=vkey)
    protected = set(versions[-keep:])
    for v in versions:
        if v in protected or (name, v) in on_site or v not in archived.get(name, set()):
            continue
        plan.append((name, v))

with open(plan_p, "w") as f:
    for name, v in plan:
        ents = sorted(known[(name, v)], key=lambda e: e["abi"])
        f.write("%s\t%s\t%s\n" % (name, v, ",".join("%s:%s:%s" % (e["abi"], e["sha256"], e.get("size", 0)) for e in ents)))

with open(txt_p, "w") as f:
    total = 0
    for name, v in plan:
        ents = sorted(known[(name, v)], key=lambda e: e["abi"])
        size = sum(int(e.get("size", 0)) for e in ents)
        total += size
        f.write("  pkg-%s-%s  (%s; %.1f MB)\n" % (name, v, ", ".join(e["abi"] for e in ents), size / 1e6))
    f.write("plan: %.1f MB in total\n" % (total / 1e6))

# retired.yaml as it will be: what is there plus the planned files, sorted
old = []
if os.path.exists(retired_p):
    cur = {}
    for line in open(retired_p):
        for k in ("name", "version", "abi", "sha256", "size", "retired"):
            m = re.match(r"\s+(?:- )?%s:\s*(\S+)" % k, line)
            if m:
                if k == "name" and cur: old.append(cur); cur = {}
                cur[k] = m.group(1)
    if cur: old.append(cur)
for name, v in plan:
    for e in sorted(known[(name, v)], key=lambda e: e["abi"]):
        old.append({"name": name, "version": v, "abi": e["abi"], "sha256": e["sha256"], "size": str(e.get("size", 0)), "retired": today})
seen = set(); rows = []
for r in sorted(old, key=lambda r: (r["name"], vkey(r["version"]), r["abi"])):
    k = (r["name"], r["version"], r["abi"])
    if k not in seen:
        seen.add(k); rows.append(r)
with open(new_p, "w") as f:
    f.write("schema: 1\n")
    if not rows:
        f.write("entries: []\n")
    else:
        f.write("entries:\n")
        for r in rows:
            f.write("  - name: %s\n    version: %s\n    abi: %s\n    sha256: %s\n    size: %s\n    retired: %s\n" %
                    (r["name"], r["version"], r["abi"], r["sha256"], r["size"], r["retired"]))
PY

n=$(wc -l < "$W/plan.tsv" | tr -d ' ')
echo "archive: $REPO, keeping the newest $keep version(s) of every package"
if [ "$n" -eq 0 ]; then echo "plan: nothing to trim"; exit 0; fi
echo "plan: $n release(s) leave the archive"
cat "$W/plan.txt"
if [ "$apply" -ne 1 ]; then echo "nothing changed: --apply deletes these releases and records them in $(basename "$RETIRED_FILE")"; exit 0; fi

# --apply: the live site and the archive agree (the full per-file check), then record, then delete
[ "${ARCHIVE_VERIFY:-}" = true ] || sh "$(dirname "$0")/verify-archive.sh" --repo "$REPO" --from "$SITE" || die "the site and the archive disagree: nothing is changed"
cp "$W/retired.new" "$RETIRED_FILE.tmp" && mv "$RETIRED_FILE.tmp" "$RETIRED_FILE"
echo "recorded in $RETIRED_FILE (commit it)"
while IFS='	' read -r name version files; do
  echo "delete pkg-$name-$version"
  "$GH" release delete "pkg-$name-$version" --repo "$REPO" --yes --cleanup-tag || die "gh could not delete pkg-$name-$version; $(basename "$RETIRED_FILE") lists releases that may still exist (harmless): run again"
done < "$W/plan.tsv"
echo "done: $n release(s) deleted; commit $(basename "$RETIRED_FILE")"
