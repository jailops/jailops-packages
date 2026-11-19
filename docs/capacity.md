# Capacity: how big the package site is and what to do when it grows

This page answers how much space the package repository uses, how that changes with FreeBSD releases and ABIs, and what to do
when it gets tight. The maintainers of this repository read it. What stays on the site and why is in
[RETENTION.md](RETENTION.md); this page does not repeat it.

## Two places take space

- **The site** at <https://pkg.jailops.net> is a GitHub Pages site. Pages publishes at most about 1 GB, and every publish
  replaces the whole site, so its size is the sum of the package files on it. This is the place with a limit.
- **The archive** in GitHub Releases holds every file ever published (RETENTION.md). It is not the constrained place: it
  holds what left the site and grows with every release.

## Reading the numbers

| What | How | On 2026-11-18 |
|---|---|---|
| The files on the site, from the index | `curl -fsS https://pkg.jailops.net/pkgops-index.json \| python3 -c 'import json,sys; d=json.load(sys.stdin); print(round(sum(p["size"] for p in d["packages"])/1e6), "MB on Pages;", round(sum(p["size"] for p in d["pruned"])/1e6), "MB pruned (archive only)")'` | 245 MB on Pages, 1775 MB pruned |
| The size GitHub measured when it deployed | `gh run view RUN --log \| grep -iE "final size\|successfully uploaded"`: the line of `upload-pages-artifact` says `Final size is N bytes` | 243721569 bytes |
| The whole archive | `gh api --paginate repos/jailops/jailops-packages/releases --jq '.[].assets[].size' \| awk '{s+=$1} END {printf "%.0f MB\n", s/1e6}'` | 2020 MB |
| The site while a run builds it | the `publish` job prints `site size: N MB` (`scripts/check-site-size.sh`) | |
| A look from the daily check | the summary of the daily update check shows the size and says so above about 800 MB | |

The index lists two arrays: `packages` is what the site serves, `pruned` is what left it and is only in the archive. Summing
both gives the archive, which is why a sum over the whole file is not the size of the site.

## Planning

**The site grows with the number of ABIs and packages, not with the number of releases.** Two versions of every package stay
(RETENTION.md), so a release replaces the oldest kept version. Between the release and the next prune the site holds one
more version: the archive grew from 1946 MB to 2020 MB with jailops 0.8.6, about 75 MB for the three large packages in both
ABIs.

    site size ~ number of ABIs x the size of the files one ABI keeps (the newest two versions of every package)

One ABI keeps about 129 MB for `FreeBSD:15:amd64` and 116 MB for `FreeBSD:15:aarch64`: 13 files each, 245 MB together. The three large
packages are `jailops`, `jailops-client` and `jailops-backupd`, a static Go binary per version and ABI.

| Case | Site | |
|---|---|---|
| `FreeBSD:15` only (two ABIs) | about 245 MB | measured |
| `FreeBSD:15` and `FreeBSD:16` (four ABIs) | about 490 MB | estimate: twice the above |
| Three majors at once (six ABIs) | about 735 MB | estimate; above the warning below |

A third major is not expected to be on the site at once: the old major leaves when FreeBSD ends its support
([release-engineering.md in jailops](https://github.com/jailops/jailops/blob/master/docs/release-engineering.md)).

## Thresholds

| Size | What happens |
|---|---|
| 700 MB | the `publish` job writes a warning (`::warning title=The site is getting big`) |
| about 800 MB | the daily update check says so in its summary |
| 900 MB | the `publish` job fails before anything is archived or deployed, and lists the ten largest packages |
| about 1 GB | the limit of GitHub Pages; a deploy above it can fail, and the upload of the artifact warns when it is over |

## When it gets tight, in this order

KEEP stays at two: it is what keeps a host that is one release behind working (RETENTION.md, "What a host sees"). Nothing
lowers it by itself.

1. **Read the numbers** above and `sh scripts/prune-plan.sh --size`. The large packages are the three of jailops.
2. **Take out an ABI that FreeBSD no longer supports.** Remove it from `abis:` in `pkgops-repo.yaml`. Its files stay in the
   archive. Announce it first: hosts on that ABI stop getting updates. Untried: check after the deploy with the commands
   above that the site no longer holds the ABI.
3. **Ask whether a package needs both ABIs.** A package that nobody installs on one architecture does not have to be built
   for it.
4. **Split a package that carries data next to its binary.** A new binary release then publishes the binary again and the
   data once.
5. **Move the package files off Pages.** The plan below.

## The fallback: object storage behind the same URL

**This is a plan. Nothing of it is built, and nothing of it is needed at the current size**, a quarter of the limit.

Hosts keep `https://pkg.jailops.net/${ABI}/latest`. The files move to an S3-compatible bucket (Hetzner Object Storage,
Backblaze B2 or similar), served through a CDN or a reverse proxy that answers for `pkg.jailops.net`. It is a hosting
change, not a change of the repository.

**Trust does not move.** The catalog is signed with the repository key (`/jailops.pub`, whose fingerprint is in the README),
and `pkg` checks the signature of the catalog and the checksum of every package against it. The storage and the CDN carry
bytes and need not be trusted.

What changes in the workflow:

- `publish` uploads the site tree to the bucket instead of handing it to Pages. The order is: the package files first (they
  are new names and never change), the catalogs and the index last, so that no catalog names a file that is not there. A
  run that stops half way leaves package files that no catalog names, which do no harm and can be removed.
- The `deploy` job goes away, or deploys only the small files (the index and the key) when Pages stays for them.
- The baseline and the cross-check with the archive read the same URL as today (`SITE_URL`).
- `verify-site.sh`, `expect-packages.sh`, `verify-archive.sh`, the dependency check and the rule that a package never
  vanishes run on the assembled tree before anything is uploaded, as they do now. The archive in Releases stays.
- The 900 MB gate has a different reason once the limit of Pages is gone: set it from what the bucket should cost.

Risks:

- **The upload is not atomic.** Pages switches a deployment as a whole; a bucket is written file by file. The order above
  covers it.
- **Caching.** The catalog keeps `max-age=600` as it has today, so a host sees a new catalog within ten minutes. Package
  files never change and can be cached for long.
- **A credential.** The workflow needs a key that can write to one bucket. Keep it in the `signing` environment with the
  other secrets ([supply-chain.md](supply-chain.md)), limited to that bucket.
- **Egress.** Every install and upgrade downloads packages: the traffic is the size of the packages times the installs.
  That number decides the cost, and nothing here measures it today.

Prices as read on the providers' pages on 2026-11-19. They change; read the pages before deciding.

| Provider | Storage | Egress | Requests |
|---|---|---|---|
| [Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/) | EUR 6.49 a month excluding VAT, with 1 TB of storage included | 1 TB included; the page prices more per hour and per TB: read it | S3 calls (PUT, GET, DELETE) are free, by the page |
| [Backblaze B2](https://www.backblaze.com/cloud-storage/pricing) | from USD 6.95 per TB a month; the first 10 GB are free | free up to 3 times the stored data, then USD 0.01 per GB | classes A, B and C are free on pay-as-you-go; class D is USD 0.004 per 10,000 after 2,500 a day |

**When to do it:** when the site is above 700 MB on an ordinary run after steps 2 to 4, or when a FreeBSD major would
otherwise force removing an ABI that hosts still use.
