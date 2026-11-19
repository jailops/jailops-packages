#!/bin/sh
# Offline tests of the ABI list (scripts/abis.sh: the union of the manifests' abis:), of the rules of scripts/check-pkgops.sh
# that keep the manifests, pkgops-repo.yaml and PKGOPS_VERSION consistent, and of the update check, which reads the list.
# FreeBSD 16 is simulated in a copy of the repository: naming the ABIs in the manifests and in pkgops-repo.yaml is all it takes.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-abis.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }

R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache .) | tar -xf - -C "$R"
abis() { env REPO_ROOT="$R" sh "$R/scripts/abis.sh" "$@" 2>&1; }
check() { env -u SITE_URL -u ACTIONS_PIN_ENFORCE CHECK_BASE= sh "$R/scripts/check-pkgops.sh" > "$T/check.out" 2>&1; }

eq "the ABIs of the manifests" "FreeBSD:15:aarch64
FreeBSD:15:amd64" "$(abis)"
eq "one architecture: one ABI per major" "FreeBSD:15:amd64" "$(abis --arch amd64)"
eq "an architecture no manifest names: an error" "error: no ABI for the architecture riscv" "$(abis --arch riscv)"
eq "usage" "error: usage: abis.sh [--arch ARCH]" "$(abis --nonsense)"
check; eq "the repository passes" 0 $?

# FreeBSD 16 in one package: the list grows, and the policy file must follow
m=$R/main/isms/pkgops.yaml
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64, FreeBSD:16:amd64, FreeBSD:16:aarch64]/' "$m"
eq "a major in one manifest is in the list" "FreeBSD:15:aarch64
FreeBSD:15:amd64
FreeBSD:16:aarch64
FreeBSD:16:amd64" "$(abis)"
eq "one architecture: one ABI per major, now two" "FreeBSD:15:amd64
FreeBSD:16:amd64" "$(abis --arch amd64)"
check; eq "pkgops-repo.yaml without the new ABIs: refused" 1 $?
has "says why" "must be exactly the ABIs of the manifests" "$T/check.out"
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64, FreeBSD:16:amd64, FreeBSD:16:aarch64]/' "$R/pkgops-repo.yaml"
check; eq "manifest and policy agree: accepted (naming a major is all it takes)" 0 $?

# one architecture of a major alone is refused
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64, FreeBSD:16:amd64]/' "$m"
check; eq "FreeBSD:16:amd64 without FreeBSD:16:aarch64: refused" 1 $?
has "says why" "abis names FreeBSD:16 but not FreeBSD:16:aarch64" "$T/check.out"
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15, FreeBSD:15:aarch64]/' "$m"
check; eq "a malformed ABI: refused" 1 $?
has "says why" "must look like FreeBSD:15:amd64" "$T/check.out"
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64]/' "$m"
cp "$HERE/pkgops-repo.yaml" "$R/pkgops-repo.yaml"
check; eq "back to the two ABIs of 15: accepted" 0 $?

# the pkgops pin is a release tag
cp "$R/PKGOPS_VERSION" "$T/pin"
printf '2aaeb59b381cfbdf1388dc5669a03b7cc50e6d1f\n' > "$R/PKGOPS_VERSION"
check; eq "a commit SHA as the pin: refused" 1 $?
has "says why" "PKGOPS_VERSION is '2aaeb59b381cfbdf1388dc5669a03b7cc50e6d1f': it must be a pkgops release tag vX.Y.Z" "$T/check.out"
printf 'master\n' > "$R/PKGOPS_VERSION"
check; eq "a branch as the pin: refused" 1 $?
printf 'v0.3.1\n' > "$R/PKGOPS_VERSION"
check; eq "a release tag: accepted" 0 $?
cp "$T/pin" "$R/PKGOPS_VERSION"
eq "the pin of the repository is a tag" 0 "$(tr -d ' \n\r' < "$HERE/PKGOPS_VERSION" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+'; echo $?)"

# the retention hint of pkgops-repo.yaml is the number of versions the site keeps (KEEP in scripts/prune-plan.sh)
sed -i 's/keep: [0-9][0-9]*/keep: 5/' "$R/pkgops-repo.yaml"
check; eq "retention.keep 5 against the site's KEEP: refused" 1 $?
has "says why" "retention.keep (5) must equal the versions the site keeps, KEEP in scripts/prune-plan.sh (2)" "$T/check.out"
cp "$HERE/pkgops-repo.yaml" "$R/pkgops-repo.yaml"
check; eq "retention.keep as in the repository: accepted" 0 $?
eq "the repository's hint is the site's KEEP" "2 2" "$(sed -n 's/^[[:space:]]*keep:[[:space:]]*\([0-9]*\).*/\1/p' "$HERE/pkgops-repo.yaml" | head -n 1) $(sed -n 's/^KEEP=${KEEP:-\([0-9]*\)}.*/\1/p' "$HERE/scripts/prune-plan.sh" | head -n 1)"

# the update check compares the names with the official catalog of every major (amd64), from the same list
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64, FreeBSD:16:amd64, FreeBSD:16:aarch64]/' "$m"
sed -i 's/^abis:.*/abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64, FreeBSD:16:amd64, FreeBSD:16:aarch64]/' "$R/pkgops-repo.yaml"
printf '{"name":"git-lite"}\n' > "$T/ps.yaml"
: > "$T/sum"; env REPO_ROOT="$R" PACKAGESITE_FILE="$T/ps.yaml" SUMMARY_FILE="$T/sum" sh "$R/.github/scripts/check-updates.sh" collisions > "$T/out" 2>&1
eq "collisions: exit 0" 0 $?
has "collisions: FreeBSD:15:amd64 compared" "- FreeBSD:15:amd64: no collision" "$T/sum"
has "collisions: FreeBSD:16:amd64 compared" "- FreeBSD:16:amd64: no collision" "$T/sum"
if grep -q "aarch64" "$T/sum"; then bad "collisions: no aarch64 line expected"; else ok "collisions: one architecture only"; fi

# no ABI in any manifest: the comparison fails loudly instead of checking nothing
for f in "$R"/main/*/pkgops.yaml; do sed -i '/^abis:/d' "$f"; done
: > "$T/sum"; env REPO_ROOT="$R" PACKAGESITE_FILE="$T/ps.yaml" SUMMARY_FILE="$T/sum" sh "$R/.github/scripts/check-updates.sh" collisions > "$T/out" 2>&1
eq "collisions without any ABI: exit 1" 1 $?
has "says why" "no ABI to compare against" "$T/out"

echo
[ "$fails" = 0 ] && echo "test-abis: all ok" || echo "test-abis: $fails FAILED"
[ "$fails" = 0 ]
