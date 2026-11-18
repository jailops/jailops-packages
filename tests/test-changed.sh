#!/bin/sh
# Offline tests of scripts/changed.sh: only what the published index lacks is built, never the rest.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/test-changed.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }

# a copy of the repository to edit, with its own git history
R=$T/repo; mkdir -p "$R"
(cd "$HERE" && tar -cf - --exclude=./.git --exclude=./site --exclude=./dist --exclude='./main/*/src' --exclude=./.baseline-cache .) | tar -xf - -C "$R"
git -C "$R" init -q -b master
git -C "$R" -c user.name=t -c user.email=t@example.org add -A
git -C "$R" -c user.name=t -c user.email=t@example.org commit -q -m base
BASE=$(git -C "$R" rev-parse HEAD)
commit() { git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@example.org commit -q -m "$1"; }
changed() { sh "$R/scripts/changed.sh" "$1" HEAD "${2:-}" | tr -s ' ' | sed 's/^ //; s/ $//'; }

. "$R/scripts/lib.sh"
# an index with every package at its current version for every ABI, minus the packages named in $1
make_index() { # make_index DIR [MISSING...]
  d=$1; shift; mkdir -p "$d"; first=1; printf '{"schema":1,"packages":[' > "$d/pkgops-index.json"
  for p in $(all_pkgs); do
    case " $* " in *" $p "*) continue ;; esac
    v=$(mf_get "$p" version)
    for abi in $(abis_of "$p"); do
      [ "$first" = 1 ] || printf ',' >> "$d/pkgops-index.json"; first=0
      printf '{"name":"%s","version":"%s","abi":"%s"}' "$p" "$v" "$abi" >> "$d/pkgops-index.json"
    done
  done
  printf '],"pruned":[]}' >> "$d/pkgops-index.json"
}

make_index "$T/full"
eq "everything published, nothing changed: builds nothing" "" "$(changed "$BASE" "$T/full")"

# touching files, scripts and the pin changes nothing as long as no version is new
echo "# a comment" >> "$R/main/unisupply/upstream.yaml"; echo "# x" >> "$R/scripts/lib.sh"; echo v0.1.0 > "$R/PKGOPS_VERSION"; echo "# w" >> "$R/.github/workflows/build-and-publish.yml"
commit "touch files"
eq "files, scripts, pin and workflow touched, versions published: builds nothing" "" "$(changed "$BASE" "$T/full")"

# a version bump builds that package and nothing else
sed -i 's/^version: .*/version: 99.0.0/' "$R/main/unisupply/pkgops.yaml"; commit "bump unisupply"
eq "one new version: builds exactly that package" "unisupply" "$(changed "$BASE" "$T/full")"

# a package missing from the index (a failed earlier deploy) is built again, others are not
make_index "$T/part" incus-sync
eq "a package missing from the site: builds exactly that one" "incus-sync unisupply" "$(changed "$BASE" "$T/part" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# first run: empty site, no index
mkdir -p "$T/empty"
eq "first run (empty site): builds every package" "$(all_pkgs | sort | tr '\n' ' ' | sed 's/ $//')" "$(changed "" "$T/empty" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# no baseline at all: the git diff decides, or everything when there is no usable base
eq "no baseline, git diff: only the package whose files changed" "unisupply" "$(changed "$BASE")"
eq "no baseline, no base: every package" "$(all_pkgs | sort | tr '\n' ' ' | sed 's/ $//')" "$(changed "" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# --pairs: name:abi,abi, only the ABIs the index lacks (a published file of the other ABI is never rebuilt)
pairs() { sh "$R/scripts/changed.sh" --pairs "$1" HEAD "${2:-}" | tr -s ' ' | sed 's/^ //; s/ $//'; }
make_index "$T/abi"                      # everything, then drop one ABI of one package
jq '.packages |= map(select(.name=="unisupply" and .abi=="FreeBSD:15:aarch64" | not))' "$T/abi/pkgops-index.json" > "$T/abi/x" && mv "$T/abi/x" "$T/abi/pkgops-index.json"
git -C "$R" reset -q --hard "$BASE"
eq "pairs: only the missing ABI of a package" "unisupply:FreeBSD:15:aarch64" "$(pairs "$BASE" "$T/abi")"
make_index "$T/pabs" incus-sync
eq "pairs: a package missing for every ABI lists them all" "incus-sync:$(abis_of incus-sync | tr '\n' ',' | sed 's/,$//')" "$(pairs "$BASE" "$T/pabs")"
eq "pairs: everything published: nothing" "" "$(pairs "$BASE" "$T/full")"
eq "pairs: first run: every package with every ABI" "$(for p in $(all_pkgs); do printf '%s:%s\n' "$p" "$(abis_of "$p" | tr '\n' ',' | sed 's/,$//')"; done | sort | tr '\n' ' ' | sed 's/ $//')" \
  "$(pairs "" "$T/empty" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

# split-plan: no token_env is public, a token_env is private
eq "split-plan: public" "unisupply:FreeBSD:15:aarch64" "$(sh "$R/scripts/split-plan.sh" public unisupply:FreeBSD:15:aarch64)"
eq "split-plan: nothing private" "" "$(sh "$R/scripts/split-plan.sh" private unisupply:FreeBSD:15:aarch64)"
sed -i 's/^token_env:.*/token_env: JAILOPS_SOURCE_TOKEN/' "$R/main/unisupply/upstream.yaml"
eq "split-plan: a token_env makes it private" "unisupply:FreeBSD:15:aarch64" "$(sh "$R/scripts/split-plan.sh" private unisupply:FreeBSD:15:aarch64 incus-sync)"
eq "split-plan: and not public" "incus-sync" "$(sh "$R/scripts/split-plan.sh" public unisupply:FreeBSD:15:aarch64 incus-sync)"
git -C "$R" checkout -q -- .

[ "$fails" = 0 ] && echo "test-changed: all ok" || { echo "test-changed: $fails FAILED"; exit 1; }
