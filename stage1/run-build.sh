#!/bin/bash
# Runs build-stage1.sh in a Debian trixie container with the project mounted on /work
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec docker run --rm -e PMP_QUIRK -v "$ROOT":/work -w /work debian:trixie bash /work/stage1/build-stage1.sh
