#!/bin/sh
# Offline tests of .github/scripts/check-updates.sh against a fake GitHub API (tests/fake-github.py). Fixtures are
# generated into a temp dir and removed again; nothing here talks to the network or needs a secret.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-updates.XXXXXX")
trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
hasnt() { if grep -q -F -e "$2" "$3"; then bad "$1: '$2' found in $3"; else ok "$1"; fi; }

# ---- unit: pure helpers
export REPO_ROOT="$HERE"
. "$HERE/scripts/lib.sh"
. "$HERE/.github/scripts/updates-lib.sh"
ver_gt 1.10.0 1.9.0 && ok "ver_gt 1.10.0 > 1.9.0 (not a string compare)" || bad "ver_gt 1.10.0 1.9.0"
ver_gt 1.0.0 1.0.0 && bad "ver_gt equal" || ok "ver_gt equal is false"
ver_gt 0.9.0 1.0.0 && bad "ver_gt downgrade" || ok "ver_gt never forward-bumps a downgrade"
eq "latest_of picks the highest plain N.N.N, ignores rc and other prefixes" 1.10.2 \
  "$(printf 'v1.9.0\nv1.10.2\nv1.11.0-rc1\nx2.0.0\nv1.10\n' | latest_of v)"
eq "latest_of empty" "" "$(printf 'nightly\n' | latest_of v)"
printf abc > "$T/abc"
eq "sha256_of" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(sha256_of "$T/abc")"
eq "fmt_age minutes" "5 min" "$(fmt_age 300)"
eq "fmt_age hours" "30 h" "$(fmt_age 108000)"
eq "fmt_age days" "3 days" "$(fmt_age 259200)"
printf '[{"number":1,"head":{"ref":"bump-pkgops-0.2.0"}},{"number":2,"head":{"ref":"bump-pkgops-pin-0.2.0"}},{"number":3,"head":{"ref":"bump-isms-0.9.0"}}]' > "$T/prs.json"
eq "open_bump_prs matches digits only" "1 bump-pkgops-0.2.0" "$(open_bump_prs "$(cat "$T/prs.json")" bump-pkgops-)"
eq "open_bump_prs pin prefix" "2 bump-pkgops-pin-0.2.0" "$(open_bump_prs "$(cat "$T/prs.json")" bump-pkgops-pin-)"
eq "pr_for_branch" 3 "$(pr_for_branch "$(cat "$T/prs.json")" bump-isms-0.9.0)"
eq "pr_for_branch none" "" "$(pr_for_branch "$(cat "$T/prs.json")" bump-isms-0.9.1)"
printf 'a\t1.0\t1.1\tbump PR opened\n' > "$T/rows"
eq "render_summary" "| \`a\` | 1.0 | 1.1 | bump PR opened |" "$(render_summary "$T/rows" | tail -n 1)"
printf '{"name":"git"}\n{"name":"isms"}\n' > "$T/site.yaml"; printf 'isms\nunisupply\n' > "$T/ours"
eq "collisions" isms "$(collisions "$T/ours" "$T/site.yaml")"

