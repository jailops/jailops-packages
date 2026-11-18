#!/bin/sh
# Offline tests of the retention policy (docs/RETENTION.md; the default keeps two versions, the tests set KEEP=1 for most of
# the cases and unset it for the default): the publish job's plan (scripts/prune-plan.sh --generate) keeps
# the newest version of every package and ABI and lists the older baseline files; signing with the plan leaves them out of the
# site; a release built in the same run drops the previous version in that run; a version built and superseded now stays
# until the next run; a package never ends without a version; the plan is deterministic. Nothing is ever deleted from the
# source site. A tiny signed repository is
# built with pkgops and served on loopback; no network, no secret, no real key (the key is generated into a temp dir).
#   PKGOPS=/path/to/pkgops    use this binary (default: pkgops on PATH when it has `fetch --pubkey`, else built from PKGOPS_SRC)
#   PKGOPS_SRC=DIR            a jailops-pkgops checkout (default ../../jailops-pkgops); needs go and GOPROXY=off modules
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRV=
T=$(mktemp -d "${TMPDIR:-/tmp}/test-prune.XXXXXX")
trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }

# ---- pkgops
PKGOPS=${PKGOPS:-$(command -v pkgops || true)}
if [ -n "$PKGOPS" ] && ! "$PKGOPS" fetch -h 2>&1 | grep -q -- '-pubkey'; then
  echo "note: $PKGOPS has no 'fetch --pubkey'; building one from PKGOPS_SRC"; PKGOPS=
fi
if [ -z "$PKGOPS" ]; then
  SRC=${PKGOPS_SRC:-$HERE/../jailops-pkgops}
  mkdir -p "$T/bin"
  (cd "$SRC" && GOTOOLCHAIN=auto GOPROXY=off go build -o "$T/bin/pkgops" ./cmd/pkgops) || { echo "cannot build pkgops"; exit 1; }
  PKGOPS=$T/bin/pkgops
fi
mkdir -p "$T/pbin"; ln -s "$PKGOPS" "$T/pbin/pkgops"
PATH="$T/pbin:$PATH"
unset GITHUB_TOKEN PKGOPS_GITHUB_TOKEN GH_TOKEN   # the archive fallback must fail fast, offline
ABI='FreeBSD:15:amd64'; ALL="$ABI/latest/All"

# ---- a throwaway key, an "upstream" site (what is published now) and a static server
pkgops key generate --out "$T/k.key" --bits 2048 >/dev/null
U=$T/upstream; mkdir -p "$U"
build() { # build NAME VERSION : one package of ~100 KB of random data in $T/dist
  head -c 100000 /dev/urandom > "$T/blob"
  cat > "$T/m.yaml" <<MF
name: $1
version: $2
origin: jailops/$1
comment: test
desc: test
www: https://example.org
maintainer: packages@jailops.net
license: BSD2CLAUSE
abis: [$ABI]
min_release: "15.1"
files:
  - source: blob
    destination: share/$1/blob
MF
  rm -rf "$T/dist"
  (cd "$T" && pkgops build -f m.yaml --abi "$ABI" -o dist --no-go-build >/dev/null) || { echo "cannot build $1"; exit 1; }
}
mk() { # mk NAME VERSION : build one package and add it to the upstream site, signed
  build "$1" "$2" && pkgops repo --repo "$U" --key "$T/k.key" "$T/dist" >/dev/null || { echo "cannot add $1 $2"; exit 1; }
}
serve() {
  rm -f "$T/port"; python3 -c '
import http.server, socketserver, functools, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
h.log_message = lambda *a, **k: None
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
s = S(("127.0.0.1", 0), h); print(s.server_address[1], flush=True); s.serve_forever()' "$1" > "$T/port" 2>/dev/null & SRV=$!
  i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  PORT=$(cat "$T/port")
}
mk alpha 1.0.0; mk alpha 1.1.0; mk alpha 1.2.0; mk beta 2.0.0
pkgops key public --key "$T/k.key" > "$U/jailops.pub"
serve "$U"; URL=http://127.0.0.1:$PORT

