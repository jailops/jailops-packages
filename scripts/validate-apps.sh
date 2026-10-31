#!/bin/sh
# validate-apps.sh [DIR]
#
# Checks the application catalog (default main/jailops-apps/apps) with `jailops app validate DIR`: the daemon's own
# parser and validator, run offline by the client (no server, no root). Run by build-and-publish.yml before jailops-apps
# is built, and by hand. Exit 1 when a definition is invalid; every problem is printed as FILE: reason.
#
# The client is built from the source of the jailops package at the version this repository packages
# (main/jailops/pkgops.yaml), fetched and sha256-verified by scripts/fetch-source.sh like for its own build (with the
# token of main/jailops/upstream.yaml when it names one), so a definition must be valid for the daemon hosts run.
# JAILOPS=/path/to/jailops uses that client instead (local work).
#
# ONE tolerated case: a client without `app validate` (JailOps 0.3.1 and older). Then the check is skipped with a loud
# warning and exit 0, and it enforces itself from the first jailops version in main/jailops/pkgops.yaml that has the
# command. Anything else (no source, a failed build, an invalid definition) fails.
set -eu
. "$(dirname "$0")/lib.sh"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

dir=${1:-$MAIN/jailops-apps/apps}
[ -d "$dir" ] || die "no catalog directory: $dir"
work=$(mktemp -d "${TMPDIR:-/tmp}/validate-apps.XXXXXX")
trap 'rm -rf "$work"' EXIT

bin=${JAILOPS:-}
version=$(base_version "$(mf_get jailops version)")
client="the jailops client $version"
if [ -n "$bin" ]; then
  note "using JAILOPS=$bin (not built from the packaged jailops $version)"
  client="the jailops client $bin"
else
  pkg_ready jailops || die "jailops: $REASON"
  sh "$REPO_ROOT/scripts/fetch-source.sh" jailops
  note "building the jailops client $version"
  (cd "$MAIN/jailops/src" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$work/jailops" ./cmd/jailops)
  bin=$work/jailops
fi

# the subcommands of `jailops app`, from cobra's completion (independent of the help layout)
if ! "$bin" __complete app "" 2>/dev/null | cut -f1 | grep -qx validate; then
  msg="$client has no 'jailops app validate': the catalog in $dir was NOT validated. The check starts by itself once main/jailops/pkgops.yaml packages a JailOps release that has the command."
  warn "$msg"
  {
    echo "################################################################################"
    echo "## NOT VALIDATED: $msg"
    echo "################################################################################"
  } >&2
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '**Catalog NOT validated:** %s\n' "$msg" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

note "jailops app validate $dir ($client)"
"$bin" app validate "$dir" || die "the catalog in $dir has invalid definitions (listed above)"
