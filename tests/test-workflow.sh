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

# the key written before the downloads (the order the workflow had before)
edit '
a = s.index("      - uses: actions/download-artifact@v8")
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

# third-party actions: unpinned fails, pinned passes, first-party / local / docker are fine
edit 's = s.replace("      - uses: actions/upload-pages-artifact@v3", "      - uses: \"example/tool@v2\"   # a tag\n      - uses: actions/upload-pages-artifact@v3")'
check; eq "unpinned third-party action: refused" 1 $?
has "unpinned: the command to pin it" "gh api repos/example/tool/commits/v2 --jq .sha" "$T/check.out"
ACTIONS_PIN_ENFORCE=0 sh "$R/scripts/check-actions-pinned.sh" "$R/.github" > "$T/pin.out" 2>&1; eq "ACTIONS_PIN_ENFORCE=0: only warns" 0 $?
has "warn mode: says so" "warning only until ACTIONS_PIN_ENFORCE=1" "$T/pin.out"
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@v3", "      - uses: example/tool/sub@0123456789abcdef0123456789abcdef01234567 # v2.1.0\n      - uses: github/codeql-action/init@v3\n      - uses: docker://alpine:3\n      - uses: actions/upload-pages-artifact@v3")'
check; eq "pinned third-party, first-party, docker: accepted" 0 $?
reset
edit 's = s.replace("      - uses: actions/upload-pages-artifact@v3", "      - uses: example/tool@0123456789abcdef\n      - uses: actions/upload-pages-artifact@v3")'
check; eq "a short SHA is not a pin" 1 $?
reset

[ "$fails" = 0 ] && echo "test-workflow: all ok" || echo "test-workflow: $fails FAILED"
exit $((fails > 0))
