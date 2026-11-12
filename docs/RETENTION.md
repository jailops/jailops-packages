# Retention: what stays on the site

The site, <https://pkg.jailops.net>, is a GitHub Pages site, and Pages publishes at most about 1 GB. Every publish
deploys the whole site again, so its size is the sum of every package file that has not been pruned.

## The policy

**The newest three versions of every package, per ABI, stay on the site. Older versions leave it.**

- Three covers the current version, the one before it (to go back to after a bad release) and one more.
- Leaving the site is not deleting: every package that was ever published is in the archive in GitHub Releases
  (`pkgops archive push` runs in every publish). Pruning never touches the archive. Only `pkgops archive prune`
  deletes from it, and it needs a typed confirmation.
- A pruned version is no longer in the catalog that `pkg update` reads, and its file is no longer served. A host that
  needs it installs the file from the archive with `pkg add URL`.
- `prune.yaml` is the only way a version leaves the site, and it is changed in a reviewed pull request.

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
needs network (it reads the published index) and `pkgops` on `PATH`, and it never deletes anything.

## When

Run `scripts/prune-plan.sh --size` before a release bump. Prune when the site is above about 800 MB, or when a publish
fails because the artifact is too large. `jailops-client`, `jailops` and `jailops-backupd` are the large packages (a
static Go binary per version and ABI).

## If the site still grows too fast

Three versions of the large packages in both ABIs is the floor of the policy. If the site is near the limit with
`KEEP=3`, the package files have to move off Pages (object storage or a server behind `pkg.jailops.net`; the URL that
hosts use does not change, and the signed catalogs verify every package wherever it is served from). That is a hosting
change, not a pruning one.
