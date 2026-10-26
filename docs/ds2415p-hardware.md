# DS2415+ hardware control: design note

Synology DS2415+ (Atom C2538, DSM platform "avoton", 12 bays) with the optional DX1215
expansion unit (12 bays). This note covers the hardware control only: the kernel driver, its
libata helper, synohwd and the package. Booting from the DOM is a separate topic.

Identifiers say `ds2415p`, not `ds2415`: Synology sells non-plus models in this family that are
different hardware (DS1515 and DS1515+), and DSM itself spells the model `DS2415p`. The DS923+
has no such sibling, which is why upstream's names carry no `p`.

## What the hardware needs (as DSM does it)

| Part | How it is driven |
|---|---|
| Fans of the NAS, power/status/alert LEDs, beeper | Front-panel microcontroller on ttyS1 (16550 at I/O 0x2F8), 9600 8N1, ASCII bytes. DSM's scemd sends `u` (fan checker) about every 10 s and `V<nn>` + `W20` for the fans |
| Green bay LEDs (DS2415+) | The 88SE9215 itself, once DSM has set its GPIO block (AHCI vendor window ABAR+0xA8/+0xAC): GPIO0-3 = link/activity of ports 0-3 |
| Orange bay LEDs (DS2415+) | 88SE9215 DATA_OUT bit 4 + port, plus Avoton GPIO 49 (GPIOBASE+0x88 bit 17) high, which DSM's synobios sets once |
| DX1215 fans, alarms, bay LEDs, mode switch | GPIO pins of the four 88SM9705 port multipliers, reached with PMP READ/WRITE (0xE4/0xE8) to vendor registers 0x3a0/0x3a4/0x3b0 on the control port: a paged 8-bit GPIO file (page 0 EMID/unit id, 1 LEDs, 2 alarms, 3 switch, 4 fan level), level and alarms on the EMID-0 master |

Bay order: DS bay = DSM disk index + 1 = 4 x (88SE9215 in PCI order: 03:00.0, 05:00.0, 06:00.0) +
port + 1. DX1215 bay = 3 x EMID + fan-out port + 1.

## Decisions

1. **A new driver, `drivers/ata/synology_ds2415p.c`, not a model table in `synology_ds923.c`.**
   The DS923+ driver is AMD FCH GPIO, the AMD UART and I2C devices; nothing of it applies to the
   DS2415+, and a model table would change DS923+ code. Everything the DS2415+ driver touches is an
   AHCI vendor register or a SATA PMP register (the one exception is GPIO 49), and it needs ahci's
   own mapping of ABAR (`struct ahci_host_priv`, `drivers/ata/ahci.h`), so it lives in
   `drivers/ata`. Kconfig `SYNOLOGY_DS2415P` (tristate, a module: nothing in it is needed to boot).
2. **PMP vendor registers through a small libata API (patch 0009), not by wrapping
   `ap->ops->error_handler` or calling `ata_exec_internal` by address.** `sata_pmp_vendor_call()`
   runs a callback from the port's EH thread in a round with nothing to recover, in place of the
   error handler, the context in which libata itself talks to a PMP; `sata_pmp_vendor_read/write()`
   take 16-bit register numbers (HOB FEATURE). This is the access pattern the out-of-tree module
   used on hardware (quiet EH round, the error handler skipped, run in the same round if a command
   timed out), without its ops swap and kallsyms lookup. Hidden symbol `SATA_PMP_VENDOR_EH`,
   selected by the driver.
3. **DS923+ unchanged, proven.** Patch 0009 adds code only at file ends and under its symbol, and
   the one line it changes in `libata-eh.c` calls an inline that is `ap->ops->error_handler(ap)`
   when the symbol is off. With the DS923+ fragments (6.18.58 tree), all 61 objects of
   `drivers/ata` are byte-identical with and without patches 0009/0010, `autoconf.h` is identical,
   and the `.config` gains only `# CONFIG_SYNOLOGY_DS2415P is not set`.
4. **Kernel config: `kernel/ds2415p.config`, merged only with `EXTRA_CONFIGS=ds2415p.config`.**
   The default build (CI, the published DS923+ kernel) is unchanged. Whether the published kernel
   should carry the driver for both models (one kernel, as the boot design prefers) or the
   DS2415+ gets its own build is the maintainer's choice; the fragment works either way.
