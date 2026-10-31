#!/bin/sh
# Offline tests of scripts/new-app.sh: the name is checked, a missing client is explained, and the client is called
# from the repository root with the catalog directory and the flags as they were given.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-new-app.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }

# a PATH with the tools the script needs and no jailops
mkdir -p "$T/bin" "$T/stub"
for t in sh grep wc printf cat dirname pwd; do
  p=$(command -v "$t" 2>/dev/null) && case $p in /*) ln -s "$p" "$T/bin/$t" ;; esac
done

for n in Memcached 1cache -cache "a b" "x;id" "" "$(printf 'a%.0s' $(seq 64))"; do
  eq "name '$n' is refused" 1 "$(PATH="$T/bin" sh "$HERE/scripts/new-app.sh" "$n" >"$T/out" 2>"$T/err"; echo $?)"
  has "name '$n': the reason is given" "is not an app name" "$T/err"
done
eq "no name: usage" 1 "$(PATH="$T/bin" sh "$HERE/scripts/new-app.sh" >"$T/out" 2>"$T/err"; echo $?)"
has "no name: usage line" "usage: sh scripts/new-app.sh NAME" "$T/err"

eq "no client: exit 1" 1 "$(PATH="$T/bin" sh "$HERE/scripts/new-app.sh" memcached >"$T/out" 2>"$T/err"; echo $?)"
has "no client: says how to install it" "pkg install -r jailops jailops-client" "$T/err"
has "no client: or build it" "./cmd/jailops" "$T/err"

# a stub client that records where it ran and what it was given
cat >"$T/stub/jailops" <<EOF
#!/bin/sh
pwd > "$T/cwd"
printf '%s\n' "\$@" > "$T/args"
EOF
chmod +x "$T/stub/jailops"
eq "with a client: exit 0" 0 "$(cd "$T" && PATH="$T/stub:$T/bin" sh "$HERE/scripts/new-app.sh" memcached --package memcached --port 11211/tcp --category database >"$T/out" 2>"$T/err"; echo $?)"
eq "the client runs in the repository root" "$HERE" "$(cat "$T/cwd")"
eq "the client gets the catalog directory and the flags" "app new memcached --dir main/jailops-apps/apps --package memcached --port 11211/tcp --category database" "$(tr '\n' ' ' <"$T/args" | sed 's/ $//')"
eq "a 63-character name is accepted" 0 "$(PATH="$T/stub:$T/bin" sh "$HERE/scripts/new-app.sh" "a$(printf 'b%.0s' $(seq 62))" >"$T/out" 2>"$T/err"; echo $?)"

[ "$fails" = 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "test-new-app: all passed"
