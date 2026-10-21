# synodeb installer: helpers shared by early and finish (busybox sh in the installer)

DOM_P1=10EE-589C                               # synoboot1, FAT: EFI/boot/SynoBootLoader.conf
DOM_P2=45e5b07d-4783-4867-a369-f99c0cd1e610    # synoboot2, ext2: kernel + initrd
DOM_MNT=/run/synodeb-dom
LOG=/var/log/synodeb-installer.log

log() { echo "synodeb: $*" >> $LOG; logger -t synodeb -- "$*" 2>/dev/null || true; }

# --- front-panel microcontroller (uP): UART 8250 at MMIO 0xFEDCA000, 9600 8N1 ---
up_dev() {
    for t in /sys/class/tty/ttyS*; do
        b=$(tr a-f A-F < "$t/iomem_base" 2>/dev/null)
        [ "$b" = 0XFEDCA000 ] && { echo "/dev/${t##*/}"; return 0; }
    done
    return 1
}
# up CMD...: '4' power LED on, '9' status LED green blinking, '8' green, ':' orange,
# '2' short beep, '3' long beep, 'V50' fans at 50 %
up() {
    d=$(up_dev) || return 0
    stty -F "$d" 9600 raw -echo 2>/dev/null || true
    for c in "$@"; do printf '%s' "$c" > "$d" 2>/dev/null; sleep 0.3; done
}

# --- DOM ---
dom_mount() { # uuid fstype
    dev=$(blkid -U "$1" 2>/dev/null) || return 1
    mkdir -p $DOM_MNT
    modprobe vfat 2>/dev/null; modprobe nls_cp437 2>/dev/null; modprobe nls_ascii 2>/dev/null
    mount -t "$2" "$dev" $DOM_MNT 2>/dev/null
}
dom_umount() { sync; umount $DOM_MNT 2>/dev/null; }
# make the menu entry titled $1 the default of the DOM GRUB
dom_default() {
    conf=$DOM_MNT/EFI/boot/SynoBootLoader.conf
    dom_mount $DOM_P1 vfat || { log "DOM synoboot1 not found"; return 1; }
    n=0; idx=
    while IFS= read -r l; do
        case "$l" in
        *menuentry\ \"$1\"*) idx=$n; break ;;
        *menuentry\ *) n=$((n + 1)) ;;
        esac
    done < "$conf"
    rc=1
    if [ -n "$idx" ] && sed "s/^set default='[0-9]*'/set default='$idx'/" "$conf" > "$conf.tmp" &&
       grep -q "^set default='$idx'" "$conf.tmp" && mv -f "$conf.tmp" "$conf"; then
        rc=0; log "DOM default entry: $1 ($idx)"
    else
        rm -f "$conf.tmp"; log "could not make $1 the DOM default"
    fi
    dom_umount
    return $rc
}
