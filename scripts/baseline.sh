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
# VERIFIED against the signing key. The index is not signed, and the publish job signs new catalogs over this baseline,
# so before anything is fetched the site's public key (SITE_URL/jailops.pub) is downloaded and accepted only when its
# sha256 is the one committed in KEY_FINGERPRINT; `pkgops fetch --pubkey` then verifies the site's signed catalogs with it
# and refuses an index that does not match them (a changed package and hash, an entry the catalog does not advertise).
# A site without that key has no signed state to take: only the archive is used then. BASELINE_KEY_FINGERPRINT
# overrides KEY_FINGERPRINT for one run (key rotation: the old key's fingerprint). A pkgops without `fetch --pubkey` is
# refused, unless BASELINE_UNVERIFIED_OK=1 (the build job, which signs nothing): then it says NOT VERIFIED and goes on.
# Limits (older versions carry no signature, no rollback serial): docs/BASELINE-CACHE.md.
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

# the trusted key: the site's copy, accepted only with the committed fingerprint
KT=$(mktemp -d "${TMPDIR:-/tmp}/baseline-key.XXXXXX"); trap 'rm -rf "$KT"' EXIT
from=$URL; source=auto
set --
if pkgops fetch -h 2>&1 | grep -q -- '-pubkey'; then
  command -v curl >/dev/null 2>&1 || die "curl is not on PATH"
  want=${BASELINE_KEY_FINGERPRINT:-$(tr -d ' \n\r' < "$REPO_ROOT/KEY_FINGERPRINT" 2>/dev/null || true)}
  is_sha256 "$want" || die "KEY_FINGERPRINT is missing or not a sha256: the baseline cannot be verified (scripts/keygen.sh)"
  code=$(curl -sS --max-time 60 --max-filesize 65536 -o "$KT/key.pub" -w '%{http_code}' "$URL/jailops.pub" 2>"$KT/err") || code=error
  case "$code" in
    200)
      have=$(sha256_of "$KT/key.pub")
      [ "$have" = "$want" ] || die "$URL/jailops.pub has sha256 $have, but KEY_FINGERPRINT says $want: the site is not signed with our key, or the key was replaced. Nothing was fetched or published."
      set -- --pubkey "$KT/key.pub" --pubkey-sha256 "$want"
      echo "baseline: verifying the published catalogs with the key $want (KEY_FINGERPRINT)"
      ;;
    404)
      # no key, so no signed state to take: the archive only (or nothing on a first run)
      warn "no public key at $URL/jailops.pub: the published site is not used as a baseline, only the archive"
      from="github-releases:$PKGOPS_ARCHIVE_REPO"; source=releases
      ;;
    *)
      [ "${BASELINE_FIRST_RUN:-}" = 1 ] || die "cannot read $URL/jailops.pub (HTTP $code: $(cat "$KT/err" 2>/dev/null)): no baseline from $URL. Nothing is published."
      warn "FIRST RUN: $URL/jailops.pub cannot be read (HTTP $code); trying the archive only"
      from="github-releases:$PKGOPS_ARCHIVE_REPO"; source=releases
      ;;
  esac
elif [ "${BASELINE_UNVERIFIED_OK:-}" = 1 ]; then
  warn "NOT VERIFIED: this pkgops has no 'fetch --pubkey', so the baseline is checked against the unsigned index only. Allowed here (BASELINE_UNVERIFIED_OK=1, nothing is signed); the publish job refuses it. Raise PKGOPS_VERSION."
else
  die "this pkgops cannot verify the published baseline against the signing key (no 'fetch --pubkey'): raise PKGOPS_VERSION to a release that has it. Nothing is signed over an unverified baseline."
fi

if out=$(pkgops fetch --from "$from" --into "$SITE" --prune "$REPO_ROOT/prune.yaml" --source "$source" "$@"); then
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
