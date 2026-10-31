# Contributing an app

The application catalog of JailOps is the directory `main/jailops-apps/apps/` of this repository: one YAML definition
per app (`NAME.yaml`) and its icon (`NAME.svg` or `NAME.png`). It is released as the signed package `jailops-apps`,
with a version of its own, so a new app reaches hosts with one pull request here and no JailOps release.

The format, the rules and how an installation works are in `docs/apps.md` of the JailOps repository; its section
**Write your own app** is the long form of this page. Other packages of this repository (not apps) are described in
[docs/ADD-A-PACKAGE.md](docs/ADD-A-PACKAGE.md).

## The short way

You need the `jailops` client (`pkg install -r jailops jailops-client`, see [README.md](README.md)) and, to try the
app, a FreeBSD 15.1 or later host that runs JailOps. Writing and validating a definition needs no server, no network
and no root.

1. **Fork** this repository and make a branch.
2. **Start the definition**, in one of two ways:
   - from nothing, prefilled from what you know:

     ```sh
     sh scripts/new-app.sh memcached --package memcached --service memcached --port 11211/tcp --category database
     ```

     This runs `jailops app new NAME --dir main/jailops-apps/apps ...`, which writes `NAME.yaml` (every section
     present, with short comments on what it does and the usual traps) and a placeholder `NAME.svg`;
   - or from a jail where you already made the software work by hand:

     ```sh
     jailops app export JAIL -o main/jailops-apps/apps/NAME.yaml
     ```

     It drafts a definition from the running jail: the packages you installed, the services enabled in `rc.conf`
     and their settings, the listening ports, the volumes, the names of the configuration files and logs. It never
     copies the content of a configuration file. Add an icon yourself (`jailops app new` writes a placeholder).
3. **Edit** the file. Every `TODO` marks something only you can write (the summary, the description, the health
   check, the notes...). Then check it:

   ```sh
   jailops app validate main/jailops-apps/apps/NAME.yaml
   ```

   It runs the daemon's own parser and validator and prints every problem as `FILE: reason`, and every `TODO` left
   as `FILE: line N: replace TODO`. It exits 0 only when nothing is left.
4. **Try it on a host.** Copy `NAME.yaml` and `NAME.svg` into `/usr/local/etc/jailops/apps/` (`apps.local_dir` of
   `jailopsd.yaml`; readable by the user `jailops`). The daemon reads that directory next to the packaged catalog, so
   at once:

   ```sh
   jailops app list --source local
   jailops app install NAME
   ```

   A local definition wins over a packaged one of the same name; `jailops app list` shows it with the source
   `local`. Iterate: fix the file, `jailops delete NAME`, `jailops app install NAME` again, until the installation
   passes its health check and the notes are right. Remove your local copy afterwards, or it keeps hiding the
   packaged one.
5. **Raise the version** of the catalog in `main/jailops-apps/pkgops.yaml`, by hand: a **minor** bump for an added
   app (`0.4.0` to `0.5.0`), a **patch** bump for a changed one (`0.4.0` to `0.4.1`). A published version is never
   rebuilt, so a change without a new version is refused by `scripts/check-pkgops.sh`.
6. **Validate the whole catalog** the way CI does (it builds the client of the JailOps release this repository
   packages; `JAILOPS=$(command -v jailops)` uses yours instead):

   ```sh
   sh scripts/validate-apps.sh
   sh scripts/check-pkgops.sh
   ```

7. **Open the pull request** with the *new app* template
   (`?template=new-app.md` on the compare page) and tick its checklist. Say what you tested and on which release.

CI runs the same validator on every pull request that changes the catalog, before it builds `jailops-apps`. A
definition must be valid for the daemon hosts actually run: one that needs a newer JailOps (a new key or category)
waits for that release.

## Review checklist

A reviewer goes through this list; the pull request template has it as checkboxes.

- **License.** `license:` names the license of the software, and it is a free software license.
- **The package exists** in the FreeBSD quarterly repository for 15.1 on amd64 and aarch64 (`pkg search`), or in the
  `jailops` repository (`repo: jailops`). `version:` of each package is the one you tested.
- **No secrets.** Nothing in the definition is a password, key or token, and the setup generates none: what needs one
  is a `config` file the person edits, and `notes` says so.
- **No network at install.** Setup commands never download anything (no `fetch`, no `git clone`, no `curl`); all the
  software comes from packages.
- **Ports declared honestly**: every port the services listen on, with the right `proto`; a port bound to localhost
  only says so in its description. `expose: true` only for what is meant to be reached from outside.
- **Data volumes for all state.** Every directory the app writes its state to is under `data:`, so it is snapshotted,
  backed up and kept across upgrades; nothing important is left in the jail root.
- **Ownership.** `pkg -r` installs from the host, where the package's own user does not exist: the directories a
  package gives to its user come out root-owned, and the data volumes start root-owned. The setup gives them to the
  right user (`mkdir -p` first for a directory that may not exist, then `chown`).
- **Health.** A `health` check that proves the service answers (`tcp`, `http` or `exec`), or the reason it has none
  stated in the description or notes (for example: no service is started until the operator configures it).
- **Notes** give the first-run steps: how to connect, what to edit first, which service to restart.
- **Tested** on FreeBSD 15.1 or later with `jailops app install` from the local directory; the pull request says what
  was tested (installed, health check passed, a client connected...).
- **Icon**: `NAME.svg` or `NAME.png` next to the definition and named in `icon:`, at most 64 KB; an SVG must be an SVG
  document (it starts with `<`), a PNG a PNG image. Simple and readable at 24 pixels; the neutral placeholder of
  `jailops app new` is acceptable.
- `jailops app validate` and `sh scripts/validate-apps.sh` pass, and `version:` of `main/jailops-apps/pkgops.yaml` was
  raised.

## Quality bar

An app in the catalog installs with one command on a fresh host and runs without a manual step, or, when it cannot
(it needs a database, a domain, a secret), says exactly which steps remain in its `notes`. It does one thing: one
definition, one jail, no dependency on another app. Its comments and texts are plain English, short, and say what
the reader needs, not how the definition was written. It uses the software's own defaults where they are safe, binds
to localhost what should not be reachable until configured, and states that in the description.

Changes to an existing app follow the same list; a change of behaviour (a new port, a new path, another package)
says so in the pull request, because installed jails keep what they were installed with.

## Featured apps

There is no `featured` key in the format. *Featured* is an editorial choice of the maintainers: an app the project
names first in the documentation and the catalog's description (today `isms`, the platform's own information
security management system). An app is a candidate when it is maintained, installs and passes its health check in the
FreeBSD end-to-end test of JailOps (`JAILOPS_E2E_APPS`), has complete first-run notes, and is useful to many
operators. Ask for it in the pull request; the maintainers decide.