# ---- the repository root the scripts run against: its own prune.yaml (no extra entries), the policy and the key's fingerprint
R=$T/root; mkdir -p "$R"
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"
cp "$HERE/pkgops-repo.yaml" "$R/pkgops-repo.yaml"
sha256sum "$U/jailops.pub" | cut -d' ' -f1 > "$R/KEY_FINGERPRINT"
export REPO_ROOT="$R" BASELINE_CACHE="$T/cache" SITE="$URL" PKGOPS="$PKGOPS"
export KEEP=1   # the sections up to 10 test the one-version rule; the default (two versions) is tested from section 11
plan() { sh "$HERE/scripts/prune-plan.sh" "$@" > "$T/out" 2>"$T/err"; }
gen() { sh "$HERE/scripts/prune-plan.sh" --generate "$1" "$2" "$3" > "$T/out" 2>"$T/err"; }   # gen BASELINE DIST OUT
base() { sh "$HERE/scripts/baseline.sh" "$1" "$URL" > "$T/out" 2>"$T/err"; }
# apply SITE DIST PLAN: what the signing step does with the plan (a copy of the site: the baseline stays as it is)
apply() { rm -rf "$4"; cp -a "$1" "$4"; if [ -n "$2" ]; then pkgops repo --repo "$4" --policy "$R/pkgops-repo.yaml" --prune "$3" --key "$T/k.key" "$2" > "$T/apply.out" 2>&1; else pkgops repo --repo "$4" --policy "$R/pkgops-repo.yaml" --prune "$3" --key "$T/k.key" > "$T/apply.out" 2>&1; fi; }
entries() { grep -c 'abi:' "$1" || true; }
triples() { awk '/abi:/{a=$NF} /name:/{n=$NF} /version:/{print a, n, $NF}' "$1" | sort | tr '\n' ';'; }
site() { (cd "$1" && find . -name '*.pkg' -path '*/All/*' | sed 's|^.*/||' | sort | tr '\n' ' '); }
listed() { jq -r '.packages[] | .name + "-" + .version' "$1/pkgops-index.json" | sort | tr '\n' ' '; }
mkdir -p "$T/nodist"

# 1. the preview names the older versions of the live site and writes nothing
plan; rc=$?
eq "preview: succeeds" 0 "$rc"
grep -q 'alpha-1.0.0' "$T/out" && grep -q 'alpha-1.1.0' "$T/out" && ok "preview: names the two older alpha versions" || bad "preview: alpha 1.0.0 and 1.1.0 not named"
grep -q 'alpha-1.2.0\|beta-2.0.0' "$T/out" && bad "preview: names a newest version" || ok "preview: names no newest version"
eq "preview: prune.yaml untouched" 0 "$(entries "$R/prune.yaml")"

# 2. the publish job's plan, no new build: the baseline's older versions are planned, the newest are not, and the plan applies
base "$T/s0"; rc=$?
eq "baseline: succeeds" 0 "$rc"
eq "baseline: the live site holds every file" "alpha-1.0.0.pkg alpha-1.1.0.pkg alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$T/s0")"
gen "$T/s0" "$T/nodist" "$T/plan1.yaml"; rc=$?
eq "generate: succeeds" 0 "$rc"
eq "generate: the two older alpha versions, nothing else" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;" "$(triples "$T/plan1.yaml")"
grep -q 'only the newest version of each package is kept' "$T/plan1.yaml" && ok "generate: the reason says the policy" || bad "generate: reason text"
eq "generate: the committed prune.yaml is untouched (nothing to commit)" 0 "$(entries "$R/prune.yaml")"
apply "$T/s0" "" "$T/plan1.yaml" "$T/f1"; rc=$?
eq "apply: signing with the plan succeeds" 0 "$rc"
eq "apply: only the newest versions stay on the site" "alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$T/f1")"
eq "apply: the index lists the same" "alpha-1.2.0 beta-2.0.0 " "$(listed "$T/f1")"
eq "apply: the baseline still holds every file (nothing is deleted from it)" "alpha-1.0.0.pkg alpha-1.1.0.pkg alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$T/s0")"
eq "apply: the pruned files are recorded in the index" 2 "$(jq '.pruned | length' "$T/f1/pkgops-index.json")"
PRUNE_FILE="$T/plan1.yaml" sh "$HERE/scripts/verify-site.sh" "$T/f1" >/dev/null 2>&1; eq "verify-site: nothing the plan lists is on the pruned site" 0 $?
PRUNE_FILE="$T/plan1.yaml" sh "$HERE/scripts/verify-site.sh" "$T/s0" >/dev/null 2>&1; eq "verify-site: a listed file still on the site stops" 1 $?

