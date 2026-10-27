#!/bin/sh
# check-updates.sh [all|collisions]     run by .github/workflows/check-updates.yml (and by tests/, against a fake API)
#
# all         for every source group (main/*/upstream.yaml): the highest non-draft, non-prerelease release (tags when the
#             repository has no release) with a plain N.N.N version; when it is higher than the repository's, a PR
#             that runs scripts/bump-version.sh (version, tarball sha256, _N reset). Then the PKGOPS_VERSION pin against
#             jailops/jailops-pkgops. Then a Markdown summary (to $GITHUB_STEP_SUMMARY, else stdout). Never merges anything.
# collisions  package names of main/ against the official FreeBSD repository (packagesite.pkg).
#
# Environment: GH_TOKEN (UPDATE_TOKEN or the workflow token; used only in the Authorization header of API calls and by
# commit-verified.sh, never printed), GITHUB_REPOSITORY, GITHUB_API_URL, GITHUB_SERVER_URL, STRICT=1 (an unreachable
# upstream fails the run at the very end), SITE_URL, a token_env secret of upstream.yaml for a private source repo.
# Test hooks: REPO_ROOT, COMMIT_CMD, PKGOPS_REPO, NOW_EPOCH, SUMMARY_FILE, PACKAGESITE_FILE, FREEBSD_ABIS.
set -u
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}; export REPO_ROOT
. "$REPO_ROOT/scripts/lib.sh"
. "$REPO_ROOT/.github/scripts/updates-lib.sh"
command -v jq >/dev/null 2>&1 || die "jq is required"

