#!/bin/bash
# Runs build-installer.sh in a Debian trixie container with the project mounted on /work
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec docker run --rm -v "$ROOT":/work -w /work debian:trixie bash /work/installer/build-installer.sh
