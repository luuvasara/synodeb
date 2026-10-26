#!/bin/sh
# install-dom.sh (experimental) — put stage-1 on a DOM whose Synology boot loader is GRUB 0.97
# (menu.lst syntax: `title`, `default N`, `fallback N`, `root (hd0,N)`), as on the DS2415+.
# Runs as root on Linux on the NAS (not on DSM).
#
#   install-dom.sh install DIR [--cmdline "..."]   copy DIR/vmlinuz and DIR/initrd.gz to
#                                  synoboot2:/stage1, add the STAGE1 entry, make it the
#                                  default and SYNOLOGY_2 the fallback
#   install-dom.sh default stage1|dsm
#   install-dom.sh remove          remove the entry and /stage1; DSM boots
#   install-dom.sh status
#
# The DOM is found by its USB ID (default f400:f400). A backup of the whole DOM is made
# first; each partition is copied, the copy is changed and checked, written back with dd and
# read back. Between writes the DOM stays read-only in the kernel (blockdev --setro).
set -eu
DOM_ID=${DOM_ID:-f400:f400}
CONF_REL=EFI/boot/SynoBootLoader.conf
TITLE=STAGE1
BEGIN='### synodeb begin'
END='### synodeb end'
# console of the DS2415+ (rear DB-9, ttyS0); noefi: needed by the DSM leg of stage-1
CMDLINE="console=ttyS0,115200n8 panic=10 quiet noefi stage1.mcu=ttyS1"

