#!/bin/sh
# Offline tests of scripts/baseline.sh (incremental baseline from the Actions cache). A tiny signed repository is built
# with pkgops and served by a static server on loopback; nothing here needs the network, a secret or a real key.
# The signing key is generated into a temp dir and deleted again.
#   PKGOPS=/path/to/pkgops    use this binary (default: pkgops on PATH, else built from PKGOPS_SRC at tag v0.1.0)
#   PKGOPS_SRC=DIR            a jailops-pkgops checkout (default ../../jailops-pkgops); needs go and GOPROXY=off modules
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-baseline.XXXXXX")
trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }

# ---- pkgops
PKGOPS=${PKGOPS:-$(command -v pkgops || true)}
if [ -z "$PKGOPS" ]; then
  SRC=${PKGOPS_SRC:-$HERE/../jailops-pkgops}
  mkdir -p "$T/src" "$T/bin"
  if git -C "$SRC" rev-parse -q --verify v0.1.0 >/dev/null 2>&1; then git -C "$SRC" archive v0.1.0 | tar -x -C "$T/src"; else cp -R "$SRC/." "$T/src/"; fi
  (cd "$T/src" && GOTOOLCHAIN=auto GOPROXY=off go build -o "$T/bin/pkgops" ./cmd/pkgops) || { echo "cannot build pkgops"; exit 1; }
  PKGOPS=$T/bin/pkgops
fi
mkdir -p "$T/pbin"; ln -s "$PKGOPS" "$T/pbin/pkgops"
PATH="$T/pbin:$PATH"
unset GITHUB_TOKEN PKGOPS_GITHUB_TOKEN GH_TOKEN   # the archive fallback must fail fast, offline
ABI='FreeBSD:15:amd64'; ALL="$ABI/latest/All"

# ---- a throwaway key, an "upstream" site and a static server
pkgops key generate --out "$T/k.key" --bits 2048 >/dev/null
U=$T/upstream; mkdir -p "$U" "$T/empty"
mk() { # mk NAME VERSION : build one package of ~100 KB of random data and add it to the upstream site
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
  (cd "$T" && pkgops build -f m.yaml --abi "$ABI" -o dist --no-go-build >/dev/null) &&
    pkgops repo --repo "$U" --key "$T/k.key" "$T/dist" >/dev/null || { echo "cannot build $1"; exit 1; }
}
serve() { python3 -c '
import http.server, socketserver, functools, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
h.log_message = lambda *a, **k: None
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
s = S(("127.0.0.1", 0), h); print(s.server_address[1], flush=True); s.serve_forever()' "$1" > "$T/port" 2>/dev/null & SRV=$!
  i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  PORT=$(cat "$T/port")
}
serve "$U"; URL=http://127.0.0.1:$PORT

# ---- the repository root the script runs against: its own prune.yaml, no entries
R=$T/root; mkdir -p "$R"
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"
export REPO_ROOT="$R"
CACHE=$T/cache; export BASELINE_CACHE="$CACHE"
run() { # run SITE [URL] ; output in $T/out, status in $?
  sh "$HERE/scripts/baseline.sh" "$1" "${2:-$URL}" > "$T/out" 2>"$T/err"
}
dl() { sed -n 's/^baseline summary: .*downloaded \([0-9?]*\),.*/\1/p' "$T/out"; }
re() { sed -n 's/^baseline summary: reused \([0-9?]*\),.*/\1/p' "$T/out"; }
st() { sed -n 's/.*removed as stale \([0-9?]*\),.*/\1/p' "$T/out"; }
by() { sed -n 's/.*bytes downloaded \([0-9?]*\).*/\1/p' "$T/out"; }
pkgs() { (cd "$1" && find . -name '*.pkg' -path '*/All/*' | sed 's|^\./||' | sort | tr '\n' ' '); }
indexed() { jq -r '.packages[].file' "$1/pkgops-index.json" | sort | tr '\n' ' '; }

