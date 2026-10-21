#!/bin/bash
# Turns a DOM written by synodeb-setup.sh into the DOM of the test VM (in a container):
# GRUB and kernel console on the emulated 16550 (ttyS0) instead of the DS923+ MMIO UART,
# SynoBootLoader.efi also as the removable-media boot file and a startup.nsh for OVMF,
# and extra kernel parameters for the INSTALLER entry ($EXTRA).
set -euo pipefail
apt-get update -qq && apt-get install -y -qq mtools fdisk >/dev/null
I=/dom.img
OFF=$(( $(sfdisk -d $I 2>/dev/null | awk -F'[=,]' '/start=/{print $2; exit}') * 512 ))
mtype -i $I@@$OFF ::/EFI/boot/SynoBootLoader.conf > /tmp/conf
sed -i -e 's/^syno_serial .*/serial --unit=0 --speed=115200/' \
       -e 's/console=uart8250,mmio32,0xfedc9000,115200n8/console=ttyS0,115200n8/' /tmp/conf
[ -z "${EXTRA:-}" ] || sed -i "/menuentry \"INSTALLER\"/,/^}/ s|^\( *linux .*\)$|\1 $EXTRA|" /tmp/conf
mcopy -o -i $I@@$OFF /tmp/conf ::/EFI/boot/SynoBootLoader.conf
mmd -i $I@@$OFF ::/EFI/BOOT 2>/dev/null || true
mcopy -o -i $I@@$OFF ::/EFI/boot/SynoBootLoader.efi /tmp/boot.efi 2>/dev/null || mtype -i $I@@$OFF ::/EFI/boot/SynoBootLoader.efi > /tmp/boot.efi
mcopy -o -i $I@@$OFF /tmp/boot.efi ::/EFI/BOOT/BOOTX64.EFI
printf 'fs0:\r\n\\EFI\\boot\\SynoBootLoader.efi\r\n' > /tmp/startup.nsh
mcopy -o -i $I@@$OFF /tmp/startup.nsh ::/startup.nsh
cat /tmp/conf
