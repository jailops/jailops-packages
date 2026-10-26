# Add a package

Five minutes, for a Go program with a tagged GitHub release. PkgOps does not build C, Rust or anything that needs a
FreeBSD toolchain: use poudriere for those.

## 1. Copy the nearest package

```sh
cp -r main/unisupply main/mytool        # a plain Go CLI; main/jailops for daemons, main/isms for a service with an npm build
```

## 2. `main/mytool/upstream.yaml` (where the source comes from)

```yaml
group: mytool                  # packages that must be bumped together share a group (jailops, jailops-client, jailops-backupd)
repo: owner/mytool             # GitHub owner/name
tag_prefix: v                  # tag = tag_prefix + version
tarball: https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz     # ${repo} ${tag} ${version}
strip_components: 1
sha256: PENDING                # then: sh scripts/bump-version.sh --pin mytool   (downloads and writes it)
token_env:                     # name of a secret/env var with read access when the repo is private (then add it to build-and-publish.yml)
prebuild:                      # steps of scripts/prebuild.sh (jailops-web:host, jailops-web:backup, isms-web); empty = none
```

Optional `bump_note: one line` in `upstream.yaml`: `check-updates.yml` puts it in every bump PR of the group under "Read before
merging" (use it for packages whose bumps can break things silently: daemons, embedded consoles, install messages).
The daily check needs a GitHub release (or tag) `vN.N.N` upstream; names must not collide with a FreeBSD port
(monthly check, see README), manually: `pkg search -x '^mytool$'` on FreeBSD.

A new prebuild step is a few lines in `case` of `scripts/prebuild.sh` (and in its `--list`).

## 3. `main/mytool/pkgops.yaml` (what goes into the package)

Required by `scripts/check-pkgops.sh` (and by pkg):

```yaml
name: mytool                   # = the directory name
version: 1.2.3                 # the upstream version; a packaging-only change becomes 1.2.3_1
origin: jailops/mytool         # always jailops/<name>: never collides with a FreeBSD port
comment: One line
desc: Longer text
www: https://github.com/owner/mytool
maintainer: packages@jailops.net
license: BSD2CLAUSE            # pkg names: BSD2CLAUSE, BSD3CLAUSE, APACHE20, MIT, ...
abis: [FreeBSD:15:amd64, FreeBSD:15:aarch64]     # both; never a single abi:
min_release: "15.1"            # exactly 15.1: a higher value would break `pkg update` for every 15.1 host
build:
  type: go
  dir: src                     # the fetched source is main/mytool/src (gitignored)
  package: ./cmd/mytool        # or packages: [{package: ./cmd/a}, {package: ./cmd/b}] for several binaries
  output: build/${ARCH}/mytool
  ldflags: -s -w -X main.version=${VERSION}
files:
  - {source: build/${ARCH}/mytool, destination: bin/mytool}
  - {source: src/LICENSE, destination: share/doc/mytool/LICENSE}
```

For a daemon: `service:` generates the rc.d script and the user (see `main/isms`), or `services:` installs one from
the source tree (see `main/jailops`: the rc.d scripts and sample configuration are taken from the fetched source, so they cannot
drift). Config files that admins edit: `config: true`. Dependencies: one line each with name, origin and version, for example
`- {name: git-lite, origin: devel/git, version: "2.56.0"}`; a dependency on a package of this repository uses `jailops/<name>`
and that package's current upstream version (`bump-version.sh` keeps it equal). Never generate secrets or keys at build or install time.

## 4. Check and build

```sh
sh scripts/check-pkgops.sh
sh scripts/bump-version.sh --pin mytool                    # sha256 of the tarball (needs the tag)
SOURCE_DATE_EPOCH=1700000000 DIST_DIR=/tmp/dist sh scripts/build-pkg.sh mytool
pkgops inspect /tmp/dist/FreeBSD:15:aarch64/mytool-1.2.3.pkg
```

With a local checkout instead of the tarball: `SRC_MYTOOL=~/src/mytool sh scripts/build-pkg.sh mytool` (never in CI).

## 5. Push to `master`

The build job builds only what changed and what the live site lacks; the publish job signs and deploys. Nothing is deleted
and nothing is rebuilt that did not change. To fix a package later without a new upstream version:
`sh scripts/bump-version.sh --revision mytool`. To take one version off the site: [README, Prune](../README.md#prune-remove-a-version-from-the-site).
