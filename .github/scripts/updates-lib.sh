# Pure helpers of check-updates.sh (sourced; also by tests/). POSIX sh. Needs scripts/lib.sh sourced first.

# ver_gt A B: A is a higher version than B (sort -V), never true for equal versions.
ver_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# latest_of PREFIX < tag names: the highest plain N.N.N version among the tags that start with PREFIX (by version, not
# by date). Nothing when there is none.
latest_of() {
  sed -n "s/^$1\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\$/\1/p" | sort -V | tail -n 1
}

# fmt_age SECONDS: "5 min", "7 h", "3 days"
fmt_age() {
  if [ "$1" -lt 0 ]; then echo "in the future"
  elif [ "$1" -lt 3600 ]; then echo "$(($1 / 60)) min"
  elif [ "$1" -lt 172800 ]; then echo "$(($1 / 3600)) h"
  else echo "$(($1 / 86400)) days"; fi
}

# index_age FILE NOW_EPOCH: age of "generated" in a pkgops-index.json; exit 1 when it cannot be read.
index_age() {
  _g=$(jq -r '.generated // empty' "$1" 2>/dev/null | sed 's/\.[0-9]*Z$/Z/') || return 1
  [ -n "$_g" ] || return 1
  _e=$(printf '%s' "$_g" | jq -R 'fromdateiso8601' 2>/dev/null) || return 1
  fmt_age "$(($2 - _e))"
}

# open_bump_prs JSON PREFIX: "NUMBER BRANCH" of the open PRs (JSON = the pulls list) whose head branch is PREFIX followed
# by a digit (so bump-pkgops- does not match bump-pkgops-pin-...).
open_bump_prs() {
  printf '%s' "$1" | jq -r --arg p "$2" '.[] | select(.head.ref | startswith($p)) | select(.head.ref | ltrimstr($p) | test("^[0-9]")) | "\(.number) \(.head.ref)"'
}

# pr_for_branch JSON BRANCH: the number of the open PR with that head branch (empty if none)
pr_for_branch() {
  printf '%s' "$1" | jq -r --arg b "$2" '[.[] | select(.head.ref == $b)][0].number // empty'
}

# render_summary ROWS_FILE (tab separated: package, in repo, upstream, status): a Markdown table
render_summary() {
  echo "| package | in repo | upstream latest | status |"
  echo "|---|---|---|---|"
  while IFS='	' read -r _p _c _l _s; do
    echo "| \`$_p\` | $_c | $_l | $_s |"
  done < "$1"
}

# collisions NAMES_FILE PACKAGESITE_YAML: the names of NAMES_FILE (one per line) that are also a package name in the
# packagesite.yaml of the official repository (one JSON object per line). Prints the colliding names.
collisions() {
  jq -r '.name' "$2" 2>/dev/null | sort -u > "$2.names"
  sort -u "$1" | comm -12 - "$2.names"
  rm -f "$2.names"
}