mk alpha 1.0.0; mk beta 1.0.0

# 1. cold: no cache at all
run "$T/s1"; rc=$?
eq "cold: succeeds" 0 "$rc"
eq "cold: downloads both packages" "reused 0, downloaded 2, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"
COLD=$(by); [ "${COLD:-0}" -gt 200000 ] && ok "cold: $COLD bytes downloaded" || bad "cold: bytes '$COLD'"
eq "cold: the cache now holds both files" 2 "$(find "$CACHE" -name '*.pkg' | wc -l | tr -d ' ')"
eq "cold: site equals the index" "$(indexed "$T/s1")" "$(pkgs "$T/s1")"

# 2. warm: the cache is restored
run "$T/s2"; rc=$?
eq "warm: succeeds" 0 "$rc"
eq "warm: downloads 0 files" "reused 2, downloaded 0, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"
eq "warm: 0 bytes" 0 "$(by)"
WARM=$(by)
eq "warm: same site as cold" "$(cd "$T/s1" && find . -name '*.pkg' -exec sha256sum {} + | sort)" "$(cd "$T/s2" && find . -name '*.pkg' -exec sha256sum {} + | sort)"

# 3. a package added upstream: only that one is downloaded
mk gamma 1.0.0
run "$T/s3"
eq "added upstream: downloads only the new package" "reused 2, downloaded 1, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"
ADD=$(by)
eq "added upstream: site equals the index" "$(indexed "$T/s3")" "$(pkgs "$T/s3")"

# 4. a version pruned (prune.yaml) although it is in the cache
mk alpha 1.1.0
run "$T/s4"   # cache now has alpha-1.0.0 (still listed upstream)
cat > "$R/prune.yaml" <<'PR'
schema: 1
entries:
  - abi: FreeBSD:15:amd64
    name: alpha
    version: "1.0.0"
    reason: superseded
PR
[ -f "$CACHE/$ALL/alpha-1.0.0.pkg" ] && ok "prune: the cache has the version" || bad "prune: not in the cache"
run "$T/s5"; rc=$?
eq "prune: succeeds" 0 "$rc"
[ ! -e "$T/s5/$ALL/alpha-1.0.0.pkg" ] && ok "prune: the pruned file is not in the site" || bad "prune: alpha-1.0.0.pkg is back"
eq "prune: removed as stale 1" 1 "$(st)"
eq "prune: the index does not list it" "" "$(jq -r '.packages[]|select(.name=="alpha" and .version=="1.0.0")|.file' "$T/s5/pkgops-index.json")"
eq "prune: site equals the index" "$(indexed "$T/s5")" "$(pkgs "$T/s5")"
eq "prune: the cache was refreshed without it" "" "$(ls "$CACHE/$ALL" | grep 'alpha-1.0.0' || true)"
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"

# 5. a corrupted cached file (same size, other bytes) is replaced
run "$T/s6"
f=$CACHE/$ALL/beta-1.0.0.pkg; sz=$(wc -c < "$f"); head -c "$sz" /dev/zero > "$f"
run "$T/s7"
eq "corrupt: exactly the damaged file is downloaded" "1" "$(dl)"
eq "corrupt: the site file has the right sha256" "$(jq -r '.packages[]|select(.name=="beta")|.sha256' "$U/pkgops-index.json")" "$(sha256sum "$T/s7/$ALL/beta-1.0.0.pkg" | cut -d' ' -f1)"
# a truncated one, too
f=$CACHE/$ALL/gamma-1.0.0.pkg; head -c 1000 "$f" > "$f.t"; mv "$f.t" "$f"
run "$T/s8"
eq "truncated: downloaded 1" "1" "$(dl)"
eq "truncated: verified" 0 "$(cd "$T/s8" && jq -r '.packages[] | "\(.sha256)  \(.file)"' pkgops-index.json | (cd "$T/s8" && sha256sum -c --quiet >/dev/null; echo $?))"

