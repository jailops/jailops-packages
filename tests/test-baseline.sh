#!/bin/sh
# Offline tests of scripts/baseline.sh (incremental baseline from the Actions cache, verified against the signing key).
# A tiny signed repository is built with pkgops and served by a static server on loopback; nothing here needs the
# network, a secret or a real key. The signing key is generated into a temp dir and deleted again.
#   PKGOPS=/path/to/pkgops    use this binary (default: pkgops on PATH when it has `fetch --pubkey`, else built from
#                             the working tree of PKGOPS_SRC)
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

# ---- a throwaway key, an "upstream" site and a static server
pkgops key generate --out "$T/k.key" --bits 2048 >/dev/null
U=$T/upstream; mkdir -p "$U" "$T/empty"
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
  build "$1" "$2" && pkgops repo --repo "$U" --key "$T/k.key" "$T/dist" >/dev/null || { echo "cannot add $1"; exit 1; }
}
serve() { rm -f "$T/port"; python3 -c '
import http.server, socketserver, functools, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
h.log_message = lambda *a, **k: None
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
s = S(("127.0.0.1", 0), h); print(s.server_address[1], flush=True); s.serve_forever()' "$1" > "$T/port" 2>/dev/null & SRV=$!
  i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  PORT=$(cat "$T/port")
}
serve "$U"; URL=http://127.0.0.1:$PORT

# ---- the repository root the script runs against: its own prune.yaml, no entries, and the key's fingerprint; the
# site publishes the public key as jailops.pub, like scripts/site-files.sh
R=$T/root; mkdir -p "$R"
printf 'schema: 1\nentries: []\n' > "$R/prune.yaml"
pkgops key public --key "$T/k.key" > "$U/jailops.pub"
sha256sum "$U/jailops.pub" | cut -d' ' -f1 > "$R/KEY_FINGERPRINT"
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

# 10. the acceptance test of the verified baseline: a package AND its index hash changed on the site, without the key.
# The run stops in the baseline step, before the publish job could write the key or sign; nothing is left to sign.
tamper() { # tamper NAME VERSION : other bytes for the same name and version, and an index that matches them
  cp "$U/$ALL/$1-$2.pkg" "$T/orig.pkg"; cp "$U/pkgops-index.json" "$T/orig-index.json"
  build "$1" "$2"; cp "$T/dist/$ABI/$1-$2.pkg" "$U/$ALL/$1-$2.pkg"
  sum=$(sha256sum "$U/$ALL/$1-$2.pkg" | cut -d' ' -f1); size=$(wc -c < "$U/$ALL/$1-$2.pkg" | tr -d ' ')
  jq --arg f "$ALL/$1-$2.pkg" --arg s "$sum" --argjson z "$size" '(.packages[] | select(.file == $f)) |= (.sha256 = $s | .size = $z)' \
    "$U/pkgops-index.json" > "$T/ix.json" && mv "$T/ix.json" "$U/pkgops-index.json"
}
untamper() { cp "$T/orig.pkg" "$U/$ALL/$1-$2.pkg"; cp "$T/orig-index.json" "$U/pkgops-index.json"; }
rm -rf "$CACHE"
tamper delta 1.0.0
pipeline() { # the publish job's order: baseline, then (only then) the key and the signature
  run "$1" && pkgops key generate --out "$T/signer.key" --bits 2048 >/dev/null && pkgops repo --repo "$1" --key "$T/signer.key" >/dev/null && echo signed > "$T/signed"
}
rm -f "$T/signed"; pipeline "$T/s20"; rc=$?
[ "$rc" != 0 ] && ok "tampered package and hash: the pipeline stops ($rc)" || bad "tampered package and hash: accepted"
grep -q 'signed catalog says' "$T/err" && ok "tampered: says the signed catalog disagrees" || bad "tampered: message: $(cat "$T/err")"
[ ! -e "$T/signed" ] && [ ! -e "$T/signer.key" ] && ok "tampered: no key was written and nothing was signed" || bad "tampered: signing was reached"
eq "tampered: nothing left in the site" "" "$(find "$T/s20" -name pkgops-index.json -o -name data.pkg 2>/dev/null | tr '\n' ' ')"
# a warm cache does not help either
untamper delta 1.0.0; run "$T/s21"; tamper delta 1.0.0
run "$T/s22"; rc=$?
[ "$rc" != 0 ] && ok "tampered with a warm cache: stops" || bad "tampered with a warm cache: accepted"
untamper delta 1.0.0

