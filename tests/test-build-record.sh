#!/bin/sh
# Offline tests of the build plan per ABI, the build record, and the two checks before the key: scripts/build-pkg.sh
# (with a pkgops stub), scripts/verify-build-record.sh and scripts/expect-packages.sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-build-record.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
rc() { "$@" > "$T/out" 2>&1; echo $?; }

R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache .) | tar -xf - -C "$R"
git -C "$R" init -q -b master
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@example.org commit -q -m base
COMMIT=$(git -C "$R" rev-parse HEAD)
. "$R/scripts/lib.sh"
REPO_ROOT=$R; MAIN=$R/main

# a pkgops that makes one file per ABI asked for, with content that depends on the ABI and the version
mkdir -p "$T/bin"
cat > "$T/bin/pkgops" <<'STUB'
#!/bin/sh
[ "$1" = version ] && { echo "pkgops stub 1.2.3"; exit 0; }
[ "$1" = build ] || exit 2
shift; mf=; abi=all; out=dist
while [ $# -gt 0 ]; do case $1 in -f) mf=$2; shift 2 ;; --abi) abi=$2; shift 2 ;; -o) out=$2; shift 2 ;; *) shift ;; esac; done
name=$(sed -n 's/^name:[[:space:]]*//p' "$mf" | head -n 1); ver=$(sed -n 's/^version:[[:space:]]*//p' "$mf" | head -n 1)
[ "$abi" != all ] || abi=$(sed -n 's/^abis:[[:space:]]*\[\(.*\)\].*/\1/p' "$mf" | tr -d ' ')
for a in $(echo "$abi" | tr ',' ' '); do mkdir -p "$out/$a"; printf '%s %s %s\n' "$name" "$ver" "$a" > "$out/$a/$name-$ver.pkg"; done
STUB
chmod +x "$T/bin/pkgops"
PATH="$T/bin:$PATH"; export PATH
export SOURCE_DATE_EPOCH=1700000000

D=$T/dist

# only the ABI asked for is built, and recorded
DIST_DIR=$D BUILD_LABEL=one sh "$R/scripts/build-pkg.sh" jailops-apps:FreeBSD:15:aarch64 > "$T/build.out" 2>&1; eq "build of one ABI: exit 0" 0 $?
V=$(mf_get jailops-apps version)
eq "only that ABI was built" "FreeBSD:15:aarch64/jailops-apps-$V.pkg" "$(cd "$D" && find . -name '*.pkg' | sed 's|^\./||')"
REC=$D/records/one.json
eq "the record: one package" 1 "$(jq '.packages | length' "$REC")"
eq "the record: the ABI" FreeBSD:15:aarch64 "$(jq -r '.packages[0].abi' "$REC")"
eq "the record: the version" "$V" "$(jq -r '.packages[0].version' "$REC")"
eq "the record: the sha256 of the file" "$(sha256_of "$D/FreeBSD:15:aarch64/jailops-apps-$V.pkg")" "$(jq -r '.packages[0].sha256' "$REC")"
eq "the record: the commit" "$COMMIT" "$(jq -r '.commit' "$REC")"
eq "the record: the pkgops that built" "pkgops stub 1.2.3" "$(jq -r '.toolchain.pkgops' "$REC")"
eq "the record: a local package names its tree" "$(git -C "$R" rev-parse HEAD:main/jailops-apps)" "$(jq -r '.packages[0].source.local' "$REC")"
eq "the record: the toolchain keys" "go node npm pkgops" "$(jq -r '.toolchain | keys_unsorted | join(" ")' "$REC")"

# an ABI the manifest does not have is refused
eq "an unknown ABI: refused" 1 "$(rc env DIST_DIR=$T/d2 sh "$R/scripts/build-pkg.sh" jailops-apps:FreeBSD:14:amd64)"

# the whole package: both ABIs
rm -rf "$D"
DIST_DIR=$D BUILD_LABEL=build sh "$R/scripts/build-pkg.sh" jailops-apps > "$T/build.out" 2>&1; eq "build of every ABI: exit 0" 0 $?
eq "the record: both ABIs" 2 "$(jq '.packages | length' "$D/records/build.json")"

# verify-build-record: the files are the recorded ones
eq "verify: the records match" 0 "$(rc env EXPECT_COMMIT=$COMMIT sh "$R/scripts/verify-build-record.sh" "$D")"
eq "verify: another commit: refused" 1 "$(rc env EXPECT_COMMIT=0000000000000000000000000000000000000000 sh "$R/scripts/verify-build-record.sh" "$D")"
has "verify: names the commits" "built from $COMMIT" "$T/out"
printf 'x' >> "$D/FreeBSD:15:amd64/jailops-apps-$V.pkg"
eq "verify: a changed file: refused" 1 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
has "verify: the size or hash differs" "the size is not the recorded" "$T/out"
printf '%s %s %s\n' jailops-apps "$V" FreeBSD:15:amd64 > "$D/FreeBSD:15:amd64/jailops-apps-$V.pkg"
eq "verify: the file restored: accepted" 0 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
printf 'x' > "$D/FreeBSD:15:amd64/stranger-1.0.pkg"
eq "verify: a package in no record: refused" 1 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
has "verify: names it" "stranger-1.0.pkg is in" "$T/out"
rm -f "$D/FreeBSD:15:amd64/stranger-1.0.pkg"
rm "$D/FreeBSD:15:aarch64/jailops-apps-$V.pkg"
eq "verify: a recorded file that is missing: refused" 1 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
printf '%s %s %s\n' jailops-apps "$V" FreeBSD:15:aarch64 > "$D/FreeBSD:15:aarch64/jailops-apps-$V.pkg"
sed -i.bak 's/^version: .*/version: 9.9.9/' "$R/main/jailops-apps/pkgops.yaml"; rm -f "$R/main/jailops-apps/pkgops.yaml.bak"
eq "verify: a record of an older version than the manifest: refused" 1 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
git -C "$R" checkout -q -- .
rm -rf "$D/records"
eq "verify: packages and no record: refused" 1 "$(rc sh "$R/scripts/verify-build-record.sh" "$D")"
mkdir -p "$T/empty"
eq "verify: nothing built, nothing to check" 0 "$(rc sh "$R/scripts/verify-build-record.sh" "$T/empty")"

# strict: a package whose source is not ready stops the run on master, is skipped in a pull request
sed -i 's/^sha256:.*/sha256: PENDING/' "$R/main/unisupply/upstream.yaml"
eq "not strict: skipped, exit 0" 0 "$(rc env DIST_DIR=$T/d3 sh "$R/scripts/build-pkg.sh" unisupply)"
has "not strict: says it was skipped" "skipping the group of unisupply" "$T/out"
eq "strict: stops" 1 "$(rc env BUILD_STRICT=1 DIST_DIR=$T/d4 sh "$R/scripts/build-pkg.sh" unisupply)"
has "strict: names the reason" "unisupply: sha256 in main/unisupply/upstream.yaml is 'PENDING'" "$T/out"
git -C "$R" checkout -q -- .

# expect-packages: every package of main/ at its version, for every ABI, in the baseline or built now
S=$T/site; mkdir -p "$S"
make_index() { # make_index FILE [SKIP_NAME]: every package and ABI, optionally without one package
  first=1; printf '{"schema":1,"packages":[' > "$1"
  for p in $(all_pkgs); do
    [ "$p" = "${2:-}" ] && continue
    for a in $(abis_of "$p"); do
      [ "$first" = 1 ] || printf ',' >> "$1"; first=0
      printf '{"name":"%s","version":"%s","abi":"%s","file":"%s/%s-%s.pkg","sha256":"%s"}' "$p" "$(mf_get "$p" version)" "$a" "$a" "$p" "$(mf_get "$p" version)" "$(printf '%s' "$p$a" | sha256sum | cut -d' ' -f1)" >> "$1"
    done
  done
  printf '],"pruned":[]}' >> "$1"
}
make_index "$S/pkgops-index.json"
mkdir -p "$T/nodist"
eq "expect: everything is in the baseline" 0 "$(rc sh "$R/scripts/expect-packages.sh" "$S" "$T/nodist")"
make_index "$S/pkgops-index.json" unisupply
eq "expect: a package that is nowhere: refused" 1 "$(rc sh "$R/scripts/expect-packages.sh" "$S" "$T/nodist")"
has "expect: names it, the version and the ABI" "MISSING: unisupply $(mf_get unisupply version) FreeBSD:15:amd64" "$T/out"
mkdir -p "$T/d6/FreeBSD:15:amd64" "$T/d6/FreeBSD:15:aarch64"
for a in FreeBSD:15:amd64 FreeBSD:15:aarch64; do echo built > "$T/d6/$a/unisupply-$(mf_get unisupply version).pkg"; done
eq "expect: the missing package built now: accepted" 0 "$(rc sh "$R/scripts/expect-packages.sh" "$S" "$T/d6")"
make_index "$S/pkgops-index.json"
eq "expect: built now with other bytes than the published file: refused" 1 "$(rc sh "$R/scripts/expect-packages.sh" "$S" "$T/d6")"
has "expect: says the file is immutable" "a published file is immutable" "$T/out"
make_index "$S/pkgops-index.json" unisupply
rm "$T/d6/FreeBSD:15:aarch64/unisupply-$(mf_get unisupply version).pkg"
eq "expect: one ABI built, the other missing: refused" 1 "$(rc sh "$R/scripts/expect-packages.sh" "$S" "$T/d6")"
has "expect: names the missing ABI" "MISSING: unisupply $(mf_get unisupply version) FreeBSD:15:aarch64" "$T/out"

[ "$fails" = 0 ] && echo "test-build-record: all ok" || { echo "test-build-record: $fails FAILED"; exit 1; }
