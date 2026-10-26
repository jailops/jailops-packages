#!/bin/sh
# baseline.sh SITE_DIR [SITE_URL]
#
# Rebuilds the published site in SITE_DIR before anything is added: `pkgops fetch` from the live site (GitHub Pages),
# and from the GitHub Releases archive when the site has no index. prune.yaml is honoured. A deploy replaces the whole
# site, so without this every package that was not rebuilt would disappear.
#
# A failure stops the run. The ONE exception is the very first publish, when there is nothing to fetch yet:
# BASELINE_FIRST_RUN=1 (the `first_run` input of the workflow) continues with an empty site, loudly.
# Needs PKGOPS_ARCHIVE_REPO (default GITHUB_REPOSITORY) and a token in GITHUB_TOKEN for the archive.
set -eu
. "$(dirname "$0")/lib.sh"

SITE=${1:?usage: baseline.sh SITE_DIR [SITE_URL]}
URL=${2:-${SITE_URL:-https://pkg.jailops.net}}
export PKGOPS_ARCHIVE_REPO="${PKGOPS_ARCHIVE_REPO:-${GITHUB_REPOSITORY:-jailops/jailops-packages}}"
command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH"
mkdir -p "$SITE"

if pkgops fetch --from "$URL" --into "$SITE" --prune "$REPO_ROOT/prune.yaml" --source auto; then
  echo "baseline: $(ls "$SITE") from $URL"
elif [ "${BASELINE_FIRST_RUN:-}" = 1 ]; then
  warn "FIRST RUN: no baseline could be fetched from $URL or the archive; starting with an empty site (BASELINE_FIRST_RUN=1)"
else
  die "no baseline from $URL (and no archive). Nothing is published, so no package can vanish. If this is the very first publish, run the workflow by hand with first_run=true."
fi
