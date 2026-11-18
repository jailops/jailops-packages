# Retention: what stays on the site

The site, <https://pkg.jailops.net>, is a GitHub Pages site, and Pages publishes at most about 1 GB. Every publish
deploys the whole site again, so its size is the sum of every package file that has not been pruned.

## The policy

**Only the newest version of every package, per ABI, stays on the site. Older versions leave it.**

- The newest version is the one `pkg` installs. A host that needs an older one gets its file from the archive.
- Leaving the site is not deleting: every package that was ever published is in the archive in GitHub Releases
  (`pkgops archive push` runs in every publish). Pruning never touches the archive. Only `pkgops archive prune`
  deletes from it, and it needs a typed confirmation.
- A pruned version is no longer in the catalog that `pkg update` reads, and its file is no longer served. A host that
  needs it installs the file from the archive with `pkg add URL`, or the baseline is rebuilt from the archive
  (`pkgops fetch --from github-releases:OWNER/REPO --into site --prune prune.yaml`).
- `prune.yaml` is the only way a version leaves the site, and it is changed in a reviewed pull request.
- Between two prunes the site holds the newest version that was published when the plan was made plus every version
  published since: after a release, the previous version stays until the next prune.

## Doing it

```sh
sh scripts/prune-plan.sh --size     # how many package files and bytes the site has now
sh scripts/prune-plan.sh            # the plan: what would leave and how much that frees; writes nothing
sh scripts/prune-plan.sh --write    # write the plan into prune.yaml
git diff prune.yaml                 # read it; the entries say who asked and why
```

Commit `prune.yaml` in a pull request. The next publish applies it: the listed files are left out of the site and
`pkgops repo` rebuilds the catalogs without them.

`KEEP=N` changes the number of versions kept, `SITE=URL` the site that is read, `PKGOPS=path` the binary. The script
needs network (it reads the published index) and `pkgops` on `PATH`, and it never deletes anything. It lists only
versions older than the newest published one. A version that a manifest names stays safe: the publish stops before
signing (`scripts/expect-packages.sh`) when a manifest names a version that is neither on the site nor built now.

## When

The daily update check writes the size of the site into its summary and says so when it is above about 800 MB. Run
`sh scripts/prune-plan.sh --write` after a release has been published, and commit the result. `jailops-client`,
`jailops` and `jailops-backupd` are the large packages (a static Go binary per version and ABI).

## If the site still grows too fast

One version of each package in both ABIs is the floor of the policy. If the site is near the limit with `KEEP=1`, the
package files have to move off Pages (object storage or a server behind `pkg.jailops.net`; the URL that
hosts use does not change, and the signed catalogs verify every package wherever it is served from). That is a hosting
change, not a pruning one.
