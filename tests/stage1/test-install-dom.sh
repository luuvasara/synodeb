#!/bin/bash
# stage1/install-dom.sh against a synthetic GRUB 0.97 DOM (the DS2415+ layout: MBR, two FAT16
# partitions, menu.lst-style SynoBootLoader.conf, no Synology files). Privileged debian:trixie
# container: docker run --rm --privileged -v "$PWD":/work debian:trixie bash /work/tests/stage1/test-install-dom.sh
set -euo pipefail
W=/work
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq fdisk dosfstools util-linux >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod -m 660 /dev/loop$i b 7 $i; done
T=$(mktemp -d); mkdir -p $T/m $T/s1 $T/bk
trap 'umount $T/m 2>/dev/null || true; blockdev --setrw $DOM $P1 $P2 2>/dev/null || true; losetup -d $DOM $P1 $P2 2>/dev/null || true' EXIT
I=$T/dom.img
truncate -s $((245760 * 512)) $I
printf 'label: dos\nstart=63, size=32067, type=83, bootable\nstart=32130, size=192780, type=83\n' | sfdisk -q $I
export DOM=$(losetup -f --show $I)
export P1=$(losetup -f --show -o $((63 * 512)) --sizelimit $((32067 * 512)) $I)
export P2=$(losetup -f --show -o $((32130 * 512)) --sizelimit $((192780 * 512)) $I)
blockdev --setrw $DOM $P1 $P2
mkfs.vfat -F 16 -n SYNOBOOT1 $P1 >/dev/null; mkfs.vfat -F 16 -n SYNOBOOT2 $P2 >/dev/null
mount $P1 $T/m; mkdir -p $T/m/EFI/boot
cat > $T/m/EFI/boot/SynoBootLoader.conf <<'EOT'
serial --unit=1 --speed=115200
terminal serial
default 1
timeout 3
fallback 0
verbose
hiddenmenu

title SYNOLOGY_1
	root (hd0,0)
	kernel /zImage root=/dev/md0 ihd_num=0 netif_num=4 syno_hw_version=DS2415+
	initrd /rd.gz

title SYNOLOGY_2
	root (hd0,1)
	cksum /grub_cksum.syno
	vender /vender show
	kernel /zImage root=/dev/md0 ihd_num=0 netif_num=4 syno_hw_version=DS2415+
	initrd /rd.gz
EOT
cp $T/m/EFI/boot/SynoBootLoader.conf $T/orig.conf; umount $T/m
mount $P2 $T/m; head -c 1M /dev/zero > $T/m/zImage; head -c 1M /dev/zero > $T/m/rd.gz; umount $T/m
head -c 3M /dev/urandom > $T/s1/vmlinuz; head -c 2M /dev/urandom > $T/s1/initrd.gz
orig=$(sha256sum < $I)
S="sh $W/stage1/install-dom.sh"
n=0
ok() { echo "== OK: $*"; n=$((n + 1)); }
cd $T/bk
$S install $T/s1 >/dev/null && ok install
$S status | tee $T/st
grep -q 'STAGE1   <- default' $T/st && ok "STAGE1 default"
mount -o ro $P1 $T/m; C=$T/m/EFI/boot/SynoBootLoader.conf
grep -qx 'default 2' $C && grep -qx 'fallback 1' $C && ok "default 2, fallback 1 (SYNOLOGY_2)"
grep -q 'kernel /stage1/vmlinuz console=ttyS0,115200n8 panic=10 quiet noefi' $C && ok "entry text"
cmp -s <(sed '/^### synodeb begin/,$d; s/^default 2$/default 1/; s/^fallback 1$/fallback 0/' $C) $T/orig.conf &&
    ok "Synology entries unchanged"
umount $T/m
mount -o ro $P2 $T/m; cmp -s $T/m/stage1/vmlinuz $T/s1/vmlinuz && cmp -s $T/m/stage1/initrd.gz $T/s1/initrd.gz && ok "stage-1 files"; umount $T/m
[ "$(blockdev --getro $P1)" = 1 ] && ok "partitions read-only after the write"
$S default dsm >/dev/null && $S status | grep -q 'SYNOLOGY_2   <- default' && ok "default dsm"
$S default stage1 >/dev/null && $S status | grep -q 'STAGE1   <- default' && ok "default stage1"
$S install $T/s1 >/dev/null && [ "$($S status | grep -c STAGE1)" = 1 ] && ok "install again: one entry"
$S remove >/dev/null && ok remove
mount -o ro $P1 $T/m; cmp -s $T/m/EFI/boot/SynoBootLoader.conf $T/orig.conf && ok "remove gives the original conf"
umount $T/m
mount -o ro $P2 $T/m; [ ! -e $T/m/stage1 ] && ok "remove deletes /stage1"; umount $T/m
ls $T/bk/synodeb-dom-backup-*.img >/dev/null && ok "backups made"
b=$(ls $T/bk/synodeb-dom-backup-*.img | head -1)
[ "$(sha256sum < "$b")" = "$orig" ] && ok "first backup = original DOM"
echo "passed $n of 15"
[ $n = 15 ]