# 3. the same run: a release is built now, and the version the baseline holds drops off in that run (the 0.8.5 case)
build alpha 1.3.0; mkdir -p "$T/d3"; cp -a "$T/dist/." "$T/d3/"
gen "$T/s0" "$T/d3" "$T/plan3.yaml"; rc=$?
eq "same run: generate succeeds" 0 "$rc"
eq "same run: every older alpha leaves, including the baseline's newest" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;FreeBSD:15:amd64 alpha 1.2.0;" "$(triples "$T/plan3.yaml")"
apply "$T/s0" "$T/d3" "$T/plan3.yaml" "$T/f3"; rc=$?
eq "same run: signing succeeds" 0 "$rc"
eq "same run: the new version and beta stay, no older alpha" "alpha-1.3.0.pkg beta-2.0.0.pkg " "$(site "$T/f3")"
eq "same run: every package still has a version (none vanished)" "alpha beta " "$(jq -r '[.packages[].name] | unique | .[]' "$T/f3/pkgops-index.json" | tr '\n' ' ')"
PRUNE_FILE="$T/plan3.yaml" sh "$HERE/scripts/verify-site.sh" "$T/f3" >/dev/null 2>&1; eq "same run: verify-site passes" 0 $?

# 4. a version built now and superseded now is not a baseline file, so it is not archived yet: it stays until the next run
build alpha 1.4.0; mkdir -p "$T/d4"; cp -a "$T/d3/." "$T/d4/"; cp -a "$T/dist/." "$T/d4/"
gen "$T/s0" "$T/d4" "$T/plan4.yaml"; rc=$?
eq "superseded now: generate succeeds" 0 "$rc"
eq "superseded now: only baseline files are planned" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;FreeBSD:15:amd64 alpha 1.2.0;" "$(triples "$T/plan4.yaml")"
grep -q 'stays this run (built now, not archived yet): FreeBSD:15:amd64 alpha-1.3.0' "$T/out" && ok "superseded now: the output says alpha-1.3.0 stays this run" || bad "superseded now: no note about alpha-1.3.0"
apply "$T/s0" "$T/d4" "$T/plan4.yaml" "$T/f4"
eq "superseded now: the site holds 1.3.0 and 1.4.0 until the next run" "alpha-1.3.0.pkg alpha-1.4.0.pkg beta-2.0.0.pkg " "$(site "$T/f4")"

# 5. a site that holds only newest versions has nothing to plan: a package never ends without a version
gen "$T/f1" "$T/nodist" "$T/plan5.yaml"; rc=$?
eq "nothing older: generate succeeds" 0 "$rc"
eq "nothing older: no entry" 0 "$(entries "$T/plan5.yaml")"
grep -q 'plan: 0 file(s)' "$T/out" && ok "nothing older: the output says so" || bad "nothing older: output"

# 5b. the next publish starts from that site: its plan is empty (the committed prune.yaml lists nothing) and the files pruned
# before stay recorded as pruned in the index, so the archive check keeps reading them as normal
apply "$T/f1" "" "$T/plan5.yaml" "$T/f5"; rc=$?
eq "carry over: signing with an empty plan succeeds" 0 "$rc"
eq "carry over: the records of the pruned files stay in the index" 2 "$(jq '.pruned | length' "$T/f5/pkgops-index.json")"
eq "carry over: the site is the same" "$(site "$T/f1")" "$(site "$T/f5")"

# 6. deterministic: the same inputs give the same plan and the same output
gen "$T/s0" "$T/d3" "$T/plan3b.yaml"; cp "$T/out" "$T/out3b"
gen "$T/s0" "$T/d3" "$T/plan3c.yaml"
eq "deterministic: the entries are the same" "$(triples "$T/plan3b.yaml")" "$(triples "$T/plan3c.yaml")"
eq "deterministic: the output is the same" "$(cat "$T/out3b")" "$(cat "$T/out")"

