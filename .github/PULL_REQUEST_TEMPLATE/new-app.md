## New or changed app

App: `NAME` (main/jailops-apps/apps/NAME.yaml)
Package(s) and version(s) tested:
Tested on: FreeBSD 15.x-RELEASE, amd64 / aarch64
What was tested (installed with `jailops app install`, health check passed, a client connected, ...):

## Checklist (CONTRIBUTING.md)

- [ ] `license:` names the software's free software license
- [ ] every package exists in the FreeBSD quarterly repository for 15.1 (or in the `jailops` repository with `repo: jailops`)
- [ ] no secret in the definition, and the setup generates none (what needs one is a `config` file the notes mention)
- [ ] no network fetch at install: the setup downloads nothing
- [ ] every listening port is declared with the right `proto`; ports bound to localhost say so
- [ ] all state is under `data:` volumes
- [ ] the setup gives the package user's directories and the data volumes their owner (`pkg -r` leaves them root-owned)
- [ ] a `health` check, or the reason there is none stated in the description or notes
- [ ] `notes` give the first-run steps
- [ ] installed and run on FreeBSD 15.1 or later with `jailops app install` from `/usr/local/etc/jailops/apps`
- [ ] icon `NAME.svg` or `NAME.png` next to the definition, named in `icon:`, at most 64 KB
- [ ] no `TODO` left: `jailops app validate main/jailops-apps/apps/NAME.yaml` passes
- [ ] `sh scripts/validate-apps.sh` passes
- [ ] `version:` in `main/jailops-apps/pkgops.yaml` raised (minor for an added app, patch for a changed one)
