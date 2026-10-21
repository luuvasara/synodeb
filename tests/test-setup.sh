#!/bin/bash
# Runs synodeb-setup.sh against a copy of a DOM image (loop devices), in a privileged
# debian:trixie container; see run-test-setup.sh.
#   OUT=1      saves the DOM right after 'install' to /out.img (for the VM test)
#   CAPTURE=1  writes terminal captures for the README to /captures
#   NET, REPO  --network and --repo of the first install
#   DOWNLOAD=1 the first install downloads the installer (published release) instead of --local
set -euo pipefail
W=/work
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq fdisk e2fsprogs dosfstools iproute2 util-linux curl ca-certificates >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod -m 660 /dev/loop$i b 7 $i; done
T=/tmp/dom
mkdir -p $T/bk $T/b
cp /dom.img $T/dom.img
part() { sfdisk -d $T/dom.img 2>/dev/null | awk -F'[=,]' -v n="$1" '/start=/{ if (++i == n) { gsub(/ /, ""); print $2, $4 } }'; }
read -r s1 z1 < <(part 1)
read -r s2 z2 < <(part 2)
SYNOBOOT=$(losetup -f --show $T/dom.img)
SYNOBOOT1=$(losetup -f --show -o $((s1 * 512)) --sizelimit $((z1 * 512)) $T/dom.img)
SYNOBOOT2=$(losetup -f --show -o $((s2 * 512)) --sizelimit $((z2 * 512)) $T/dom.img)
export SYNOBOOT SYNOBOOT1 SYNOBOOT2 SYNODEB_TEST=1
trap 'losetup -d $SYNOBOOT $SYNOBOOT1 $SYNOBOOT2' EXIT
S="bash $W/synodeb-setup.sh"
INST=$W/build/out/installer
cd $T/bk
ok() { echo "== OK: $*"; }
conf_sha() { # sha256 of SynoBootLoader.conf in a FAT image
    mount -o loop,ro "$1" $T/b && sha256sum $T/b/EFI/boot/SynoBootLoader.conf | cut -c1-64; umount $T/b
}

$S status
$S install --yes --network "${NET:-dhcp}" --hostname nas --lang en ${DOWNLOAD:---local $INST} ${REPO:+--repo "$REPO"} | tee $T/install.out
grep -q 'Password:' $T/install.out && ok install
$S status | tee $T/st
grep -q 'INSTALLER   <- default' $T/st && ok "INSTALLER default"
if [ -n "${OUT:-}" ]; then cp $T/dom.img /out.img; ok "DOM saved"; fi
$S boot dsm && $S status > $T/st && grep -q 'SYNOLOGY_2   <- default' $T/st && ok "boot dsm"
! $S boot debian 2>/dev/null && ok "boot debian refused without Debian"
$S cancel && $S status > $T/st && ! grep -q -e INSTALLER -e 'synodeb:' $T/st && ok cancel
$S install --yes --network dsm --local $INST >/dev/null && ok "install again (static)"
dd if="$SYNOBOOT1" bs=64k 2>/dev/null | grep -a -o 'netcfg/get_ipaddress=[^ ]*' | head -1
$S uninstall --yes
dd if="$SYNOBOOT1" of=$T/p1.img bs=64k 2>/dev/null
dd if=/dom.img of=$T/o1.img bs=512 skip="$s1" count="$z1" 2>/dev/null
[ "$(conf_sha $T/p1.img)" = "$(conf_sha $T/o1.img)" ] && ok "uninstall gives the original conf"
b=$(ls $T/bk/synodeb-dom-backup-*.img | head -1)
$S restore "$b" --yes && [ "$(sha256sum < "$SYNOBOOT" | cut -c1-64)" = "$(sha256sum < /dom.img | cut -c1-64)" ] &&
    ok "restore = original image"

# terminal captures for the README
if [ -n "${CAPTURE:-}" ]; then
    printf '4\nq\n' | script -qc "bash $W/synodeb-setup.sh" /dev/null > /captures/menu.txt 2>&1 || true
    printf '\n\nen\nyes\n' | script -qc "bash $W/synodeb-setup.sh install --hostname nas --local $INST" /dev/null > /captures/install.txt 2>&1
    $S status > /captures/status.txt 2>&1
    bash $W/synodeb-setup.sh --help > /captures/help.txt 2>&1
fi