5. **Binding: DMI and PCI topology.** The DS2415+ BIOS has Insyde placeholder DMI strings
   (`Insyde` / `MohonPeak` / `Type2 - Board Product Name1`), so DMI alone could match other Avoton
   boards on the same reference BIOS. The driver also needs the Avoton PCU 8086:1f38 at 00:1f.0,
   exactly three 1b4b:9215 and exactly one 1b4b:9235, all bound to ahci (device links: it probes
   after ahci and is unbound before it). A DS923+ fails both checks. Not known: whether the
   RS2416+ (same BIOS image, same synobios LED code) has the same topology; if so it would bind,
   doing there what DSM does on it.
6. **LEDs: orange only, as LED class devices.** `syno:orange:disk1..12` (DS bays) and
   `syno-dx1:orange:disk1..12` (DX1215 bays), `max_brightness` 1. The green LEDs are the
   controllers' own link/activity outputs (DS2415+) or the PMP's (DX1215, enabled by clearing the
   page-1 mask bit), so the per-port triggers of patch 0005 have nothing to drive here.
7. **GPIO 49 by a one-byte write, not gpio-ich.** gpio-ich's output cache for Avoton starts at 0,
   so its first write to the SUS bank would also clear the other SUS outputs. The driver takes the
   I/O range (+0x80..+0x8b) with `request_region`, checks that pin 49 is a GPIO output, writes the
   byte at +0x8a read at probe with only bit 1 set (the write tested on hardware), and writes the
   probe value back on unbind. `GPIO_ICH` stays off.
8. **DX1215 write rules in one function (`dx_write()`).** Only Synology's two output-enable
   values, page select words, and data words for page 1 (bits 0-2 fault, bit 6 LED mask) or page 4
   (bits 1:0 fan level, master only), each a read-modify-write of the page read in the same EH round
   with the pulse bits (page 1 bit 5, page 4 bit 4) clear; the stop code is never written. hwmon
   `synology_dx1215`: `fan1_alarm`, `fan2_alarm`, `pwm1` (255 full, 128 middle, 64 low), values
   cached up to `refresh_s` (10 s) so reads do not each cost an EH round.
9. **synohwd: a `DS2415PDaemon` subclass**, picked by `model` in synohwd.toml or recognised (the
   platform device, or DMI + Avoton LPC); the DS923+ code paths are as before and the DS923+ tests
   are unchanged. The uP gets only measured bytes (allow-list: never `1`, `C`, `3` or V below 10);
   `u` every 10 s; DS2415+ duty from DSM's DUAL_MODE_LOW/HIGH tables (70 % if a source cannot be
   read, 99 % if none can); alert LED (`LA1`/`LA3`) and orange status blink in DSM's ALERT_LED band;
   DX1215 level from DSM's DX1215 table on the hottest DX1215 disk (low 0, middle 48, full 55 °C;
   61 °C = shutdown threshold; disks asleep = low), full on any fan alarm. Bytes from the uP are only
   logged: their meaning (it streams `3` and `K`) and the power button byte are not known.
10. **Package `pkg/synology-ds2415p`, hardware control only**, rather than the overlay of the
    boot design: it needs no new build tool, and the boot-side files (DOM handling, initramfs with
    `ehci_pci`, notifications, UPS) are not settled yet and can join the same directory. It
    conflicts with `synology-ds923` (both ship synohwd and its unit). No `rtc_cmos` blacklist:
    it is the only RTC here. No DOM read-only rule: the DOM is where the kernel and boot files go.
    `tools/publish.sh` is not changed yet.

## Evidence

Measured on the DS2415+ + DX1215 with an out-of-tree module of the same logic (kernel
6.18.58-Unraid): GPIO page reads on all four PMPs, EMID 0-3 per lane, the unit id 0x13 on the
master; fan level writes full/middle/low read back, stop sets both alarm bits (page 2 bits 0
and 1); page 1 mask and fault bits read back and light the DX1215 trays; the 88SE9215 init
(green link/activity); GPIO 49 byte write lighting the DS2415+ orange LEDs; both bay maps,
tray by tray; DEFAULT/MANUAL = page 3 bit 0 (1 = DEFAULT); the uP byte map and the 10 s `u`.

Not tested on hardware: this driver and patch 0009 as such (built with W=1 on a 6.18.58 tree
with patches 0001-0007, not on 7.3), resume, and synohwd's DS2415+ code (offline tests only).