# 7. KEEP keeps more
KEEP=2 gen "$T/s0" "$T/d3" "$T/plan7.yaml"; rc=$?
eq "KEEP=2: succeeds" 0 "$rc"
eq "KEEP=2: alpha 1.0.0 and 1.1.0 leave, 1.2.0 and 1.3.0 stay" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;" "$(triples "$T/plan7.yaml")"
KEEP=0 plan; rc=$?
eq "KEEP=0 is refused" 1 "$rc"
KEEP=0 gen "$T/s0" "$T/nodist" "$T/plan0.yaml"; rc=$?
eq "KEEP=0 is refused by generate too" 1 "$rc"

# 8. an extra entry in the committed prune.yaml stays in the plan and is not repeated by the policy
cp "$R/prune.yaml" "$T/prune.yaml.keep"
pkgops prune --plan --from "$URL" --manifest "$R/prune.yaml" --name alpha --version 1.1.0 --by test --reason "by hand" >/dev/null
eq "extra: one explicit entry in the committed file" 1 "$(entries "$R/prune.yaml")"
gen "$T/s0" "$T/nodist" "$T/plan8.yaml"; rc=$?
eq "extra: generate succeeds" 0 "$rc"
eq "extra: the explicit entry and the policy's, none twice" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;" "$(triples "$T/plan8.yaml")"
grep -q 'by hand' "$T/plan8.yaml" && ok "extra: the explicit entry keeps its reason" || bad "extra: reason lost"
cp "$T/prune.yaml.keep" "$R/prune.yaml"

# 9. no baseline index: refused
mkdir -p "$T/empty"
gen "$T/empty" "$T/nodist" "$T/plan9.yaml"; rc=$?
eq "no index: refused" 1 "$rc"

# 10. the size gate: a site above the limit stops the publish before the deploy
mkdir -p "$T/big/FreeBSD:15:amd64/latest/All"
head -c 3000000 /dev/zero > "$T/big/FreeBSD:15:amd64/latest/All/big-1.pkg"
sh "$HERE/scripts/check-site-size.sh" "$T/big" 900 >/dev/null 2>&1; eq "size gate: 3 MB is below 900 MB" 0 $?
sh "$HERE/scripts/check-site-size.sh" "$T/big" 2 >/dev/null 2>&1; eq "size gate: 3 MB is not below 2 MB" 1 $?
SITE_LIMIT_MB=3 sh "$HERE/scripts/check-site-size.sh" "$T/big" >/dev/null 2>&1; eq "size gate: the limit from SITE_LIMIT_MB" 1 $?

# 11. the default is two versions: the newest and the one before it stay, and a live site that already holds two loses nothing
unset KEEP
plan; rc=$?
eq "default: the preview succeeds" 0 "$rc"
grep -q 'alpha-1.0.0' "$T/out" && ! grep -q 'alpha-1.1.0' "$T/out" && ok "default: the preview names only alpha 1.0.0" || bad "default: the preview names the wrong versions"
gen "$T/s0" "$T/nodist" "$T/plan11.yaml"; rc=$?
eq "default: generate succeeds" 0 "$rc"
eq "default: only the version before the newest two leaves" "FreeBSD:15:amd64 alpha 1.0.0;" "$(triples "$T/plan11.yaml")"
grep -q 'the newest 2 versions of each package are kept' "$T/plan11.yaml" && ok "default: the reason says two versions" || bad "default: reason text"
apply "$T/s0" "" "$T/plan11.yaml" "$T/f11"
eq "default: two versions of alpha and beta stay on the site" "alpha-1.1.0.pkg alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$T/f11")"
gen "$T/f11" "$T/nodist" "$T/plan11b.yaml"; rc=$?
eq "live state: a site with at most two versions of each package, generate succeeds" 0 "$rc"
eq "live state: nothing leaves" 0 "$(entries "$T/plan11b.yaml")"
gen "$T/s0" "$T/d3" "$T/plan11c.yaml"
eq "default, same run: a new alpha 1.3.0 pushes 1.0.0 and 1.1.0 out and keeps 1.2.0" "FreeBSD:15:amd64 alpha 1.0.0;FreeBSD:15:amd64 alpha 1.1.0;" "$(triples "$T/plan11c.yaml")"
export KEEP=1

