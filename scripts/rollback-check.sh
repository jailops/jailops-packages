#!/bin/sh
# rollback-check.sh: the experiment behind "Rolling back" in docs/RETENTION.md, on a real pkg(8). A manual FreeBSD check, not part of
# tests/run.sh: it needs a FreeBSD host, root and pkg.
#
#   sh scripts/rollback-check.sh build DIR [ABI]     any host with pkgops: a signed fixture repository, three states of one site
#   sh scripts/rollback-check.sh serve DIR [PORT]    any host with python3: serves DIR on loopback; GET /__phase/NAME switches the site
#   sh scripts/rollback-check.sh check URL           FreeBSD, root: runs the steps against the site at URL and prints what pkg does
#
# The fixture is two packages, depb and depa (depa depends on depb), each in versions 1.0.0 and 2.0.0, signed with a throwaway key:
#   full    both versions' files, the catalog lists the newest (2.0.0) only, exactly as pkgops writes it
#   v1only  what the site held before version 2.0.0 was published
#   pruned  the full site without the 1.0.0 files (the version that left the site)
# `check` installs into a root of its own (pkg -r) with its own database: nothing of the host's packages is touched. A host
# without python3 serves the directory from another machine and forwards the port (ssh -R PORT:127.0.0.1:PORT root@host).
set -u
mode=${1:-}; ABI_DEFAULT='FreeBSD:15:amd64'

case $mode in
build)
  DIR=${2:?usage: build DIR [ABI]}; ABI=${3:-$ABI_DEFAULT}
  command -v pkgops >/dev/null || { echo "pkgops is not on PATH" >&2; exit 1; }
  export GOTOOLCHAIN=${GOTOOLCHAIN:-local}   # pkgops build runs no Go build here (--no-go-build); the toolchain is never downloaded
  rm -rf "$DIR"; mkdir -p "$DIR/w" "$DIR/full"
  pkgops key generate --out "$DIR/k.key" --bits 2048 >/dev/null || exit 1
  mk() { # mk SITE NAME VERSION [DEPENDENCY]
    head -c 50000 /dev/urandom > "$DIR/w/blob"
    { printf 'name: %s\nversion: %s\norigin: jailops/%s\ncomment: rollback check\ndesc: rollback check\nwww: https://example.org\n' "$2" "$3" "$2"
      printf 'maintainer: packages@jailops.net\nlicense: BSD2CLAUSE\nabis: [%s]\nmin_release: "15.1"\n' "$ABI"
      [ -n "${4:-}" ] && printf 'deps:\n  - {name: %s, origin: jailops/%s, version: "%s"}\n' "$4" "$4" "$3"
      printf 'files:\n  - source: blob\n    destination: share/%s/blob\n' "$2"; } > "$DIR/w/m.yaml"
    rm -rf "$DIR/dist"
    (cd "$DIR/w" && pkgops build -f m.yaml --abi "$ABI" -o ../dist --no-go-build >/dev/null) &&
      pkgops repo --repo "$1" --key "$DIR/k.key" "$DIR/dist" >/dev/null || { echo "cannot build $2 $3" >&2; exit 1; }
  }
  mkdir -p "$DIR/v1only"
  mk "$DIR/v1only" depb 1.0.0; mk "$DIR/v1only" depa 1.0.0 depb
  mk "$DIR/full" depb 1.0.0; mk "$DIR/full" depa 1.0.0 depb; mk "$DIR/full" depb 2.0.0; mk "$DIR/full" depa 2.0.0 depb
  for s in full v1only; do pkgops key public --key "$DIR/k.key" > "$DIR/$s/jailops.pub"; done
  cp -a "$DIR/full" "$DIR/pruned"; rm -f "$DIR/pruned/$ABI"/latest/All/dep?-1.0.0.pkg
  sha256sum "$DIR/full/jailops.pub" 2>/dev/null | cut -d' ' -f1 > "$DIR/fingerprint" || sha256 -q "$DIR/full/jailops.pub" > "$DIR/fingerprint"
  rm -rf "$DIR/w" "$DIR/dist"
  echo "built $DIR (full, v1only, pruned); key sha256 $(cat "$DIR/fingerprint")"
  ;;
