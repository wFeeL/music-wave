#!/usr/bin/env bash
set -euo pipefail

podman run --rm -v "$PWD":/src:Z -w /src docker.io/library/swift:6.3-noble swift test --scratch-path .build/linux "$@"
