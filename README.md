# jailops-packages

Signed FreeBSD packages for JailOps and a few related tools, built with [PkgOps](https://github.com/jailops/jailops-pkgops)
(no FreeBSD builder, no ports tree) and served as a pkg(8) repository from GitHub Pages at
`https://pkg.jailops.net/${ABI}/latest`.

- **FreeBSD 15.1 and later only**, `amd64` and `aarch64` (`FreeBSD:15:amd64`, `FreeBSD:15:aarch64`). Every package
  declares a minimum release of 15.1; pkg itself refuses it on 15.0.
- Repository status: **UNVERIFIED on GitHub** until the one-time setup below is done and the first run succeeded.
  The packages and the repository layout were verified with real pkg 2.8.4 on FreeBSD 15.1 (see "Verification").

## Use it

As root on a FreeBSD 15.1+ host:

```sh
mkdir -p /usr/local/etc/pkg/keys /usr/local/etc/pkg/repos
fetch -o /usr/local/etc/pkg/keys/jailops.pub https://pkg.jailops.net/jailops.pub
sha256 -q /usr/local/etc/pkg/keys/jailops.pub
# must print exactly: b9fb3c980044dbd7a37c6e53e6a17510b054ba3af65e538eb2eae0f14be26a70
```

The fingerprint is the sha256 of the public key file (also published at
<https://pkg.jailops.net/jailops.fingerprint> and committed as `KEY_FINGERPRINT`). Compare it with this README on
GitHub, not only with what the same web server told you; do not go on if it differs.

```sh
cat > /usr/local/etc/pkg/repos/jailops.conf <<'EOF'
jailops: {
  url: "https://pkg.jailops.net/${ABI}/latest",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/keys/jailops.pub",
  enabled: yes
}
EOF
pkg update
pkg install jailops
```

(No `mirror_type`: the repository is plain HTTPS, not an SRV mirror set.) Package names and origins (`jailops/<name>`)
do not collide with FreeBSD ports; pkg picks the highest version across all enabled repositories, so keep it that way.

## Packages

| package | what it is |
|---|---|
| `jailops-client` | `jailops` and `jailops-sync`, the command line client and fleet tool. Depends on `git-lite`. |
| `jailops` | `jailopsd` (daemon, REST API, embedded web console) and `jailops-priv` (privileged helper), their rc.d scripts and sample configuration, user and group `jailops`, `/var/db/jailops`. Depends on `jailops-client` of the same version. |
| `jailops-backupd` | The JailOps backup node with its rc.d script and sample configuration, user `jailops-backup`. It needs PostgreSQL for its control plane, but the package does **not** depend on a postgresql package: the database may be on another host or in any flavour you run. |
| `pkgops` | The PkgOps command line tool (no service). |
| `isms` | The [isms](https://github.com/unidoc/isms) ISMS platform: one Go binary with the Vue interface embedded, an rc.d service, `/usr/local/etc/isms/server.env` (mode 0600, owner `isms`). Needs PostgreSQL (not installed). **Nothing is generated for you**: the install message lists the exact commands (secret, signing key, migrations). |
| `unisupply` | [unisupply](https://github.com/unidoc/unisupply), Go supply chain analysis (CLI). |
| `age-plugin-sshagent` | [age](https://age-encryption.org) plugin deriving identities from ssh-agent signatures. |
| `incus-sync` | GitOps fleet manager for Incus. On FreeBSD it is a **client of remote Linux Incus hosts**; Incus itself does not run on FreeBSD. |

Services are installed disabled. Enable with `sysrc NAME_enable=YES`, then `service NAME start`; each package prints its
next steps when it is installed. The `git-lite` dependency comes from the official repository (the full `git` would pull in perl and python,
about 1 GB; `jailops-sync` only needs the core git commands, which git-lite has, tested on FreeBSD 15.1).

## Problems

Open an issue at <https://github.com/jailops/jailops-packages/issues> with `pkg -vv | head -40`, `uname -U` and the
exact command and output. Bugs in a program itself belong to the program's own repository (linked above).

---

# Maintainers

## How it works

```
main/<pkg>/pkgops.yaml     what goes into the package (PkgOps manifest)
main/<pkg>/upstream.yaml   where the source comes from: repo, tag prefix, tarball URL, sha256, prebuild step, token
pkgops-repo.yaml           policy: ABIs and minimum release 15.1 (refused otherwise)
prune.yaml                 the ONLY way a version leaves the site
scripts/                   check, fetch-source, prebuild, build-pkg, baseline, changed, verify-site, site-files, bump-version, keygen
.github/workflows/         build-and-publish.yml, check-updates.yml (scripts: .github/scripts/)
tests/                     offline tests of the update check: sh tests/run.sh
KEY_FINGERPRINT            sha256 of the public signing key (not secret; the publish job refuses another key)
PKGOPS_VERSION             the pinned pkgops release (v0.1.0)
```

A push to `master` runs `build-and-publish.yml`:

1. **build** job: `scripts/check-pkgops.sh`, install the pinned pkgops, `scripts/baseline.sh` (`pkgops fetch` from the live
   site, or from the GitHub Releases archive when the site has no index), `scripts/changed.sh` (the packages whose
   current version is missing from the baseline index, and nothing else: touching files, scripts or the pin builds nothing), `scripts/build-pkg.sh`
   (fetch source with sha256 check, prebuild, `pkgops build --abi all`), then an unsigned `pkgops repo` + `pkgops verify`
   in the runner. Pull requests and other branches stop here: **no signing, no publishing**.
2. **publish** job (master only, GitHub Environment `signing`): fetches the baseline again, writes the key to
   `$RUNNER_TEMP` with umask 077, `scripts/site-files.sh` (public key `jailops.pub`, `jailops.fingerprint`, `CNAME`,
   `index.html`, all derived from the secret on every run), `pkgops repo --policy --prune --key`, `pkgops verify`,
   `scripts/verify-site.sh` (no package vanished), `pkgops archive push` (every `.pkg` into GitHub Releases), removes the key,
   uploads the site as the Pages artifact.
3. **deploy** job: `actions/deploy-pages`. The site is an artifact; no binary is ever in git or a `gh-pages` branch.

Packages that are already published are never rebuilt: the published index is the only trigger (a package is built when its
version is not in it), so a change to a script, the pin or a workflow rebuilds nothing, and a real change to a package
bumps its version (`scripts/check-pkgops.sh` insists on it). Their files come from the baseline. A concurrency group (`publish`) serialises
publishes. Nothing is deleted automatically: no `--keep`, no `--replace`. Builds are reproducible per package
(`SOURCE_DATE_EPOCH` = commit time of `main/<pkg>`), so a re-run never produces a second file for one version.

### Why the baseline is cached and why the cache cannot change the result

Every run needs the whole published history as its baseline (a deploy replaces the whole site), and that history grows with
every package version. Downloading all of it twice per run (build job, publish job) is wasteful, so `scripts/baseline.sh`
restores the previously published `.pkg` files from the GitHub Actions cache (`.baseline-cache`, package files only, laid out
like the site) and lets `pkgops fetch` download only what it does not already have. The cache is a pure optimisation:
the live index (pkg.jailops.net, or the Releases archive) is fetched every time and alone decides what exists. `pkgops fetch`
keeps a cached file only when its size and sha256 match that index and replaces any other one; afterwards the script deletes
every `.pkg` in the working site that the index does not list (a pruned version, an old build, a foreign file; `pkgops repo`
would otherwise reindex them back in) and every `*.part`, then verifies each listed file's sha256 again. An empty, missing,
stale or poisoned cache therefore gives the same site as no cache, and the signing key never goes near it (the cache path is
`.baseline-cache` only; it is saved only by the publish job on master, never for a pull request, and not on `first_run`).
The run prints `baseline summary: reused N, downloaded N, removed as stale N, bytes downloaded N`. Offline test:
`tests/test-baseline.sh`.

Remaining cost, honestly: the Pages artifact still contains the whole site on every deploy (GitHub Pages replaces the site as a
whole; the published site is limited to 1 GB), so the upload grows with the history even though the downloads no longer do.
The next step if that gets close is `prune.yaml` (old versions leave the site, the Releases archive keeps them). Moving the
package files out of Pages is NOT done now. The cache keys (`baseline-<PKGOPS_VERSION hash>-<run id>`, restored by prefix, so a new
PkgOps version starts clean) and the restore/save behaviour are UNVERIFIED on GitHub; the entries are evicted after 7 days
unused or when the repository's cache quota is full, which only means a cold download.

Go builds use `GOTOOLCHAIN=auto` (workflow-level `env:`, and `build-pkg.sh` sets it; `check-pkgops.sh` fails without it),
`actions/setup-go` (stable) and `actions/setup-node` 24 for the web builds.

## Add a package in 5 minutes

See [docs/ADD-A-PACKAGE.md](docs/ADD-A-PACKAGE.md): copy the nearest `main/<pkg>`, edit two files, run
`sh scripts/check-pkgops.sh`, build it locally, push to `master`.

## Releases, bumps, and packaging fixes

- **New upstream version**: `check-updates.yml` (daily 06:00 UTC, or Run workflow) takes, per source group, the highest
  non-draft, non-prerelease release with a plain `N.N.N` version (by version sort, not by date; the tags when the repository
  has no release) and only ever goes forward. It opens one pull request per bump (branch `bump-<group>-<version>`, label
  `update`) that runs `scripts/bump-version.sh VERSION PKG...`: version (a `_N` revision is reset), sha256 of the tarball and the
  dependency versions between sibling packages. Commits go through the Contents API (Verified). The PR body has the release
  notes URL, the compare link and, from `bump_note:` in `upstream.yaml`, a warning line (isms, jailops: read before
  merging). The build workflow is dispatched on the branch (a PR opened with the workflow token may not start
  `pull_request` runs): it builds and verifies, never signs or publishes. Nothing is merged automatically; merging to
  `master` publishes. By hand: `sh scripts/bump-version.sh 0.2.0 jailops-client jailops jailops-backupd`.
  - Idempotent: an open PR (or a leftover branch whose PR was closed on purpose) for the same bump is detected and left alone;
    when a newer upstream appears the older bump PR is commented, closed and its branch deleted, superseded by the new one.
  - One unreachable upstream (private without token, renamed) does not stop the others: it is listed in the summary. Run
    workflow with `strict` to fail at the end when any was unreachable (a PR that could not be opened always fails the run).
  - **Summary** on the run page: a table of every package (in repo, upstream latest, status: up to date / bump PR opened /
    bump PR already open / upstream unreachable / pinned PENDING sha256), the `PKGOPS_VERSION` line, and the age of the last
    publish (`generated` in <https://pkg.jailops.net/pkgops-index.json>; skipped when the site does not exist yet).
  - **`PKGOPS_VERSION`**: the same run checks the latest release of `jailops/jailops-pkgops` and opens a one-line PR
    (`bump-pkgops-pin-<version>`). The publish job runs that pkgops with the signing key, so the PR text says: read the
    changelog (linked) first; the PR build already runs the new version (unsigned). A commit SHA pin is not checked.
  - **Monthly** (1st, 06:30 UTC; or Run workflow with `collisions`): our package names against `packagesite.pkg` of
    `https://pkg.freebsd.org/FreeBSD:15:amd64/latest/`; a collision fails the job. If the catalog cannot be fetched or
    unpacked (needs tar with zstd/xz) it only warns, unless `strict`; then check by hand: `pkg search -x '^name$'` on a FreeBSD host.
  - Optional secret `UPDATE_TOKEN` (used as `GH_TOKEN` in the `check` job only, never printed) instead of the workflow token.
  - Tests, offline (fake GitHub API on localhost, Go YAML parse of the workflows): `sh tests/run.sh`; run it after touching
    `.github/scripts/` or the workflow. Needs jq, python3, go with `gopkg.in/yaml.v3` in the module cache.
- **A packaging-only change** (rc.d, config, files, script): `sh scripts/bump-version.sh --revision PKG` makes `0.1.0_1`.
  A published version is immutable: `check-pkgops.sh BASE` fails when `main/<pkg>/` changed and the version did not.
- **The first release of a source**: set `sha256: PENDING` until the tag exists, then `sh scripts/bump-version.sh --pin PKG...`.
  A package whose sha256 is PENDING (or whose token secret is missing) is skipped, with its group, with a warning.
  `BUILD_STRICT=1` turns the skip into a failure.
- **jailops, jailops-client, jailops-backupd** are built from `jailops/jailops`, which is private and untagged for now. They need
  the tag `v0.1.0` (then pin the sha256) and a read token in the secret `JAILOPS_SOURCE_TOKEN` (also an env var for the
  scripts); with a public repository, empty `token_env:` in the three `upstream.yaml` files.
  `jailops/jailops-pkgops` `v0.1.0` must exist before `PKGOPS_VERSION` and the `pkgops` package work.

## Prune (remove a version from the site)

Pruning removes a version from GitHub Pages only; the Releases archive keeps it. Either use the PkgOps admin UI
(`pkgops serve --source https://pkg.jailops.net --prune-via github:jailops/jailops-packages@master:prune.yaml ...`,
docs/admin.md of PkgOps), or on a machine:

```sh
pkgops prune --plan --from https://pkg.jailops.net --older-than 90d -n     # look first (-n writes nothing)
pkgops prune --plan --from https://pkg.jailops.net --name hello --version 0.1.0
git diff prune.yaml && git commit -am "Prune hello 0.1.0" && git push
```

`prune.yaml` is the only way things leave the site; pruning the newest version of a package needs `force: true`.
Deleting from the archive is a separate, confirmed command (`pkgops archive prune ... --confirm "delete from archive"`).

## One-time manual setup (all UNVERIFIED: no GitHub or Cloudflare account was used to write this)

1. Create the repository `github.com/jailops/jailops-packages`, default branch `master`; push this tree.
2. Settings, Pages: Source = **GitHub Actions**. Custom domain `pkg.jailops.net` (the workflow also writes `CNAME`); enforce HTTPS
   once the certificate is issued.
3. Cloudflare DNS: `CNAME pkg -> jailops.github.io`, **public (proxy off or on, but never behind Cloudflare Access)**: pkg clients
   cannot do an Access login. Check that `https://pkg.jailops.net/jailops.pub` answers without a login.
4. Make the signing key **yourself**: `sh scripts/keygen.sh` (needs `pkgops` on PATH). It writes the key outside the repository
   (`~/.config/jailops-packages/jailops-repo.key`), `KEY_FINGERPRINT` and the README fingerprint. Back the key up.
5. Settings, Environments, New environment `signing` (admin-only secrets; no required reviewers needed). Add the secret
   `PKG_REPO_KEY` there (`gh secret set PKG_REPO_KEY --env signing --repo jailops/jailops-packages < ~/.config/jailops-packages/jailops-repo.key`).
   Never a repository-level secret, never in a pull request. Commit `KEY_FINGERPRINT` and `README.md`.
6. Optional repository secrets: `JAILOPS_SOURCE_TOKEN` (read access to `jailops/jailops` while it is private), `UPDATE_TOKEN`
   (a token that may open PRs and start workflows, for `check-updates.yml`).
7. Publish the pkgops tag `v0.1.0` in `jailops/jailops-pkgops` (or put a commit SHA in `PKGOPS_VERSION`), tag `jailops/jailops` `v0.1.0`
   and run `sh scripts/bump-version.sh --pin pkgops jailops-client jailops jailops-backupd`.
8. First publish only: Actions, "Build and publish", Run workflow with `first_run` = true (there is no site and no archive to
   take a baseline from). Every later run without it fails when no baseline can be fetched, so nothing can vanish.
9. Branch protection on `master` is yours to decide (you push straight to `master`). The workflows never need it.
10. The admin UI (`pkgops serve --source ...`): a GitHub App installed on this repository only (Contents and Actions read-write,
    Metadata read), the private key on the host that runs `pkgops serve` (0600), the service on a **separate admin hostname** behind
    Cloudflare Access (self-hosted application, AUD tag, allow list). See PkgOps docs/admin.md. The admin hostname must never be `pkg.jailops.net`.

## Local work

```sh
sh scripts/check-pkgops.sh                                   # manifests, policy, workflows, immutability: sh scripts/check-pkgops.sh BASE_REF
# a package from its tarball:
SOURCE_DATE_EPOCH=1700000000 sh scripts/build-pkg.sh unisupply            # dist/<ABI>/<name>-<version>.pkg
# from a local checkout instead (development only, refused in Actions, announced loudly, not verified):
SRC_JAILOPS=~/src/jailops SRC_JAILOPS_CLIENT=~/src/jailops SRC_JAILOPS_BACKUPD=~/src/jailops sh scripts/build-pkg.sh jailops-client jailops jailops-backupd
# a repository with a THROWAWAY key (never the real one):
pkgops key generate --out /tmp/t/t.key && pkgops repo --repo /tmp/site --policy pkgops-repo.yaml --prune prune.yaml --key /tmp/t/t.key dist
pkgops verify /tmp/site/FreeBSD:15:amd64/latest --pubkey /tmp/t/t.pub
```

Environment: `SRC_<PKG>` (package name upper-cased, `-` to `_`), `JAILOPS_SOURCE_TOKEN`, `DIST_DIR`, `SOURCE_DATE_EPOCH`,
`NPM_CI_ARGS`, `BUILD_STRICT`, `BASELINE_FIRST_RUN`, `NO_DOWNLOAD` (bump). Tools: a POSIX sh, curl, tar, jq (or python3), Go, Node 24 for the web builds.
`*.key`, `*.pem`, `site/`, `dist/`, `main/*/src/`, `main/*/build/` are in `.gitignore`; `check-pkgops.sh` fails if key material is in the tree.

## Verification

Done locally (FreeBSD 15.1-RELEASE arm64 with pkg 2.8.4 as the target, a throwaway signing key):

- all eight manifests build with `pkgops build --abi all`; seven were built from real sources (isms was only
  manifest-tested with a labelled placeholder binary: its source build, a Node/npm build of downloaded code, was not run here);
- `pkgops repo` with the policy and prune files, `pkgops verify` (signed), `pkgops inspect`: every package carries the
  `FreeBSD_version: 1501000` annotation;
- real `pkg` in a private root with `pkg -r`: `pkg update`, `pkg install jailops jailops-backupd pkgops age-plugin-sshagent incus-sync unisupply`
  (41 packages with git and its dependencies from the official repository), users and groups created, directories, rc.d scripts, `pkg check -s`;
  a 15.0 userland (`OSVERSION=1500000`) is refused by `pkg update`;
- the baseline cache against a local static site (`tests/test-baseline.sh`: cold, warm, added, pruned, corrupted, foreign files, first run, failure);
- the scripts against a local fake git repository and a local HTTP site (changed packages, baseline, bump, pin, sha256 mismatch,
  first run, key fingerprint guard, negative checks of `check-pkgops.sh`).

**UNVERIFIED**: everything on GitHub (workflows, Pages incl. `FreeBSD:15:amd64` directory names with colons, deploy-pages,
`pkgops archive push`, the Contents-API commit helper, PR/dispatch/label/supersede behaviour of `check-updates.yml`, the monthly packagesite.pkg download), Cloudflare, the pkgops
`v0.1.0` release and install script download path, the private `jailops/jailops` source (no tag, no token yet), the isms
FreeBSD parts (service, paths, user, message: the build recipe itself is the production APKBUILD's), a real boot with the rc.d scripts, actionlint (not available).

## Open decisions

- `jailops` source: make `jailops/jailops` public or keep the token; retire its own rsync/VM release pipeline when this repository is live.
- Package names: `jailops`, `jailops-client`, `jailops-backupd`, `pkgops`, `isms`, `unisupply`, `age-plugin-sshagent` and `incus-sync` were searched in the official FreeBSD package repository on 2026-10-26 (pkg 2.8.4, FreeBSD 15.1) and none exists there; search again before the first publish, because the ports tree moves.
- GitHub tarballs are not guaranteed byte-stable; a sha256 mismatch fails the build (re-pin deliberately).
- Pages limits (1 GB site, bandwidth): a lot of history may need a different host; pruning or the archive restore path help.
