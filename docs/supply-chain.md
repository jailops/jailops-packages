# CI supply chain and the signing key

What the workflows may do, where the signing key is, what the YAML enforces, and what only the GitHub settings can
enforce. `scripts/check-pkgops.sh` checks the YAML rules below on every push and pull request (`tests/test-workflow.sh`
tests the checks).

## The publish job, in order

`build-and-publish.yml`, job `publish` (master only, environment `signing`):

1. checkout (`persist-credentials: false`), install the pinned pkgops (`.github/actions/setup-pkgops`);
2. download the built packages (`actions/download-artifact`), restore the baseline cache (`actions/cache/restore`);
3. `scripts/baseline.sh`: the published site's public key is accepted only with the sha256 in `KEY_FINGERPRINT`, and
   `pkgops fetch --pubkey` verifies the site's signed catalogs before it takes anything (docs/BASELINE-CACHE.md);
4. `pkgops verify-archive`: the baseline agrees with the GitHub Releases archive (older versions, which no signature
   covers, and versions that were published and are now missing);
5. **Sign**: the only step with the key on disk. It writes `$RUNNER_TEMP/pkg-repo.key` with umask 077, runs
   `scripts/site-files.sh` (public key, fingerprint) and `pkgops repo --key`, and removes the key when it ends;
6. **Remove the signing key** (`if: always()`): removes it again, whatever happened;
7. verify the signed repository, archive push, refresh the cache, upload the Pages artifact, save the cache.

`check-pkgops.sh` fails when anything of steps 1 to 4 comes after the key is written, when the step after signing is
not an `if: always()` removal of `pkg-repo.key`, when `secrets.PKG_REPO_KEY` appears anywhere else, and when the job
holding it can run for a pull request.

Removing a file on the runner's disk is best effort (`shred` cannot promise much on a journaling or copy-on-write file
system); the runner is a fresh VM per job and is discarded after it.

## Permissions

`permissions: {}` at the top of `build-and-publish.yml`; each job names its own:

| job | permissions | secrets |
|---|---|---|
| `build` | `contents: read` | `JAILOPS_SOURCE_TOKEN` (source download; optional) |
| `publish` | `contents: write` (one release per package version) | `PKG_REPO_KEY` (environment `signing`) |
| `deploy` | `pages: write`, `id-token: write` | none |

`check-updates.yml` already sets its permissions per job.

## Actions in use

All are first party (`actions/*`, GitHub's own) and stay on their major tags:
`actions/checkout`, `actions/setup-go`, `actions/setup-node`, `actions/cache/restore`, `actions/cache/save`,
`actions/upload-artifact`, `actions/download-artifact`, `actions/upload-pages-artifact`, `actions/deploy-pages`, plus the
local `./.github/actions/setup-pkgops`. The majors were not compared with the newest releases when this was written (no
network): `gh api repos/actions/checkout/releases/latest --jq .tag_name`, and so on.

There is no third-party action. `scripts/check-actions-pinned.sh` keeps it that way unless one is pinned to a full
commit SHA: `ACTIONS_PIN_ENFORCE: "1"` in the workflow-level `env:` makes it fail; `"0"` would only warn. To pin one:

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
2. **Environment `github-pages`**: deployment branches `master` only (GitHub creates it with that rule; check it).
3. **`master`**: a branch protection rule or ruleset (no force push, no deletion, pull requests with review if more than
   one person can push). Anyone who can push to `master` can change this workflow and so use the key in the next run;
   the environment rules do not stop that. `gh api repos/jailops/jailops-packages/branches/master/protection` (404: none)
   and `gh api repos/jailops/jailops-packages/rulesets`.
4. **Actions settings**: Workflow permissions "Read repository contents" (the jobs ask for more where they need it);
   fork pull requests need approval before workflows run.
   `gh api repos/jailops/jailops-packages/actions/permissions/workflow`.
5. Who is an admin: admins can change every rule above. Keep that list short.
