#!/bin/bash
# Boots build/out/stage1 in QEMU against disk and USB-stick images and checks which stage-2
# it starts; runs in a privileged debian:trixie container (see run-test-stage1.sh).
# Stage-2 is the same kernel with a tiny initrd that prints "STAGE2 <mark>" and powers off.
set -euo pipefail
W=/work
S1=$W/build/out/stage1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends qemu-system-x86 busybox-static cpio gzip fdisk \
    e2fsprogs dosfstools mdadm util-linux >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod -m 660 /dev/loop$i b 7 $i; done
T=$(mktemp -d)
LOOPS=
cleanup() { umount $T/m 2>/dev/null || true; for l in $LOOPS; do losetup -d $l 2>/dev/null || true; done; }
trap cleanup EXIT
mkdir -p $T/m $T/r/bin

# stage-2 initrd
cp /bin/busybox $T/r/bin/
cat > $T/r/init <<'EOF'
#!/bin/busybox sh
/bin/busybox mkdir -p /proc; /bin/busybox mount -t proc proc /proc
for a in $(/bin/busybox cat /proc/cmdline); do case $a in mark=*) echo "STAGE2 ${a#mark=}" ;; esac; done
/bin/busybox poweroff -f
EOF
chmod 755 $T/r/init
(cd $T/r && find . | cpio -o -H newc --quiet | gzip) > $T/s2.gz

ploop() { # image partition-number -> $PL, loop device of that partition
    read -r st sz < <(sfdisk -d "$1" 2>/dev/null | awk -F'[=,]' -v n="$2" '/start=/{ if (++i == n) { gsub(/ /, ""); print $2, $4 } }')
    PL=$(losetup -f --show -o $((st * 512)) --sizelimit $((sz * 512)) "$1"); LOOPS="$LOOPS $PL"
    blockdev --setrw $PL   # a loop device can keep the read-only flag of an earlier user
}
stage2() { # mountpoint mark
    mkdir -p "$1/stage2"
    cp $S1/vmlinuz "$1/stage2/vmlinuz"; cp $T/s2.gz "$1/stage2/initrd.gz"
    printf 'KERNEL=stage2/vmlinuz\nINITRD=stage2/initrd.gz\nCMDLINE="console=ttyS0 panic=-1 mark=%s"\n' "$2" > "$1/stage2/stage2.conf"
}

# disk: p1 md RAID1 (metadata 1.0, one member) with ext4 and stage-2 "md"; p2 empty.
# The array is created by the stage-1 kernel itself in a first QEMU run (the host kernel may
# write superblock fields an older kernel refuses); with metadata 1.0 the filesystem starts
# at the beginning of the member, so the host then writes it through the member, below the
# superblock, without assembling the array.
truncate -s 160M $T/disk.img
printf 'label: gpt\nsize=64MiB\nsize=64MiB\n' | sfdisk -q $T/disk.img
mkdir -p $T/p/bin
cat > $T/p/prep <<'EOF2'
#!/bin/sh
export PATH=/bin:/sbin
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
for m in ahci sd_mod md_mod raid1; do modprobe $m; done; sleep 2
mdadm --create /dev/md0 --run --force --level=1 --raid-devices=1 --metadata=1.0 /dev/sda1 && mdadm --stop /dev/md0 && echo PREP-OK
poweroff -f
EOF2
chmod 755 $T/p/prep
(cd $T/p && echo prep | cpio -o -H newc --quiet | gzip) | cat $S1/initrd.gz - > $T/prep.gz
timeout 300 qemu-system-x86_64 -accel kvm -accel tcg -m 1024 -cpu max -nographic -no-reboot \
    -kernel $S1/vmlinuz -initrd $T/prep.gz -append "console=ttyS0 panic=-1 rdinit=/prep" \
    -drive if=none,id=d0,format=raw,file=$T/disk.img -device ahci,id=ahci -device ide-hd,drive=d0,bus=ahci.0 \
    < /dev/null > $T/prep.log 2>&1 || true
