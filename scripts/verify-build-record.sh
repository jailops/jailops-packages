#!/bin/sh
# verify-build-record.sh DIST_DIR
#
# Checks the packages in DIST_DIR against the build records (DIST_DIR/records/*.json, scripts/build-pkg.sh) before
# anything is signed: every record is of this schema and of the commit in EXPECT_COMMIT (when set); every recorded
# package is the version of its manifest, for an ABI of its manifest, and its file exists with the recorded size and
# sha256; every .pkg in DIST_DIR/<ABI>/ is recorded. A file nobody built, or one that changed on its way from the
# build to here, stops the run. With no .pkg and no record there is nothing to check and nothing to sign but the baseline.
set -eu
. "$(dirname "$0")/lib.sh"
DIST=${1:?usage: verify-build-record.sh DIST_DIR}
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"
bad=0
fail() { echo "BUILD RECORD: $*" >&2; bad=1; }

recs=$(find "$DIST/records" -maxdepth 1 -name '*.json' 2>/dev/null | sort || true)
pkgs=$(cd "$DIST" 2>/dev/null && find . -mindepth 2 -maxdepth 2 -name '*.pkg' 2>/dev/null | sed 's|^\./||' | sort || true)
if [ -z "$recs" ]; then
  [ -z "$pkgs" ] || die "BUILD RECORD: $DIST holds packages but no record (dist/records/*.json)"
  echo "verify-build-record: nothing was built" >&2; exit 0
fi

listed=$(mktemp "${TMPDIR:-/tmp}/build-record.XXXXXX"); rows=$(mktemp "${TMPDIR:-/tmp}/build-record.XXXXXX")
trap 'rm -f "$listed" "$rows"' EXIT
for r in $recs; do
  [ "$(jq -r '.schema' "$r")" = 1 ] || fail "$r: schema is not 1"
  if [ -n "${EXPECT_COMMIT:-}" ] && [ "$(jq -r '.commit' "$r")" != "$EXPECT_COMMIT" ]; then
    fail "$r: built from $(jq -r '.commit' "$r"), this run is $EXPECT_COMMIT"
  fi
  jq -r '.packages[] | [.name, .version, .abi, .file, (.size|tostring), .sha256] | @tsv' "$r" > "$rows"
  while IFS="$(printf '\t')" read -r name version abi file size sha; do
    echo "$file" >> "$listed"
    [ -f "$MAIN/$name/pkgops.yaml" ] || { fail "$r: $name is not a package of main/"; continue; }
    [ "$(mf_get "$name" version)" = "$version" ] || fail "$r: $name is recorded at $version, main/$name is at $(mf_get "$name" version)"
    abis_of "$name" | grep -qx "$abi" || fail "$r: $abi is not an ABI of $name"
    [ -f "$DIST/$file" ] || { fail "$r: $file is recorded and missing"; continue; }
    [ "$(wc -c < "$DIST/$file" | tr -d ' ')" = "$size" ] || fail "$file: the size is not the recorded $size"
    [ "$(sha256_of "$DIST/$file")" = "$sha" ] || fail "$file: the sha256 is not the recorded $sha"
  done < "$rows"
done
for f in $pkgs; do
  grep -qxF "$f" "$listed" || fail "$f is in $DIST and in no build record"
done
[ "$bad" = 0 ] && echo "verify-build-record: $(echo "$pkgs" | wc -w | tr -d ' ') packages match their records" >&2
exit $bad
