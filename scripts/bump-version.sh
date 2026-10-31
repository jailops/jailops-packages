#!/bin/sh
# bump-version.sh VERSION PKG...    a new upstream version: version in main/PKG/pkgops.yaml (a _N revision is reset), the
#                                   tarball's sha256 in main/PKG/upstream.yaml (downloaded), and the versions of sibling
#                                   dependencies in the same group (jailops -> jailops-client). Give every package of a
#                                   group together. For a package with source: local only the version is written.
# bump-version.sh --revision PKG... a packaging-only change (rc.d, config, files): 0.1.0 -> 0.1.0_1 -> 0.1.0_2
# bump-version.sh --pin PKG...      only write the sha256 of the current version (the tag now exists)
# bump-version.sh --groups          one line per source group: GROUP REPO TAG_PREFIX PKG,PKG,... (for check-updates.yml)
#
# NO_DOWNLOAD=1 writes PENDING instead of downloading. Edits plain files only; commits nothing.
set -eu
. "$(dirname "$0")/lib.sh"

replace_line() { # replace_line FILE KEY NEWLINE
  sed "s|^$2:.*|$3|" "$1" > "$1.new" && mv "$1.new" "$1"
}
set_version() { replace_line "$MAIN/$1/pkgops.yaml" version "version: $2"; }
set_sha() { replace_line "$MAIN/$1/upstream.yaml" sha256 "sha256: $2"; }
pin() {
  if is_local "$1"; then echo "$1: source: local, nothing to pin"; return; fi
  if [ "${NO_DOWNLOAD:-}" = 1 ]; then set_sha "$1" PENDING; return; fi
  s=$(sh "$REPO_ROOT/scripts/fetch-source.sh" --print-sha "$1")
  is_sha256 "$s" || die "$1: no sha256 from the download"
  set_sha "$1" "$s"; echo "$1: sha256 $s"
}
sync_deps() { # dependencies on a package of the same group follow its upstream version; another group's are left alone
  for p in $(all_pkgs); do
    f="$MAIN/$p/pkgops.yaml"; cp "$f" "$f.new"
    for s in $(group_members "$(group_of "$p")"); do
      v=$(base_version "$(mf_get "$s" version)")
      sed "/{name: $s,/ s/version: \"[^\"]*\"/version: \"$v\"/" "$f.new" > "$f.new2" && mv "$f.new2" "$f.new"
    done
    if cmp -s "$f" "$f.new"; then rm -f "$f.new"; else mv "$f.new" "$f"; echo "$p: dependency versions synced"; fi
  done
}

case "${1:-}" in
--groups)
  # packages with source: local have no upstream to check
  for p in $(all_pkgs); do is_local "$p" || group_of "$p"; done | sort -u | while read -r g; do
    first=$(group_members "$g" | head -n 1)
    echo "$g $(up_get "$first" repo) $(up_get "$first" tag_prefix) $(group_members "$g" | tr '\n' ',' | sed 's/,$//')"
  done
  ;;
--revision)
  shift; [ $# -ge 1 ] || die "usage: bump-version.sh --revision PKG..."
  for p in "$@"; do
    v=$(mf_get "$p" version)
    case "$v" in *_[0-9]*) n=${v##*_}; new="${v%_*}_$((n + 1))" ;; *) new="${v}_1" ;; esac
    set_version "$p" "$new"; echo "$p: $v -> $new"
  done
  ;;
--pin)
  shift; [ $# -ge 1 ] || die "usage: bump-version.sh --pin PKG..."
  for p in "$@"; do is_local "$p" && die "$p: source: local, nothing to pin"; pin "$p"; done
  ;;
-*|"") die "usage: bump-version.sh VERSION PKG... | --revision PKG... | --pin PKG... | --groups" ;;
*)
  ver=$1; shift; [ $# -ge 1 ] || die "usage: bump-version.sh VERSION PKG..."
  echo "$ver" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || die "VERSION must look like 1.2.3 (got '$ver')"
  for p in "$@"; do
    old=$(mf_get "$p" version)
    set_version "$p" "$ver"; echo "$p: $old -> $ver"
  done
  sync_deps
  for p in "$@"; do pin "$p"; done
  ;;
esac
