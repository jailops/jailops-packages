#!/bin/sh
# build-pkg.sh PKG[:ABI,ABI]...
#
# For each package: fetch the source (nothing for source: local), run the prebuild steps, then
# `pkgops build -f main/PKG/pkgops.yaml --abi ABIS -o dist` (ABIS: the ones after the colon, else all).
# Output: dist/<ABI>/<name>-<version>.pkg, a list of what was built in dist/built.txt, and the build record
# dist/records/$BUILD_LABEL.json (BUILD_LABEL, default build): the commit, the toolchain and the name, version, ABI,
# size and sha256 of every package built, with the sha256 of its source. scripts/verify-build-record.sh checks the
# record against the files before anything is signed.
#
# A package whose source is not ready (sha256 still PENDING, token missing) is SKIPPED with a warning, together with
# the other packages of its group (jailops needs the same-version jailops-client). BUILD_STRICT=1 turns a skip into a failure.
# SOURCE_DATE_EPOCH is the commit time of the package directory, so the same inputs give the same bytes on a re-run
# and `pkgops archive push` never sees two different files for one version.
set -eu
. "$(dirname "$0")/lib.sh"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

[ $# -ge 1 ] || die "usage: build-pkg.sh PKG[:ABI,ABI]..."
OUT="${DIST_DIR:-$REPO_ROOT/dist}"
command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH (see .github/actions/setup-pkgops)"
mkdir -p "$OUT/records"; : > "$OUT/built.txt"
LABEL=${BUILD_LABEL:-build}
rec="$OUT/records/$LABEL.parts"; : > "$rec"

skip=" "
for entry in "$@"; do
  pkg=${entry%%:*}
  [ -f "$MAIN/$pkg/pkgops.yaml" ] || die "no such package: $pkg"
  for member in $(group_members "$(group_of "$pkg")"); do
    if ! pkg_ready "$member"; then
      [ "${BUILD_STRICT:-}" != 1 ] || die "$member: $REASON"
      warn "skipping the group of $pkg: $member is not ready: $REASON"
      skip="$skip$(group_members "$(group_of "$pkg")" | tr '\n' ' ')"
      break
    fi
  done
done

for entry in "$@"; do
  pkg=${entry%%:*}
  case "$entry" in *:*) abis=${entry#*:} ;; *) abis=all ;; esac
  case "$skip" in *" $pkg "*) echo "$pkg: skipped"; continue ;; esac
  if [ "$abis" != all ]; then
    for a in $(echo "$abis" | tr ',' ' '); do
      abis_of "$pkg" | grep -qx "$a" || die "$pkg: $a is not an ABI of main/$pkg/pkgops.yaml"
    done
  fi
  note "== $pkg $(mf_get "$pkg" version) ($abis)"
  sh "$REPO_ROOT/scripts/fetch-source.sh" "$pkg"
  # the source token has done its job: npm, go and the build run without it
  env -u JAILOPS_SOURCE_TOKEN sh "$REPO_ROOT/scripts/prebuild.sh" "$pkg"
  if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct -- "main/$pkg" 2>/dev/null || true)
  else epoch=$SOURCE_DATE_EPOCH; fi
  [ -n "$epoch" ] || die "$pkg: no commit time for main/$pkg (not a git checkout?): set SOURCE_DATE_EPOCH"
  SOURCE_DATE_EPOCH=$epoch env -u JAILOPS_SOURCE_TOKEN pkgops build -f "$MAIN/$pkg/pkgops.yaml" --abi "$abis" -o "$OUT"
  echo "$pkg $(mf_get "$pkg" version)" >> "$OUT/built.txt"
  [ "$abis" != all ] || abis=$(abis_of "$pkg" | tr '\n' ',' | sed 's/,$//')
  ver=$(mf_get "$pkg" version)
  for a in $(echo "$abis" | tr ',' ' '); do
    f="$a/$pkg-$ver.pkg"
    [ -f "$OUT/$f" ] || die "$pkg: pkgops build made no $OUT/$f"
    if is_local "$pkg"; then src=$(printf '{"local":"%s"}' "$(git -C "$REPO_ROOT" rev-parse "HEAD:main/$pkg" 2>/dev/null || echo unknown)")
    else src=$(printf '{"url":"%s","sha256":"%s"}' "$(tarball_url "$pkg")" "$(up_get "$pkg" sha256)"); fi
    printf '{"name":"%s","version":"%s","abi":"%s","file":"%s","size":%s,"sha256":"%s","source":%s}\n' \
      "$pkg" "$ver" "$a" "$f" "$(wc -c < "$OUT/$f" | tr -d ' ')" "$(sha256_of "$OUT/$f")" "$src" >> "$rec"
  done
done
echo "built:" >&2; cat "$OUT/built.txt" >&2

# the build record: one JSON file next to the packages
tool() { "$@" 2>/dev/null | head -n 1 || true; }
jq -n --slurpfile pk "$rec" --arg commit "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
  --arg go "$(tool go version)" --arg node "$(tool node --version)" --arg npm "$(tool npm --version)" \
  --arg pkgops "$(tool pkgops version)" \
  '{schema: 1, commit: $commit, toolchain: {go: $go, node: $node, npm: $npm, pkgops: $pkgops}, packages: $pk}' \
  > "$OUT/records/$LABEL.json"
rm -f "$rec"
echo "build record: $OUT/records/$LABEL.json" >&2
