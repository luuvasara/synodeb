#!/bin/bash
# tests/stage1/run-test-stage1.sh: QEMU boot tests of build/out/stage1 (build it first with
# stage1/run-build.sh); console logs go to build/stage1-test
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/build/stage1-test"
kvm=(); [ -e /dev/kvm ] && kvm=(--device /dev/kvm)
exec docker run --rm --privileged "${kvm[@]}" -v "$ROOT":/work -v "$ROOT/build/stage1-test":/out debian:trixie bash /work/tests/stage1/test-stage1.sh
