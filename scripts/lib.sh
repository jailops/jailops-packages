# Shared helpers, sourced by the other scripts (not run by itself). POSIX sh.
# REPO_ROOT may be set to run against another checkout (the tests do).

: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
MAIN="$REPO_ROOT/main"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "$*" >&2; }
# a GitHub Actions annotation when running there, plain text otherwise
warn() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$*"; else echo "warning: $*" >&2; fi; }

# yget KEY [FILE]: the value of a top-level "KEY: value" line (stdin without FILE). Trailing " # comment",
# surrounding quotes and spaces are removed. The manifest and upstream.yaml are flat enough for this.
yget() {
  sed -n "s/^$1:[[:space:]]*//p" "${2:--}" | head -n 1 |
    sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

pkg_dir() { echo "$MAIN/$1"; }
mf_get() { yget "$2" "$MAIN/$1/pkgops.yaml"; }
up_get() { yget "$2" "$MAIN/$1/upstream.yaml"; }

all_pkgs() {
  for d in "$MAIN"/*/; do
    [ -f "${d}pkgops.yaml" ] && basename "$d"
  done
}

# 0.8.1_2 -> 0.8.1 : the upstream version, without the packaging revision
base_version() { echo "${1%_[0-9]*}"; }

# SRC override variable of a package: age-plugin-sshagent -> SRC_AGE_PLUGIN_SSHAGENT
src_var() { echo "SRC_$(echo "$1" | tr 'a-z-' 'A-Z_')"; }
src_override() { eval "echo \"\${$(src_var "$1"):-}\""; }

is_sha256() { echo "$1" | grep -Eq '^[0-9a-f]{64}$'; }

# is_local PKG: the package's source is its own directory (upstream.yaml says source: local): no tarball, no sha256,
# no upstream release; its version is the one in pkgops.yaml, raised by hand
is_local() { [ "$(up_get "$1" source)" = local ]; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256 -q "$1"; fi
}

# tarball_url PKG: upstream tarball URL for the manifest's version
tarball_url() {
  _v=$(base_version "$(mf_get "$1" version)")
  _t="$(up_get "$1" tag_prefix)$_v"
  _r=$(up_get "$1" repo)
  up_get "$1" tarball | sed -e "s|\${repo}|$_r|g" -e "s|\${tag}|$_t|g" -e "s|\${version}|$_v|g"
}

# pkg_ready PKG: 0 when the package can be built now. Otherwise 1 with the reason in $REASON.
pkg_ready() {
  REASON=
  is_local "$1" && return 0
  [ -n "$(src_override "$1")" ] && return 0
  _s=$(up_get "$1" sha256)
  if ! is_sha256 "$_s"; then
    REASON="sha256 in main/$1/upstream.yaml is '$_s': pin it with scripts/bump-version.sh --pin $1 once the tag exists"
    return 1
  fi
  _e=$(up_get "$1" token_env)
  if [ -n "$_e" ] && [ -z "$(eval "echo \"\${$_e:-}\"")" ]; then
    REASON="the source needs a token in \$$_e (secret $_e), which is not set; empty token_env in upstream.yaml when the repository is public"
    return 1
  fi
  return 0
}

# group_of PKG, group_members GROUP
group_of() { _g=$(up_get "$1" group); echo "${_g:-$1}"; }
group_members() {
  for _p in $(all_pkgs); do
    [ "$(group_of "$_p")" = "$1" ] && echo "$_p"
  done
}

# index_has SITE NAME VERSION ABI: is the version listed in SITE/pkgops-index.json?
index_has() {
  [ -f "$1/pkgops-index.json" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg n "$2" --arg v "$3" --arg a "$4" '.packages[]? | select(.name==$n and .version==$v and .abi==$a)' "$1/pkgops-index.json" >/dev/null 2>&1
  else
    python3 - "$1/pkgops-index.json" "$2" "$3" "$4" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(p.get("name") == sys.argv[2] and p.get("version") == sys.argv[3] and p.get("abi") == sys.argv[4] for p in d.get("packages", [])) else 1)
PY
  fi
}

# abis_of PKG: the ABIs of the manifest, one per line
abis_of() {
  sed -n 's/^abis:[[:space:]]*\[\(.*\)\].*/\1/p' "$MAIN/$1/pkgops.yaml" | tr ',' '\n' | sed 's/[[:space:]]//g'
}