# 6. foreign files in the cache
run "$T/s9"
mkdir -p "$CACHE/$ALL" "$CACHE/FreeBSD:99:x/latest/All"
printf x > "$CACHE/$ALL/evil-9.pkg"; printf x > "$CACHE/FreeBSD:99:x/latest/All/other-1.pkg"
printf x > "$CACHE/junk.txt"; printf x > "$CACHE/$ALL/beta-1.0.0.pkg.part"; ln -s /etc/passwd "$CACHE/$ALL/link.pkg"
run "$T/s10"; rc=$?
eq "foreign: succeeds" 0 "$rc"
eq "foreign: site equals the index (nothing foreign)" "$(indexed "$T/s10")" "$(pkgs "$T/s10")"
eq "foreign: no .part, no other files" "" "$(cd "$T/s10" && find . -type f ! -name '*.pkg' ! -name pkgops-index.json | tr '\n' ' ')"
eq "foreign: removed as stale 2" 2 "$(st)"
eq "foreign: the refreshed cache is clean" "$(indexed "$T/s10")" "$(cd "$CACHE" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
# garbage cache that is not even a directory tree of ours
rm -rf "$CACHE"; mkdir -p "$CACHE/x"; printf x > "$CACHE/x/y"
run "$T/s11"; eq "junk-only cache = cold" "reused 0, downloaded 4, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"
rm -rf "$CACHE"
run "$T/s12"; eq "missing cache = cold" "reused 0, downloaded 4, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"

# 7. first_run: unchanged (the cache is ignored; an empty source continues with an empty site)
BASELINE_FIRST_RUN=1 run "$T/s13"
eq "first_run with a source: cache ignored, everything fetched" "reused 0, downloaded 4, removed as stale 0" "$(sed -n 's/^baseline summary: \(.*\), bytes.*/\1/p' "$T/out")"
serve "$T/empty"; EMPTY=http://127.0.0.1:$PORT
BASELINE_FIRST_RUN=1 run "$T/s14" "$EMPTY"; rc=$?
eq "first_run without a baseline: continues" 0 "$rc"
grep -q 'FIRST RUN' "$T/err" "$T/out" && ok "first_run: says so loudly" || bad "first_run: no warning"
eq "first_run without a baseline: the site is empty" "" "$(find "$T/s14" -type f | tr '\n' ' ')"

# 8. failure: no baseline stops the run, with or without a cache
run "$T/s15" "$EMPTY"; rc=$?
[ "$rc" != 0 ] && ok "no baseline: stops ($rc)" || bad "no baseline: exit 0"
grep -q 'no baseline from' "$T/err" && ok "no baseline: says why" || bad "no baseline: message"
mkdir -p "$CACHE/$ALL"; cp "$T/s13/$ALL/beta-1.0.0.pkg" "$CACHE/$ALL/"
run "$T/s16" "$EMPTY"; rc=$?
[ "$rc" != 0 ] && ok "no baseline with a populated cache: still stops" || bad "a cache replaced the baseline"
run "$T/s17" "http://127.0.0.1:1"; rc=$?
[ "$rc" != 0 ] && ok "unreachable site: stops" || bad "unreachable site: exit 0"

# 9. --refresh-cache after the site changed (publish adds a package)
rm -rf "$CACHE"; run "$T/s18"
mk delta 1.0.0; run "$T/s19"; sh "$HERE/scripts/baseline.sh" --refresh-cache "$T/s19" >/dev/null
eq "refresh-cache: holds exactly the indexed files" "$(indexed "$T/s19")" "$(cd "$CACHE" && find . -name '*.pkg' | sed 's|^\./||' | sort | tr '\n' ' ')"

echo "bytes downloaded: cold $COLD (2 packages), warm $WARM, one package added $ADD"
[ "$fails" = 0 ] && echo "test-baseline: all ok" || echo "test-baseline: $fails FAILED"
exit $((fails > 0))
