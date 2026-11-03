# The baseline cache

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

## Verified against the signing key

The index (`pkgops-index.json`) is not signed, and the publish job signs new catalogs over the baseline. So before
anything is fetched, `scripts/baseline.sh` downloads the site's public key (`jailops.pub`) and accepts it only when its
sha256 is the one committed in `KEY_FINGERPRINT`; `pkgops fetch --pubkey` then verifies both signed catalogs of every ABI
with it and refuses the baseline when the index does not match them: a package changed together with its index hash, a
package or version the signed catalog does not advertise, a newer version than the signed one, a prune that would make
an unsigned version the newest. The run stops in the baseline step; in the publish job that is before the key is written
(docs/supply-chain.md). `tests/test-baseline.sh` has the cases, including that acceptance test.

- **First publish**: there is no key and no index on the site; `first_run` stays the explicit, logged way to start
  from nothing. A site without `jailops.pub` is never used as a baseline, only the archive.
- **Key rotation**: the site is still signed with the old key during the first publish with the new one. Set
  `BASELINE_KEY_FINGERPRINT` (the old fingerprint) in the workflow for that one run, then remove it.
- **Older versions are not signed**: pkg's catalog lists only the newest version of each package, so the older ones
  are checked against the index only, as before. They are never advertised or signed by the next run. The publish job
  compares the baseline with the GitHub Releases archive (`pkgops verify-archive`) before the key is written, which
  catches a changed older file as long as the archive is intact.
- **Rollback**: the catalogs carry no signed serial or date. An older signed catalog served next to the current index
  is refused (the index then lists versions above the signed ones). A complete older snapshot of the site verifies;
  then every package whose current version is missing is rebuilt from `main/` (only the published index decides what
  is built), and in the publish job `verify-archive` stops the run, since the archive holds versions the snapshot lacks.
- **The archive** is not signed either; it is trusted as far as this GitHub repository is.
- A signed index (history and a serial covered by the key) is a design note in PkgOps `docs/hosting.md`, "Verified
  baseline"; it needs a change of what pkgops signs.

Where it lives: `scripts/baseline.sh` (`--refresh-cache SITE` rewrites the cache from a final site), the `actions/cache/restore@v4` steps and the single `actions/cache/save@v4` step in `.github/workflows/build-and-publish.yml`, and the checks in `scripts/check-pkgops.sh`.
