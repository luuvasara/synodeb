# Example: Unraid from a USB stick through stage-1 (experimental)

stage-1 boots any Linux kernel and initrd that a `stage2/stage2.conf` names; it does not
have to be Debian. This page is a worked example with a very different system: **Unraid**,
which runs from RAM and keeps its configuration on a FAT USB stick. It was done on a DS2415+
(Intel Atom C2538, GRUB 0.97 DOM) with a DX1215 expansion unit, Unraid 7.3.4.

Why stage-1 is needed for this: the DS2415+ BIOS boots only the DOM (a rear USB stick is
ignored, even one with a copy of the DOM layout), GRUB on the DOM sees only the DOM, and the
DOM (120 MiB) is too small for Unraid. Stage-1 on the DOM can see the rear USB ports and
kexec Unraid's kernel from the stick.

## The stick

A normal Unraid stick (FAT32, label `UNRAID`, made with Unraid's own tool or by hand from the
release zip; check the zip against the checksum on the Unraid download page). Add one
directory, `stage2/`, with this `stage2.conf`:

```sh
# stage-1 boot config for an Unraid stick: <stick>/stage2/stage2.conf
# paths are relative to the stick; Unraid updates replace bzimage/bzroot in place
KERNEL=bzimage
INITRD=bzroot
CMDLINE="initrd=/bzroot console=tty0 console=ttyS0,115200n8 panic=10"
```

What Unraid needs on its command line:

- `initrd=/bzroot`: as Unraid's own `syslinux.cfg` passes it (not tried without it);
- `console=ttyS0,115200n8`: the rear serial port of the DS2415+, so the boot can be followed
  (the NAS has no screen); `console=tty0` is harmless;
- `panic=10`: a kernel panic reboots instead of hanging, back into stage-1.

Nothing else: Unraid finds its flash by the `UNRAID` label, checks its `bz*` files and starts
from RAM. No write to the DOM or to the disks is needed to boot it.

With a DX1215 attached, see [DX1215](#dx1215-expansion-unit) below for one more parameter.

## Boot

With stage-1 on the DOM (`stage1/install-dom.sh`, see `stage1/README.md`), the stick in a rear
USB port and the default order `usb,disks,dsm`:

```
stage1: boot order: usb disks dsm
stage1: stage-2 on sdc1: bzimage bzroot
```

Measured on the unit (serial console timestamps):

| | time |
|---|---|
| stage-1 picks the stick | 1 s after `boot order` |
| Unraid finds its flash, DX1215 attached, stock Unraid kernel | about 4 min after stage-1 (one boot) |
| Unraid login prompt, same setup | about 5 to 5.5 min (two boots) |
| Unraid `Run /init`, DX1215 attached, with `libata.force=...norst` | 103 s (200 s without) |
| Debian instead, stick present but `stage2/` renamed | 12 s after `boot order` (the 10 s USB wait) |

The web UI answered (HTTP 302 to the registration page) and Unraid's trial licence started
normally although Unraid was started by kexec and not by syslinux (only that was tried).

## Switching back

- **Back to Debian (or whatever is on the disks):** rename `stage2/` on the stick to
  `stage2.off` (on any computer, or from Unraid: `/boot/stage2`) and reboot. stage-1 boots a
  stick only when it has `stage2/stage2.conf`.
- **Unraid again:** rename it back.
- `stage1.order=disks,dsm` on the stage-1 entry leaves sticks out of the boot order.

## Caveats found on the way

- **No serial login.** Unraid has no getty on the serial port, only on a monitor and
  keyboard. With SSH still off on a fresh stick the first boot cannot be reached at all. A
  respawning `agetty` on `ttyS0` started from the stick's `config/go` gives a login prompt on
  the serial console. Without a login, magic SysRq over the serial line (BREAK, then `s`,
  `u`, `b`) still syncs and reboots, back into stage-1.
- **Placeholder MACs.** The four onboard NICs of the DS2415+ carry Intel's placeholder MAC
  (`00:a0:c9:00:00:00` to `:03`); DSM sets the real ones at boot from the DOM's `vender` file.
  Any other system comes up with the placeholders, so two such units clash on one LAN and a
  DHCP server may give a different lease than it gives Debian (seen: a different address for
  the same MAC, because the client id differs). Unraid needs a fix for this after boot (we do
  it in a separately hosted Unraid plugin, see below).
- **RAM.** Unraid runs from RAM. The test unit has 16 GB; the stock DS2415+ has 2 GB, which
  will be tight (not tried).

### DX1215 expansion unit

Each Marvell 88SM9705 port multiplier in the DX1215 reports 6 ports under Linux (DSM shows 5).
Port 5 is the enclosure-management (SEMB) device and never answers a soft reset, so libata's
error handling retries it for about a minute per round and every disk on the host waits.
Measured with one disk inside and one in the DX1215: the internal disk appeared at 200.6 s.

- synodeb's kernel can carry a quirk for this (`kernel/patches/0008-ata-libata-pmp-disable-SEMB-port-on-Marvell-88SM9705.patch`, proposed separately):
  the internal disk at 18.6 s, the DX1215 disk at 21.3 s. stage-1 built with `PMP_QUIRK=1`
  has it too.
- Unraid's kernel does not, and its libata is built in (not a module), so it cannot be
  swapped. A command-line workaround halves the wait: tell libata not to soft-reset link 5
  of each port multiplier. On the DS2415+ the DX1215 hangs off ata19 to ata22:

  ```sh
  CMDLINE="initrd=/bzroot console=tty0 console=ttyS0,115200n8 panic=10 libata.force=19.05:norst,20.05:norst,21.05:norst,22.05:norst"
  ```

  Measured: four `ataN.05: FORCE: link flag 0x6 forced` lines, `Run /init` at 103 s instead of
  200 s. It stops only the soft reset; the hard reset of port 5 is still tried. The port
  numbers depend on the unit: take them from the `ataNN.05` lines in `dmesg`. The obvious
  `libata.force=NN.05:disable` does nothing (it applies after IDENTIFY, which port 5 never
  reaches).

## Completing it: hardware support on Unraid

Booting is all stage-1 does. The DS2415+ and DX1215 hardware (front-panel microcontroller,
fans, MACs, the DX1215 fans and alarms, bay LEDs) is handled on Unraid by two Unraid plugins
that we maintain and host separately
(https://github.com/luuvasara/unraid-synology-hardware and
https://github.com/luuvasara/unraid-synology-expansion); they are not part of synodeb and are
not proposed for it.
