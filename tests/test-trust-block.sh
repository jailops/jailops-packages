#!/bin/sh
# Offline test of the trust block of README.md ("Use it"), run with stubs for fetch, sha256 and pkg and the paths moved
# under a temp directory: the right key goes into place and the repository is configured and installed from; the wrong
# key changes nothing at all, not even when the repository was configured before; and the fingerprint in the block is
# the one committed in KEY_FINGERPRINT.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-trust-block.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { if grep -q -F -e "$2" "$3"; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }

# the block: from `sh -eu <<'JAILOPS_TRUST'` to the line JAILOPS_TRUST
awk '/^sh -eu <<.JAILOPS_TRUST. / {on=1} on {print} on && /^JAILOPS_TRUST$/ {exit}' "$HERE/README.md" > "$T/block"
[ -s "$T/block" ] || { echo "FAIL no trust block in README.md"; exit 1; }
sed -n 's/^FINGERPRINT=//p' "$T/block" > "$T/fp"
eq "the block has one fingerprint constant" 1 "$(wc -l < "$T/fp" | tr -d ' ')"
eq "the fingerprint of the block is KEY_FINGERPRINT" "$(tr -d ' \n' < "$HERE/KEY_FINGERPRINT")" "$(tr -d ' \n' < "$T/fp")"
has "the first line installs from the jailops repository only after the block" "&& pkg install -r jailops jailops" "$T/block"

# stubs: fetch copies the key the test serves, sha256 -q hashes a file, pkg logs its arguments
mkdir -p "$T/bin"
cat > "$T/bin/fetch" <<'STUB'
#!/bin/sh
out=; while [ $# -gt 0 ]; do case $1 in -qo) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$SERVED_KEY" "$out"
STUB
cat > "$T/bin/sha256" <<'STUB'
#!/bin/sh
[ "$1" = -q ] && shift
sha256sum "$1" | cut -d' ' -f1
STUB
cat > "$T/bin/pkg" <<'STUB'
#!/bin/sh
echo "pkg $*" >> "$PKG_LOG"
STUB
chmod +x "$T/bin/fetch" "$T/bin/sha256" "$T/bin/pkg"

printf 'the public key of the repository\n' > "$T/good.pub"
GOOD=$(sha256sum "$T/good.pub" | cut -d' ' -f1)
printf 'a key somebody else made\n' > "$T/evil.pub"

# the block with this host's paths under $T and the fingerprint of the key the test serves
run() { # run KEYFILE FINGERPRINT: the block's script (the heredoc body) with the test's paths
  sed -e '1d' -e '$d' "$T/block" |
    sed -e "s|/usr/local/etc/pkg|$T/etc|g" -e "s|^FINGERPRINT=.*|FINGERPRINT=$2|" > "$T/script"
  : > "$T/pkg.log"
  SERVED_KEY=$1 PKG_LOG=$T/pkg.log PATH="$T/bin:$PATH" sh -eu "$T/script" > "$T/out" 2>&1
}

rm -rf "$T/etc"
run "$T/good.pub" "$GOOD"; eq "the right key: exit 0" 0 $?
eq "the key is in place" "$(cat "$T/good.pub")" "$(cat "$T/etc/keys/jailops.pub")"
has "the repository is configured" 'url: "https://pkg.jailops.net/${ABI}/latest"' "$T/etc/repos/jailops.conf"
has "it points at that key" "pubkey: \"$T/etc/keys/jailops.pub\"" "$T/etc/repos/jailops.conf"
eq "the catalog of that repository is updated" "pkg update -r jailops" "$(cat "$T/pkg.log")"

# a wrong key on a host that is already set up: nothing changes
run "$T/evil.pub" "$GOOD"; eq "another key: exit 1" 1 $?
has "it says nothing was changed" "nothing was changed" "$T/out"
eq "the key in place is still the right one" "$(cat "$T/good.pub")" "$(cat "$T/etc/keys/jailops.pub")"
eq "no pkg command ran" "" "$(cat "$T/pkg.log")"

# a wrong key on a fresh host: no key, no configuration
rm -rf "$T/etc"
run "$T/evil.pub" "$GOOD"; eq "another key on a fresh host: exit 1" 1 $?
eq "nothing was created" "" "$(ls "$T/etc" 2>/dev/null)"
eq "no temporary files are left" "" "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'jailops-trust.*' 2>/dev/null)"

[ "$fails" = 0 ] && echo "test-trust-block: all ok" || { echo "test-trust-block: $fails FAILED"; exit 1; }
