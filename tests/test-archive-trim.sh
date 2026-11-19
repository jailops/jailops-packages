#!/bin/sh
# Offline tests of scripts/archive-trim.sh and of retired.yaml in scripts/verify-archive.sh (docs/RETENTION.md, "Trimming the
# archive"). The site is a directory with a hand-made pkgops-index.json, the archive is a list of release tags behind a fake `gh`
# that logs what it is asked to delete, and `pkgops verify-archive` is a stand-in that prints canned output in pkgops's format.
# No network, no secret, nothing is ever deleted anywhere real.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-archive-trim.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# ---- the site: live (the newest two of each package) and pruned versions, both ABIs
mkdir -p "$T/site"
python3 - "$T/site/pkgops-index.json" <<'PY'
import hashlib, json, sys
def e(name, ver, size=1000000):
    out = []
    for abi in ("FreeBSD:15:aarch64", "FreeBSD:15:amd64"):
        out.append({"abi": abi, "name": name, "version": ver, "sha256": hashlib.sha256(("%s-%s-%s" % (abi, name, ver)).encode()).hexdigest(), "size": size})
    return out
live, pruned = [], []
for v in ("0.8.5", "0.8.6"): live += e("jailops", v, 10000000) + e("jailops-client", v, 2000000)
live += e("jailops-apps", "0.4.2", 500000)
for v in ("0.7.3", "0.8.3", "0.8.4"): pruned += e("jailops", v, 9000000)
pruned += e("jailops-client", "0.8.4", 1900000)
live += e("tool", "2.0,1") + e("tool", "1.10.0_1")
pruned += e("tool", "1.9.0") + e("tool", "1.10.0")
json.dump({"schema": 1, "packages": live, "pruned": pruned}, open(sys.argv[1], "w"))
PY

# ---- the archive: one release per version, behind a fake gh
TAGS="$T/tags"
for t in pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-0.8.5 pkg-jailops-0.8.6 \
         pkg-jailops-client-0.8.4 pkg-jailops-client-0.8.5 pkg-jailops-client-0.8.6 pkg-jailops-apps-0.4.2 \
         'pkg-tool-1.9.0' 'pkg-tool-1.10.0' 'pkg-tool-1.10.0_1' 'pkg-tool-2.0,1' pkg-unknown-1.0.0; do echo "$t"; done > "$TAGS"
cp "$TAGS" "$T/tags.all"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<FK
#!/bin/sh
case "\$1 \$2" in
"release list") python3 -c 'import json,sys; print(json.dumps([{"tagName": l.strip()} for l in open(sys.argv[1]) if l.strip()]))' "$TAGS" ;;
"release delete")
  echo "\$3" >> "$T/gh.log"
  [ "\${FAKE_FAIL_TAG:-}" = "\$3" ] && { echo "gh: HTTP 500" >&2; exit 1; }
  grep -vxF "\$3" "$TAGS" > "$TAGS.n"; mv "$TAGS.n" "$TAGS" ;;
*) echo "fake gh: unexpected \$*" >&2; exit 2 ;;
esac
FK
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" SITE="$T/site" REPO=o/r RETIRED_FILE="$T/retired.yaml" RETIRED_DATE=2030-01-02 ARCHIVE_VERIFY=true
trim() { sh "$HERE/scripts/archive-trim.sh" "$@" > "$T/out" 2> "$T/err"; }
: > "$T/gh.log"

# 1. arguments
trim; eq "no --keep: refused" 1 $?
trim --keep 0; eq "--keep 0: refused" 1 $?
trim --keep x; eq "--keep x: refused" 1 $?
trim --keep 2 --bogus; eq "an unknown option: refused" 1 $?
eq "refused calls delete nothing" 0 "$(wc -l < "$T/gh.log" | tr -d ' ')"

