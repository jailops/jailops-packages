#!/bin/sh
# check-pkgops.sh [--strict] [BASE_REF]
#
# Validates the repository before anything is built. Run by the workflows on every push and pull request, and by hand.
# Exit 1 with one "FAIL" line per problem. Checks, per package under main/:
#   - the directory name is the package name; pkgops.yaml and upstream.yaml exist
#   - min_release is exactly "15.1" (a higher one would break `pkg update` for the WHOLE repository on 15.1 hosts),
#     both ABIs are listed in abis:, no single abi:
#   - origin jailops/<name>, comment, www, maintainer packages@jailops.net, license set
#   - every dependency has name, origin and a version; a dependency on a package of the same group has that
#     package's upstream version (jailops -> jailops-client, and it must exist). A dependency on a package of another
#     group (jailops -> jailops-apps) is not kept in step: pkg resolves dependencies by name, so any version of it
#     satisfies the dependency, and the version only records what it was written against
#   - upstream.yaml: group repo tag_prefix tarball strip_components sha256 token_env prebuild; sha256 is 64 hex or PENDING
#     (--strict: PENDING fails); prebuild steps exist; token_env is passed by the build workflow. Or `source: local`
#     (the package is built from its own directory): then only prebuild, no upstream keys, and no file from src/
#   - the packages of one group share one upstream version
#   - files named in pkgops.yaml outside src/ and build/ exist
# Repository-wide:
#   - pkgops-repo.yaml and prune.yaml say what the policy says (15.1, both ABIs, schema 1)
#   - no private key material is in the tree
#   - every workflow that builds sets GOTOOLCHAIN: auto at workflow level; scripts that run go or pkgops build too
#   - check-updates.yml: calls only scripts that exist, uses no secret except UPDATE_TOKEN and JAILOPS_SOURCE_TOKEN (UPDATE_TOKEN
#     in no other workflow), and the monthly collisions job holds no write permission
#   - the signing secret appears only in build-and-publish.yml, once, with `environment: signing`, never in a pull_request job
#   - immutability, with BASE_REF (or $CHECK_BASE): a package whose main/<pkg>/ changed since BASE_REF must have a new
#     version (scripts/bump-version.sh --revision for a packaging change). Exceptions: pinning a PENDING sha256, and a
#     change of comment lines of pkgops.yaml only (outside block scalars; comments never reach the package).
set -eu
. "$(dirname "$0")/lib.sh"

STRICT=
[ "${1:-}" = "--strict" ] && { STRICT=1; shift; }
BASE=${1:-${CHECK_BASE:-}}
bad=0
fail() { echo "FAIL $*" >&2; bad=1; }

tmpf=$(mktemp "${TMPDIR:-/tmp}/check-pkgops.XXXXXX"); trap 'rm -f "$tmpf"' EXIT

pkgs=$(all_pkgs)
[ -n "$pkgs" ] || fail "no package under main/"

