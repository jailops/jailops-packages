# Contributing

A new package or a fix to one is one pull request. [docs/ADD-A-PACKAGE.md](docs/ADD-A-PACKAGE.md) has the steps and the
format of `main/NAME/pkgops.yaml` and `main/NAME/upstream.yaml`; [README.md](README.md) explains the build and publish
workflow.

Before you open the pull request:

- `sh scripts/check-pkgops.sh` passes (manifests, policy, workflows; `sh scripts/check-pkgops.sh BASE_REF` also checks
  that the version of every changed package was raised: a published version is immutable);
- `sh tests/run.sh` passes when you touched `scripts/`, `tests/` or `.github/`;
- the package builds locally (`sh scripts/build-pkg.sh NAME`) and installs on a FreeBSD 15.1 or later host.