# 2. the plan: the oldest beyond the newest two of each package, nothing written
trim --keep 2; eq "dry run succeeds" 0 $?
plan=$(grep '^  pkg-' "$T/out" | sed 's/  (.*//' | tr -d ' ' | tr '\n' ' ')
eq "plan: the older versions, ordered like pkg orders them (1.9.0 < 1.10.0 < 1.10.0_1 < 2.0,1)" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-client-0.8.4 pkg-tool-1.9.0 pkg-tool-1.10.0 " "$plan"
trim --keep 2; cp "$T/out" "$T/out1"; trim --keep 2; cmp -s "$T/out" "$T/out1" && ok "plan: the same twice" || bad "plan: differs between runs"
grep -q 'nothing changed' "$T/out" && ok "dry run says that it changed nothing" || bad "dry run: no 'nothing changed' line"
eq "dry run: nothing deleted" 0 "$(wc -l < "$T/gh.log" | tr -d ' ')"
[ ! -e "$T/retired.yaml" ] && ok "dry run: retired.yaml not written" || bad "dry run wrote retired.yaml"
grep -q 'pkg-jailops-0.8.5\|pkg-jailops-0.8.6\|pkg-jailops-client-0.8.5\|pkg-jailops-client-0.8.6\|jailops-apps\|pkg-tool-2.0\|pkg-tool-1.10.0_1' "$T/out" && bad "plan names a version of the newest two, or one that is on the site" || ok "plan: the newest versions and everything on the site stay"
grep -q 'pkg-unknown' "$T/out" && bad "plan names a release the index does not know" || ok "plan: a release the index does not know is not touched"
trim --keep 1; plan=$(grep '^  pkg-' "$T/out" | sed 's/  (.*//' | tr -d ' ' | tr '\n' ' ')
eq "--keep 1: the live site still keeps its versions (nothing on the site is planned)" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-client-0.8.4 pkg-tool-1.9.0 pkg-tool-1.10.0 " "$plan"
trim --keep 3; plan=$(grep '^  pkg-' "$T/out" | sed 's/  (.*//' | tr -d ' ' | tr '\n' ' ')
eq "--keep 3: older still" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-tool-1.9.0 " "$plan"

# 3. a release the index does not know does not push a known version out of the newest N
echo 'pkg-jailops-9.9.9' >> "$TAGS"; trim --keep 2
plan=$(grep '^  pkg-' "$T/out" | sed 's/  (.*//' | tr -d ' ' | tr '\n' ' ')
eq "an unknown newest release changes nothing" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-client-0.8.4 pkg-tool-1.9.0 pkg-tool-1.10.0 " "$plan"
cp "$T/tags.all" "$TAGS"

# 4. the site and the archive disagree: nothing happens
grep -vxF pkg-jailops-0.8.6 "$TAGS" > "$T/tags.x"; cp "$T/tags.x" "$TAGS"
trim --keep 2 --apply; eq "a version on the site without a release: refused" 1 $?
grep -q 'disagree' "$T/err" && ok "the message says that they disagree" || bad "no 'disagree' message"
eq "refused: nothing deleted" 0 "$(wc -l < "$T/gh.log" | tr -d ' ')"
[ ! -e "$T/retired.yaml" ] && ok "refused: retired.yaml not written" || bad "refused run wrote retired.yaml"
cp "$T/tags.all" "$TAGS"

# 5. --apply: record, then delete, in the order of the plan
trim --keep 2 --apply; eq "apply succeeds" 0 $?
eq "apply: the releases of the plan are deleted, in order" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-client-0.8.4 pkg-tool-1.9.0 pkg-tool-1.10.0 " "$(tr '\n' ' ' < "$T/gh.log")"
eq "apply: the others are still in the archive" "pkg-jailops-0.8.5 pkg-jailops-0.8.6 pkg-jailops-apps-0.4.2 pkg-jailops-client-0.8.5 pkg-jailops-client-0.8.6 pkg-tool-1.10.0_1 pkg-tool-2.0,1 pkg-unknown-1.0.0 " "$(sort "$TAGS" | tr '\n' ' ')"
eq "retired.yaml: one entry per file (six versions, two ABIs)" 12 "$(grep -c 'abi:' "$T/retired.yaml")"
grep -q 'name: jailops$' "$T/retired.yaml" && grep -q "retired: 2030-01-02" "$T/retired.yaml" && grep -q "sha256: $(sha 'FreeBSD:15:amd64-jailops-0.8.3')" "$T/retired.yaml" && ok "retired.yaml: name, date and the sha256 of the index" || bad "retired.yaml: fields"
grep -q 'size: 9000000' "$T/retired.yaml" && ok "retired.yaml: the size" || bad "retired.yaml: size"
cp "$T/retired.yaml" "$T/retired.1"; : > "$T/gh.log"
trim --keep 2 --apply; eq "a second apply succeeds" 0 $?
grep -q 'nothing to trim' "$T/out" && ok "the second apply has nothing to trim" || bad "the second apply plans something"
cmp -s "$T/retired.yaml" "$T/retired.1" && ok "retired.yaml: the same, no duplicates" || bad "retired.yaml changed on a second apply"
eq "the second apply deletes nothing" 0 "$(wc -l < "$T/gh.log" | tr -d ' ')"