serve)
  DIR=${2:?usage: serve DIR [PORT]}; PORT=${3:-18089}
  exec python3 - "$DIR" "$PORT" <<'PY'
import http.server, os, socketserver, sys, time
root, port = sys.argv[1], int(sys.argv[2])
state = {"dir": os.path.join(root, "full")}
class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        return os.path.join(state["dir"], os.path.normpath(path.split("?")[0]).lstrip("/"))
    def do_GET(self):
        if self.path.startswith("/__phase/"):
            name = self.path[len("/__phase/"):]
            d = os.path.join(root, name)
            if name not in ("full", "v1only", "pruned") or not os.path.isdir(d):
                self.send_error(404); return
            state["dir"] = d
            now = time.time()   # a new publish has a newer Last-Modified: touch the catalog files
            for base, _, files in os.walk(d):
                if os.path.basename(base) != "All":
                    for f in files:
                        os.utime(os.path.join(base, f), (now, now))
            self.send_response(200); self.end_headers(); self.wfile.write(name.encode()); return
        super().do_GET()
    def log_message(self, *a): pass
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
print("serving", root, "on http://127.0.0.1:%d" % port, flush=True)
S(("127.0.0.1", port), H).serve_forever()
PY
  ;;
check)
  URL=${2:?usage: check URL}; URL=${URL%/}
  [ "$(uname -s)" = FreeBSD ] && [ "$(id -u)" -eq 0 ] || { echo "check runs on FreeBSD as root" >&2; exit 1; }
  ABI=${ABI:-$ABI_DEFAULT}
  T=$(mktemp -d /var/tmp/rollback-check.XXXXXX) || exit 1; trap 'rm -rf "$T"' EXIT
  fails=0
  ok() { echo "ok   $*"; }
  bad() { echo "FAIL $*"; fails=$((fails + 1)); }
  eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
  phase() { fetch -qo /dev/null "$URL/__phase/$1" 2>/dev/null; }
  phase full || echo "note: $URL has no /__phase endpoint (the 'serve' mode has one): the catalog-age step is skipped"
  fetch -qo "$T/jailops.pub" "$URL/jailops.pub" || { echo "cannot fetch the key"; exit 1; }
  echo "key sha256 $(sha256 -q "$T/jailops.pub")"
  # one pkg configuration per client: its own repository file, database, cache and root
  client() { # client NAME : writes $T/NAME.conf and $T/NAME.repos
    mkdir -p "$T/$1.repos" "$T/$1.db" "$T/$1.cache" "$T/$1.root"
    cat > "$T/$1.repos/rb.conf" <<EOF
rb: { url: "$URL/\${ABI}/latest", signature_type: "pubkey", pubkey: "$T/jailops.pub", mirror_type: "none", enabled: yes }
EOF
    cat > "$T/$1.conf" <<EOF
REPOS_DIR: ["$T/$1.repos"]
PKG_DBDIR: "$T/$1.db"
PKG_CACHEDIR: "$T/$1.cache"
ABI: "$ABI"
OSVERSION: $(uname -U)
EOF
  }
  P() { c=$1; shift; pkg -C "$T/$c.conf" -r "$T/$c.root" "$@"; }
  installed() { P "$1" info -q -a 2>/dev/null | sort | tr '\n' ' '; }
  B="$URL/$ABI/latest/All"
  say() { echo "\$ pkg $*"; }
  client a
  say update -f; P a update -f >"$T/o" 2>&1; eq "update succeeds" 0 $?
  eq "the catalog lists the newest version of each package only" "depa-2.0.0 depb-2.0.0 " "$(P a rquery -a '%n-%v' | sort | tr '\n' ' ')"
  say install -y depa; P a install -y depa >"$T/o" 2>&1; eq "install takes the catalog's versions" "depa-2.0.0 depb-2.0.0 " "$(installed a)"
  say add "$B/depa-1.0.0.pkg"; P a add "$B/depa-1.0.0.pkg" >"$T/o" 2>&1; rc=$?; cat "$T/o"
  eq "add without -f: exit status" 0 "$rc"
  eq "add without -f: nothing changed (check with pkg info, the status says nothing)" "depa-2.0.0 depb-2.0.0 " "$(installed a)"
  say add -f depb-1.0.0 depa-1.0.0
  P a add -f "$B/depb-1.0.0.pkg" >"$T/o" 2>&1; eq "add -f depb 1.0.0" 0 $?
  P a add -f "$B/depa-1.0.0.pkg" >"$T/o" 2>&1; eq "add -f depa 1.0.0" 0 $?
  eq "the previous versions are installed" "depa-1.0.0 depb-1.0.0 " "$(installed a)"
  say install -y depa-1.0.0; P a install -y depa-1.0.0 >"$T/o" 2>&1; rc=$?; tail -1 "$T/o"
  [ "$rc" -ne 0 ] && ok "install by name-version: refused, the previous version is not in the catalog" || bad "install by name-version succeeded"
  say lock -y depa depb; P a lock -y depa depb >"$T/o" 2>&1
  say upgrade -y; P a upgrade -y >"$T/o" 2>&1; eq "a locked rollback survives pkg upgrade" "depa-1.0.0 depb-1.0.0 " "$(installed a)"
  P a unlock -y depa depb >"$T/o" 2>&1
  say upgrade -y; P a upgrade -y >"$T/o" 2>&1; eq "unlocked, pkg upgrade goes forward again" "depa-2.0.0 depb-2.0.0 " "$(installed a)"
  client b
  P b update -f >"$T/o" 2>&1
  say add -f "$B/depa-1.0.0.pkg" "(nothing installed)"; P b add -f "$B/depa-1.0.0.pkg" >"$T/o" 2>&1; rc=$?; grep -i 'missing dep' "$T/o"
  [ "$rc" -ne 0 ] && ok "add of depa first: refused, the dependency is not fetched" || bad "add of depa first succeeded"
  eq "nothing was installed by the refused add" "" "$(installed b)"
  P b add "$B/depb-1.0.0.pkg" >"$T/o" 2>&1; P b add "$B/depa-1.0.0.pkg" >"$T/o" 2>&1
  eq "dependencies first works" "depa-1.0.0 depb-1.0.0 " "$(installed b)"
  # a client whose cached catalog names version 1.0.0 after that file has left the site
  if phase v1only; then
    client c; P c update -f >"$T/o" 2>&1
    eq "a client takes the catalog of the site that holds version 1.0.0 only" "depa-1.0.0 depb-1.0.0 " "$(P c rquery -a '%n-%v' | sort | tr '\n' ' ')"
    sleep 2   # a publish happens later than the client's last update: the new catalog has a newer Last-Modified
    phase pruned
    say install -U -y depa "(cached catalog, version 1.0.0 gone from the site)"; P c install -U -y depa >"$T/o" 2>&1; rc=$?; tail -1 "$T/o"
    [ "$rc" -ne 0 ] && grep -q 'Not Found' "$T/o" && ok "-U with the old catalog: Not Found, exit status $rc" || bad "-U with the old catalog did not fail with Not Found"
    eq "nothing is half installed after the failure" "" "$(installed c)"
    P c info -a >"$T/o" 2>&1; eq "the database is usable after the failure" 0 $?
    say install -y depa "(autoupdate on, the site's catalog is newer)"; P c install -y depa >"$T/o" 2>&1; [ -n "$(installed c)" ] || tail -3 "$T/o"
    eq "without -U pkg takes the new catalog by itself and installs" "depa-2.0.0 depb-2.0.0 " "$(installed c)"
    phase full
  fi
  echo; echo "rollback-check: $fails failed"; [ "$fails" -eq 0 ]
  ;;
*) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
