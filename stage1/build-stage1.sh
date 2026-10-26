#!/bin/bash
# Builds stage-1 (experimental): Debian trixie's own kernel and a small busybox initrd with
# kexec and mdadm. Stage-1 goes on the DOM once; it finds the real system on the disks (or
# on a USB stick) and kexecs into it, so kernel updates never write the DOM (see
# stage1/README.md). Runs in a debian:trixie container (see run-build.sh).
# Output in build/out/stage1: vmlinuz, initrd.gz, VERSION, SHA256SUMS.
#   PMP_QUIRK=1  rebuild libata.ko with kernel/patches/*libata-pmp*.patch (Debian ships libata
#                as a module, so the kernel image stays Debian's signed one)
set -euo pipefail
W=/work
DEST=$W/build/out/stage1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends linux-image-amd64 busybox-static kexec-tools mdadm kmod \
    cpio gzip xz-utils >/dev/null
KV=$(ls /lib/modules | head -n 1)
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT
mkdir -p "$R"/{bin,sbin,etc,proc,sys,dev,mnt,run,lib/modules}

# busybox applets; not busybox itself: a busybox -> busybox link makes /init fail with ELOOP
cp /bin/busybox "$R/bin/"
for a in $(/bin/busybox --list | grep -vx busybox); do ln -sf busybox "$R/bin/$a"; done
# the kernel runs /sbin/modprobe for request_module(), e.g. ext4 asking for crc32c
ln -s ../bin/busybox "$R/sbin/modprobe"
for x in /sbin/kexec /sbin/mdadm; do
    cp "$x" "$R/sbin/"
    for l in $(ldd "$x" | grep -o '/[^ ]*'); do mkdir -p "$R$(dirname "$l")"; cp -L "$l" "$R$l"; done
done
for m in $(cat $W/stage1/modules); do
    for f in $(modprobe -S "$KV" -D "$m" 2>/dev/null | awk '/^insmod/ { print $2 }'); do
        mkdir -p "$R$(dirname "$f")"; cp "$f" "$R$f"
    done
done
cp /lib/modules/"$KV"/modules.{order,builtin,builtin.modinfo} "$R/lib/modules/$KV/"
find "$R/lib/modules" -name '*.ko.xz' -exec xz -d {} +   # busybox modprobe loads only plain .ko

if [ "${PMP_QUIRK:-0}" = 1 ]; then
    apt-get install -y -qq --no-install-recommends linux-headers-amd64 linux-source gcc make patch \
        bc libelf-dev >/dev/null
    S=$(mktemp -d)
    tar -C "$S" -xf /usr/src/linux-source-*.tar.xz --wildcards '*/drivers/ata' '*/drivers/scsi'
    cd "$S"/linux-source-*
    for p in $W/kernel/patches/*libata-pmp*.patch; do patch -p1 < "$p"; done
    make -s -C /lib/modules/"$KV"/build M="$PWD/drivers/ata" modules -j"$(nproc)" >/dev/null
    strip --strip-debug drivers/ata/libata.ko
    cp drivers/ata/libata.ko "$R/lib/modules/$KV/kernel/drivers/ata/libata.ko"
    cd /
fi
depmod -b "$R" "$KV"
cp $W/stage1/modules "$R/etc/modules"
install -m 755 $W/stage1/init "$R/init"

# smoke test: the shell, kexec, mdadm and the modules must work inside the tree
chroot "$R" /bin/sh -c 'kexec --version && mdadm --version && ls /lib/modules/*/kernel/drivers/ata/ahci.ko /lib/modules/*/modules.dep && echo initrd-ok' ||
    { echo "stage-1 smoke test failed" >&2; exit 1; }

mkdir -p "$DEST"
(cd "$R" && find . | cpio -o -H newc --quiet | gzip -9) > "$DEST/initrd.gz"
cp /boot/vmlinuz-"$KV" "$DEST/vmlinuz"
echo "$KV" > "$DEST/VERSION"
(cd "$DEST" && sha256sum vmlinuz initrd.gz > SHA256SUMS)
ls -l "$DEST"