die() { echo "install-dom: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
dsha() { dd if="$1" bs=64k 2>/dev/null | sha256sum | cut -d' ' -f1; }

find_dom() { # -> DOM=/dev/sdX (overridable for tests: DOM=/dev/loopN P1=... P2=...)
    [ -n "${DOM:-}" ] && return
    for b in /sys/block/sd*; do
        d=$(readlink -f "$b/device") || continue
        while [ -n "$d" ] && [ "$d" != /sys ]; do
            if [ -f "$d/idVendor" ]; then
                [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$DOM_ID" ] && DOM=/dev/${b##*/}
                break
            fi
            d=${d%/*}
        done
    done
    [ -n "${DOM:-}" ] || die "no DOM (USB $DOM_ID) found"
}
T=
cleanup() {
    [ -n "$T" ] || return 0
    umount "$T/m" 2>/dev/null || true
    rm -rf "$T"
    for p in "$DOM" "$P1" "$P2"; do blockdev --setro "$p" 2>/dev/null || true; done
}
setup() {
    [ "$(id -u)" = 0 ] || die "run as root"
    find_dom
    P1=${P1:-${DOM}1} P2=${P2:-${DOM}2}
    for p in "$P1" "$P2"; do
        [ -b "$p" ] || die "$p not found"
        ! grep -q "^$p " /proc/mounts || die "$p is mounted: stopping"
    done
    T=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    mkdir "$T/m"
}
grab() { # partition -> copy mounted on $T/m
    dd if="$1" of="$T/p.img" bs=64k 2>/dev/null || die "reading $1 failed"
    [ "$(sha "$T/p.img")" = "$(dsha "$1")" ] || die "reading $1 twice gave different data: stopping"
    mount -t vfat -o loop "$T/p.img" "$T/m" || die "mounting the copy of $1 failed (FAT expected)"
}
put() { # partition: write the changed copy back and read it back
    sync; umount "$T/m"
    if command -v fsck.vfat >/dev/null 2>&1; then
        fsck.vfat -n "$T/p.img" >/dev/null 2>&1 || die "the changed copy of $1 does not pass fsck.vfat: DOM unchanged"
    fi
    blockdev --setrw "$DOM" "$1" 2>/dev/null || true
    dd if="$T/p.img" of="$1" bs=64k conv=fsync 2>/dev/null || die "writing $1 failed: restore the backup"
    sync; blockdev --flushbufs "$1" 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    blockdev --setro "$DOM" "$1" 2>/dev/null || true
    [ "$(dsha "$1")" = "$(sha "$T/p.img")" ] || die "$1 does not read back as written: restore the backup"
}
backup() {
    B=${BACKUP_DIR:-$PWD}/synodeb-dom-backup-$(date +%Y%m%d-%H%M%S).img
    dd if="$DOM" of="$B" bs=64k 2>/dev/null || die "DOM backup failed"
    [ "$(sha "$B")" = "$(dsha "$DOM")" ] || die "the DOM backup does not match a second read: stopping"
    sha "$B" > "$B.sha256"; chmod 600 "$B" "$B.sha256"
    echo "DOM backup: $B (copy it off the NAS)"
}

# menu.lst helpers. Entries are counted from 0 in the order of their `title` lines; an entry
# runs until the next `title`, a synodeb marker or the end of the file.
entry() { awk -v t="$2" '/^[[:space:]]*title[[:space:]]/ { if ($2 == t) { print n; exit } n++ }' "$1"; }
check_conf() {
    [ -f "$1" ] || die "$CONF_REL missing on the DOM"
    grep -q '^[[:space:]]*default[[:space:]]' "$1" || die "unexpected $CONF_REL (no 'default': not GRUB 0.97?)"
    [ -n "$(entry "$1" SYNOLOGY_2)" ] || die "unexpected $CONF_REL (no SYNOLOGY_2 entry)"
}
strip_conf() {
    awk -v b="$BEGIN" -v e="$END" 'index($0, b) == 1 { skip = 1; next } index($0, e) == 1 { skip = 0; next }
        !skip { print }' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
set_line() { # conf keyword value: `default N` / `fallback N`, only if the line exists
    sed "s/^\([[:space:]]*$2\)[[:space:]].*/\1 $3/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

cmd_install() {
    dir=${1:-}
    [ -f "$dir/vmlinuz" ] && [ -f "$dir/initrd.gz" ] || die "usage: $0 install DIR (with vmlinuz, initrd.gz)"
    setup
    backup
    grab "$P1"; check_conf "$T/m/$CONF_REL"; umount "$T/m"
    grab "$P2"
    [ -f "$T/m/zImage" ] && [ -f "$T/m/rd.gz" ] || die "synoboot2 has no zImage/rd.gz: unexpected DOM, stopping"
    rm -rf "$T/m/stage1"
    free=$(df -Pk "$T/m" | awk 'NR == 2 { print $4 }')
    need=$(( ( $(stat -L -c %s "$dir/vmlinuz") + $(stat -L -c %s "$dir/initrd.gz") ) / 1024 + 1024 ))
    [ "$free" -ge "$need" ] || die "not enough space on synoboot2 ($need KB needed, $free KB free): DOM unchanged"
    mkdir "$T/m/stage1"
    cp "$dir/vmlinuz" "$dir/initrd.gz" "$T/m/stage1/"
    for f in vmlinuz initrd.gz; do [ "$(sha "$T/m/stage1/$f")" = "$(sha "$dir/$f")" ] || die "copy of $f is wrong"; done
    put "$P2"
    grab "$P1"
    C=$T/m/$CONF_REL
    [ -f "$C.dsm" ] || cp "$C" "$C.dsm"   # the original, once
    { strip_conf "$C"
      echo "$BEGIN (written by install-dom.sh)"
      printf 'title %s\n\troot (hd0,1)\n\tvender /vender show\n\tkernel /stage1/vmlinuz %s\n\tinitrd /stage1/initrd.gz\n' \
          "$TITLE" "$CMDLINE"
      echo "$END"; } > "$C.new"
    set_line "$C.new" default "$(entry "$C.new" $TITLE)"
    set_line "$C.new" fallback "$(entry "$C.new" SYNOLOGY_2)"
    mv "$C.new" "$C"
    put "$P1"
    echo "Done: $TITLE is the default boot entry, SYNOLOGY_2 the fallback."
}
cmd_default() {
    case "${1:-}" in stage1) t=$TITLE ;; dsm) t=SYNOLOGY_2 ;; *) die "usage: $0 default stage1|dsm" ;; esac
    setup
    grab "$P1"
    C=$T/m/$CONF_REL
    check_conf "$C"
    n=$(entry "$C" $t); [ -n "$n" ] || die "no $t entry"
    set_line "$C" default "$n"
    put "$P1"
    echo "Default boot entry: $t"
}
cmd_remove() {
    setup
    backup
    grab "$P1"
    C=$T/m/$CONF_REL
    check_conf "$C"
    if [ -f "$C.dsm" ]; then mv "$C.dsm" "$C"; else strip_conf "$C" > "$C.new"; mv "$C.new" "$C"; fi
    set_line "$C" default "$(entry "$C" SYNOLOGY_2)"
    put "$P1"
    grab "$P2"; rm -rf "$T/m/stage1"; put "$P2"
    echo "Done: stage-1 removed, DSM boots."
}
cmd_status() {
    setup
    grab "$P1"
    C=$T/m/$CONF_REL
    d=$(sed -n 's/^[[:space:]]*default[[:space:]]*\([0-9]*\).*/\1/p' "$C" | head -n 1)
    echo "DOM: $DOM"
    awk -v d="$d" '/^[[:space:]]*title[[:space:]]/ { printf "  %d %s%s\n", n, $2, (n == d ? "   <- default" : ""); n++ }' "$C"
    umount "$T/m"
}

cmd=${1:-}; [ $# = 0 ] || shift
dir=
while [ $# -gt 0 ]; do
    case "$1" in
    --cmdline) CMDLINE=${2:-}; shift ;;
    -*) die "unknown option $1" ;;
    *) dir=$1 ;;
    esac
    shift
done
case "$cmd" in
install) cmd_install "$dir" ;;
default) cmd_default "$dir" ;;
remove) cmd_remove ;;
status) cmd_status ;;
*) sed -n '2,14p' "$0"; exit 1 ;;
esac
