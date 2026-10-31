#!/bin/sh
# new-app.sh NAME [FLAGS...]
#
# Starts a new app of the catalog: runs `jailops app new NAME --dir main/jailops-apps/apps FLAGS...` from the repository
# root, which writes main/jailops-apps/apps/NAME.yaml (a commented starter definition with TODO markers) and a
# placeholder NAME.svg. The flags go to the client as they are, for example:
#
#   sh scripts/new-app.sh memcached --package memcached --service memcached --port 11211/tcp --category database
#
# Needs the jailops client in PATH (no server, no network, no root). CONTRIBUTING.md describes the rest.
set -eu
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: sh scripts/new-app.sh NAME [--package PKG[,PKG...]] [--service NAME] [--port N[/proto]] [--category C] [--force]"
name=$1
shift
# a jail name: ^[a-z][a-z0-9-]{0,62}$ (the file name, the app name and the default jail name)
if ! printf '%s\n' "$name" | grep -Eqx '[a-z][a-z0-9-]{0,62}' || [ "$(printf '%s' "$name" | wc -l)" -ne 0 ]; then
  die "'$name' is not an app name: a lower-case letter, then lower-case letters, digits and dashes, at most 63 characters"
fi

if ! command -v jailops >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: the jailops client is not in PATH; `jailops app new` writes the starter definition.

Install it on FreeBSD 15.1 or later, from this repository (README.md, "Use it", configures it):
  pkg install -r jailops jailops-client

Or build it from the JailOps source: the package ./cmd/jailops, with Go and
CGO_ENABLED=0, into a directory in your PATH (no root needed).

Then run this script again.
EOF
  exit 1
fi

cd "$REPO_ROOT"
exec jailops app new "$name" --dir main/jailops-apps/apps "$@"
