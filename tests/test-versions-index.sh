#!/bin/sh
# Offline tests of scripts/versions-index.py (versions.json, the informational index of the newest versions) on a
# fixture site: two ABIs whose catalogs (packagesite.pkg, made here with tar) differ, revisions and versions that sort
# wrong as text, and the refusals (an entry not in pkgops-index.json, a missing or unreadable catalog, a duplicate).
# Also: verify-site.sh is not disturbed by the extra file, and the scripts that decide what is built or published never
# read it. Needs python3 and tar (gzip; zstd is used when it is installed, as on the runner).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-versions.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
gen() { SOURCE_DATE_EPOCH=1793750400 python3 "$HERE/scripts/versions-index.py" "$1" > "$T/out" 2>&1; }
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1/versions.json" "$2"; }

# catalog SITE ABI COMPRESS LINE...: SITE/ABI/latest/packagesite.pkg holding packagesite.yaml with these JSON lines
catalog() {
  s=$1 abi=$2 z=$3; shift 3
  d=$T/cat.$$; rm -rf "$d"; mkdir -p "$d" "$s/$abi/latest"
  : > "$d/packagesite.yaml"
  for l in "$@"; do printf '%s\n' "$l" >> "$d/packagesite.yaml"; done
  printf 'fake signature\n' > "$d/signature"
  (cd "$d" && tar -c $z -f "$s/$abi/latest/packagesite.pkg" signature packagesite.yaml)
  rm -rf "$d"
}
entry() { printf '{"name":"%s","origin":"jailops/%s","version":"%s","comment":"%s","www":"https://jailops.net","abi":"%s","desc":"x"}' "$1" "$1" "$2" "$3" "$4"; }
index() {  # index SITE "ABI NAME VERSION"...
  s=$1; shift
  python3 - "$s/pkgops-index.json" "$@" <<'PY'
import json, sys
pk = [dict(zip(("abi", "name", "version"), a.split())) for a in sys.argv[2:]]
for p in pk:
    p["file"] = f'{p["abi"]}/latest/All/{p["name"]}-{p["version"]}.pkg'
json.dump({"schema": 1, "generator": "pkgops", "generated": "2026-11-04T00:00:00Z", "packages": pk, "pruned": []}, open(sys.argv[1], "w"))
PY
}

Z=-z
command -v zstd >/dev/null 2>&1 && Z=--zstd
A=FreeBSD:15:amd64 B=FreeBSD:15:aarch64

# --- the normal case: isms 0.9.0 on both ABIs, an older jailops-apps on aarch64, revisions and 0.10 > 0.9
S=$T/site
catalog "$S" $A $Z "$(entry isms 0.9.0 'ISMS platform' $A)" "$(entry jailops-apps 0.4.2 'App catalog' $A)" \
  "$(entry pkgops 0.10.0 'PkgOps' $A)" "$(entry hello 1.0.0_2 'Hello' $A)"
catalog "$S" $B $Z "$(entry isms 0.9.0 'ISMS platform' $B)" "$(entry jailops-apps 0.4.1 'App catalog, older' $B)" \
  "$(entry pkgops 0.9.9 'PkgOps' $B)" "$(entry hello 1.0.0_10 'Hello' $B)" "$(entry armonly 0.1.0 'Only on arm' $B)"
index "$S" "$A isms 0.8.1" "$A isms 0.9.0" "$B isms 0.8.1" "$B isms 0.9.0" "$A jailops-apps 0.4.2" "$B jailops-apps 0.4.1" \
  "$A pkgops 0.10.0" "$B pkgops 0.9.9" "$A hello 1.0.0_2" "$B hello 1.0.0_10" "$B armonly 0.1.0"
gen "$S"; eq "a site with two ABIs: written" 0 $?
has "it says what it wrote" "versions.json: 5 packages" "$T/out"
eq "schema 1" 1 "$(get "$S" 'd["schema"]')"
eq "generated_at (SOURCE_DATE_EPOCH)" 2026-11-04T00:00:00Z "$(get "$S" 'd["generated_at"]')"
eq "the ABIs" "['FreeBSD:15:aarch64', 'FreeBSD:15:amd64']" "$(get "$S" 'd["abis"]')"
eq "the repository URL" 'https://pkg.jailops.net/${ABI}/latest' "$(get "$S" 'd["repository"]')"
eq "isms: the newest published version, not an older one still on the site" 0.9.0 "$(get "$S" 'd["packages"]["isms"]["version"]')"
eq "isms: per ABI" "{'FreeBSD:15:aarch64': '0.9.0', 'FreeBSD:15:amd64': '0.9.0'}" "$(get "$S" 'd["packages"]["isms"]["abis"]')"
eq "isms: origin" jailops/isms "$(get "$S" 'd["packages"]["isms"]["origin"]')"
eq "isms: comment" "ISMS platform" "$(get "$S" 'd["packages"]["isms"]["comment"]')"
eq "isms: www" https://jailops.net "$(get "$S" 'd["packages"]["isms"]["www"]')"
eq "ABIs that differ: the highest across them" 0.4.2 "$(get "$S" 'd["packages"]["jailops-apps"]["version"]')"
eq "ABIs that differ: comment of the highest" "App catalog" "$(get "$S" 'd["packages"]["jailops-apps"]["comment"]')"
eq "ABIs that differ: both listed" "{'FreeBSD:15:aarch64': '0.4.1', 'FreeBSD:15:amd64': '0.4.2'}" "$(get "$S" 'd["packages"]["jailops-apps"]["abis"]')"
eq "0.10.0 is above 0.9.9 (not text order)" 0.10.0 "$(get "$S" 'd["packages"]["pkgops"]["version"]')"
eq "revision _10 is above _2" 1.0.0_10 "$(get "$S" 'd["packages"]["hello"]["version"]')"
eq "a package of one ABI lists only that ABI" "['FreeBSD:15:aarch64']" "$(get "$S" 'list(d["packages"]["armonly"]["abis"])')"
eq "the keys of a package" "['version', 'origin', 'comment', 'www', 'abis']" "$(get "$S" 'list(d["packages"]["isms"])')"
cp "$S/versions.json" "$T/v1"; gen "$S"; cmp -s "$S/versions.json" "$T/v1"; eq "the same site gives the same file" 0 $?
[ ! -e "$S/.versions.json.tmp" ]; eq "no temporary file left" 0 $?
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$S/versions.json"; eq "it is JSON" 0 $?

