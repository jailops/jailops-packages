#!/bin/sh
# Offline tests of the workflow rules in scripts/check-pkgops.sh (the signing key is written only after every download,
# restore and baseline check and removed right after signing; permissions per job) and of scripts/check-actions-pinned.sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-workflow.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }

R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache .) | tar -xf - -C "$R"
BP=$R/.github/workflows/build-and-publish.yml
cp "$BP" "$T/bp.orig"
check() { env -u SITE_URL -u ACTIONS_PIN_ENFORCE CHECK_BASE= sh "$R/scripts/check-pkgops.sh" > "$T/check.out" 2>&1; }
reset() { cp "$T/bp.orig" "$BP"; }
# edit SCRIPT : apply a python edit to the workflow (python3 is needed by the other tests too)
edit() { python3 - "$BP" "$1" <<'PY'
import sys
p, code = sys.argv[1], sys.argv[2]
s = open(p).read()
exec(code)
open(p, "w").write(s)
PY
}

check; eq "the workflow passes" 0 $?

# the deploy job without its status check function (build-private skipped => deploy skipped, the site never deployed)
edit 's = s.replace("    if: ${{ always() && needs.publish.result == '"'"'success'"'"' }}\n", "")'
check; eq "deploy without always(): refused" 1 $?
has "deploy without always(): says why" "the job deploy must say 'if: always() && needs.publish.result == success'" "$T/check.out"
reset

# the recovery job checking out current master instead of the commit of the run (the site of an older commit then misses
# the packages of the newer manifests)
edit 's = s.replace("          ref: ${{ steps.run.outputs.sha }}\n", "")'
check; eq "redeploy without the run's commit: refused" 1 $?
has "redeploy without the run's commit: says why" "the job redeploy must check out" "$T/check.out"
reset

# the key written before the downloads (the order the workflow had before)
edit '
a = s.index("      - uses: actions/download-artifact@")
k = s.index("      # The only step with the key on disk")
b = s.index("      - name: Remove the signing key")
c = s.index("      - name: Verify the signed repository")
s = s[:a] + s[k:b] + s[a:k] + s[b:]'
check; eq "key before the downloads: refused" 1 $?
has "key before the downloads: says why" "downloads, restores or fetches after the key is written" "$T/check.out"
reset

# the removal step not right after the signing step, or not if: always()
edit 's = s.replace("      - name: Remove the signing key\n        if: always()\n", "      - name: Remove the signing key\n")'
check; eq "removal without if: always(): refused" 1 $?
has "removal: says why" "must remove pkg-repo.key with 'if: always()'" "$T/check.out"
reset

# a job without permissions, and workflow-wide permissions
edit 's = s.replace("    permissions:\n      pages: write\n      id-token: write\n", "")'
check; eq "a job without permissions: refused" 1 $?
has "a job without permissions: names it" "job 'deploy' has no permissions" "$T/check.out"
reset
edit 's = s.replace("permissions: {}\n", "permissions:\n  contents: write\n")'
check; eq "workflow-wide permissions: refused" 1 $?
reset

# actions: every one is pinned to a commit SHA, GitHub's own included; local, docker:// and a listed owner are fine
edit 's = s.replace("      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1", "      - uses: \"example/tool@v2\"   # a tag\n      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1")'
check; eq "unpinned third-party action: refused" 1 $?
has "unpinned: the command to pin it" "gh api repos/example/tool/commits/v2 --jq .sha" "$T/check.out"
ACTIONS_PIN_ENFORCE=0 sh "$R/scripts/check-actions-pinned.sh" "$R/.github" > "$T/pin.out" 2>&1; eq "ACTIONS_PIN_ENFORCE=0: only warns" 0 $?
has "warn mode: says so" "warning only until ACTIONS_PIN_ENFORCE=1" "$T/pin.out"
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1", "      - uses: actions/upload-pages-artifact@v3\n      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1")'
check; eq "an action of actions/ on a tag: refused" 1 $?
has "the first-party tag is named" "actions/upload-pages-artifact@v3 is not pinned" "$T/check.out"
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1", "      - uses: example/tool/sub@0123456789abcdef0123456789abcdef01234567 # v2.1.0\n      - uses: docker://alpine:3\n      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1")'
check; eq "pinned third-party and docker: accepted" 0 $?
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1", "      - uses: github/codeql-action/init@v3\n      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1")'
ACTIONS_FIRST_PARTY="github/" sh "$R/scripts/check-actions-pinned.sh" "$R/.github" > "$T/pin.out" 2>&1; eq "a listed owner (ACTIONS_FIRST_PARTY) may stay on a tag" 0 $?
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1", "      - uses: example/tool@0123456789abcdef\n      - uses: actions/upload-pages-artifact@56afc609e74202658d3ffba0e8f6dda462b719fa   # v3.0.1")'
check; eq "a short SHA is not a pin" 1 $?
reset

