#!/bin/sh
# site-files.sh SITE_DIR KEY_FILE
#
# Adds the non-package files of the site, all derived from the signing key on every run (nothing is committed):
#   jailops.pub          the public key, PEM
#   jailops.fingerprint  the file for pkg's "fingerprints" mode (`pkgops key fingerprint`)
#   index.html           static/index.html
#   CNAME                the custom domain (default pkg.jailops.net; $PAGES_CNAME)
#   .nojekyll
# Refuses to go on if the key is not the one whose fingerprint is committed in KEY_FINGERPRINT, so a wrong secret
# can never replace the public key clients trust.
set -eu
. "$(dirname "$0")/lib.sh"
SITE=${1:?usage: site-files.sh SITE_DIR KEY_FILE}; KEY=${2:?usage: site-files.sh SITE_DIR KEY_FILE}
[ -s "$KEY" ] || die "the signing key is empty: set the PKG_REPO_KEY secret of the 'signing' environment (scripts/keygen.sh)"
mkdir -p "$SITE"
pkgops key public --key "$KEY" > "$SITE/jailops.pub"
pkgops key fingerprint "$SITE/jailops.pub" > "$SITE/jailops.fingerprint"
have=$(sed -n 's/^fingerprint:[[:space:]]*"\{0,1\}\([0-9a-f]\{64\}\).*/\1/p' "$SITE/jailops.fingerprint")
want=$(tr -d ' \n\r' < "$REPO_ROOT/KEY_FINGERPRINT" 2>/dev/null || true)
is_sha256 "$want" || die "KEY_FINGERPRINT is missing or not a sha256: run scripts/keygen.sh and commit the file it writes"
[ "$have" = "$want" ] || die "the signing key's fingerprint is $have but KEY_FINGERPRINT says $want: wrong PKG_REPO_KEY secret?"
cp "$REPO_ROOT/static/index.html" "$SITE/index.html"
echo "${PAGES_CNAME:-pkg.jailops.net}" > "$SITE/CNAME"
: > "$SITE/.nojekyll"
echo "site files written; key fingerprint $have"