# ---- integration: a fake repository and a fake API
FIX="$T/fix"; ROOT="$T/root"; mkdir -p "$FIX" "$ROOT/main" "$ROOT/.github/scripts" "$ROOT/scripts"
cp "$HERE"/scripts/*.sh "$ROOT/scripts/"; cp "$HERE"/.github/scripts/*.sh "$ROOT/.github/scripts/"
python3 "$HERE/tests/fake-github.py" "$FIX" "$T/port" & SRV=$!
i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
URL="http://127.0.0.1:$(cat "$T/port")"

mkpkg() { # NAME VERSION SHA [NOTE]
  mkdir -p "$ROOT/main/$1"
  printf 'name: %s\nversion: %s\n' "$1" "$2" > "$ROOT/main/$1/pkgops.yaml"
  printf 'group: %s\nrepo: owner/%s\ntag_prefix: v\ntarball: %s/tarball/${tag}\nstrip_components: 1\nsha256: %s\ntoken_env:\nprebuild:\n' "$1" "$1" "$URL" "$3" > "$ROOT/main/$1/upstream.yaml"
  [ -z "${4:-}" ] || echo "bump_note: $4" >> "$ROOT/main/$1/upstream.yaml"
}
rel() { # NAME JSON
  printf '%s' "$2" > "$FIX/repos__owner__$1__releases"
}
OLD=0000000000000000000000000000000000000000000000000000000000000000
mkpkg foo 1.2.0_2 $OLD "Read the static-build patch notes"
mkpkg bar 1.0.0 $OLD
mkpkg baz 1.0.0 $OLD
mkpkg pend 0.1.0 PENDING
mkpkg dup 1.0.0 $OLD
mkpkg stale 1.0.0 $OLD
mkpkg tagonly 0.2.0 $OLD
# a package built from its own directory: no upstream, never checked or bumped
mkdir -p "$ROOT/main/catalog"; printf 'name: catalog\nversion: 0.4.0\n' > "$ROOT/main/catalog/pkgops.yaml"
printf 'source: local\nprebuild:\n' > "$ROOT/main/catalog/upstream.yaml"
echo v0.1.0 > "$ROOT/PKGOPS_VERSION"
rel foo '[{"tag_name":"v1.3.0","draft":false,"prerelease":false},{"tag_name":"v1.5.0-rc1","draft":false,"prerelease":true},{"tag_name":"v2.0.0","draft":true,"prerelease":false},{"tag_name":"v1.4.0","draft":false,"prerelease":false}]'
rel baz '[{"tag_name":"v0.9.0","draft":false,"prerelease":false}]'
rel pend '[]'; printf '[]' > "$FIX/repos__owner__pend__tags"
rel dup '[{"tag_name":"v1.1.0","draft":false,"prerelease":false}]'
rel stale '[{"tag_name":"v1.2.0","draft":false,"prerelease":false},{"tag_name":"v1.1.0","draft":false,"prerelease":false}]'
rel tagonly '[]'; printf '[{"name":"v0.3.0"},{"name":"v0.2.0"}]' > "$FIX/repos__owner__tagonly__tags"
printf '[{"tag_name":"v0.2.0","draft":false,"prerelease":false},{"tag_name":"v0.1.0","draft":false,"prerelease":false}]' > "$FIX/repos__jailops__jailops-pkgops__releases"
for t in v1.4.0 v1.2.0 v0.3.0; do printf 'tarball %s' "$t" > "$FIX/tarball__$t"; done
printf '[{"number":7,"head":{"ref":"bump-dup-1.1.0"}},{"number":8,"head":{"ref":"bump-stale-1.1.0"}}]' > "$FIX/repos__me__packages__pulls"
cat > "$T/commit-stub.sh" <<STUB
#!/bin/sh
b=\$1; shift 2; mkdir -p "$T/committed/\$b"
for f in "\$@"; do mkdir -p "$T/committed/\$b/\$(dirname \$f)"; cp "\$f" "$T/committed/\$b/\$f"; done
STUB
git -C "$ROOT" init -q && git -C "$ROOT" add -A && git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm base
GEN=2026-10-23T06:00:00.123456Z
printf '{"schema":1,"generated":"%s","packages":[],"pruned":[]}' "$GEN" > "$FIX/pkgops-index.json"

runit() { # OUTFILE... env from caller
  env REPO_ROOT="$ROOT" GITHUB_REPOSITORY=me/packages GITHUB_API_URL="$URL" GITHUB_SERVER_URL=https://github.example \
    GH_TOKEN=sekrit-token COMMIT_CMD="sh $T/commit-stub.sh" SITE_URL="$URL" SUMMARY_FILE="$T/summary.md" \
    NOW_EPOCH=$(( $(date -u -d "2026-10-23T06:00:00Z" +%s) + 259200 + 100 )) "$@" \
    sh "$ROOT/.github/scripts/check-updates.sh" all
}
: > "$T/summary.md"
runit > "$T/out1" 2>&1; rc=$?
eq "run 1 exits 0 although bar is unreachable" 0 "$rc"
S="$T/summary.md"; L="$FIX/requests.log"
has "summary: table header" "| package | in repo | upstream latest | status |" "$S"
has "summary: foo bump (prereleases and drafts ignored, 1.4.0 chosen)" "| \`foo\` | 1.2.0_2 | 1.4.0 | bump PR opened" "$S"
has "summary: unreachable" "| \`bar\` | 1.0.0 | ? | upstream unreachable |" "$S"
has "summary: up to date, no downgrade" "| \`baz\` | 1.0.0 | 0.9.0 | up to date |" "$S"
has "summary: PENDING" "| \`pend\` | 0.1.0 | - | pinned PENDING sha256" "$S"
has "summary: dup already open" "| \`dup\` | 1.0.0 | 1.1.0 | bump PR already open ([#7]" "$S"
has "summary: stale superseded" "superseded #8" "$S"
has "summary: tag fallback" "| \`tagonly\` | 0.2.0 | 0.3.0 | bump PR opened" "$S"
has "summary: local source listed, not checked" "| \`catalog\` | 0.4.0 | - | local source: version raised by hand, not checked |" "$S"
hasnt "local source: no upstream request" "catalog" "$L"
hasnt "local source: no request without a repository" "/repos//" "$L"
has "summary: pkgops line" "\`PKGOPS_VERSION\`: \`v0.1.0\`, latest release of jailops/jailops-pkgops: v0.2.0, bump PR opened" "$S"
has "summary: publish age" "Last publish: 3 days ago" "$S"
has "summary: unreachable count" "1 upstream(s) unreachable." "$S"
want=$(printf 'tarball v1.4.0' | sha256sum | cut -d' ' -f1)
has "sha256 of the tarball committed" "sha256: $want" "$T/committed/bump-foo-1.4.0/main/foo/upstream.yaml"
has "_N reset" "version: 1.4.0" "$T/committed/bump-foo-1.4.0/main/foo/pkgops.yaml"
hasnt "_N reset (no revision left)" "_2" "$T/committed/bump-foo-1.4.0/main/foo/pkgops.yaml"
eq "PKGOPS_VERSION one-line change" v0.2.0 "$(cat "$T/committed/bump-pkgops-pin-0.2.0/PKGOPS_VERSION")"
eq "working tree restored" v0.1.0 "$(cat "$ROOT/PKGOPS_VERSION")"
eq "main restored" 0 "$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')"
npr=$(grep -c '^POST /repos/me/packages/pulls ' "$L"); eq "four PRs opened (foo, stale, tagonly, pkgops)" 4 "$npr"
hasnt "no PR for dup" "bump-dup" "$L"
has "stale PR closed" "PATCH /repos/me/packages/pulls/8 " "$L"
has "stale branch deleted" "DELETE /repos/me/packages/git/refs/heads/bump-stale-1.1.0" "$L"
has "stale comment" "Superseded by #" "$L"
has "label update" '"labels":["update"]' "$L"
has "build dispatched" "workflows/build-and-publish.yml/dispatches" "$L"
has "PR body: bump_note" "Read before merging:** Read the static-build patch notes" "$L"
has "PR body: release notes URL" "https://github.example/owner/foo/releases/tag/v1.4.0" "$L"
has "PR body: compare link" "https://github.example/owner/foo/compare/v1.2.0...v1.4.0" "$L"
has "pkgops PR: signing key warning" "signing key is available to the pkgops version" "$L"
has "pkgops PR: changelog" "Read the changelog first" "$L"
has "pkgops PR: new version builds" "build on this PR runs with the new version" "$L"
hasnt "token never echoed (log)" "sekrit-token" "$T/out1"
hasnt "token never echoed (summary)" "sekrit-token" "$S"

# run 2: every bump PR is open now: nothing new, even for the superseding PR
: > "$L"; : > "$S"
printf '[{"number":7,"head":{"ref":"bump-dup-1.1.0"}},{"number":9,"head":{"ref":"bump-foo-1.4.0"}},{"number":10,"head":{"ref":"bump-stale-1.2.0"}},{"number":11,"head":{"ref":"bump-tagonly-0.3.0"}},{"number":12,"head":{"ref":"bump-pkgops-pin-0.2.0"}}]' > "$FIX/repos__me__packages__pulls"
runit > "$T/out2" 2>&1; rc=$?
eq "run 2 exits 0" 0 "$rc"
eq "run 2 opens no PR" 0 "$(grep -c . "$L" | tr -d ' ')"
has "run 2: foo already open" "| \`foo\` | 1.2.0_2 | 1.4.0 | bump PR already open ([#9]" "$S"
has "run 2: pkgops already open" "v0.2.0, bump PR already open" "$S"

# a closed PR whose branch still exists is not reopened
: > "$L"; : > "$S"; printf '[]' > "$FIX/repos__me__packages__pulls"
printf '[{"number":5}]' > "$FIX/repos__me__packages__pulls__stateall"
printf '{}' > "$FIX/repos__me__packages__git__ref__heads__bump-foo-1.4.0"
runit > "$T/out3" 2>&1
has "branch with a closed PR is skipped" "branch bump-foo-1.4.0 exists, its pull request was closed" "$S"
hasnt "the closed PR's branch is kept" "DELETE /repos/me/packages/git/refs/heads/bump-foo-1.4.0" "$L"

# a branch that never had a PR (a run stopped before opening it) is made again
: > "$L"; : > "$S"; printf '[]' > "$FIX/repos__me__packages__pulls__stateall"
runit > "$T/out3b" 2>&1
has "a branch without any PR is removed" "DELETE /repos/me/packages/git/refs/heads/bump-foo-1.4.0" "$L"
has "and the PR is opened" "POST /repos/me/packages/pulls" "$L"
rm "$FIX/repos__me__packages__git__ref__heads__bump-foo-1.4.0" "$FIX/repos__me__packages__pulls__stateall"

# strict: fails at the very end, after the summary was written
for f in foo stale tagonly dup; do printf '[]' > "$FIX/repos__owner__${f}__releases"; done
: > "$S"; runit STRICT=1 > "$T/out4" 2>&1; rc=$?
eq "strict run exits 1 on an unreachable upstream" 1 "$rc"
has "strict: summary still written" "upstream unreachable" "$S"

# no site yet: skipped gracefully
: > "$S"; runit SITE_URL="$URL/nowhere" > "$T/out5" 2>&1; rc=$?
eq "no site: exit 0" 0 "$rc"
has "no site: message" "Last publish: unknown" "$S"

# collisions
printf '{"name":"git-lite"}\n{"name":"baz"}\n' > "$T/ps.yaml"
: > "$S"; env REPO_ROOT="$ROOT" PACKAGESITE_FILE="$T/ps.yaml" SUMMARY_FILE="$S" sh "$ROOT/.github/scripts/check-updates.sh" collisions > "$T/out6" 2>&1; rc=$?
eq "collision found exits 1" 1 "$rc"; has "collision named" "collision** with official packages: baz" "$S"
printf '{"name":"git-lite"}\n' > "$T/ps.yaml"
: > "$S"; env REPO_ROOT="$ROOT" PACKAGESITE_FILE="$T/ps.yaml" SUMMARY_FILE="$S" sh "$ROOT/.github/scripts/check-updates.sh" collisions > "$T/out7" 2>&1; rc=$?
eq "no collision exits 0" 0 "$rc"

echo
[ "$fails" = 0 ] && echo "test-updates: all passed" || echo "test-updates: $fails FAILED"
[ "$fails" = 0 ]
