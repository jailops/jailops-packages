#!/bin/sh
# build-pkg.sh PKG...
#
# For each package: fetch the source, run the prebuild steps, then `pkgops build -f main/PKG/pkgops.yaml --abi all -o dist`.
# Output: dist/<ABI>/<name>-<version>.pkg and a list of what was built in dist/built.txt.
#
# A package whose source is not ready (sha256 still PENDING, token missing) is SKIPPED with a warning, together with
# the other packages of its group (jailops needs the same-version jailops-client). BUILD_STRICT=1 turns a skip into a failure.
# SOURCE_DATE_EPOCH is the commit time of the package directory, so the same inputs give the same bytes on a re-run
# and `pkgops archive push` never sees two different files for one version.
set -eu
. "$(dirname "$0")/lib.sh"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

[ $# -ge 1 ] || die "usage: build-pkg.sh PKG..."
OUT="${DIST_DIR:-$REPO_ROOT/dist}"
command -v pkgops >/dev/null 2>&1 || die "pkgops is not on PATH (see .github/actions/setup-pkgops)"
mkdir -p "$OUT"; : > "$OUT/built.txt"

skip=" "
for pkg in "$@"; do
  for member in $(group_members "$(group_of "$pkg")"); do
    if ! pkg_ready "$member"; then
      [ "${BUILD_STRICT:-}" != 1 ] || die "$member: $REASON"
      warn "skipping the group of $pkg: $member is not ready: $REASON"
      skip="$skip$(group_members "$(group_of "$pkg")" | tr '\n' ' ')"
      break
    fi
  done
done

for pkg in "$@"; do
  case "$skip" in *" $pkg "*) echo "$pkg: skipped"; continue ;; esac
  note "== $pkg $(mf_get "$pkg" version)"
  sh "$REPO_ROOT/scripts/fetch-source.sh" "$pkg"
  sh "$REPO_ROOT/scripts/prebuild.sh" "$pkg"
  if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct -- "main/$pkg" 2>/dev/null || true)
  else epoch=$SOURCE_DATE_EPOCH; fi
  [ -n "$epoch" ] || die "$pkg: no commit time for main/$pkg (not a git checkout?): set SOURCE_DATE_EPOCH"
  SOURCE_DATE_EPOCH=$epoch pkgops build -f "$MAIN/$pkg/pkgops.yaml" --abi all -o "$OUT"
  echo "$pkg $(mf_get "$pkg" version)" >> "$OUT/built.txt"
done
echo "built:" >&2; cat "$OUT/built.txt" >&2
