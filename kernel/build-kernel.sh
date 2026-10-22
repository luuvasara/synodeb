#!/bin/bash
# Builds vanilla Linux (kernel/VERSION) with the Debian configuration + the DS923+ fragment
# and produces the .deb packages. Runs in a debian:trixie container (see run-build.sh).
set -euo pipefail
# shellcheck source=/dev/null
. /work/kernel/VERSION
VER=$KVER
SRC=/work/build/linux-$VER
OUT=/work/build/out
PKGVER=$KPKGVER
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev \
    dwarves libdw-dev rsync kmod cpio debhelper-compat python3 xz-utils zstd git lsb-release \
    curl gpg gpgv >/dev/null
mkdir -p "$OUT"
# kernel.org tarball, verified with the signed sha256sums.asc (keys of Greg Kroah-Hartman,
# Linus Torvalds and the kernel.org checksum autosigner: kernel/keys/kernel.org.asc)
TB=/work/build/linux-$VER.tar.xz
if [ ! -f "$TB" ]; then
    curl -fsSL -o "$TB.tmp" "https://cdn.kernel.org/pub/linux/kernel/v${VER%%.*}.x/linux-$VER.tar.xz"
    mv "$TB.tmp" "$TB"
fi
curl -fsSL -o /work/build/sha256sums.asc "https://cdn.kernel.org/pub/linux/kernel/v${VER%%.*}.x/sha256sums.asc"
gpg --batch -q --dearmor -o /tmp/kernel.org.gpg < /work/kernel/keys/kernel.org.asc
gpgv --keyring /tmp/kernel.org.gpg /work/build/sha256sums.asc 2>/dev/null || { echo "sha256sums.asc: bad signature" >&2; exit 1; }
want=$(awk -v f="linux-$VER.tar.xz" '$2 == f { print $1 }' /work/build/sha256sums.asc)
[ -n "$want" ] && [ "$(sha256sum "$TB" | cut -d' ' -f1)" = "$want" ] || { echo "$TB: wrong sha256" >&2; exit 1; }
# Sources: a linux-$VER tree under git (commit "vanilla" = the tarball). The patches
# (kernel/patches) are applied again only when they change, after resetting the files
# they touch to vanilla; the new drivers (kernel/src) are copied only when different.
# So make rebuilds only what changed. FULL=1 starts again from the tarball.
export GIT_AUTHOR_NAME=synodeb GIT_AUTHOR_EMAIL=synodeb@localhost
export GIT_COMMITTER_NAME=synodeb GIT_COMMITTER_EMAIL=synodeb@localhost
git config --global --add safe.directory "$SRC"
if [ "${FULL:-0}" = 1 ] || [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    tar -C /work/build -xf /work/build/linux-$VER.tar.xz
    git -C "$SRC" init -q
    git -C "$SRC" add -A
    git -C "$SRC" commit -qm vanilla
fi
cd "$SRC"
STAMP=$(cat /work/kernel/patches/*.patch | sha256sum | cut -d' ' -f1)
if [ "$(cat .synodeb-patches 2>/dev/null)" != "$STAMP" ]; then
    echo "patches changed: touched files reset to vanilla"
    git checkout -q -- .
    for p in /work/kernel/patches/*.patch; do
        echo "patch $(basename "$p")"
        patch -p1 --forward --no-backup-if-mismatch < "$p"
    done
    echo "$STAMP" > .synodeb-patches
else
    echo "patches unchanged"
fi
rsync -rc --itemize-changes /work/kernel/src/ ./
cp /work/kernel/config-debian-7.3-rc7 .config
scripts/kconfig/merge_config.sh -m .config /work/kernel/ds923.config /work/kernel/ds923-slim.config
make olddefconfig
for o in SYNOLOGY_DS923=y LEDS_ATMEGA1608=m RTC_DRV_S35390A=y RTC_DRV_CMOS=m PINCTRL_AMD=y \
         SERIAL_8250_DW=y I2C_DESIGNWARE_PLATFORM=y EFI_VARS_PSTORE_DEFAULT_DISABLE=y \
         ATA_LEDS=y LEDS_TRIGGER_TIMER DEBUG_INFO_NONE; do
    grep -E "^CONFIG_$o" .config || { echo "missing CONFIG_$o"; exit 1; }
done
make -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="$PKGVER" LOCALVERSION="-$ABI-ds923"
[ "$(make -s kernelrelease LOCALVERSION="-$ABI-ds923")" = "$KREL" ] || { echo "kernelrelease is not $KREL" >&2; exit 1; }
rm -f ../linux-image-*-dbg_*.deb
mv ../linux-*.deb "$OUT"/
cp .config "$OUT"/config-$KREL
# Metapackages: always depend on the latest kernel (like linux-image-amd64 in Debian)
for kind in image headers; do
    d=/tmp/meta-$kind
    rm -rf "$d"; mkdir -p "$d/DEBIAN"
    cat > "$d/DEBIAN/control" <<EOT
Package: linux-$kind-ds923
Version: $PKGVER
Architecture: amd64
Maintainer: synodeb <synodeb@users.noreply.github.com>
Depends: linux-$kind-$KREL (= $PKGVER)
Section: kernel
Priority: optional
Description: Linux kernel for the Synology DS923+ ($kind, latest)
 Depends on the latest synodeb kernel $kind package.
EOT
    dpkg-deb --root-owner-group -Zxz -b "$d" "$OUT/linux-$kind-ds923_${PKGVER}_amd64.deb" >/dev/null
done
ls -la "$OUT"