# --- refusals: the file is only written from catalogs that agree with the index
cp -R "$S" "$T/s2"; index "$T/s2" "$A isms 0.8.1" "$B isms 0.8.1" "$B isms 0.9.0" "$A jailops-apps 0.4.2" "$B jailops-apps 0.4.1" \
  "$A pkgops 0.10.0" "$B pkgops 0.9.9" "$A hello 1.0.0_2" "$B hello 1.0.0_10" "$B armonly 0.1.0"
gen "$T/s2"; eq "an entry not in pkgops-index.json: refused" 1 $?
has "says which" "isms 0.9.0 is not in pkgops-index.json" "$T/out"
cp -R "$S" "$T/s3"; rm "$T/s3/$B/latest/packagesite.pkg"; rm -f "$T/s3/versions.json"
gen "$T/s3"; eq "an ABI without a catalog: refused" 1 $?
[ ! -e "$T/s3/versions.json" ]; eq "and nothing is written" 0 $?
cp -R "$S" "$T/s4"; printf 'not a tar archive' > "$T/s4/$A/latest/packagesite.pkg"
gen "$T/s4"; eq "an unreadable catalog: refused" 1 $?
has "says what is needed" "a tar with zstd is needed" "$T/out"
cp -R "$S" "$T/s5"; catalog "$T/s5" $A -z "$(entry isms 0.9.0 x $A)" "$(entry isms 0.9.0 x $A)"
gen "$T/s5"; eq "a name listed twice: refused" 1 $?
cp -R "$S" "$T/s6"; catalog "$T/s6" $A -z '{"name":"isms","version":"0.9.0"'
gen "$T/s6"; eq "a line that is not JSON: refused" 1 $?
cp -R "$S" "$T/s7"; catalog "$T/s7" $A -z '{"name":"isms","version":"<script>"}'
gen "$T/s7"; eq "a version with odd characters: refused" 1 $?
cp -R "$S" "$T/s8"; rm "$T/s8/pkgops-index.json"
gen "$T/s8"; eq "no pkgops-index.json: refused" 1 $?
mkdir -p "$T/s9"; index "$T/s9"
gen "$T/s9"; eq "no ABI directory: refused" 1 $?
python3 "$HERE/scripts/versions-index.py" > "$T/out" 2>&1; eq "no argument: usage" 1 $?

# --- the extra file does not disturb verify-site.sh (it reads pkgops-index.json only)
R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache scripts main prune.yaml pkgops-repo.yaml KEY_FINGERPRINT) | tar -xf - -C "$R"
V=$T/vsite; mkdir -p "$V"
args=$(REPO_ROOT=$R sh -c '. "$REPO_ROOT/scripts/lib.sh"; for p in $(all_pkgs); do v=$(mf_get "$p" version); for a in $(abis_of "$p"); do printf "|%s %s %s" "$a" "$p" "$v"; done; done')
(IFS='|'; set -f; index "$V" ${args#|})
printf '{"schema":1}\n' > "$V/versions.json"
REPO_ROOT=$R sh "$R/scripts/verify-site.sh" "$V" > "$T/out" 2>&1; eq "verify-site.sh with versions.json on the site" 0 $?

# --- nothing that decides what is built or published reads versions.json (check-pkgops.sh enforces it too)
users=$(cd "$HERE" && grep -l 'versions\.json' scripts/baseline.sh scripts/changed.sh scripts/verify-site.sh scripts/lib.sh scripts/build-pkg.sh scripts/site-files.sh .github/scripts/*.sh 2>/dev/null)
eq "the baseline, changed and verify scripts do not read versions.json" "" "$users"

[ "$fails" = 0 ] && echo "test-versions-index: all ok" || echo "test-versions-index: $fails FAILED"
exit $((fails > 0))
