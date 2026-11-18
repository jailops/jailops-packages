# CI supply chain and the signing key

What the workflows may do, where the signing key is, what the YAML enforces, and what only the GitHub settings can
enforce. `scripts/check-pkgops.sh` checks the YAML rules below on every push and pull request (`tests/test-workflow.sh`
tests the checks).

## The publish job, in order

`build-and-publish.yml`, job `publish` (master only, environment `signing`):

1. checkout (`persist-credentials: false`), install the pinned pkgops (`.github/actions/setup-pkgops`);
2. download the built packages (`actions/download-artifact`) and check them against the build records
   (`scripts/verify-build-record.sh`: every file is in a record with the size and sha256 it had when it was built, from
   this commit, at the version of its manifest), restore the baseline cache (`actions/cache/restore`);
3. `scripts/baseline.sh`: the published site's public key is accepted only with the sha256 in `KEY_FINGERPRINT`, and
   `pkgops fetch --pubkey` verifies the site's signed catalogs before it takes anything (docs/BASELINE-CACHE.md);
4. `pkgops verify-archive`: the baseline agrees with the GitHub Releases archive (older versions, which no signature
   covers, and versions that were published and are now missing);
   `scripts/expect-packages.sh`: every package of `main/`, at its version, for every ABI, is in the baseline or was built
   now, and a file built now has the bytes of the file that is already published;
5. **Sign**: the only step with the key on disk. It writes `$RUNNER_TEMP/pkg-repo.key` with umask 077, runs
   `scripts/site-files.sh` (public key, fingerprint) and `pkgops repo --key`, and removes the key when it ends;
6. **Remove the signing key** (`if: always()`): removes it again, whatever happened;
7. verify the signed repository (`scripts/verify-site.sh` with `VERIFY_SITE_STRICT=1`: a package that is not ready is
   a failure too), write `versions.json` from the verified catalogs (informational, unsigned; never an
   input of a later run: README, "versions.json"), archive push, refresh the cache, upload the Pages artifact, save
   the cache.

`check-pkgops.sh` fails when anything of steps 1 to 4 comes after the key is written, when the step after signing is
not an `if: always()` removal of `pkg-repo.key`, when `secrets.PKG_REPO_KEY` appears anywhere else, and when the job
holding it can run for a pull request.

Removing a file on the runner's disk is best effort (`shred` cannot promise much on a journaling or copy-on-write file
system); the runner is a fresh VM per job and is discarded after it.

## Permissions

`permissions: {}` at the top of `build-and-publish.yml`; each job names its own:

| job | permissions | secrets |
|---|---|---|
| `build` | `contents: read` | none |
| `build-private` | `contents: read` | `JAILOPS_SOURCE_TOKEN` (environment `source`, master only) |
| `publish` | `contents: write` (one release per package version) | `PKG_REPO_KEY` (environment `signing`) |
| `deploy` | `pages: write`, `id-token: write` | none |

`check-updates.yml` already sets its permissions per job.

## Actions in use

Every action is pinned to a full commit SHA, GitHub's own included, with the version it was at in a comment:
`actions/checkout`, `actions/setup-go`, `actions/setup-node`, `actions/cache/restore`, `actions/cache/save`,
`actions/upload-artifact`, `actions/download-artifact`, `actions/upload-pages-artifact`, `actions/deploy-pages`, plus the
local `./.github/actions/setup-pkgops` (no pin needed). A tag can be moved by whoever owns the action; a SHA cannot.
`scripts/check-actions-pinned.sh` fails on any action that is not pinned: `ACTIONS_PIN_ENFORCE: "1"` in the workflow-level
`env:` makes it fail; `"0"` would only warn. To pin one, or to move a pin to a newer release:

```sh
gh api repos/OWNER/REPO/commits/TAG --jq .sha          # the commit the tag points at (annotated tags resolved)
gh api --paginate repos/OWNER/REPO/tags --jq '.[] | select(.commit.sha == "SHA") | .name'   # its version tags
git ls-remote https://github.com/OWNER/REPO 'refs/tags/TAG' 'refs/tags/TAG^{}'                # cross-check
```

and write `uses: OWNER/REPO@<40-hex SHA>   # vX.Y.Z`.

### pkgops itself

The publish job runs pkgops with the key. `PKGOPS_VERSION` pins it to a release tag, and the release archive is checked
against that release's `checksums.txt`: both come from the same place, so the tag is the trust. For a pin that cannot
move, put the commit in `PKGOPS_VERSION` (`setup-pkgops` then builds pkgops from that commit):

```sh
gh api repos/jailops/jailops-pkgops/commits/vX.Y.Z --jq .sha > PKGOPS_VERSION
```

**`PKGOPS_VERSION` must name a pkgops release that has `fetch --pubkey`** (the first release after 0.2.0). With an
older one the build job warns (NOT VERIFIED) and the publish job stops in the baseline step, before the key, and
publishes nothing.

## The source token