for p in $pkgs; do
  d="$MAIN/$p"; m="$d/pkgops.yaml"; u="$d/upstream.yaml"
  [ "$(mf_get "$p" name)" = "$p" ] || fail "$p: name in pkgops.yaml is '$(mf_get "$p" name)', the directory is $p"
  [ -f "$u" ] || { fail "$p: upstream.yaml is missing"; continue; }

  v=$(mf_get "$p" version)
  echo "$v" | grep -Eq '^[0-9]+(\.[0-9]+)*(_[0-9]+)?$' || fail "$p: version '$v' must be N.N.N or N.N.N_R"

  mr=$(mf_get "$p" min_release)
  [ "$mr" = "15.1" ] || fail "$p: min_release is '$mr', it must be \"15.1\" (a package needing more would make 'pkg update' fail for every 15.1 host)"
  grep -Eq '^min_osversion:' "$m" && fail "$p: use min_release: \"15.1\", not min_osversion"
  grep -Eq '^abi:' "$m" && fail "$p: single 'abi:' is not allowed, list both in abis:"
  abis=$(abis_of "$p" | sort | tr '\n' ' ')
  [ "$abis" = "FreeBSD:15:aarch64 FreeBSD:15:amd64 " ] || fail "$p: abis must be exactly [FreeBSD:15:amd64, FreeBSD:15:aarch64], got: $abis"

  [ "$(mf_get "$p" origin)" = "jailops/$p" ] || fail "$p: origin must be jailops/$p (names that never collide with a FreeBSD port), got '$(mf_get "$p" origin)'"
  [ -n "$(mf_get "$p" comment)" ] || fail "$p: comment is empty"
  [ -n "$(mf_get "$p" www)" ] || fail "$p: www is empty"
  [ "$(mf_get "$p" maintainer)" = "packages@jailops.net" ] || fail "$p: maintainer must be packages@jailops.net"
  [ -n "$(mf_get "$p" license)" ] || fail "$p: license is empty"

  # dependencies: lines of the form  - {name: X, origin: Y, version: "Z"}  under deps:
  sed -n '/^deps:/,/^[a-z]/p' "$m" | grep -E '^[[:space:]]*-' > "$tmpf" || true
  while read -r line; do
    n=$(echo "$line" | sed -n 's/.*name:[[:space:]]*\([^,}]*\).*/\1/p' | sed 's/[[:space:]]*$//')
    o=$(echo "$line" | sed -n 's/.*origin:[[:space:]]*\([^,}]*\).*/\1/p' | sed 's/[[:space:]]*$//')
    dv=$(echo "$line" | sed -n 's/.*version:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p')
    if [ -z "$n" ] || [ -z "$o" ] || [ -z "$dv" ]; then fail "$p: dependency needs name, origin and version on one line: $line"; continue; fi
    if [ -f "$MAIN/$n/pkgops.yaml" ]; then
      if [ -f "$u" ] && [ -f "$MAIN/$n/upstream.yaml" ] && [ "$(group_of "$n")" = "$(group_of "$p")" ]; then
        want=$(base_version "$(mf_get "$n" version)")
        [ "$dv" = "$want" ] || fail "$p: dependency $n is version $dv but $n in this repository is $want (scripts/bump-version.sh keeps them equal)"
      else
        echo "$dv" | grep -Eq '^[0-9]+(\.[0-9]+)*(_[0-9]+)?$' || fail "$p: dependency $n has version '$dv', not a version"
      fi
      [ "$o" = "jailops/$n" ] || fail "$p: dependency $n has origin $o, expected jailops/$n"
    fi
  done < "$tmpf"
  if [ "$p" = jailops ]; then
    grep -Eq '\{name: jailops-client,' "$m" || fail "jailops: must depend on jailops-client (same version)"
  fi

  src=$(up_get "$p" source)
  if [ "$src" = local ]; then
    # built from this directory: nothing to download, pin or check for updates
    for k in group repo tag_prefix tarball strip_components sha256 token_env bump_note; do
      grep -Eq "^$k:" "$u" && fail "$p: upstream.yaml says source: local, so '$k:' has no meaning there; remove it"
    done
    grep -Eq "^prebuild:" "$u" || fail "$p: upstream.yaml has no 'prebuild:' key"
    sed -n 's/^[[:space:]-]*source:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$m" | grep -q '^src/' &&
      fail "$p: source: local, but pkgops.yaml takes files from src/, which only a download fills"
  else
    [ -z "$src" ] || fail "$p: upstream.yaml source: '$src' is unknown (local, or no source: key for a tarball)"
    for k in group repo tag_prefix tarball strip_components sha256 token_env prebuild; do
      grep -Eq "^$k:" "$u" || fail "$p: upstream.yaml has no '$k:' key"
    done
    echo "$(up_get "$p" repo)" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || fail "$p: upstream repo must be owner/name"
    up_get "$p" tarball | grep -Eq '\$\{(tag|version)\}' || fail "$p: upstream tarball must contain \${tag} or \${version}"
    s=$(up_get "$p" sha256)
    if [ "$s" = PENDING ]; then
      [ -z "$STRICT" ] || fail "$p: sha256 is PENDING (pin it: scripts/bump-version.sh --pin $p)"
      echo "note $p: sha256 PENDING, the package is skipped by the build until it is pinned" >&2
    else
      is_sha256 "$s" || fail "$p: sha256 '$s' is neither 64 hex digits nor PENDING"
    fi
  fi
  known=$(sh "$REPO_ROOT/scripts/prebuild.sh" --list)
  for step in $(up_get "$p" prebuild); do
    case " $known " in *" $step "*) ;; *) fail "$p: unknown prebuild step '$step'" ;; esac
  done
  te=$(up_get "$p" token_env)
  if [ -n "$te" ] && ! grep -q "secrets\.$te" "$REPO_ROOT"/.github/workflows/build-and-publish.yml 2>/dev/null; then
    fail "$p: token_env $te is not passed to the build by .github/workflows/build-and-publish.yml (env: $te: \${{ secrets.$te }})"
  fi

  # files that come from this directory (not from the fetched source or the build) must exist
  sed -n 's/^[[:space:]-]*source:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$m" > "$tmpf"
  while read -r f; do
    case "$f" in src/*|build/*) ;; *) [ -e "$d/$f" ] || fail "$p: file $f named in pkgops.yaml does not exist" ;; esac
  done < "$tmpf"
done

# packages of one group: one upstream version
for g in $(for p in $pkgs; do [ -f "$MAIN/$p/upstream.yaml" ] && group_of "$p"; done | sort -u); do
  vs=$(for p in $(group_members "$g"); do base_version "$(mf_get "$p" version)"; done | sort -u | tr '\n' ' ')
  [ "$(echo $vs | wc -w)" = 1 ] || fail "group $g: its packages have different upstream versions: $vs"
done

# policy files
grep -Eq '^min_release:[[:space:]]*"?15\.1"?' "$REPO_ROOT/pkgops-repo.yaml" || fail "pkgops-repo.yaml: min_release must be 15.1"
grep -q 'FreeBSD:15:amd64' "$REPO_ROOT/pkgops-repo.yaml" && grep -q 'FreeBSD:15:aarch64' "$REPO_ROOT/pkgops-repo.yaml" || fail "pkgops-repo.yaml: abis must list FreeBSD:15:amd64 and FreeBSD:15:aarch64"
grep -Eq '^schema:[[:space:]]*1' "$REPO_ROOT/pkgops-repo.yaml" || fail "pkgops-repo.yaml: schema: 1 missing"
grep -Eq '^schema:[[:space:]]*1' "$REPO_ROOT/prune.yaml" || fail "prune.yaml: schema: 1 missing"
grep -Eq '^entries:' "$REPO_ROOT/prune.yaml" || fail "prune.yaml: entries: missing"

# no key material in the tree (the pattern is assembled so this file does not match itself)
pat="-----BEGIN [A-Z ]*PRIV""ATE KEY-----"
if grep -rIl --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=src --exclude-dir=dist --exclude-dir=temp -e "$pat" "$REPO_ROOT" >/dev/null 2>&1; then
  fail "private key material found in: $(grep -rIl --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=src --exclude-dir=dist --exclude-dir=temp -e "$pat" "$REPO_ROOT" | tr '\n' ' ')"
fi
for f in $(find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -path '*/node_modules' -prune -o -path '*/.pkgops-src' -prune -o -path "$REPO_ROOT/temp" -prune -o -type f \( -name '*.key' -o -name '*.rsa' -o -name '*.pem' \) -print 2>/dev/null); do
  fail "key file in the tree: $f"
