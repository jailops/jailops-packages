#!/bin/sh
# sh tests/run.sh: offline tests of which packages are built (test-changed.sh), of the baseline cache (test-baseline.sh) and of the update check (fake GitHub API, no network, no secrets) and a Go YAML parse of the
# workflows. Needs jq, python3 (the fake API server) and go with gopkg.in/yaml.v3 in the module cache (GOPROXY=off).
set -eu
cd "$(dirname "$0")"
sh test-updates.sh
(cd yamlcheck && GOFLAGS=-mod=mod GOPROXY=off go run . ../../.github/workflows/*.yml)
sh test-baseline.sh
sh test-changed.sh
