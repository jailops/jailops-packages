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

Where it lives: `scripts/baseline.sh` (`--refresh-cache SITE` rewrites the cache from a final site), the `actions/cache/restore@v4` steps and the single `actions/cache/save@v4` step in `.github/workflows/build-and-publish.yml`, and the checks in `scripts/check-pkgops.sh`.
