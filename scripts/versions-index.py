#!/usr/bin/env python3
"""versions-index.py SITE_DIR

Writes SITE_DIR/versions.json: the newest version of every package of the repository, per ABI and across ABIs, for
web pages and scripts that want to show "the current version" (jailops.net reads it). It is INFORMATIONAL and NOT
SIGNED: pkg(8) never reads it, and nothing in this repository decides anything from it (baseline.sh, changed.sh and
verify-site.sh read pkgops-index.json and the signed catalogs; check-pkgops.sh keeps it that way).

Source: the repository's own catalog, SITE_DIR/<ABI>/latest/packagesite.pkg (a tar archive, zstd-compressed by
pkgops, holding packagesite.yaml: one JSON object per package, the newest version of each name). The publish job runs
this right after `pkgops verify --pubkey` has verified those catalogs, so every value here comes from a signed
catalog. Every entry must also be in SITE_DIR/pkgops-index.json (so it names a file that is on the site), or this
fails. Unpacking needs a tar that reads the archive's compression (GNU tar with zstd on the runner); TAR overrides.

Schema 1 (README.md, "versions.json"):
  {"schema": 1, "generated_at": "2026-11-04T12:00:00Z", "repository": "https://pkg.jailops.net/${ABI}/latest",
   "abis": ["FreeBSD:15:aarch64", "FreeBSD:15:amd64"],
   "packages": {"isms": {"version": "0.9.0", "origin": "jailops/isms", "comment": "...", "www": "https://...",
                         "abis": {"FreeBSD:15:aarch64": "0.9.0", "FreeBSD:15:amd64": "0.9.0"}}}}
"version" is the highest version across the ABIs (pkg's order: epoch, then the version, then the _revision); "abis"
of a package lists only the ABIs that have it. SOURCE_DATE_EPOCH fixes generated_at (tests).
"""
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

SCHEMA = 1
REPOSITORY = "https://pkg.jailops.net/${ABI}/latest"
ABI_RE = re.compile(r"FreeBSD:[0-9]+:[a-z0-9_]+")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
VERSION_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_,-]*")


def die(msg):
    print(f"error: versions-index: {msg}", file=sys.stderr)
    sys.exit(1)


def vkey(v):
    """Sort key of a pkg version: the ,epoch first, then the version by components (numbers by value, a number above
    a word), then the _revision. Enough for the versions this repository publishes (N.N.N, N.N.N_N)."""
    main, _, epoch = v.partition(",")
    main, _, rev = main.partition("_")
    parts = []
    for tok in re.findall(r"[0-9]+|[A-Za-z]+", main):
        parts.append((1, int(tok), "") if tok.isdigit() else (0, 0, tok.lower()))
    return (int(epoch) if epoch.isdigit() else 0, parts, int(rev) if rev.isdigit() else 0)


def catalog(path):
    """The entries of packagesite.yaml inside a packagesite.pkg."""
    tar = os.environ.get("TAR", "tar")
    try:
        r = subprocess.run([tar, "-xOf", str(path), "packagesite.yaml"], capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        die(f"cannot run {tar} on {path}: {e}")
    if r.returncode:
        die(f"cannot unpack packagesite.yaml from {path} (a tar with zstd is needed): {r.stderr.decode(errors='replace').strip()[:300]}")
    out = []
    for n, line in enumerate(r.stdout.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            e = json.loads(line)
        except ValueError as err:
            die(f"{path}: packagesite.yaml line {n} is not JSON: {err}")
        if not isinstance(e, dict) or not isinstance(e.get("name"), str) or not isinstance(e.get("version"), str):
            die(f"{path}: packagesite.yaml line {n} has no name or version")
        if not NAME_RE.fullmatch(e["name"]) or not VERSION_RE.fullmatch(e["version"]):
            die(f"{path}: packagesite.yaml line {n}: unexpected name or version {e['name']!r} {e['version']!r}")
        out.append(e)
    return out


def build(site):
    site = pathlib.Path(site)
    idx = site / "pkgops-index.json"
    if not idx.is_file():
        die(f"{site} has no pkgops-index.json")
    try:
        listed = {(p["abi"], p["name"], p["version"]) for p in json.loads(idx.read_text(encoding="utf-8"))["packages"]}
    except (ValueError, KeyError, TypeError) as e:
        die(f"{idx} is not a pkgops index: {e}")
    abis = sorted(d.name for d in site.iterdir() if d.is_dir() and ABI_RE.fullmatch(d.name))
    if not abis:
        die(f"{site} has no <ABI>/ directories")
    pkgs = {}
    for abi in abis:
        ps = site / abi / "latest" / "packagesite.pkg"
        if not ps.is_file():
            die(f"{ps} is missing")
        seen = set()
        for e in catalog(ps):
            name, ver = e["name"], e["version"]
            if name in seen:
                die(f"{ps}: {name} is listed twice")
            seen.add(name)
            if (abi, name, ver) not in listed:
                die(f"{ps}: {name} {ver} is not in pkgops-index.json")
            p = pkgs.setdefault(name, {"abis": {}})
            p["abis"][abi] = ver
            if "version" not in p or vkey(ver) > vkey(p["version"]):
                p.update(version=ver, origin=str(e.get("origin", "")), comment=str(e.get("comment", "")), www=str(e.get("www", "")))
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    now = datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc) if epoch else datetime.datetime.now(datetime.timezone.utc)
    return {
        "schema": SCHEMA,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repository": REPOSITORY,
        "abis": abis,
        "packages": {n: {k: pkgs[n][k] for k in ("version", "origin", "comment", "www", "abis")} for n in sorted(pkgs)},
    }


def main():
    if len(sys.argv) != 2:
        die("usage: versions-index.py SITE_DIR")
    data = build(sys.argv[1])
    out = pathlib.Path(sys.argv[1]) / "versions.json"
    tmp = out.with_name(".versions.json.tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(out)
    print(f"versions.json: {len(data['packages'])} packages, ABIs {', '.join(data['abis'])}: "
          + ", ".join(f"{n} {p['version']}" for n, p in data["packages"].items()))


if __name__ == "__main__":
    main()
