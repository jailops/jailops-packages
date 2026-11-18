#!/bin/sh
# check-site-size.sh SITE_DIR [LIMIT_MB]
#
# The publish job's last stop before the site is archived and uploaded: GitHub Pages publishes at most about 1 GB, and a
# missed prune must never reach the deploy. The sum of the file sizes of SITE_DIR must stay below LIMIT_MB (default 900,
# or SITE_LIMIT_MB); otherwise the job fails here with the sizes of the largest packages. From seven ninths of the limit
# (700 MB for 900) it warns. Prints the size either way.
set -eu
. "$(dirname "$0")/lib.sh"
SITE=${1:?usage: check-site-size.sh SITE_DIR [LIMIT_MB]}
LIMIT=${2:-${SITE_LIMIT_MB:-900}}
case "$LIMIT" in ''|*[!0-9]*) die "LIMIT_MB must be a number (got '$LIMIT')" ;; esac
[ -d "$SITE" ] || die "$SITE is not a directory"
bytes=$(find "$SITE" -type f -printf '%s\n' | awk '{t += $1} END {print t + 0}')
mb=$((bytes / 1000000))
echo "site size: $mb MB (limit $LIMIT MB; GitHub Pages publishes at most about 1 GB)"
if [ "$mb" -ge $((LIMIT * 7 / 9)) ] && [ "$mb" -lt "$LIMIT" ]; then
  echo "::warning title=The site is getting big::$mb MB; the publish stops at $LIMIT MB. Two versions of every package are kept (docs/RETENTION.md)."
fi
if [ "$mb" -ge "$LIMIT" ]; then
  echo "::error title=The site is too big::$mb MB is not below $LIMIT MB. Nothing is archived or deployed. The retention policy (docs/RETENTION.md) keeps only the newest two versions of every package: look at the packages below."
  find "$SITE" -type f -name '*.pkg' -printf '%s %p\n' | sort -rn | head -n 10 >&2
  exit 1
fi
