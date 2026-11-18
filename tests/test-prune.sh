#!/bin/sh
# Offline tests of the retention policy (docs/RETENTION.md): scripts/prune-plan.sh keeps the newest version of every package
# and ABI and lists the older ones in prune.yaml; the baseline then leaves them out of the site; the next release adds a version
# and the previous one drops off at the next plan. Nothing is ever deleted from the source site. A tiny signed repository is
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

# ---- the repository root the scripts run against: its own prune.yaml and the key's fingerprint
R=$T/root; mkdir -p "$R"
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"
sha256sum "$U/jailops.pub" | cut -d' ' -f1 > "$R/KEY_FINGERPRINT"
export REPO_ROOT="$R" BASELINE_CACHE="$T/cache" SITE="$URL" PKGOPS="$PKGOPS"
plan() { sh "$HERE/scripts/prune-plan.sh" "$@" > "$T/out" 2>"$T/err"; }
base() { sh "$HERE/scripts/baseline.sh" "$1" "$URL" > "$T/out" 2>"$T/err"; }
entries() { grep -c 'abi:' "$R/prune.yaml" || true; }
site() { (cd "$1" && find . -name '*.pkg' -path '*/All/*' | sed 's|^.*/||' | sort | tr '\n' ' '); }
listed() { jq -r '.packages[] | .name + "-" + .version' "$1/pkgops-index.json" | sort | tr '\n' ' '; }

# 1. the plan keeps the newest of each package and lists the rest; it writes nothing
plan; rc=$?
eq "plan: succeeds" 0 "$rc"
grep -q 'alpha-1.0.0' "$T/out" && grep -q 'alpha-1.1.0' "$T/out" && ok "plan: names the two older alpha versions" || bad "plan: alpha 1.0.0 and 1.1.0 not named"
grep -q 'alpha-1.2.0\|beta-2.0.0' "$T/out" && bad "plan: names a newest version" || ok "plan: names no newest version"
eq "plan: prune.yaml untouched" 0 "$(entries)"

# 2. written, then applied: only the newest versions are on the site, and the source site loses nothing
plan --write; rc=$?
eq "write: succeeds" 0 "$rc"
eq "write: two entries" 2 "$(entries)"
grep -q 'only the newest version of each package is kept' "$R/prune.yaml" && ok "write: the reason says the policy" || bad "write: reason text"
base "$T/s1"; rc=$?
eq "apply: baseline succeeds" 0 "$rc"
eq "apply: the site holds only the newest versions" "alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$T/s1")"
eq "apply: the index lists the same" "alpha-1.2.0 beta-2.0.0 " "$(listed "$T/s1")"
eq "apply: the source site still holds every file (nothing is deleted)" "alpha-1.0.0.pkg alpha-1.1.0.pkg alpha-1.2.0.pkg beta-2.0.0.pkg " "$(site "$U")"

# 3. the next release adds a version: the previous one drops off at the next plan, the old entries stay and are not repeated
mk alpha 1.3.0
base "$T/s2"; rc=$?
eq "next release: published on top of the old plan" "alpha-1.2.0.pkg alpha-1.3.0.pkg beta-2.0.0.pkg " "$(site "$T/s2")"
plan --write; rc=$?
eq "next release: write succeeds" 0 "$rc"
eq "next release: one more entry, none repeated" 3 "$(entries)"
base "$T/s3"; rc=$?
eq "next release: only the newest are left" "alpha-1.3.0.pkg beta-2.0.0.pkg " "$(site "$T/s3")"
plan; rc=$?
eq "idempotent: a plan with nothing older is empty and succeeds" 0 "$rc"
grep -q '^prune ' "$T/out" && bad "idempotent: lists entries again" || ok "idempotent: lists nothing"
eq "idempotent: still three entries" 3 "$(entries)"

# 4. KEEP keeps more
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"
KEEP=2 plan --write; rc=$?
eq "KEEP=2: succeeds" 0 "$rc"
eq "KEEP=2: two entries (alpha 1.0.0 and 1.1.0)" 2 "$(entries)"
base "$T/s4"
eq "KEEP=2: the newest two are kept" "alpha-1.2.0.pkg alpha-1.3.0.pkg beta-2.0.0.pkg " "$(site "$T/s4")"
KEEP=0 plan; rc=$?
eq "KEEP=0 is refused" 1 "$rc"

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
