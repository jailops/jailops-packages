#!/bin/sh
# fetch-source.sh [--print-sha] PKG...
#
# Puts the source of each package's current version into main/PKG/src/ (gitignored, replaced each time):
# the upstream tarball named by main/PKG/upstream.yaml, verified against its sha256, OR a local copy when
# SRC_<PKG>=/path is set (SRC_AGE_PLUGIN_SSHAGENT for age-plugin-sshagent). Never both: an override replaces the
# download completely, is announced loudly, is not verified, and is refused inside GitHub Actions.
# A package with `source: local` in upstream.yaml is built from its own directory: nothing is fetched, src/ is not made.
#
# --print-sha downloads the tarball only and prints its sha256 (used by bump-version.sh).
set -eu
. "$(dirname "$0")/lib.sh"

PRINT_SHA=
[ "${1:-}" = "--print-sha" ] && { PRINT_SHA=1; shift; }
[ $# -ge 1 ] || die "usage: fetch-source.sh [--print-sha] PKG..."

download() { # download PKG DEST
  url=$(tarball_url "$1")
  token_env=$(up_get "$1" token_env)
  token=; [ -n "$token_env" ] && token=$(eval "echo \"\${$token_env:-}\"")
  note "$1: downloading $url"
  if [ -n "$token" ]; then
    # a token is only ever sent to GitHub, whatever upstream.yaml says (a changed url must not leak it)
    case "$url" in
      https://github.com/*|https://api.github.com/*) ;;
      *) die "$1: refusing to send a token to $url: tokens go only to https://github.com/ or https://api.github.com/" ;;
    esac
    # the header is not forwarded to the other host the redirect goes to
    curl -fsSL --retry 3 --retry-delay 2 -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" -o "$2" "$url"
  else
    curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$url"
  fi
}

for pkg in "$@"; do
  [ -f "$MAIN/$pkg/pkgops.yaml" ] || die "no such package: $pkg"
  override=$(src_override "$pkg")
  if is_local "$pkg"; then
    [ -z "$PRINT_SHA" ] || die "$pkg: source: local, there is no tarball and no sha256"
    [ -z "$override" ] || die "$pkg: source: local, it is built from main/$pkg itself; unset $(src_var "$pkg")"
    note "$pkg: local source (main/$pkg), nothing to fetch"
    continue
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fetch-source.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT

  if [ -n "$PRINT_SHA" ]; then
    [ -z "$override" ] || die "$pkg: $(src_var "$pkg") is set; --print-sha is about the real tarball"
    download "$pkg" "$tmp/src.tgz"
    sha256_of "$tmp/src.tgz"
    continue
  fi

  dest="$MAIN/$pkg/src"
  rm -rf "$dest"; mkdir -p "$dest"
  if [ -n "$override" ]; then
    [ "${GITHUB_ACTIONS:-}" != true ] || die "$pkg: $(src_var "$pkg") is set inside GitHub Actions; local overrides are for development only"
    [ -d "$override" ] || die "$pkg: $(src_var "$pkg")=$override is not a directory"
    note "$pkg: LOCAL SOURCE $override (NOT the tarball, NOT verified, whatever is in that directory)"
    (cd "$override" && tar cf - --exclude=./.git --exclude=./temp --exclude=./bin .) | tar xf - -C "$dest"
  else
    pkg_ready "$pkg" || die "$pkg: $REASON"
    download "$pkg" "$tmp/src.tgz"
    want=$(up_get "$pkg" sha256); got=$(sha256_of "$tmp/src.tgz")
    [ "$want" = "$got" ] || die "$pkg: sha256 mismatch for $(tarball_url "$pkg"): upstream.yaml says $want, the download is $got"
    note "$pkg: sha256 verified ($got)"
    tar xzf "$tmp/src.tgz" -C "$dest" --strip-components="$(up_get "$pkg" strip_components)"
  fi
  rm -rf "$tmp"; trap - EXIT
done