# the source token: only in build-private (master only, with an Environment), never in the job a pull request runs
check; eq "the workflow passes" 0 $?
edit 's = s.replace("          BUILD_LABEL: build\n", "          BUILD_LABEL: build\n          JAILOPS_SOURCE_TOKEN: ${{ secrets.JAILOPS_SOURCE_TOKEN }}\n")'
check; eq "the source token in the build job: refused" 1 $?
has "token twice: says so" "secrets.JAILOPS_SOURCE_TOKEN must appear exactly once" "$T/check.out"
reset
edit 's = s.replace("    environment: source\n", "")'
check; eq "build-private without its Environment: refused" 1 $?
has "no Environment: says so" "build-private must say 'environment: source'" "$T/check.out"
reset
edit 's = s.replace("    if: github.event_name != '"'"'pull_request'"'"' && github.ref == '"'"'refs/heads/master'"'"' && needs.build.outputs.private != '"'"''"'"'\n", "")'
check; eq "build-private without the master condition: refused" 1 $?
has "no condition: says so" "build-private must have a" "$T/check.out"
reset
sed -i 's/^token_env:.*/token_env: SOME_OTHER_TOKEN/' "$R/main/unisupply/upstream.yaml"
check; eq "a token_env other than JAILOPS_SOURCE_TOKEN: refused" 1 $?
cp "$HERE/main/unisupply/upstream.yaml" "$R/main/unisupply/upstream.yaml"
sed -i 's/^token_env:.*/token_env: JAILOPS_SOURCE_TOKEN/' "$R/main/jailops/upstream.yaml"
check; eq "the source of the catalog validator behind a token: refused" 1 $?
has "jailops token: says why" "token_env must be empty" "$T/check.out"
cp "$HERE/main/jailops/upstream.yaml" "$R/main/jailops/upstream.yaml"
check; eq "and the repository passes again" 0 $?

# the retention policy is applied by the publish job itself
edit 's = s.replace("sh scripts/prune-plan.sh --generate site dist", "echo no plan")'
check; eq "publish without the prune plan: refused" 1 $?
has "no prune plan: says why" "must run 'prune-plan.sh --generate'" "$T/check.out"
reset
edit 's = s.replace("--prune \"$PRUNE_FILE\" --key", "--prune prune.yaml --key")'
check; eq "signing without the generated plan: refused" 1 $?
has "signing without the plan: says why" "must apply the generated plan" "$T/check.out"
reset
edit 's = s.replace("        run: sh scripts/check-site-size.sh site 900\n", "        run: echo no size gate\n")'
check; eq "publish without the size gate: refused" 1 $?
has "no size gate: says why" "must run scripts/check-site-size.sh" "$T/check.out"
reset
edit '
k = s.index("      # After the archive push, before the upload")
e = s.index("      - name: Cache the published package files")
blk = s[k:e]
s = s[:k] + s[e:]
u = s.index("      # Only here: after the signed repository verified")
s = s[:u] + blk + s[u:]'
check; eq "the final archive check after the upload step: refused" 1 $?
has "archive check after the upload: says why" "must verify the final site against the archive" "$T/check.out"
reset
edit 's = s.replace("        run: sh scripts/verify-archive.sh --repo \"$GITHUB_REPOSITORY\" --from site\n", "        run: echo no check\n")'
check; eq "publish without the final archive check: refused" 1 $?
has "no final archive check: says why" "must verify the final site against the archive" "$T/check.out"
reset
check; eq "and the workflow passes again" 0 $?

# versions.json: written after the signed catalogs are verified, never before; and no deciding script reads it
edit 's = s.replace("        run: python3 scripts/versions-index.py site\n", "        run: echo no index\n")'
check; eq "publish job without versions.json: refused" 1 $?
has "versions.json missing: says why" "must write versions.json" "$T/check.out"
reset
edit '
v = s.index("      # versions.json: the newest version")
a = s.index("      - name: Archive every published package")
blk = s[v:a]
s = s[:v] + s[a:]
k = s.index("      # The only step with the key on disk")
s = s[:k] + blk + s[k:]'
check; eq "versions.json before the verified catalogs: refused" 1 $?
reset
printf '\n# test\njq . site/versions.json >/dev/null\n' >> "$R/scripts/changed.sh"
check; eq "a deciding script that reads versions.json: refused" 1 $?
has "names the script" "scripts/changed.sh reads versions.json" "$T/check.out"
(cd "$HERE" && cp scripts/changed.sh "$R/scripts/changed.sh")
check; eq "and passes again without it" 0 $?

[ "$fails" = 0 ] && echo "test-workflow: all ok" || echo "test-workflow: $fails FAILED"
exit $((fails > 0))
