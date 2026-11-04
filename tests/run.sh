#!/bin/sh
# sh tests/run.sh: offline tests of which packages are built (test-changed.sh), of a package with source: local
# (test-local.sh), of scripts/new-app.sh (test-new-app.sh), of versions.json (test-versions-index.sh), of the baseline cache and its verification against the signing
# key (test-baseline.sh), of the workflow rules and action pins (test-workflow.sh) and of the update check (fake GitHub API,
# no network, no secrets) and a Go YAML parse of the workflows. Needs jq, python3 (the fake API server) and go with gopkg.in/yaml.v3 in the module cache (GOPROXY=off).
set -eu
cd "$(dirname "$0")"
sh test-updates.sh
(cd yamlcheck && GOFLAGS=-mod=mod GOPROXY=off go run . ../../.github/workflows/*.yml)
sh test-versions-index.sh
sh test-baseline.sh
sh test-changed.sh
sh test-local.sh
sh test-new-app.sh
sh test-workflow.sh