# 12. the dependency closure: a package that stays on the site must find its jailops/... dependencies on the site, by name
buildd() { # buildd NAME VERSION DEPSLINES: one package with dependencies in $T/dist
  head -c 1000 /dev/urandom > "$T/blob"
  cat > "$T/m.yaml" <<MF
name: $1
version: $2
origin: jailops/$1
comment: test
desc: test
www: https://example.org
maintainer: packages@jailops.net
license: BSD2CLAUSE
abis: [$ABI]
min_release: "15.1"
deps:
$3
files:
  - source: blob
    destination: share/$1/blob
MF
  rm -rf "$T/dist"
  (cd "$T" && pkgops build -f m.yaml --abi "$ABI" -o dist --no-go-build >/dev/null) || { echo "cannot build $1"; exit 1; }
}
CL=$T/cl
buildd top 1.0.0 '  - {name: lib, origin: jailops/lib, version: "2.0.0"}
  - {name: curl, origin: ftp/curl, version: "8"}'
pkgops repo --repo "$CL" --key "$T/k.key" "$T/dist" >/dev/null
VERIFY_SITE_STRICT=1 sh "$HERE/scripts/verify-site.sh" "$CL" > "$T/out" 2>&1; eq "closure: a kept package whose jailops/ dependency is not on the site fails" 1 $?
grep -q 'MISSING dependency: top 1.0.0 FreeBSD:15:amd64 needs lib' "$T/out" && ok "closure: names the package and the missing dependency" || bad "closure: message"
grep -q 'needs curl' "$T/out" && bad "closure: a dependency outside jailops/ is not checked" || ok "closure: a dependency outside jailops/ is not checked"
sh "$HERE/scripts/verify-site.sh" "$CL" >/dev/null 2>&1; eq "closure: not checked outside the strict mode" 0 $?
buildd lib 2.0.0 '  []'
pkgops repo --repo "$CL" --key "$T/k.key" "$T/dist" >/dev/null
VERIFY_SITE_STRICT=1 sh "$HERE/scripts/verify-site.sh" "$CL" >/dev/null 2>&1; eq "closure: the dependency is there, by name, and passes" 0 $?
# the version the package recorded (2.0.0) is not what counts: pkg resolves by name
buildd lib 3.0.0 '  []'
printf 'schema: 1\nentries:\n  - abi: %s\n    name: lib\n    version: 2.0.0\n' "$ABI" > "$T/pr12.yaml"
pkgops repo --repo "$CL" --key "$T/k.key" --prune "$T/pr12.yaml" "$T/dist" >/dev/null 2>&1
VERIFY_SITE_STRICT=1 sh "$HERE/scripts/verify-site.sh" "$CL" >/dev/null 2>&1; eq "closure: another version of the dependency satisfies it (by name)" 0 $?