`JAILOPS_SOURCE_TOKEN` (a private source repository) exists in one job only: `build-private`, for master, with the
Environment `source`. The job a pull request runs (`build`) has no secret and builds the packages whose `upstream.yaml` has
an empty `token_env`; a package with a `token_env` is built by `build-private` on master (a pull request prints a notice
that it was not built). A pull request can change a script and a workflow, so a secret the job could read would be a
secret the pull request could read: only an Environment limited to `master` keeps it out. `build-pkg.sh` runs the prebuild
steps (`npm ci --ignore-scripts`, the web build) and `pkgops build` without the token even there. `token_env` is empty or
`JAILOPS_SOURCE_TOKEN`; the source of `jailops`, which `scripts/validate-apps.sh` builds in `build`, has an empty one.
`check-pkgops.sh` checks all of this. `token_env` must be a plain variable name (`[A-Z_][A-Z0-9_]*`); anything else stops
the run before it is expanded. The checkouts in `check-updates.yml` do not keep the workflow token in `.git`.

## What stays on Pages

The site keeps the newest version of every package, per ABI (`docs/RETENTION.md`). Older versions are listed in
`prune.yaml`, left out of the signed catalogs and no longer served; every one of them stays in the archive in GitHub
Releases, which a prune never touches. The cross-check before the key exists reads `pruned from Pages, still archived`
as normal and fails on `pruned from Pages and not archived`, so a file leaves the site only when the archive holds it.
A pruned version is restored from the archive with `pkgops fetch --from github-releases:OWNER/REPO --into site --prune
prune.yaml` or installed with `pkg add URL`.

## Recovery: the archive is ahead of Pages

The publish job archives every published package before the deploy, from the same bytes. A run that archived and then
did not deploy leaves the archive ahead of the live site, and the next publish stops at "Cross-check the baseline with
the archive" with `archived, not on Pages and not pruned`. That stop is the check working: nothing is signed or
archived by the run that stops. Re-running the old run does not help, because a re-run uses the workflow file of its own
commit.

The signed site of the earlier run is the `github-pages` artifact of that run (it keeps for one day). Deploy it as it is,
then publish again:

    gh api repos/jailops/jailops-packages/actions/runs/RUN/artifacts --jq '.artifacts[] | [.name, .expired] | @tsv'
    gh workflow run build-and-publish.yml -f deploy_run_id=RUN
    gh run watch
    gh workflow run build-and-publish.yml

`deploy_run_id` runs only the job `redeploy`. It accepts a completed push or dispatch run of this workflow on master
whose job `publish` succeeded, and checks out the commit that run was built from: the manifests, `KEY_FINGERPRINT`,
`prune.yaml`, the scripts and the pkgops pin of the verification are those of that commit, because the site is compared with
the repository state it was made from, not with current master. It checks `site/jailops.pub` against `KEY_FINGERPRINT`,
verifies the signed catalogs, the site and the archive, and deploys exactly those bytes: no build, no signing, no key. The check
`scripts/check-pkgops.sh` requires `deploy` to run when `publish` succeeded (`if: always() && needs.publish.result ==
'success'`): a job whose `needs` chain holds a skipped job, here `build-private` without a `token_env`, is skipped
unless it has a status check function.

## What only the GitHub settings can enforce

The YAML cannot prove that any of these exist. Confirm them in the repository settings (or with the commands), and
again after any change of owners or admins:

1. **Environment `signing`** (Settings, Environments):
   - Deployment branches and tags: **Selected branches, `master` only**. Without it, a workflow on any branch that names
     `environment: signing` gets the key.
   - The secret `PKG_REPO_KEY` is here and **not** a repository secret (`gh secret list` must not list it;
     `gh secret list --env signing` must).
   - Required reviewers: optional. With them, every publish waits for an approval (and "Prevent self-review" stops the
     pusher from approving their own run). Without them, anyone who can push to `master` publishes.
   - `gh api repos/jailops/jailops-packages/environments/signing --jq '{protection_rules, deployment_branch_policy}'`
2. **Environment `source`** (only when a package has a `token_env`): deployment branches **`master` only**, and the
   secret `JAILOPS_SOURCE_TOKEN` there with read access to that source repository only, not a repository secret.
   `gh api repos/jailops/jailops-packages/environments/source --jq '{protection_rules, deployment_branch_policy}'`
3. **Environment `github-pages`**: deployment branches `master` only (GitHub creates it with that rule; check it).
4. **`master`**: a branch protection rule or ruleset (no force push, no deletion, pull requests with review if more than
   one person can push). Anyone who can push to `master` can change this workflow and so use the key in the next run;
   the environment rules do not stop that. `gh api repos/jailops/jailops-packages/branches/master/protection` (404: none)
   and `gh api repos/jailops/jailops-packages/rulesets`.
5. **Actions settings**: Workflow permissions "Read repository contents" (the jobs ask for more where they need it);
   fork pull requests need approval before workflows run.
   `gh api repos/jailops/jailops-packages/actions/permissions/workflow`.
6. Who is an admin: admins can change every rule above. Keep that list short.