done

# workflows
wf="$REPO_ROOT/.github/workflows"
for f in "$wf"/*.yml; do
  [ -f "$f" ] || continue
  if grep -Eq 'build-pkg\.sh|pkgops build|go (build|run|install)|setup-go|npm ' "$f"; then
    awk '/^env:/ {e=1; next} /^[^[:space:]#]/ {e=0} e && /^[[:space:]]+GOTOOLCHAIN:[[:space:]]*auto[[:space:]]*$/ {ok=1} END {exit ok?0:1}' "$f" ||
      fail "$(basename "$f"): runs go or pkgops build but does not set GOTOOLCHAIN: auto in the workflow-level env:"
  fi
done
for f in "$REPO_ROOT"/scripts/*.sh; do
  if grep -Eq '^[[:space:]]*(.*[[:space:]])?(pkgops build|go (build|run|install))' "$f" && ! grep -q 'GOTOOLCHAIN' "$f"; then
    fail "scripts/$(basename "$f"): runs go or pkgops build but never mentions GOTOOLCHAIN"
  fi
done
cu="$wf/check-updates.yml"
if [ -f "$cu" ]; then
  for sc in $(grep -o '\.github/scripts/[A-Za-z0-9_.-]*\.sh' "$cu" | sort -u); do
    [ -f "$REPO_ROOT/$sc" ] || fail "check-updates.yml: calls $sc, which does not exist"
  done
  extra=$(grep -o 'secrets\.[A-Za-z0-9_]*' "$cu" | sort -u | grep -v -e '^secrets\.UPDATE_TOKEN$' -e '^secrets\.JAILOPS_SOURCE_TOKEN$' || true)
  [ -z "$extra" ] || fail "check-updates.yml: unexpected secret(s): $extra"
  other_ut=$(grep -l 'secrets\.UPDATE_TOKEN' "$wf"/*.yml 2>/dev/null | grep -v 'check-updates.yml' || true)
  [ -z "$other_ut" ] || fail "UPDATE_TOKEN is used outside check-updates.yml: $other_ut"
  awk '/^  collisions:/ {c=1; next} /^  [a-z_-]+:[[:space:]]*$/ {c=0} c && /(contents|pull-requests|actions):[[:space:]]*write/ {bad=1} END {exit bad?1:0}' "$cu" ||
    fail "check-updates.yml: the collisions job must not have write permissions"
fi
if [ -d "$wf" ]; then
  others=$(grep -l 'PKG_REPO_KEY' "$wf"/*.yml 2>/dev/null | grep -v 'build-and-publish.yml' || true)
  [ -z "$others" ] || fail "PKG_REPO_KEY is used outside build-and-publish.yml: $others"
  bp="$wf/build-and-publish.yml"
  if [ -f "$bp" ]; then
    n=$(grep -c 'secrets\.PKG_REPO_KEY' "$bp" || true)
    [ "$n" = 1 ] || fail "build-and-publish.yml: secrets.PKG_REPO_KEY must appear exactly once (found $n)"
    grep -Eq '^[[:space:]]+environment:[[:space:]]*signing[[:space:]]*$' "$bp" || fail "build-and-publish.yml: the job that holds the key must say 'environment: signing'"
    # the line of the secret must sit in the job that is skipped for pull requests
    kj=$(awk '/^  [a-z_-]+:[[:space:]]*$/ {job=$1} /secrets\.PKG_REPO_KEY/ {print job}' "$bp" | tr -d ':')
    if [ -n "$kj" ]; then
      awk -v j="  $kj:" '$0 == j {inj=1; next} /^  [a-z_-]+:[[:space:]]*$/ {inj=0} inj && /github\.event_name != .pull_request./ {ok=1} END {exit ok?0:1}' "$bp" ||
        fail "build-and-publish.yml: job '$kj' holds the signing key but has no \"github.event_name != 'pull_request'\" condition"
    fi
  fi
fi

# the baseline cache: restored in both baseline steps, saved only in the publish job (never for a pull request), and only
# the .baseline-cache directory, never the key, the site or the workspace
if [ -f "$bp" ]; then
  [ "$(grep -c 'uses: actions/cache/save@v4' "$bp")" = 1 ] || fail "build-and-publish.yml: actions/cache/save@v4 must appear exactly once"
  grep -Eq 'uses: actions/cache(/restore)?@' "$bp" && grep -E 'uses: actions/cache(/restore|/save)?@' "$bp" | grep -vq '@v4' && fail "build-and-publish.yml: pin actions/cache to @v4"
  [ "$(grep -c 'uses: actions/cache/restore@v4' "$bp")" = 2 ] || fail "build-and-publish.yml: actions/cache/restore@v4 must appear twice (build and publish baseline)"
  grep -Eq 'uses: actions/cache@' "$bp" && fail "build-and-publish.yml: use actions/cache/restore and /save, not actions/cache (it would save in the build job and in pull requests)"
  sj=$(awk '/^  [a-z_-]+:[[:space:]]*$/ {job=$1} /actions\/cache\/save/ {print job}' "$bp" | tr -d ':')
  [ "$sj" = publish ] || fail "build-and-publish.yml: actions/cache/save must be in the publish job, found in '$sj'"
  grep -B4 'uses: actions/cache/save@v4' "$bp" | grep -q "github.event_name != 'pull_request'.*refs/heads/master" ||
    fail "build-and-publish.yml: the cache save step must be conditional on github.event_name != 'pull_request' and master"
  # the `with:` blocks of the cache steps (up to the next blank line)
  cblk=$(awk '/uses: actions\/cache\// {c=1} /^[[:space:]]*$/ {c=0} c' "$bp")
  paths=$(echo "$cblk" | sed -n 's/^[[:space:]]*path:[[:space:]]*//p' | sort -u | tr '\n' ' ')
  [ "$paths" = ".baseline-cache " ] || fail "build-and-publish.yml: the cache path must be exactly .baseline-cache (found: $paths)"
  ! echo "$cblk" | grep -Eq 'KEY_FILE|pkg-repo\.key|RUNNER_TEMP|secrets\.|site' || fail "build-and-publish.yml: a cache step mentions the key, a secret or the site"
  grep -Fxq '.baseline-cache/' "$REPO_ROOT/.gitignore" || fail ".gitignore: .baseline-cache/ is missing"