# 6. a failed deletion stops the run; a rerun finishes the rest
rm -f "$T/retired.yaml"; cp "$T/tags.all" "$TAGS"; : > "$T/gh.log"
FAKE_FAIL_TAG=pkg-jailops-0.8.3 trim --keep 2 --apply; eq "a failed gh delete stops the run" 1 $?
grep -q 'gh could not delete pkg-jailops-0.8.3' "$T/err" && ok "the message names the release" || bad "no message for the failed delete"
eq "the failure stops after the failed release" "pkg-jailops-0.7.3 pkg-jailops-0.8.3 " "$(tr '\n' ' ' < "$T/gh.log")"
[ -s "$T/retired.yaml" ] && ok "the record was written before the deletes" || bad "retired.yaml missing after a failed delete"
: > "$T/gh.log"; trim --keep 2 --apply; eq "a rerun succeeds" 0 $?
eq "the rerun deletes what is left" "pkg-jailops-0.8.3 pkg-jailops-0.8.4 pkg-jailops-client-0.8.4 pkg-tool-1.9.0 pkg-tool-1.10.0 " "$(tr '\n' ' ' < "$T/gh.log")"
eq "retired.yaml has no duplicate entries" 12 "$(grep -c 'abi:' "$T/retired.yaml")"

# 7. verify-archive.sh accepts "gone for good" for the files in retired.yaml, and only for them
mkdir -p "$T/fk"
cat > "$T/fk/pkgops" <<'FK'
#!/bin/sh
echo "on Pages, not archived (PROBLEM): ${FAKE_PROBLEM:-0}"
echo "archived, not on Pages and not pruned (PROBLEM): 0"
echo "pruned from Pages, still archived (normal): 1"
echo "   FreeBSD:15:amd64 jailops-0.8.6"
n=$(printf '%s' "${FAKE_GONE:-}" | tr ',' '\n' | grep -c .)
[ -n "${FAKE_COUNT:-}" ] && n=$FAKE_COUNT
echo "pruned from Pages and not archived (gone for good): $n"
printf '%s' "${FAKE_GONE:-}" | tr ',' '\n' | grep . | sed 's/^/   /'
[ "${FAKE_PROBLEM:-0}" = 0 ] || exit 1
FK
chmod +x "$T/fk/pkgops"
va() { (PATH="$T/fk:$PATH"; sh "$HERE/scripts/verify-archive.sh" --repo x/y > "$T/va.out" 2>&1); }
va; eq "verify-archive: nothing gone for good passes" 0 $?
FAKE_GONE='FreeBSD:15:amd64 jailops-0.8.3,FreeBSD:15:aarch64 jailops-0.7.3' va; eq "verify-archive: files recorded in retired.yaml may be gone" 0 $?
grep -q 'all recorded in retired.yaml' "$T/va.out" && ok "verify-archive: says that they are recorded" || bad "verify-archive: no note"
FAKE_GONE='FreeBSD:15:amd64 jailops-0.8.3,FreeBSD:15:amd64 jailops-0.8.6' va; eq "verify-archive: one file that is not recorded stops" 1 $?
grep -q 'FreeBSD:15:amd64 jailops-0.8.6' "$T/va.out" && ok "verify-archive: names the file" || bad "verify-archive: file not named"
FAKE_GONE='FreeBSD:15:amd64 jailops-0.8.3' RETIRED_FILE="$T/none.yaml" va; eq "verify-archive: no retired.yaml: nothing may be gone" 1 $?
FAKE_COUNT=2 va; eq "verify-archive: a count that pkgops does not list is not read as retired" 1 $?
FAKE_PROBLEM=1 FAKE_GONE='FreeBSD:15:amd64 jailops-0.8.3' va; eq "verify-archive: pkgops's own failure stays a failure" 1 $?
FAKE_GONE='FreeBSD:15:amd64 jailops-client-0.8.4' va; eq "verify-archive: a package with a dash in its name is matched whole" 0 $?

[ "$fails" = 0 ] && echo "test-archive-trim: all passed" || { echo "test-archive-trim: $fails FAILED"; exit 1; }