# 11. the key on the site is not the committed one
cp "$U/jailops.pub" "$T/good.pub"
pkgops key generate --out "$T/other.key" --bits 2048 >/dev/null; pkgops key public --key "$T/other.key" > "$U/jailops.pub"
run "$T/s23"; rc=$?
[ "$rc" != 0 ] && grep -q 'KEY_FINGERPRINT says' "$T/err" && ok "another key on the site: stops" || bad "another key on the site: rc $rc $(cat "$T/err")"
# ... and a whole site re-signed with that key (catalogs, index, key file all agree) stops the same way
cp -R "$U" "$T/forged"; pkgops repo --repo "$T/forged" --key "$T/other.key" --replace >/dev/null
kill "$SRV" 2>/dev/null; serve "$T/forged"; FORGED=http://127.0.0.1:$PORT
run "$T/s24" "$FORGED"; rc=$?
[ "$rc" != 0 ] && ok "a site re-signed with another key: stops" || bad "a site re-signed with another key: accepted"
cp "$T/good.pub" "$U/jailops.pub"
kill "$SRV" 2>/dev/null; serve "$U"; URL=http://127.0.0.1:$PORT
# key rotation: the old fingerprint for one run
BASELINE_KEY_FINGERPRINT=$(sha256sum "$T/good.pub" | cut -d' ' -f1) run "$T/s25"; rc=$?
eq "BASELINE_KEY_FINGERPRINT: used instead of KEY_FINGERPRINT" 0 "$rc"
# no key on the site at all: the site is not taken as a baseline (offline the archive fails too, so the run stops)
mv "$U/jailops.pub" "$T/away.pub"
run "$T/s26"; rc=$?
[ "$rc" != 0 ] && grep -q 'no public key' "$T/err" && ok "no key on the site: the site is not used" || bad "no key on the site: rc $rc"
mv "$T/away.pub" "$U/jailops.pub"

# 12. rollback: an older, genuinely signed catalog next to the current index is refused; a whole older snapshot
# (catalogs and index of an earlier day) verifies, because the catalog has no serial (docs/BASELINE-CACHE.md)
D=$U/$ABI/latest; mkdir -p "$T/old" "$T/new"
for f in data.pkg packagesite.pkg meta meta.conf; do cp "$D/$f" "$T/old/$f"; done; cp "$U/pkgops-index.json" "$T/old/"
mk alpha 1.2.0
for f in data.pkg packagesite.pkg meta meta.conf; do cp "$D/$f" "$T/new/$f"; cp "$T/old/$f" "$D/$f"; done; cp "$U/pkgops-index.json" "$T/new/"
run "$T/s27"; rc=$?
[ "$rc" != 0 ] && grep -q 'newer than alpha-1.1.0' "$T/err" && ok "rollback: an old signed catalog with the current index stops" || bad "rollback: rc $rc $(cat "$T/err")"
cp "$T/old/pkgops-index.json" "$U/"
run "$T/s28"; rc=$?
eq "rollback: a consistent older snapshot verifies (the limit)" 0 "$rc"
eq "rollback: ... and its baseline does not have the newer version" "" "$(jq -r '.packages[]|select(.name=="alpha" and .version=="1.2.0")|.file' "$T/s28/pkgops-index.json")"
for f in data.pkg packagesite.pkg meta meta.conf; do cp "$T/new/$f" "$D/$f"; done; cp "$T/new/pkgops-index.json" "$U/"
run "$T/s29"; eq "back to the current state" 0 "$?"

# 13. an older pkgops without `fetch --pubkey`
mkdir -p "$T/oldbin"
cat > "$T/oldbin/pkgops" <<SH
#!/bin/sh
if [ "\$1" = fetch ] && [ "\${2:-}" = -h ]; then echo "usage: pkgops fetch --from URL --into DIR" >&2; exit 2; fi
exec "$PKGOPS" "\$@"
SH
chmod +x "$T/oldbin/pkgops"
PATH="$T/oldbin:$PATH" run "$T/s30"; rc=$?
[ "$rc" != 0 ] && grep -q 'raise PKGOPS_VERSION' "$T/err" && ok "old pkgops: refused" || bad "old pkgops: rc $rc"
PATH="$T/oldbin:$PATH" BASELINE_UNVERIFIED_OK=1 run "$T/s31"; rc=$?
[ "$rc" = 0 ] && grep -q 'NOT VERIFIED' "$T/err" && ok "old pkgops with BASELINE_UNVERIFIED_OK=1: warns and goes on" || bad "old pkgops, unverified ok: rc $rc"

echo "bytes downloaded: cold $COLD (2 packages), warm $WARM, one package added $ADD"
[ "$fails" = 0 ] && echo "test-baseline: all ok" || echo "test-baseline: $fails FAILED"
exit $((fails > 0))