fi

# is_published NAME VERSION: the live index lists this version (PUBLISHED_INDEX: a file to read instead of SITE_URL)
pubidx=
if [ -n "${PUBLISHED_INDEX:-}" ]; then pubidx=$(cat "$PUBLISHED_INDEX" 2>/dev/null || true)
elif [ -n "${SITE_URL:-}" ] && command -v curl >/dev/null 2>&1; then pubidx=$(curl -fsS "$SITE_URL/pkgops-index.json" 2>/dev/null || true); fi
is_published() {
  [ -n "$pubidx" ] && command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "$pubidx" | jq -e --arg n "$1" --arg v "$2" 'any(.packages[]; .name == $n and .version == $v)' >/dev/null 2>&1
}

# no_comments < pkgops.yaml: the manifest without its comment lines. Lines inside a block scalar (after a key ending in
# | or >, while they are blank or indented deeper than that key) are kept: there a # is text, for example in a script.
no_comments() {
  awk '
    blk { match($0, /^ */); if ($0 ~ /^[[:space:]]*$/ || RLENGTH > ind) { print; next } blk = 0 }
    /^[[:space:]]*#/ { next }
    { print }
    /[|>][-+0-9]*[[:space:]]*(#.*)?$/ { match($0, /^ */); ind = RLENGTH; blk = 1 }
  '
}

# immutability against a base commit
if [ -n "$BASE" ] && git -C "$REPO_ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null; then
  for p in $pkgs; do
    changed=$(git -C "$REPO_ROOT" diff --name-only "$BASE" -- "main/$p" | tr '\n' ' ')
    [ -n "$changed" ] || continue
    old=$(git -C "$REPO_ROOT" show "$BASE:main/$p/pkgops.yaml" 2>/dev/null | yget version || true)
    [ -n "$old" ] || continue                       # a new package
    new=$(mf_get "$p" version)
    [ "$old" != "$new" ] || {
      if [ "$changed" = "main/$p/upstream.yaml " ] &&
         [ "$(git -C "$REPO_ROOT" show "$BASE:main/$p/upstream.yaml" | yget sha256)" = PENDING ]; then continue; fi
      if [ "$changed" = "main/$p/pkgops.yaml " ] &&
         [ "$(git -C "$REPO_ROOT" show "$BASE:main/$p/pkgops.yaml" | no_comments)" = "$(no_comments < "$MAIN/$p/pkgops.yaml")" ]; then
        echo "note $p: only comments of pkgops.yaml changed; the package is the same, the version stays" >&2
        continue
      fi
      # Only a PUBLISHED version is immutable: a version the live index does not list can still be corrected. When the
      # index cannot be read (offline, no jq, no SITE_URL) the check stays strict.
      is_published "$p" "$new" || continue
      how="scripts/bump-version.sh --revision $p"
      is_local "$p" && how="raise version: in main/$p/pkgops.yaml (the minor for a new app, the patch for a fix)"
      fail "$p: main/$p changed ($changed) but the version is still $old: a published version is immutable. Bump it: $how"
    }
  done
else
  [ -z "$BASE" ] || echo "note: base '$BASE' is unknown to git; the immutability check is skipped" >&2
fi

if [ "$bad" = 0 ]; then echo "check-pkgops: ok ($(echo $pkgs | wc -w) packages)"; fi
exit $bad
