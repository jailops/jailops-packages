#!/bin/sh
# keygen.sh [DIR]
#
# YOU run this, once, on your own machine. It makes the repository signing key with `pkgops key generate`
# (RSA 4096, the kind pkg verifies), puts it in DIR (default ~/.config/jailops-packages, mode 0700; never in this repository),
# and writes the PUBLIC fingerprint into ./KEY_FINGERPRINT (commit that) and into README.md's placeholder.
# It never prints the private key and never uploads anything.
#
# Then, by hand (the commands are printed at the end):
#   1. back the private key up somewhere durable: losing it means every client has to trust a new key
#   2. store it as the secret PKG_REPO_KEY of the GitHub Environment `signing`
#   3. commit KEY_FINGERPRINT (and the README change)
set -eu
. "$(dirname "$0")/lib.sh"
command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH (go install jailops.net/pkgops/cmd/pkgops@v0.1.0, or a release binary)"
DIR=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/jailops-packages}
umask 077
mkdir -p "$DIR"; chmod 700 "$DIR"
KEY="$DIR/jailops-repo.key"
[ ! -e "$KEY" ] || die "$KEY already exists: refusing to overwrite a signing key"
pkgops key generate --out "$KEY" --bits 4096 >/dev/null
chmod 600 "$KEY"
PUB="$DIR/jailops-repo.pub"
fp=$(pkgops key fingerprint "$PUB" | sed -n 's/^fingerprint:[[:space:]]*"\{0,1\}\([0-9a-f]\{64\}\).*/\1/p')
is_sha256 "$fp" || die "could not read the fingerprint"
echo "$fp" > "$REPO_ROOT/KEY_FINGERPRINT"
if grep -q 'FINGERPRINT-PENDING' "$REPO_ROOT/README.md" 2>/dev/null; then
  sed "s/FINGERPRINT-PENDING/$fp/g" "$REPO_ROOT/README.md" > "$REPO_ROOT/README.md.new" && mv "$REPO_ROOT/README.md.new" "$REPO_ROOT/README.md"
fi
cat <<MSG
private key (keep it secret): $KEY
public key (not secret):        $PUB
fingerprint (sha256 of the PEM): $fp
written: $REPO_ROOT/KEY_FINGERPRINT (and the placeholder in README.md)

Next, yourself:
  1. back up $KEY
  2. gh secret set PKG_REPO_KEY --env signing --repo jailops/jailops-packages < $KEY
     (create the environment first: Settings > Environments > New environment > signing)
  3. git add KEY_FINGERPRINT README.md && git commit -m "Signing key fingerprint"
MSG