API=${GITHUB_API_URL:-https://api.github.com}
SERVER=${GITHUB_SERVER_URL:-https://github.com}
SELF=${GITHUB_REPOSITORY:-}
BASE_BRANCH=master
COMMIT_CMD=${COMMIT_CMD:-sh $REPO_ROOT/.github/scripts/commit-verified.sh}
PKGOPS_REPO=${PKGOPS_REPO:-jailops/jailops-pkgops}
SITE_URL=${SITE_URL:-https://pkg.jailops.net}
STRICT=${STRICT:-}
cd "$REPO_ROOT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-updates.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
ROWS="$WORK/rows"; : > "$ROWS"
UNREACHABLE=0; ERRORS=0
TAB=$(printf '\t')

# api METHOD PATH [JSON] [TOKEN]: body on stdout, non-zero on an HTTP error
api() {
  _t=${4:-${GH_TOKEN:-}}
  if [ -n "${3:-}" ]; then
    curl --fail-with-body -sS --max-time 60 -X "$1" -H "Authorization: Bearer $_t" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" -d "$3" "$API$2"
  else
    curl --fail-with-body -sS --max-time 60 -X "$1" -H "Authorization: Bearer $_t" -H "Accept: application/vnd.github+json" "$API$2"
  fi
}

# list_names REPO KIND TOKEN: tag names of the releases (non-draft, non-prerelease) or of the tags; fails when unreachable
list_names() {
  _n=1
  while [ "$_n" -le 10 ]; do
    case "$2" in
    releases) _o=$(api GET "/repos/$1/releases?per_page=100&page=$_n" "" "$3") || return 1
              printf '%s' "$_o" | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' ;;
    tags)     _o=$(api GET "/repos/$1/tags?per_page=100&page=$_n" "" "$3") || return 1
              printf '%s' "$_o" | jq -r '.[].name' ;;
    esac
    [ "$(printf '%s' "$_o" | jq length)" -ge 100 ] || break
    _n=$((_n + 1))
  done
}

# upstream_latest REPO PREFIX TOKEN: the highest version; empty when none; return 1 when unreachable
upstream_latest() {
  _v=$(list_names "$1" releases "$3") || return 1
  _l=$(printf '%s\n' "$_v" | latest_of "$2")
  if [ -z "$_l" ]; then
    _v=$(list_names "$1" tags "$3") || return 1
    _l=$(printf '%s\n' "$_v" | latest_of "$2")
  fi
  printf '%s' "$_l"
}

ensure_label_and_set() { # PR_NUMBER
  api POST "/repos/$SELF/labels" '{"name":"update","color":"0e8a16","description":"automated upstream update"}' >/dev/null 2>&1 || true
  api POST "/repos/$SELF/issues/$1/labels" '{"labels":["update"]}' >/dev/null || warn "could not label #$1"
}

# open_pr BRANCH TITLE BODY: creates the PR; prints its number; labels it; dispatches the unsigned build on the branch
open_pr() {
  _j=$(jq -n --arg t "$2" --arg b "$3" --arg h "$1" --arg base "$BASE_BRANCH" '{title:$t, body:$b, head:$h, base:$base}')
  _r=$(api POST "/repos/$SELF/pulls" "$_j") || return 1
  _num=$(printf '%s' "$_r" | jq -r '.number // empty'); [ -n "$_num" ] || return 1
  ensure_label_and_set "$_num"
  # a PR opened with the workflow token may not start pull_request workflows: dispatch the build on the branch
  api POST "/repos/$SELF/actions/workflows/build-and-publish.yml/dispatches" "$(jq -n --arg r "$1" '{ref:$r}')" >/dev/null ||
    warn "could not dispatch the build on $1"
  printf '%s' "$_num"
}

# supersede NEW_NUMBER "NUMBER BRANCH"...: close the older bump PRs and delete their branches
supersede() {
  _new=$1; shift
  for _pair in "$@"; do
    _on=${_pair%% *}; _ob=${_pair#* }
    api POST "/repos/$SELF/issues/$_on/comments" "$(jq -n --arg b "Superseded by #$_new (a newer upstream version appeared). Closing this one." '{body:$b}')" >/dev/null || true
    api PATCH "/repos/$SELF/pulls/$_on" '{"state":"closed"}' >/dev/null || warn "could not close #$_on"
    api DELETE "/repos/$SELF/git/refs/heads/$_ob" >/dev/null || true
    echo "closed #$_on ($_ob), superseded by #$_new"
  done
}

branch_exists() { api GET "/repos/$SELF/git/ref/heads/$1" >/dev/null 2>&1; }
pr_link() { echo "[#$1]($SERVER/$SELF/pull/$1)"; }

# existing_pr PREFIX BRANCH: 0 and STATUS set when nothing is to be created (a PR for this very bump is open, or the
# branch exists without an open PR: somebody closed it on purpose)
existing_pr() {
  _ex=$(pr_for_branch "$OPEN_PRS" "$2")
  if [ -n "$_ex" ]; then STATUS="bump PR already open ($(pr_link "$_ex"))"; return 0; fi
  if branch_exists "$2"; then
    # a branch that never had a pull request is what a run leaves behind when it stops before opening one (a 403 on
    # the pull request call, for one): make it again. A branch whose PR was closed is somebody's decision: leave it.
    _any=$(api GET "/repos/$SELF/pulls?state=all&head=${SELF%%/*}:$2&per_page=1" 2>/dev/null | jq 'length' 2>/dev/null || echo 1)
    if [ "$_any" = 0 ]; then
      echo "branch $2 exists without any pull request (an earlier run stopped before opening it): making it again"
      api DELETE "/repos/$SELF/git/refs/heads/$2" >/dev/null || { STATUS="branch $2 exists and could not be removed: skipped"; return 0; }
      return 1
    fi
    STATUS="branch $2 exists, its pull request was closed (by hand?): skipped"; return 0
  fi
  return 1
}

# create_bump_pr PREFIX BRANCH TITLE BODY FILES...: the edits are in the working tree. Commit them (verified) to
# BRANCH, open the PR, close the older bump PRs of the same prefix. Sets STATUS; 1 on an error.
create_bump_pr() {
  _prefix=$1; _branch=$2; _title=$3; _body=$4; shift 4
  _old=$(open_bump_prs "$OPEN_PRS" "$_prefix")
  $COMMIT_CMD "$_branch" "$_title" "$@" || { STATUS="error: could not commit $_branch"; return 1; }
  _num=$(open_pr "$_branch" "$_title" "$_body") || { STATUS="error: could not open the PR for $_branch"; return 1; }
  STATUS="bump PR opened ($(pr_link "$_num"))"
  if [ -n "$_old" ]; then
    printf '%s\n' "$_old" > "$WORK/old"
    while read -r _on _ob; do
      supersede "$_num" "$_on" "$_ob"
    done < "$WORK/old"
    STATUS="$STATUS, superseded $(cut -d' ' -f1 "$WORK/old" | sed 's/^/#/' | tr '\n' ' ' | sed 's/ $//')"
  fi
  return 0
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ROWS"; }

process_group() { # GROUP REPO PREFIX PKG,PKG...
  _g=$1; _repo=$2; _pre=$3; _pk=$(echo "$4" | tr ',' ' ')
  _first=${_pk%% *}
  _cur=$(base_version "$(mf_get "$_first" version)")
  _tenv=$(up_get "$_first" token_env); _tok=${GH_TOKEN:-}
  if [ -n "$_tenv" ] && [ -n "$(eval "echo \"\${$_tenv:-}\"")" ]; then _tok=$(eval "echo \"\${$_tenv}\""); fi
  _pend=; for _p in $_pk; do [ "$(up_get "$_p" sha256)" = PENDING ] && _pend=1; done
  STATUS=; _lat=
  if ! _lat=$(upstream_latest "$_repo" "$_pre" "$_tok"); then
    STATUS="upstream unreachable"; UNREACHABLE=$((UNREACHABLE + 1)); _lat="?"
    warn "$_g: cannot read releases of $_repo (private without a token, or no such repository)"
  elif [ -z "$_lat" ]; then
    STATUS="no ${_pre}N.N.N release or tag yet"; _lat="-"
    [ -z "$_pend" ] || STATUS="pinned PENDING sha256 (no release yet)"
  elif ! ver_gt "$_lat" "$_cur"; then
    STATUS="up to date"
    [ -z "$_pend" ] || STATUS="pinned PENDING sha256 (pin it: scripts/bump-version.sh --pin)"
  else
    echo "$_g: $_cur -> $_lat"
    _branch="bump-$_g-$_lat"; _tag="$_pre$_lat"
    if ! existing_pr "bump-$_g-" "$_branch"; then
      _notes=$(for _p in $_pk; do up_get "$_p" bump_note; done | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
      _body="Automated version check: [$_repo]($SERVER/$_repo) has **$_tag**; this repository has $_pre$_cur.

- Release notes: $SERVER/$_repo/releases/tag/$_tag
- Compare: $SERVER/$_repo/compare/$_pre$_cur...$_tag
- Bumped: $_pk (version, sha256 of the source tarball, a \`_N\` revision is reset, sibling dependency versions follow).

The build workflow runs on this branch and does **not** sign or publish (only a push to master does). Check its log before merging. This PR is never merged automatically, and a bump never prunes anything."
      [ -z "$_notes" ] || _body="$_body

**Read before merging:** $_notes"
      if sh "$REPO_ROOT/scripts/bump-version.sh" "$_lat" $_pk; then
        _files=$(git status --porcelain -- main | sed 's/^...//' | tr '\n' ' ')
        # shellcheck disable=SC2086
        create_bump_pr "bump-$_g-" "$_branch" "$_g: bump to $_lat" "$_body" $_files || ERRORS=$((ERRORS + 1))
      else
        STATUS="error: bump-version.sh failed (the tarball download?)"; ERRORS=$((ERRORS + 1))
      fi
      git checkout -- main
    fi
  fi
  for _p in $_pk; do row "$_p" "$(mf_get "$_p" version)" "$_lat" "$STATUS"; done
}

check_groups() {
  sh "$REPO_ROOT/scripts/bump-version.sh" --groups > "$WORK/groups" || die "bump-version.sh --groups failed"
  while read -r g repo prefix members; do
    process_group "$g" "$repo" "$prefix" "$members"
  done < "$WORK/groups"
}

PIN_LINE=
check_pkgops_pin() {
  _pin=$(tr -d ' \n\r' < PKGOPS_VERSION)
  case "$_pin" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) PIN_LINE="\`PKGOPS_VERSION\`: \`$_pin\` (not a release tag: not checked)"; return 0 ;;
  esac
  if ! _lat=$(upstream_latest "$PKGOPS_REPO" v "${GH_TOKEN:-}"); then
    UNREACHABLE=$((UNREACHABLE + 1)); PIN_LINE="\`PKGOPS_VERSION\`: \`$_pin\`, latest release of $PKGOPS_REPO: ? (upstream unreachable)"; return 0
  fi
  if [ -z "$_lat" ] || ! ver_gt "$_lat" "${_pin#v}"; then
    _show=${_lat:+v$_lat}
    PIN_LINE="\`PKGOPS_VERSION\`: \`$_pin\`, latest release of $PKGOPS_REPO: ${_show:-none}, up to date"; return 0
  fi
  _tag="v$_lat"; _branch="bump-pkgops-pin-$_lat"
  echo "PKGOPS_VERSION: $_pin -> $_tag"
  STATUS=
  if ! existing_pr "bump-pkgops-pin-" "$_branch"; then
    _body="Automated check: [$PKGOPS_REPO]($SERVER/$PKGOPS_REPO) released **$_tag**; \`PKGOPS_VERSION\` pins $_pin. One line changes.

**The signing key is available to the pkgops version that the publish job uses**, so this is code that runs next to the repository key. Read the changelog first: $SERVER/$PKGOPS_REPO/releases/tag/$_tag (compare: $SERVER/$PKGOPS_REPO/compare/$_pin...$_tag).

The build on this PR runs with the new version (unsigned; nothing is published until a push to master). This PR is never merged automatically."
    printf '%s\n' "$_tag" > PKGOPS_VERSION
    create_bump_pr "bump-pkgops-pin-" "$_branch" "pkgops: bump PKGOPS_VERSION to $_tag" "$_body" PKGOPS_VERSION || ERRORS=$((ERRORS + 1))
    git checkout -- PKGOPS_VERSION
  fi
  PIN_LINE="\`PKGOPS_VERSION\`: \`$_pin\`, latest release of $PKGOPS_REPO: $_tag, $STATUS"
}

publish_age_line() {
  curl -fsS --max-time 20 -o "$WORK/index.json" "$SITE_URL/pkgops-index.json" 2>/dev/null || { echo "Last publish: unknown ($SITE_URL/pkgops-index.json is not reachable yet)"; return 0; }
  if _a=$(index_age "$WORK/index.json" "${NOW_EPOCH:-$(date +%s)}"); then echo "Last publish: $_a ago (\`generated\` in $SITE_URL/pkgops-index.json)"
  else echo "Last publish: unknown (no readable \`generated\` in the index)"; fi
}

write_summary() {
  {
    echo "## Update check $(date -u +%Y-%m-%d)"
    echo
    render_summary "$ROWS"
    echo
    echo "$PIN_LINE"
    echo
    publish_age_line
    [ "$UNREACHABLE" = 0 ] || { echo; echo "$UNREACHABLE upstream(s) unreachable${STRICT:+ (strict: this run fails)}."; }
    [ "$ERRORS" = 0 ] || { echo; echo "$ERRORS error(s) while opening PRs: see the log."; }
  } >> "${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stdout}}"
}

run_all() {
  [ -n "$SELF" ] || die "GITHUB_REPOSITORY is not set"
  OPEN_PRS=$(api GET "/repos/$SELF/pulls?state=open&per_page=100") || die "cannot list the open pull requests"
  check_groups
  check_pkgops_pin
  write_summary
  [ "$ERRORS" = 0 ] || exit 1
  if [ -n "$STRICT" ] && [ "$UNREACHABLE" != 0 ]; then echo "strict: $UNREACHABLE upstream(s) unreachable" >&2; exit 1; fi
  exit 0
}

run_collisions() {
  abis=${FREEBSD_ABIS:-FreeBSD:15:amd64}
  all_pkgs > "$WORK/ours"
  rc=0
  printf '## Package names against the official FreeBSD repository\n\n' >> "${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stdout}}"
  for abi in $abis; do
    f=${PACKAGESITE_FILE:-}
    if [ -z "$f" ]; then
      if ! curl -fsSL --max-time 300 -o "$WORK/ps.pkg" "https://pkg.freebsd.org/$abi/latest/packagesite.pkg" ||
         ! tar -xOf "$WORK/ps.pkg" packagesite.yaml > "$WORK/packagesite.yaml" 2>/dev/null; then
        msg="official catalog for $abi not readable (download or tar/zstd): collisions NOT checked, do it by hand (docs/ADD-A-PACKAGE.md)"
        warn "$msg"; echo "- $abi: $msg" >> "${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stdout}}"
        [ -z "$STRICT" ] || rc=1
        continue
      fi
      f="$WORK/packagesite.yaml"
    fi
    hit=$(collisions "$WORK/ours" "$f")
    if [ -n "$hit" ]; then
      echo "- $abi: **collision** with official packages: $(echo $hit)" >> "${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stdout}}"
      echo "FAIL $abi: package name(s) also in the official repository: $(echo $hit)" >&2; rc=1
    else
      echo "- $abi: no collision ($(wc -l < "$WORK/ours" | tr -d ' ') names checked)" >> "${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-/dev/stdout}}"
    fi
  done
  exit $rc
}

case "${1:-all}" in
all) run_all ;;
collisions) run_collisions ;;
*) die "usage: check-updates.sh [all|collisions]" ;;
esac
