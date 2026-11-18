# Retention: what stays on the site

The site, <https://pkg.jailops.net>, is a GitHub Pages site, and Pages publishes at most about 1 GB. Every publish
deploys the whole site again, so its size is the sum of every package file on it.

## The policy

**The newest two versions of every package, per ABI, stay on the site. Older versions leave it, automatically.**

- The newest version is the one `pkg` installs: the signed catalog lists only the newest version of each package. The one
  before it stays as a file on the site (and in `pkgops-index.json` with its sha256): a host whose cached catalog is one
  release old still finds the file that catalog names, and a rollback by one release has a file to install.
- Leaving the site is not deleting: every package that was ever published is in the archive in GitHub Releases
  (`pkgops archive push` runs in every publish). Pruning never touches the archive. Only `pkgops archive prune`
  deletes from it, and it needs a typed confirmation.
- A pruned version is no longer in the catalog that `pkg update` reads, and its file is no longer served. Rolling back
  to it is described below.
- With two versions of each package the site is about 245 MB today and at most about 300 MB if every package had a
  previous version (by the sizes in the index), well below 1 GB.

## How it happens

The `publish` job makes the plan in every master run (`scripts/prune-plan.sh --generate`), before it signs: it assembles the
repository about to be signed (the baseline and the packages built now), and for every package and ABI plans the files
older than the newest two versions. The signing step applies the plan, the catalogs are written without those files, and
the index lists them under `pruned`. Nothing is committed and nobody runs anything. The plan is in the job log, in the job
summary and in the artifact `prune-plan` of the run.

So a release that is built in a run drops the version before the previous one in that run. A run that builds nothing prunes
whatever is older than the newest two.

What the job guarantees:

- A version is planned only when two newer versions of the same package and ABI are in the repository to sign: a package
  never ends without a version, and the newest always stays. (`pkgops` also refuses to prune the newest version unless an
  entry says `force: true`; the plan never does.)
- Only files of the baseline are planned. The cross-check of the baseline with the archive runs before, and stops the
  run unless every file on the live site is archived with the same sha256, so every file that leaves the site is in the
  archive. A version built in a run and already superseded in it stays on the site until the next run, when it is a
  baseline file.
- Every dependency with an origin `jailops/...` of every package on the signed site is on the site for the same ABI, by name
  (`scripts/verify-site.sh`, strict mode): pkg's solver resolves a dependency by name, not by the version a package recorded,
  so a pruned version never leaves a kept package without what it needs.
- After the archive push and before the upload, `scripts/verify-archive.sh` checks the final site: every file on it and every
  pruned file is archived. A pruned file that is not archived stops the run, and nothing is deployed.
- The assembled site must stay below 900 MB (`scripts/check-site-size.sh`, a warning from 700 MB); a missed prune fails the
  job before the deploy, not the deploy after it.
- The plan is the same for the same baseline and packages.

`prune.yaml` in the repository is optional and normally empty: explicit extra entries for an administrator's exceptional
removal (`pkgops prune --plan --name N --version V`, then commit). The job adds its own entries to a copy of that file.

## Looking

```sh
sh scripts/prune-plan.sh --size     # how many package files and bytes the live site has now
sh scripts/prune-plan.sh            # what the next publish would drop from the live site; writes nothing
```

Both read the published index, so they need network and `pkgops` on `PATH`. The daily update check writes the size of
the site into its summary and says so when it is above about 800 MB.

## What a host sees

A host whose cached catalog is at most one release old never meets a missing file: the catalog names the version that was
newest then, and that file is still on the site. A host with a much older catalog (it did not run `pkg update` through more
than two releases) can get `Not Found` for a file that has left the site, until `pkg update -f` fetches the current
catalog; allow up to ten minutes after a deploy for the Pages cache. Nothing is half-installed or locked by that: pkg
fetches a file before it installs it. The newest version of every package is always on the site.

## Rolling back

`pkg upgrade` never goes down, so a rollback is a decision about the next version, not an edit of the site.

- **Roll forward (the way):** put the code of the good release into a new, higher version (`scripts/bump-version.sh`) and
  publish it. Every host moves up to it with `pkg upgrade`.
- **Back by one release on a host:** the previous version is a file on the site, not in the catalog (the catalog lists only
  the newest). Install the dependencies first and then the package, by URL: `pkg add
  https://pkg.jailops.net/FreeBSD:15:amd64/latest/All/jailops-client-0.8.5.pkg`, then the same for `jailops-0.8.5.pkg` (name
  and version of the previous release; the ABI directory is the host's). Compare the sha256 of the file with the `sha256` of its
  entry in <https://pkg.jailops.net/pkgops-index.json> first: a file outside the catalog is not covered by the signature.
- **Older than that:** the file is in the archive, in the release `pkg-<name>-<version>` of this repository, as the asset
  `<name>-<version>-<ABI with : as _>.pkg`. Download it, compare its sha256 with the `sha256` of its entry under `pruned` in the
  index (or with `archive.json` in the same release), then `pkg add FILE`, dependencies first as above.
- **`redeploy` is recovery, not rollback.** `deploy_run_id` deploys the signed site of an earlier publish run after a failed
  deploy (docs/supply-chain.md). Its artifact lives one day, and an older site fails `verify-archive` because the archive is
  ahead of it.
- **A local mirror of the archive** is a different thing: `pkgops fetch --from github-releases:OWNER/REPO --into DIR` brings
  back every archived file, about 2 GB, over what Pages publishes. Use it for a mirror on a host, never as the site.

## If the site still grows too fast

Two versions of each package in both ABIs is the floor of the policy that keeps rollback by one release. If the site is
near the limit with it, the package files have to move off Pages (object storage or a server behind `pkg.jailops.net`; the
URL that hosts use does not change, and the signed catalogs verify every package wherever it is served from). That is a
hosting change, not a pruning one.
