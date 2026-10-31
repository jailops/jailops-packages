## What changes

<!-- One or two sentences. Adding or changing an app? Use the new-app template instead: add
     ?template=new-app.md to the compare page URL (see CONTRIBUTING.md). -->

## Checks

- [ ] the version of every changed package was raised (`scripts/bump-version.sh`, or by hand for `jailops-apps`)
- [ ] `sh scripts/check-pkgops.sh` passes
- [ ] for a change of the app catalog: `sh scripts/validate-apps.sh` passes
