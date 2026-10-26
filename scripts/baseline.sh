#!/bin/sh
# baseline.sh SITE_DIR [SITE_URL]
# baseline.sh --refresh-cache SITE_DIR
#
# Rebuilds the published site in SITE_DIR before anything is added: `pkgops fetch` from the live site (GitHub Pages),
# and from the GitHub Releases archive when the site has no index. prune.yaml is honoured. A deploy replaces the whole
# site, so without this every package that was not rebuilt would disappear.
#
# INCREMENTAL, and the cache cannot change the result. BASELINE_CACHE (default .baseline-cache, the directory the workflow
# restores from the GitHub Actions cache) holds only .pkg files, laid out like the site. They are copied into SITE_DIR
# before `pkgops fetch`, which keeps a file only when its size and sha256 match the freshly fetched index and downloads
# every other one. Afterwards every .pkg in SITE_DIR that the index does not list (a pruned version, an old build, a
# foreign or poisoned file) and every *.part is deleted, and every listed file is verified once more. So the live
# index alone decides what exists; an empty, missing or poisoned cache gives the same site as no cache.
# The cache is not used when BASELINE_FIRST_RUN=1.
#
# --refresh-cache SITE_DIR: replace the cache with the files SITE_DIR's index lists (after the site is final).
#
# A failure stops the run. The ONE exception is the very first publish, when there is nothing to fetch yet:
# BASELINE_FIRST_RUN=1 (the `first_run` input of the workflow) continues with an empty site, loudly.
# Needs PKGOPS_ARCHIVE_REPO (default GITHUB_REPOSITORY) and a token in GITHUB_TOKEN for the archive.
set -eu
. "$(dirname "$0")/lib.sh"

CACHE=${BASELINE_CACHE:-$REPO_ROOT/.baseline-cache}
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"

# listed SITE: the files the index lists, one per line, sorted
listed() { jq -r '.packages[].file' "$1/pkgops-index.json" | sort; }

refresh_cache() {
  [ -f "$1/pkgops-index.json" ] || { warn "baseline cache not refreshed: $1 has no pkgops-index.json"; return 0; }
  rm -rf "$CACHE.new"; mkdir -p "$CACHE.new"
  listed "$1" > "$CACHE.new/.list"
  while IFS= read -r f; do
    [ -f "$1/$f" ] || continue
    mkdir -p "$CACHE.new/$(dirname "$f")"
    cp -p "$1/$f" "$CACHE.new/$f"
  done < "$CACHE.new/.list"
  rm -f "$CACHE.new/.list"
  rm -rf "$CACHE"; mv "$CACHE.new" "$CACHE"
  echo "baseline cache: $(find "$CACHE" -type f -name '*.pkg' | wc -l | tr -d ' ') files in $CACHE"
}

if [ "${1:-}" = --refresh-cache ]; then
  refresh_cache "${2:?usage: baseline.sh --refresh-cache SITE_DIR}"
  exit 0
fi

SITE=${1:?usage: baseline.sh SITE_DIR [SITE_URL]}
URL=${2:-${SITE_URL:-https://pkg.jailops.net}}
export PKGOPS_ARCHIVE_REPO="${PKGOPS_ARCHIVE_REPO:-${GITHUB_REPOSITORY:-jailops/jailops-packages}}"
command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not on PATH"
mkdir -p "$SITE"

# seed: regular .pkg files from the cache only (no symlinks, nothing else); fetch decides whether each one is kept
if [ -d "$CACHE" ] && [ "${BASELINE_FIRST_RUN:-}" != 1 ]; then
  find "$CACHE" -type f -name '*.pkg' > "$SITE/.seed.list"
  while IFS= read -r f; do
    rel=${f#"$CACHE"/}
    case "$rel" in /*|../*|*/../*) continue ;; esac
    mkdir -p "$SITE/$(dirname "$rel")"
    cp "$f" "$SITE/$rel"
  done < "$SITE/.seed.list"
  rm -f "$SITE/.seed.list"
fi

if out=$(pkgops fetch --from "$URL" --into "$SITE" --prune "$REPO_ROOT/prune.yaml" --source auto); then
  echo "$out"
  [ -f "$SITE/pkgops-index.json" ] || die "pkgops fetch succeeded but wrote no pkgops-index.json"
  # the index decides: drop every .pkg it does not list, and partial downloads
  stale=0
  find "$SITE" -type f -name '*.part' -exec rm -f {} +
  listed "$SITE" > "$SITE/.want.list"
  (cd "$SITE" && find . -type f -path '*/All/*.pkg' | sed 's|^\./||' | sort) > "$SITE/.have.list"
  comm -23 "$SITE/.have.list" "$SITE/.want.list" > "$SITE/.stale.list"
  while IFS= read -r f; do
    rm -f "$SITE/$f"; stale=$((stale + 1))
  done < "$SITE/.stale.list"
  rm -f "$SITE/.have.list" "$SITE/.stale.list"
  # every listed file exists with the sha256 of the index
  jq -r '.packages[] | "\(.sha256)  \(.file)"' "$SITE/pkgops-index.json" > "$SITE/.sums.list"
  (cd "$SITE" && sha256sum -c --quiet .sums.list >/dev/null) || die "the baseline in $SITE does not match its index"
  rm -f "$SITE/.sums.list" "$SITE/.want.list"
  dl=$(echo "$out" | sed -n 's/.*: \([0-9]*\) downloaded, \([0-9]*\) already present.*, \([0-9]*\) bytes ->.*/\1/p')
  re=$(echo "$out" | sed -n 's/.*: \([0-9]*\) downloaded, \([0-9]*\) already present.*, \([0-9]*\) bytes ->.*/\2/p')
  by=$(echo "$out" | sed -n 's/.*: \([0-9]*\) downloaded, \([0-9]*\) already present.*, \([0-9]*\) bytes ->.*/\3/p')
  echo "baseline summary: reused ${re:-?}, downloaded ${dl:-?}, removed as stale $stale, bytes downloaded ${by:-?}"
  refresh_cache "$SITE"
elif [ "${BASELINE_FIRST_RUN:-}" = 1 ]; then
  warn "FIRST RUN: no baseline could be fetched from $URL or the archive; starting with an empty site (BASELINE_FIRST_RUN=1)"
else
  die "no baseline from $URL (and no archive). Nothing is published, so no package can vanish. If this is the very first publish, run the workflow by hand with first_run=true."
fi