# 13. a second run with an empty prune.yaml keeps the earlier pruned[] records, and the archive check passes on it. The archive is
# a stand-in (a list of what was published) that applies the rules of `pkgops verify-archive` (internal/archive.Verify)
mkdir -p "$T/fake2"
jq -r '.packages[] | "\(.abi) \(.name)-\(.version) \(.sha256)"' "$U/pkgops-index.json" | sort > "$T/archive.list"
cat > "$T/fake2/pkgops" <<FK
#!/bin/sh
[ "\$1" = verify-archive ] || exec "$PKGOPS" "\$@"
while [ \$# -gt 0 ]; do case "\$1" in --from) from=\$2; shift ;; esac; shift; done
idx=\$from/pkgops-index.json
jq -r '.packages[] | "\(.abi) \(.name)-\(.version) \(.sha256)"' "\$idx" | sort > "$T/live.list"
jq -r '.pruned[]? | "\(.abi) \(.name)-\(.version)"' "\$idx" | sort > "$T/pruned.list"
n1=\$(awk 'NR==FNR {a[\$1" "\$2]=1; next} !(\$1" "\$2 in a)' "$T/archive.list" "$T/live.list" | wc -l)
n2=\$(awk 'NR==FNR {l[\$1" "\$2]=1; next} {k=\$1" "\$2; if (!(k in l)) print k}' "$T/live.list" "$T/archive.list" | sort | comm -23 - "$T/pruned.list" | wc -l)
n3=\$(awk 'NR==FNR {a[\$1" "\$2]=\$3; next} (\$1" "\$2 in a) && a[\$1" "\$2] != \$3' "$T/archive.list" "$T/live.list" | wc -l)
n4=\$(awk 'NR==FNR {a[\$1" "\$2]=1; next} (\$1" "\$2 in a)' "$T/archive.list" "$T/pruned.list" | wc -l)
n5=\$(awk 'NR==FNR {a[\$1" "\$2]=1; next} !(\$1" "\$2 in a)' "$T/archive.list" "$T/pruned.list" | wc -l)
echo "on Pages, not archived (PROBLEM): \$n1"
echo "archived, not on Pages and not pruned (PROBLEM): \$n2"
echo "sha256 differs between Pages and archive (PROBLEM): \$n3"
echo "pruned from Pages, still archived (normal): \$n4"
echo "pruned from Pages and not archived (gone for good): \$n5"
[ "\$n1\$n2\$n3" = 000 ] || exit 1
FK
chmod +x "$T/fake2/pkgops"
va() { (PATH="$T/fake2:$PATH"; sh "$HERE/scripts/verify-archive.sh" --repo x/y --from "$1" > "$T/va.out" 2>&1); }
va "$T/f1"; eq "archive: the first pruned site passes" 0 $?
grep -q 'still archived (normal): 2' "$T/va.out" && ok "archive: the two pruned files are read as normal" || bad "archive: pruned count"
va "$T/f5"; eq "archive: the second run (empty prune.yaml) passes" 0 $?
grep -q 'still archived (normal): 2' "$T/va.out" && ok "archive: the earlier pruned records are still there" || bad "archive: records lost in the second run"
cp "$T/archive.list" "$T/archive.keep"; grep -v ' alpha-1.0.0 ' "$T/archive.list" > "$T/archive.x"; cp "$T/archive.x" "$T/archive.list"
va "$T/f5"; eq "archive: a pruned file that the archive does not hold stops the run" 1 $?
cp "$T/archive.keep" "$T/archive.list"
printf 'FreeBSD:15:amd64 alpha-1.9.0 %s\n' "$(printf x | sha256sum | cut -d' ' -f1)" >> "$T/archive.list"
va "$T/f5"; eq "archive: an archived file that neither the site nor the index mentions stops the run" 1 $?
cp "$T/archive.keep" "$T/archive.list"

# 14. the size warning from seven ninths of the limit
mkdir -p "$T/near/FreeBSD:15:amd64/latest/All"
head -c 3500000 /dev/zero > "$T/near/FreeBSD:15:amd64/latest/All/near-1.pkg"
sh "$HERE/scripts/check-site-size.sh" "$T/near" 4 > "$T/size.out" 2>&1; eq "size warning: below the limit passes" 0 $?
grep -q '::warning' "$T/size.out" && ok "size warning: printed from seven ninths of the limit" || bad "size warning: not printed"
sh "$HERE/scripts/check-site-size.sh" "$T/near" 900 > "$T/size.out" 2>&1
grep -q '::warning' "$T/size.out" && bad "size warning: printed far below the limit" || ok "size warning: not printed far below the limit"

# 5. scripts/verify-archive.sh stops on a pruned file that the archive does not hold, which pkgops only lists
mkdir -p "$T/fake"
cat > "$T/fake/pkgops" <<'FK'
#!/bin/sh
echo "on Pages, not archived (PROBLEM): ${FAKE_PROBLEM:-0}"
echo "pruned from Pages, still archived (normal): 3"
echo "pruned from Pages and not archived (gone for good): ${FAKE_GONE:-0}"
[ "${FAKE_PROBLEM:-0}" = 0 ] || exit 1
FK
chmod +x "$T/fake/pkgops"
(PATH="$T/fake:$PATH"; sh "$HERE/scripts/verify-archive.sh" --repo x/y >/dev/null 2>&1); eq "verify-archive: nothing gone for good passes" 0 $?
(PATH="$T/fake:$PATH"; FAKE_GONE=2 sh "$HERE/scripts/verify-archive.sh" --repo x/y >/dev/null 2>&1); eq "verify-archive: a pruned file that is not archived stops" 1 $?
(PATH="$T/fake:$PATH"; FAKE_PROBLEM=1 sh "$HERE/scripts/verify-archive.sh" --repo x/y >/dev/null 2>&1); eq "verify-archive: pkgops's own failure stays a failure" 1 $?

[ "$fails" = 0 ] && echo "test-prune: all passed" || { echo "test-prune: $fails FAILED"; exit 1; }
