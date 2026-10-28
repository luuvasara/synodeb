# ata: libata-pmp: disable the SEMB port on Marvell 88SM9705 (linux-ide, ready to send)

Prepared 2026-10-28. Same change as synodeb commit 9bdaebd, rebased on the libata
`for-next` branch, with a commit message written for the libata maintainers.

## Files

- `0001-ata-libata-pmp-disable-the-SEMB-port-on-Marvell-88SM.patch`: the mail
  (git format-patch, `base-commit:` = libata for-next fb2c3f44a7e1, "Merge tag 'ata-7.4-rc1'").

## Before sending

1. Replace `SENDER NAME <sender@example.invalid>` (From and Signed-off-by) with the
   sender's identity. The kernel asks for a "known identity" in Signed-off-by
   (Documentation/process/submitting-patches.rst: "using a known identity (sorry, no
   anonymous contributions.)").
2. Search lore for earlier 88SM9705 patches: https://lore.kernel.org/linux-ide/?q=9705
   (not done here: lore and git.kernel.org served a bot check). Mainline as of for-next
   fb2c3f44a7e1 has no 0x9705 anywhere in drivers/ata.

```sh
git clone --depth 1 -b for-next https://git.kernel.org/pub/scm/linux/kernel/git/libata/linux.git
cd linux
git am /path/to/0001-ata-libata-pmp-disable-the-SEMB-port-on-Marvell-88SM.patch
git commit --amend --reset-author   # fix the Signed-off-by line in the editor
git format-patch -1 --base=HEAD~1
./scripts/checkpatch.pl --strict 0001-*.patch
./scripts/get_maintainer.pl 0001-*.patch
git send-email --to=dlemoal@kernel.org --to=cassel@kernel.org \
    --cc=linux-ide@vger.kernel.org --cc=illofspeed@gmail.com 0001-*.patch
```

