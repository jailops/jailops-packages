#!/bin/sh
# Offline tests of a package with `source: local` (main/jailops-apps): nothing is fetched, pinned or checked for updates,
# its version is its own, the dependency of jailops on it is not kept in step, and the immutability rule still applies.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-local.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
hasnt() { if grep -q -F -e "$2" "$3"; then bad "$1: '$2' found in $3"; else ok "$1"; fi; }

# a copy of the repository to edit, with its own git history
R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache .) | tar -xf - -C "$R"
git -C "$R" init -q -b master
commit() { git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@example.org commit -q -m "$1"; }
commit base
BASE=$(git -C "$R" rev-parse HEAD)
restore() { git -C "$R" checkout -q -- .; git -C "$R" clean -qfd -- main; }
check() { env -u SITE_URL CHECK_BASE= sh "$R/scripts/check-pkgops.sh" "$@" > "$T/check.out" 2>&1; }
APPS=$R/main/jailops-apps

check; eq "check-pkgops accepts the repository" 0 $?
. "$R/scripts/lib.sh"
REPO_ROOT=$R; MAIN=$R/main
is_local jailops-apps && ok "jailops-apps is local" || bad "jailops-apps is not local"
is_local jailops && bad "jailops is local" || ok "jailops is not local"
pkg_ready jailops-apps && ok "a local package is always ready" || bad "jailops-apps not ready: $REASON"

# nothing is fetched or pinned
sh "$R/scripts/fetch-source.sh" jailops-apps > "$T/fetch.out" 2>&1; eq "fetch-source: exit 0" 0 $?
has "fetch-source: says so" "local source (main/jailops-apps), nothing to fetch" "$T/fetch.out"
[ ! -e "$APPS/src" ] && ok "fetch-source: no src/" || bad "fetch-source made $APPS/src"
sh "$R/scripts/fetch-source.sh" --print-sha jailops-apps > /dev/null 2>&1 && bad "--print-sha of a local package succeeded" || ok "--print-sha refused"
SRC_JAILOPS_APPS=$T sh "$R/scripts/fetch-source.sh" jailops-apps > /dev/null 2>&1 && bad "an SRC_ override of a local package was used" || ok "SRC_ override refused"
sh "$R/scripts/bump-version.sh" --pin jailops-apps > /dev/null 2>&1 && bad "--pin of a local package succeeded" || ok "--pin refused"

# no upstream to check: not in the groups of check-updates.yml, and jailops-apps left the jailops group
sh "$R/scripts/bump-version.sh" --groups > "$T/groups"
hasnt "--groups leaves the local package out" "jailops-apps" "$T/groups"
eq "the jailops group" "jailops jailops-backupd jailops-client" "$(grep '^jailops ' "$T/groups" | cut -d' ' -f4 | tr ',' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# the version is raised by itself; nothing else moves
sh "$R/scripts/bump-version.sh" 0.9.0 jailops-apps > "$T/bump.out" 2>&1; eq "bump of the local package: exit 0" 0 $?
eq "bump: version written" 0.9.0 "$(mf_get jailops-apps version)"
eq "bump: only that manifest changed" "main/jailops-apps/pkgops.yaml" "$(git -C "$R" status --porcelain | sed 's/^...//')"
restore
# a bump of the jailops group keeps its sibling dependency in step, not the one on jailops-apps
NO_DOWNLOAD=1 sh "$R/scripts/bump-version.sh" 0.8.0 jailops-client jailops jailops-backupd > /dev/null 2>&1
has "group bump: jailops-client dependency follows" '{name: jailops-client, origin: jailops/jailops-client, version: "0.8.0"}' "$R/main/jailops/pkgops.yaml"
hasnt "group bump: the jailops-apps dependency is left alone" '{name: jailops-apps, origin: jailops/jailops-apps, version: "0.8.0"}' "$R/main/jailops/pkgops.yaml"
check; eq "group bump: check-pkgops still accepts it" 0 $?
restore

# the rules of a local upstream.yaml
echo 'sha256: PENDING' >> "$APPS/upstream.yaml"
check; eq "local + sha256: refused" 1 $?; has "local + sha256: reason" "source: local, so 'sha256:' has no meaning" "$T/check.out"
restore
sed -i.bak 's/^source: local/source: remote/' "$APPS/upstream.yaml"; rm -f "$APPS/upstream.yaml.bak"
check; eq "unknown source: refused" 1 $?; has "unknown source: reason" "source: 'remote' is unknown" "$T/check.out"
restore
printf '  - source: src/LICENSE.md\n    destination: share/doc/jailops-apps/X\n' >> "$APPS/pkgops.yaml"
check; eq "local + src/: refused" 1 $?; has "local + src/: reason" "takes files from src/" "$T/check.out"
restore
sed -i.bak 's/{name: jailops-apps, origin: jailops\/jailops-apps, version: "[^"]*"}/{name: jailops-apps, origin: jailops\/jailops-apps, version: "any"}/' "$R/main/jailops/pkgops.yaml"; rm -f "$R/main/jailops/pkgops.yaml.bak"
check; eq "cross-group dependency without a version: refused" 1 $?; has "cross-group dependency: reason" "dependency jailops-apps has version 'any'" "$T/check.out"
restore

# immutability: the published versions are those of the index
printf '{"packages":[{"name":"jailops","version":"%s"},{"name":"jailops-apps","version":"%s"}]}' \
  "$(mf_get jailops version)" "$(mf_get jailops-apps version)" > "$T/index.json"
printf '# a comment\n' >> "$APPS/apps/nginx.yaml"; commit "apps without a version"
PUBLISHED_INDEX=$T/index.json check "$BASE"; eq "a changed app without a new version: refused" 1 $?
has "the hint names the manifest" "raise version: in main/jailops-apps/pkgops.yaml" "$T/check.out"
sed -i.bak 's/^version: .*/version: 0.9.0/' "$APPS/pkgops.yaml"; rm -f "$APPS/pkgops.yaml.bak"; commit "and the version"
PUBLISHED_INDEX=$T/index.json check "$BASE"; eq "with a new version: accepted" 0 $?
git -C "$R" reset -q --hard "$BASE"
sed -i.bak 's/^deps:/# a new comment\ndeps:/' "$R/main/jailops/pkgops.yaml"; rm -f "$R/main/jailops/pkgops.yaml.bak"; commit "comment only"
PUBLISHED_INDEX=$T/index.json check "$BASE"; eq "a comment-only change of a published manifest: accepted" 0 $?
has "comment-only: noted" "only comments of pkgops.yaml changed" "$T/check.out"
git -C "$R" reset -q --hard "$BASE"
sed -i.bak 's/^    echo "JailOps is installed/    # inside the script\n    echo "JailOps is installed/' "$R/main/jailops/pkgops.yaml"; rm -f "$R/main/jailops/pkgops.yaml.bak"; commit "script line"
PUBLISHED_INDEX=$T/index.json check "$BASE"; eq "a # line inside a block scalar is content: refused" 1 $?
git -C "$R" reset -q --hard "$BASE"

[ "$fails" = 0 ] && echo "test-local: all ok" || { echo "test-local: $fails FAILED"; exit 1; }
