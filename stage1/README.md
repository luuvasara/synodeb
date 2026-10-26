# stage-1: a kexec boot that never writes the DOM (experimental)

The DS923+ boot copies every new kernel and initrd to the DOM. stage-1 is a different boot
path for models whose DOM is small or worn, or where its writes should be kept to a
minimum: a small, rarely changed kernel and initrd go on the DOM **once**, and at every boot
they find the real system on the disks (or on a USB stick) and start it with `kexec`.
Kernel updates then only write the disks.

Status: experimental. Developed and tested on a DS2415+ (Intel Atom C2538, GRUB 0.97 DOM)
with a DX1215 expansion unit; the DS923+ boot is not changed by anything here.

## How it boots

```
BIOS -> Synology GRUB (DOM) -> stage-1 kernel + initrd (DOM, read only)
     -> kexec -> the first stage-2 found: USB stick, then the disks, then DSM
```

A **stage-2** is any filesystem with `stage2/stage2.conf`:

```sh
KERNEL=stage2/vmlinuz
INITRD=stage2/initrd.img
CMDLINE="root=UUID=... ro console=ttyS0,115200n8 panic=10"
```

Paths are relative to that filesystem. The file is read, not run. For Debian it lives in
`/boot/stage2/` (on a separate `/boot`, so the path in the filesystem is `stage2/`); for a
USB stick at the top of the stick.

Order and waits (kernel command line of the stage-1 entry):

| parameter | default | |
|---|---|---|
| `stage1.order=` | `usb,disks,dsm` | sources in this order |
| `stage1.usbwait=` | `10` | seconds a USB stick gets before the disks are tried |
| `stage1.settle=` | `30` | seconds the disks get (md arrays, slow expansion units) |
| `stage1.dom=` | `f400:f400` | USB vendor:product of the DOM |
| `stage1.mcu=` | (none) | tty of the front-panel microcontroller, e.g. `ttyS1`: status LED green, orange when nothing is found |
| `stage1.shell` | | a shell on the console after the scan, instead of booting |

The loop polls once a second and boots the first source that is there: a stick with a
`stage2.conf` boots within a second or two, Debian on the disks once the USB wait is over.
To stop booting a stick, rename its `stage2/` directory (e.g. to `stage2.off`); the next boot
starts the disks again. Nothing found: a shell on the console, status LED orange.

Safety rules in `init`:

- **The DOM is never written.** It is found by its USB ID and set read-only in the kernel
  (`blockdev --setro`, disk and partitions) before anything is mounted, and it is never a
  stage-2 source.
- **Everything is mounted read-only** (`ro,noload` for ext4, so not even the journal is
  replayed).
- **md arrays are assembled read-only and degraded** (`mdadm --assemble --scan --run
  --readonly`): a missing disk or a switched-off expansion unit does not block the boot.
- **md members are never mounted.** With metadata 0.90 or 1.0 (superblock at the end) the
  filesystem is visible on each member too; a device with holders is skipped.

## DSM as the last resort

`dsm` in the order boots DSM's own kernel and ramdisk from the DOM by kexec, when nothing
else was found. It needs two things, both learnt the hard way:

- **stage-1 must run with `noefi`.** DSM's 3.10 kernel dies in `efi_init` (an early page
  fault, the CPU halts, `panic=` cannot help) when kexec hands it EFI state. With `noefi` the
  running kernel has no EFI runtime services, and `kexec -s` (kexec_file) then builds
  `boot_params` without `efi_info`; ACPI is passed as `acpi_rsdp=` (the `ACPI20=` value of
  `/sys/firmware/efi/systab`). Without `noefi` the leg is skipped with a message. Debian and
  Unraid run normally after a `noefi` stage-1.
- **The disks must hold a DSM system.** DSM's installer takes partitions 1 and 2 of every disk
  as its system and swap arrays and formats them, whatever is there. So the leg runs only if
  partition 1 of some disk carries an md 0.90 superblock (64 KiB-aligned at its end; magic
  `a92b4efc` in either byte order, DSM writes it big-endian on some platforms); otherwise
  stage-1 says `no DSM system on the disks; DSM not started (its installer would format them)`.

The DSM command line is the `kernel` line of the `SYNOLOGY_2` entry of a GRUB 0.97
`SynoBootLoader.conf` (partition from its `root (hd0,N)`), plus what GRUB's `vender /vender
show` adds (`macs=`, `sn=`, decoded from the DOM's `vender` file with the DS2415+ layout),
plus `acpi_rsdp=`. On a GRUB2 DOM (DS923+) the entry is not found and the leg is skipped.

## Build and test

```sh
stage1/run-build.sh                 # build/out/stage1: vmlinuz, initrd.gz, VERSION, SHA256SUMS
PMP_QUIRK=1 stage1/run-build.sh     # with libata.ko rebuilt with kernel/patches/*libata-pmp*
tests/stage1/run-test-stage1.sh     # boots it in QEMU against disk and USB-stick images
```

The kernel is Debian trixie's own (`linux-image-amd64`), unchanged. The initrd is busybox,
`kexec` and `mdadm` with the modules in `stage1/modules`. Fixes found on the hardware that
are built in: no `busybox -> busybox` self-link (it made `/init` fail with ELOOP and the
kernel panic), `/sbin/modprobe` present (ext4 asks for `crc32c` through it), modules
decompressed (busybox modprobe loads only plain `.ko`), `/run` present (mdadm's map file),
`TERM=dumb` (busybox ash otherwise waits for a cursor-position reply on the serial console).