`git send-email` also Ccs `stable@vger.kernel.org` from the `Cc:` trailer. That is the
usual way to ask for a stable backport; stable only acts once the patch is in Linus' tree.
Without an SMTP setup, `b4 send --web-auth` (kernel.org's b4 tool) sends through the
kernel.org web endpoint instead.

## Who gets it (get_maintainer.pl on this patch)

- Damien Le Moal <dlemoal@kernel.org>, maintainer, LIBATA SUBSYSTEM
- Niklas Cassel <cassel@kernel.org>, maintainer, LIBATA SUBSYSTEM
- linux-ide@vger.kernel.org, the list
- linux-kernel@vger.kernel.org, listed too; recent libata patches usually go to linux-ide only

## What was checked here

| check | result |
|---|---|
| `checkpatch.pl --strict` | 0 errors, 0 checks, 1 warning: "stable@ ... perhaps it also needs a 'Fixes:' tag?" Expected: a new hardware quirk fixes no earlier commit (the 88SM4140 quirk, 945b47441d83, went in with `Cc: stable` and no `Fixes:` too). |
| `git am` on for-next fb2c3f44a7e1 | applies; tree identical to the prepared branch |
| build, x86_64 defconfig (ATA=y, SATA_PMP=y), `W=1`, `drivers/ata/libata-pmp.o` | no warnings; the object contains `cmp $0x9705` |
| on hardware | Debian 6.12 libata with the same code change (only the comment differs): one boot without, one with, numbers in the commit message |
| datasheet | Marvell 88SM9705 functional specifications (MV-S109142-00 Rev. A, 2015-06-12): "up to five device ports and one SEMB port"; port number 5 = SEMB; GSCR port count "6h if SEMB enabled and 5h if not". The marvell.com link in the patch returned 403 to scripts; a copy is at https://datasheet.datasheetarchive.com/originals/crawler/marvell.com/91b517554bc6719fae423689cb95cef2.pdf |

## Style followed

- Subject prefix `ata: libata-pmp:` as in c62aff1174cf ("ata: libata-pmp: add JMicron JMS562
  quirk", 2026-06, the latest quirk added to this function).
- Commit message as in that patch: log lines that show the failure, why the existing knobs
  don't help, what the change does, then the test result.
- The code is the existing 88SM4140 SEMB quirk (945b47441d83) for vendor 0x1b4b, device 0x9705,
  port 5.

## Related work (checked 2026-10-28)

- **Kyrylo Biryuk** works on the same chain (Marvell 88SE9235 + 88SM9705 in a Synology
  DX1222): "ata: libahci: re-enable FBS after error handling on a port multiplier" (v4,
  2026-10-12), Reviewed-by Damien Le Moal, applied by Niklas Cassel to libata for-7.4
  (https://patchew.org/linux/20261012103917.389-1-illofspeed@gmail.com/). Worth a Cc: he has the
  hardware and could confirm whether his DX1222 shows the same port-5 retry loop. It is a
  different file (libahci.c); no conflict with this patch.
- **Generic 88SM9705 boards** (1-to-5 SATA multiplier cards, NVR boards) report 5 ports, i.e.
  SEMB disabled, and probe in about 2 s. Public dmesg samples in linuxhw/Dmesg, e.g.
  `ata5.15: Port Multiplier 1.2, 0x1b4b:0x9705 r160, 5 ports, feat 0x5/0x1f` followed by
  `ata5: EH complete` 1.6 s later. This patch does nothing on them (no link 5).
- Synology's own kernel handles the 88SM9705 in its patched libata (its GPL kernel tree);
  never upstreamed and not used here.
- A community comment says the DX517 also uses the 88SM9705
  (https://github.com/RROrg/rr/issues/18569); not verified.

## Hardware with the 88SM9705 (checked 2026-10-28)

Only units that enable the SEMB report 6 ports and hit the port-5 retry loop. Every
generic board found reports 5 ports, so the patch does nothing on it.

| Hardware | What it is | Ports reported | Port-5 stall | Source |
|---|---|---|---|---|
| Synology DX1215 | 12-bay expansion unit, four 88SM9705 r160 behind a Marvell 88SE9235 | 6 | **yes**, measured | this patch |
| Synology DX1222 | 12-bay expansion unit, 88SM9705 behind a Marvell 88SE9235 | not stated | unknown | Kyrylo Biryuk's libahci FBS patch (Oct 2026) |
| Synology DX517 | 5-bay expansion unit | unknown | unknown | reseller spec "Adopts Marvell 88SM9705" (totallytech.com.au); community comments (007revad/Synology_enable_eunit#57, RROrg/rr#18569) |
| Syba SD-PEX40104 / SD-PEX40105 and similar unbranded "PCIe x1 8-port SATA" cards | PCIe card, Marvell 88SE9215 + 88SM9705 | 5 (expected, see next row) | no | sybausa.com product page; eBay/Newegg listings |
| Desktops with such a card (MSI H510M-A PRO, ASUS PRIME H510M-A, PRIME A320M-C, M5A99FX PRO, Gigabyte B450 AORUS M, B550 VISION D-P, X470 AORUS ULTRA GAMING) | 88SM9705 behind a Marvell AHCI add-in controller | 5 | no, EH done in ~2 s | linuxhw/Dmesg samples |
| teleplatforms D4E4S16P8 | storage board, four 88SM9705 on the chipset AHCI | 5 | no | linuxhw/Dmesg sample |
| NVR boards (e.g. J1900 + 2x 88SE9215 + 88SM9705) | video recorder mainboard | unknown | unknown | RROrg/rr#18569 |

Older Synology units use other chips and are not affected: DX510 = SiI3726, DX513 = SiI3826
(community comments in 007revad/Synology_enable_eunit#57 and r/synology). The 88SM9715 is the
sister part sold "with Enclosure Management" (Marvell product selector guide, 2018).

## Not in this submission

The PMP vendor-register patch (synodeb PR #5) is not sent: it adds an exported libata API
with no in-tree user, and libata takes new interfaces only together with a driver that uses them.
