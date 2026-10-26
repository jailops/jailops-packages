#!/bin/sh
# prebuild.sh PKG...      run the prebuild steps named in main/PKG/upstream.yaml inside main/PKG/src
# prebuild.sh --list      the known steps
#
# Steps are fixed recipes, not arbitrary commands, so upstream.yaml cannot run anything else:
#   jailops-web:APP   go run ./scripts/gen-ts -check, then cd web && npm ci && npm run build -- --app APP
#                     (APP is host for jailopsd, backup for jailops-backupd; web/apps.json)
#   isms-web          what unidoc-aports/main/isms/APKBUILD does before go build: scripts/sync-migrations.sh,
#                     cd web && npm ci && npm run build, copy web/dist into cmd/isms/web/dist
# Needs Node 24 and npm. NPM_CI_ARGS (for example --prefer-offline) is added to `npm ci`.
set -eu
. "$(dirname "$0")/lib.sh"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

[ "${1:-}" = "--list" ] && { echo "jailops-web:host jailops-web:backup isms-web"; exit 0; }
[ $# -ge 1 ] || die "usage: prebuild.sh PKG..."

npm_ci() { npm ci ${NPM_CI_ARGS:-}; }

for pkg in "$@"; do
  steps=$(up_get "$pkg" prebuild)
  [ -n "$steps" ] || { note "$pkg: no prebuild steps"; continue; }
  src="$MAIN/$pkg/src"
  [ -d "$src" ] || die "$pkg: $src is missing: run scripts/fetch-source.sh $pkg first"
  command -v node >/dev/null 2>&1 || die "$pkg: node is required for: $steps"
  note "$pkg: node $(node --version), npm $(npm --version)"
  for step in $steps; do
    note "$pkg: prebuild step $step"
    case "$step" in
    jailops-web:*)
      app=${step#jailops-web:}
      (cd "$src" && go run ./scripts/gen-ts -check)
      (cd "$src/web" && npm_ci && npm run build -- --app "$app")
      ;;
    isms-web)
      (cd "$src" && ./scripts/sync-migrations.sh)
      (cd "$src/web" && npm_ci && npm run build)
      mkdir -p "$src/cmd/isms/web/dist"
      cp -r "$src/web/dist/." "$src/cmd/isms/web/dist/"
      ;;
    *) die "$pkg: unknown prebuild step '$step' (known: $("$0" --list))" ;;
    esac
  done
done