grep -q PREP-OK $T/prep.log || { echo "creating the md array in QEMU failed"; tail -20 $T/prep.log; exit 1; }
ploop $T/disk.img 1; L=$PL
used=$(mdadm --examine $L | awk '/Used Dev Size/ { print $5 }')
losetup -d $L
read -r st sz < <(sfdisk -d $T/disk.img 2>/dev/null | awk -F'[=,]' '/start=/{ gsub(/ /, ""); print $2, $4; exit }')
L=$(losetup -f --show -o $((st * 512)) --sizelimit $((used * 512)) $T/disk.img); LOOPS="$LOOPS $L"; blockdev --setrw $L
mkfs.ext4 -q $L
mount $L $T/m && stage2 $T/m md && umount $T/m
losetup -d $L
# a second disk whose partition 1 carries a DSM-style md 0.90 superblock (big-endian magic)
truncate -s 80M $T/dsm.img
printf 'label: dos\nsize=64MiB\n' | sfdisk -q $T/dsm.img
ploop $T/dsm.img 1; D=$PL
sec=$(blockdev --getsz $D)
printf '\xa9\x2b\x4e\xfc' | dd of=$D bs=4096 seek=$(( (sec / 128 * 128 - 128) / 8 )) conv=notrunc 2>/dev/null
for l in $LOOPS; do losetup -d $l 2>/dev/null || true; done; LOOPS=

# USB stick: FAT with stage-2 "usb"
mkstick() { # stage2 dir name
    rm -f $T/stick.img; truncate -s 64M $T/stick.img
    printf 'label: dos\ntype=c\n' | sfdisk -q $T/stick.img
    ploop $T/stick.img 1; L=$PL
    mkfs.vfat -n STICK $L >/dev/null
    mount $L $T/m && stage2 $T/m usb
    [ "$1" = stage2 ] || mv $T/m/stage2 "$T/m/$1"
    umount $T/m; losetup -d $L
}

pass=0 fail=0
run() { # name expect cmdline-extra [stick]; runs that end in the stage-1 shell time out
    name=$1 expect=$2 extra=$3 limit=300
    case $expect in STAGE2*) ;; *) limit=60 ;; esac
    usb=(); [ -n "${4:-}" ] && usb=(-device qemu-xhci -drive "if=none,id=s,format=raw,file=$T/stick.img" -device "usb-storage,drive=s")
    timeout $limit qemu-system-x86_64 -accel kvm -accel tcg -m 1024 -cpu max -nographic -no-reboot \
        -kernel $S1/vmlinuz -initrd $S1/initrd.gz \
        -append "console=ttyS0 panic=-1 stage1.usbwait=6 stage1.settle=12 $extra" \
        -device ahci,id=ahci -drive if=none,id=d0,format=raw,file=$T/disk.img -device ide-hd,drive=d0,bus=ahci.0 \
        -drive if=none,id=d1,format=raw,file=$T/dsm.img -device ide-hd,drive=d1,bus=ahci.1 \
        "${usb[@]}" < /dev/null > $T/$name.log 2>&1 || true
    if grep -q -- "$expect" $T/$name.log; then echo "== OK: $name ($expect)"; pass=$((pass + 1))
    else echo "== FAIL: $name (no '$expect')"; grep '^stage1:\|STAGE2' $T/$name.log | sed 's/^/   /'; fail=$((fail + 1)); fi
    cp $T/$name.log /out/ 2>/dev/null || true
}

run disks-only 'STAGE2 md' ''
grep -q 'stage-2 on md' $T/disks-only.log && echo "== OK: booted from the md array, not its member" ||
    { echo "== FAIL: not booted from md"; fail=$((fail + 1)); }
mkstick stage2
run stick-wins 'STAGE2 usb' '' stick
run order-disks 'STAGE2 md' 'stage1.order=disks' stick
mkstick stage2.off
run stick-off 'STAGE2 md' '' stick
mkstick stage2
run stick-as-dom 'set read-only' 'stage1.dom=46f4:0001' stick
grep -q 'STAGE2 md' $T/stick-as-dom.log && echo "== OK: a DOM is never a stage-2 source" ||
    { echo "== FAIL: DOM used as a source"; fail=$((fail + 1)); }
run dsm-needs-noefi 'DSM needs stage-1 booted with noefi' 'stage1.order=dsm'
run dsm-guard 'DSM system array on' 'stage1.order=dsm noefi'
# the same disk without the superblock: DSM must not be started
dd if=/dev/zero of=$T/dsm.img bs=1M seek=1 count=64 conv=notrunc 2>/dev/null
run dsm-guard-none 'no DSM system on the disks' 'stage1.order=dsm noefi'
echo "passed $pass, failed $fail"
[ $fail = 0 ]
