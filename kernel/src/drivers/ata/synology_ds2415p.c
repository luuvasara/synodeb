// SPDX-License-Identifier: GPL-2.0
/*
 * Synology DS2415+ bay LEDs and DX1215 expansion unit.
 *
 * The DS2415+ (Atom C2538, DSM platform "avoton") has twelve bays on three
 * Marvell 88SE9215 (03:00.0 bays 1-4, 05:00.0 bays 5-8, 06:00.0 bays 9-12,
 * port order, as DSM's DiskIdxMap) and an expansion port on a Marvell
 * 88SE9235 (07:00.0). The firmware leaves the bay LEDs dark; DSM sets them
 * up itself, and drives the DX1215 expansion unit through the GPIO pins of
 * its port multipliers. This driver does the same:
 *
 *  - 88SE9215 GPIO block, reached through the AHCI vendor window
 *    (ABAR+0xA8 address, ABAR+0xAC data), as DSM's
 *    syno_mv_9235_gpio_active_init(): DATA_OUT_ENABLE (active low) = 0,
 *    DATA_OUT = 0, GPIO_ACTIVE = 0x00B6D8D1. GPIO0-3 then show link and
 *    activity of ports 0-3 by themselves (the green LEDs), GPIO4-7 follow
 *    DATA_OUT: bit 4 + port = orange fault LED of that port.
 *  - Avoton GPIO 49 (SUS bank, GPIOBASE+0x88 bit 17) high: an enable the
 *    orange LEDs need, set by DSM's synobios on its first LED call and never
 *    cleared. gpio-ich is not used: its output cache starts at 0 and the
 *    first write would clear the other SUS outputs. The driver writes one
 *    byte (GPIOBASE+0x8a), the byte read at probe with only bit 1 changed,
 *    and puts the probe value back on unbind.
 *  - DX1215: four 88SM9705 PMPs, one per 88SE9235 port. Their vendor
 *    registers 0x3a0 (output), 0x3a4 (output enable), 0x3b0 (input) carry a
 *    paged 8-bit GPIO file (Synology's libhwcontrol and kernel): page 0
 *    bits 7:5 EMID, 4:0 unit id (0x13 = DX1215; EMID 0 = unit master);
 *    page 1 bits 0-2 orange fault LED of the PMP's fan-out ports 0-2, bit 6
 *    all disk LEDs off; page 2 bits 0/1 fan 1/2 alarm; page 3 bit 0 the
 *    rear DEFAULT/MANUAL switch (1 = DEFAULT); page 4 bits 1:0 fan level
 *    (00 full, 01 middle, 10 low, 11 stop), bit 4 a power-switch pulse.
 *    The fan level and the alarms live on the master only. DX bay =
 *    3 * EMID + fan-out port + 1. Register access goes through
 *    sata_pmp_vendor_call() (quiet EH rounds of the port). Every PMP write
 *    is checked by dx_write(): only Synology's two output-enable values,
 *    page select words, and data words for page 1 (bits 0-2 and 6) or
 *    page 4 (bits 1:0, never stop, master only), both read-modify-write of
 *    the page read in the same round, the pulse bits (page 1 bit 5, page 4
 *    bit 4) always 0.
 *
 * Interfaces: LEDs syno:orange:disk1..12 (DS bays) and
 * syno-dx1:orange:disk1..12 (DX1215 bays); hwmon "synology_dx1215" with
 * fan1_alarm, fan2_alarm and pwm1 (255 full, 128 middle, 64 low; a write
 * above 128 gives full, above 64 middle, else low); dx_model, dx_switch
 * and dx_ports (one "ataN EMID" line per PMP) on the platform device.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dmi.h>
#include <linux/hwmon.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/jiffies.h>
#include <linux/leds.h>
#include <linux/libata.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#include "ahci.h"

#define DRV_NAME		"synology-ds2415p"
#define DS_CTRLS		3
#define DS_PORTS		4
#define DS_BAYS			(DS_CTRLS * DS_PORTS)
#define DX_PMPS			4
#define DX_BAYS_PER_PMP		3
#define DX_BAYS			(DX_PMPS * DX_BAYS_PER_PMP)

/* 88SE9215 GPIO block in the AHCI vendor window (DSM ahci.c) */
#define MV_WIN_ADDR		0xa8
#define MV_WIN_DATA		0xac
#define MV_GPIO_OUT		0x07071020
#define MV_GPIO_OE		0x07071024	/* active low */
#define MV_GPIO_FUNC		0x07071058
#define MV_GPIO_FUNC_DSM	0x00b6d8d1
#define MV_FAULT(port)		(1U << (4 + (port)))
#define MV_FAULT_ALL		0xf0U

/* Avoton PCU (LPC, 00:1f.0) GPIO, second (SUS) bank */
#define PCH_GPIOBASE		0x48
#define PCH_BASE_MASK		0xff80
#define PCH_USE_SEL2		0x80	/* 1 = GPIO */
#define PCH_IO_SEL2		0x84	/* 0 = output */
#define PCH_LVL2_B2		0x8a	/* bits 16-23 of LVL2 (+0x88) */
#define PCH_REGION		0x0c
#define PCH_GPIO49		(1U << 17)
#define PCH_B2_GPIO49		0x02

/* 88SM9705 GPIO registers and the register word R of 0x3a0/0x3b0 */
#define DX_REG_OUT		0x3a0
#define DX_REG_EN		0x3a4
#define DX_REG_IN		0x3b0
#define DX_EN_ALL_OUT		0xfffffU	/* before every 0x3a0 write */
#define DX_EN_READ		0xfc7c0U	/* before reading 0x3b0 */
#define DX_R_WCTL		(1U << 14)	/* write strobe, active low */
#define DX_R_RCTL		(1U << 15)	/* read strobe, active low */
#define DX_R_PAGE(p)		((((p) & 3U) << 17) | ((((p) >> 2) & 1U) << 19))
#define DX_R_ALLOWED		(DX_R_WCTL | DX_R_RCTL | DX_R_PAGE(7))
/* a page select word: W_CTL high, only strobe and page bits */
#define DX_R_SELECT_OK(r)	(((r) & (DX_R_WCTL | ~DX_R_ALLOWED)) == DX_R_WCTL)
#define DX_R_SEL(p, rlow)	(DX_R_WCTL | ((rlow) ? 0 : DX_R_RCTL) | DX_R_PAGE(p))
/* data byte <-> its R bits: d[4:0] = R[4:0], d[7:5] = R[13:11] */
#define DX_DEC(r)		(((r) & 0x1fU) | (((r) >> 6) & 0xe0U))
#define DX_ENC(d)		(((d) & 0x1fU) | (((d) << 6) & 0x3800U))
#define DX_R_DATA(p, d, wlow)	(DX_R_RCTL | ((wlow) ? 0 : DX_R_WCTL) | \
				 DX_R_PAGE(p) | DX_ENC(d))

#define DX_PAGES		5
#define DX_UNIQUE_DX1215	0x13
#define DX_P1_FAULT		0x07
#define DX_P1_BUZZER		0x20	/* pulse line: never set */
#define DX_P1_LED_MASK		0x40	/* 1 = all disk LEDs off */
#define DX_P1_CHANGEABLE	(DX_P1_FAULT | DX_P1_LED_MASK)
#define DX_P3_DEFAULT		0x01
#define DX_P4_FAN		0x03
#define DX_P4_POWER_PULSE	0x10	/* pulse line: never set */

enum { DX_FAN_FULL, DX_FAN_MIDDLE, DX_FAN_LOW, DX_FAN_STOP };

static const u8 dx_level_pwm[4] = { 255, 128, 64, 0 };

static bool disk_leds = true;
module_param(disk_leds, bool, 0444);
MODULE_PARM_DESC(disk_leds, "Set up the bay LEDs as DSM does (88SE9215 GPIO, GPIO 49, DX1215 LED mask)");

static unsigned int refresh_s = 10;
module_param(refresh_s, uint, 0644);
MODULE_PARM_DESC(refresh_s, "Max age in s of the DX1215 values before a read asks the unit again");

struct ds_ctrl {
	struct pci_dev *pdev;
	void __iomem *mmio;		/* ahci's ABAR mapping */
	spinlock_t lock;		/* the vendor window */
	u32 fault;			/* DATA_OUT fault bits we set */
};

struct ds_led {
	struct led_classdev cdev;
	struct ds2415p *ds;
	int ctrl, port;
	char name[32];
};

struct dx_pmp {
	struct ata_port *ap;
	int emid;			/* -1: no DX1215 PMP seen on this lane */
};

struct dx_led {
	struct led_classdev cdev;
	struct ds2415p *ds;
	int bay;			/* 0..11 */
	char name[32];
};

struct ds2415p {
	struct device *dev;
	struct ds_ctrl ctrl[DS_CTRLS];
	struct ds_led ds_led[DS_BAYS];

	/* GPIO 49 */
	u16 pch_base;
	bool pch_region;
	u8 pch_probe_b2;

	/* DX1215 */
	struct ata_host *dx_host;
	struct dx_pmp pmp[DX_PMPS];
	struct mutex dx_lock;		/* DX cycles, the cache below, registration */
	int master;			/* index into pmp[], -1 = none */
	u8 mpage[DX_PAGES];		/* master pages, read at mstamp */
	bool mvalid;
	unsigned long mstamp;
	bool dx_registered;
	struct delayed_work dx_work;
	struct dx_led dx_led[DX_BAYS];
};

static struct pci_dev *ds2415p_9215[DS_CTRLS], *ds2415p_9235;
static struct platform_device *ds2415p_pdev;

/* ---------------------------------------------------------------- DS bays */

/*
 * The only access to the vendor window: three GPIO addresses, the index
 * register put back afterwards. Caller holds c->lock.
 */
static void __ds_win(struct ds_ctrl *c, u32 addr, bool write, u32 *val)
{
	u32 idx, old;

	if (WARN_ON_ONCE(addr != MV_GPIO_OUT && addr != MV_GPIO_OE && addr != MV_GPIO_FUNC))
		return;
	idx = readl(c->mmio + MV_WIN_ADDR);
	writel(addr, c->mmio + MV_WIN_ADDR);
	old = readl(c->mmio + MV_WIN_DATA);
	if (write)
		writel(*val, c->mmio + MV_WIN_DATA);
	else
		*val = old;
	writel(idx, c->mmio + MV_WIN_ADDR);
	readl(c->mmio + MV_WIN_ADDR);	/* flush */
}

static void ds_win(struct ds_ctrl *c, u32 addr, bool write, u32 *val)
{
	unsigned long flags;

	spin_lock_irqsave(&c->lock, flags);
	__ds_win(c, addr, write, val);
	spin_unlock_irqrestore(&c->lock, flags);
}

/* DSM syno_mv_9235_gpio_active_init(), plus our fault bits */
static void ds_ctrl_init(struct ds_ctrl *c)
{
	u32 v = 0;

	ds_win(c, MV_GPIO_OE, true, &v);
	v = c->fault;
	ds_win(c, MV_GPIO_OUT, true, &v);
	v = MV_GPIO_FUNC_DSM;
	ds_win(c, MV_GPIO_FUNC, true, &v);
}

static void ds_led_set(struct led_classdev *cdev, enum led_brightness value)
{
	struct ds_led *led = container_of(cdev, struct ds_led, cdev);
	struct ds_ctrl *c = &led->ds->ctrl[led->ctrl];
	unsigned long flags;
	u32 v;

	/* DSM syno_mv_9235_disk_led_set(): DATA_OUT read-modify-write */
	spin_lock_irqsave(&c->lock, flags);
	if (value)
		c->fault |= MV_FAULT(led->port);
	else
		c->fault &= ~MV_FAULT(led->port);
	__ds_win(c, MV_GPIO_OUT, false, &v);
	v = (v & ~MV_FAULT(led->port)) | (c->fault & MV_FAULT(led->port));
	__ds_win(c, MV_GPIO_OUT, true, &v);
	spin_unlock_irqrestore(&c->lock, flags);
}

static enum led_brightness ds_led_get(struct led_classdev *cdev)
{
	struct ds_led *led = container_of(cdev, struct ds_led, cdev);
	u32 v;

	ds_win(&led->ds->ctrl[led->ctrl], MV_GPIO_OUT, false, &v);
	return v & MV_FAULT(led->port) ? 1 : 0;
}

/* GPIO 49 high (on) or back to the value read at probe (off) */
static void ds_pch_set(struct ds2415p *ds, bool on)
{
	u8 v = on ? ds->pch_probe_b2 | PCH_B2_GPIO49 : ds->pch_probe_b2;
	u32 use, io;

	if (!ds->pch_region)
		return;
	use = inl(ds->pch_base + PCH_USE_SEL2);
	io = inl(ds->pch_base + PCH_IO_SEL2);
	if (!(use & PCH_GPIO49) || (io & PCH_GPIO49)) {
		dev_warn(ds->dev, "GPIO 49 is no longer a GPIO output: not written\n");
		return;
	}
	outb(v, ds->pch_base + PCH_LVL2_B2);
}

static void ds_pch_attach(struct ds2415p *ds)
{
	struct pci_dev *lpc = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(0x1f, 0));
	u32 cfg = 0, use, io;
	u16 base;

	if (!lpc)
		return;
	pci_read_config_dword(lpc, PCH_GPIOBASE, &cfg);
	pci_dev_put(lpc);
	base = cfg & PCH_BASE_MASK;
	if (!(cfg & 1) || base < 0x400) {
		dev_warn(ds->dev, "GPIOBASE 0x%08x is not an I/O base: orange LEDs stay dark\n", cfg);
		return;
	}
	if (!devm_request_region(ds->dev, base + PCH_USE_SEL2, PCH_REGION, DRV_NAME)) {
		dev_warn(ds->dev, "GPIO ports 0x%x owned by another driver: orange LEDs stay dark\n",
			 base + PCH_USE_SEL2);
		return;
	}
	use = inl(base + PCH_USE_SEL2);
	io = inl(base + PCH_IO_SEL2);
	if (!(use & PCH_GPIO49) || (io & PCH_GPIO49)) {
		dev_warn(ds->dev, "GPIO 49 is not a GPIO output (USE_SEL2 0x%08x IO_SEL2 0x%08x)\n",
			 use, io);
		return;
	}
	ds->pch_base = base;
	ds->pch_probe_b2 = inb(base + PCH_LVL2_B2);
	ds->pch_region = true;
}

static int ds_bays_probe(struct ds2415p *ds)
{
	int i, port, ret;

	for (i = 0; i < DS_CTRLS; i++) {
		struct ds_ctrl *c = &ds->ctrl[i];
		struct ata_host *host = pci_get_drvdata(ds2415p_9215[i]);
		struct ahci_host_priv *hpriv = host ? host->private_data : NULL;

		if (!hpriv || !hpriv->mmio)
			return dev_err_probe(ds->dev, -ENODEV, "%s: no AHCI host\n",
					     pci_name(ds2415p_9215[i]));
		c->pdev = ds2415p_9215[i];
		c->mmio = hpriv->mmio;
		spin_lock_init(&c->lock);
		ds_ctrl_init(c);
	}
	ds_pch_attach(ds);
	ds_pch_set(ds, true);

	for (i = 0; i < DS_BAYS; i++) {
		struct ds_led *led = &ds->ds_led[i];

		led->ds = ds;
		led->ctrl = i / DS_PORTS;
		led->port = i % DS_PORTS;
		snprintf(led->name, sizeof(led->name), "syno:orange:disk%d", i + 1);
		led->cdev.name = led->name;
		led->cdev.max_brightness = 1;
		led->cdev.brightness_set = ds_led_set;
		led->cdev.brightness_get = ds_led_get;
		led->cdev.flags = LED_RETAIN_AT_SHUTDOWN;
		ret = devm_led_classdev_register(ds->dev, &led->cdev);
		if (ret)
			return dev_err_probe(ds->dev, ret, "register %s\n", led->name);
	}
	for (i = 0; i < DS_CTRLS; i++) {
		u32 oe, out, func;

		ds_win(&ds->ctrl[i], MV_GPIO_OE, false, &oe);
		ds_win(&ds->ctrl[i], MV_GPIO_OUT, false, &out);
		ds_win(&ds->ctrl[i], MV_GPIO_FUNC, false, &func);
		port = i * DS_PORTS + 1;
		dev_info(ds->dev, "bays %d-%d on %s: gpio oe 0x%08x out 0x%08x func 0x%08x\n",
			 port, port + DS_PORTS - 1, pci_name(ds->ctrl[i].pdev), oe, out, func);
	}
	if (ds->pch_region)
		dev_info(ds->dev, "GPIO 49 (orange enable) high, GPIOBASE 0x%x byte 0x%02x\n",
			 ds->pch_base, ds->pch_probe_b2);
	return 0;
}

/* ---------------------------------------------------------------- DX1215 */

/* One request, run by dx_cycle_fn() in a quiet EH round of one PMP port. */
struct dx_req {
	unsigned int pages;		/* bit n: read page n */
	int wpage;			/* -1, 1 or 4 */
	u8 wmask, wval;			/* page bits to change and their value */
	u8 page[DX_PAGES];		/* data bytes read (and written) */
	unsigned int valid;		/* pages read */
	u32 out, en;			/* 0x3a0/0x3a4 found at the start */
	int armed;			/* page of the write sequence running, -1 none */
	u8 cur, new;			/* its byte as read and as written */
};

/*
 * A data word for the page being written, as dx_write_page() armed it: the
 * new byte differs from the one read in this round only in the allowed bits,
 * no pulse bit, page 4 only on the master and never the stop code.
 */
static bool dx_data_ok(const struct dx_req *r, u32 val)
{
	unsigned int d = DX_DEC(val);
	int p = r->armed;

	if (p != 1 && p != 4)
		return false;
	if (d != r->new || (val != DX_R_DATA(p, d, 0) && val != DX_R_DATA(p, d, 1)))
		return false;
	if (!(r->valid & 1) || (r->page[0] & 0x1f) != DX_UNIQUE_DX1215)
		return false;
	if (p == 4)
		return r->page[0] == DX_UNIQUE_DX1215 &&
		       !((d | r->cur) & DX_P4_POWER_PULSE) &&
		       !((d ^ r->cur) & ~DX_P4_FAN) && (d & DX_P4_FAN) != DX_FAN_STOP;
	return !((d | r->cur) & DX_P1_BUZZER) && !((d ^ r->cur) & ~DX_P1_CHANGEABLE);
}

/* The only PMP write of the driver. */
static unsigned int dx_write(struct ata_port *ap, struct dx_req *r, u16 reg, u32 val)
{
	bool ok;

	if (reg == DX_REG_EN)
		ok = val == DX_EN_ALL_OUT || val == DX_EN_READ;
	else if (reg == DX_REG_OUT)
		ok = DX_R_SELECT_OK(val) || dx_data_ok(r, val);
	else
		ok = false;
	if (!ok) {
		WARN_ONCE(1, DRV_NAME ": refused PMP write reg 0x%x val 0x%x\n", reg, val);
		return AC_ERR_INVALID;
	}
	return sata_pmp_vendor_write(ap, reg, val);
}

/* Synology's syno_pm_gpio store: output enable all-out, then 0x3a0 */
static unsigned int dx_out(struct ata_port *ap, struct dx_req *r, u32 val)
{
	unsigned int err = dx_write(ap, r, DX_REG_EN, DX_EN_ALL_OUT);

	if (!err)
		err = dx_write(ap, r, DX_REG_OUT, val);
	usleep_range(1000, 2000);
	return err;
}

/* page select with both strobes high, R_CTL low, read 0x3b0, strobes high */
static unsigned int dx_read_page(struct ata_port *ap, struct dx_req *r, int pg)
{
	unsigned int err;
	u32 raw;

	err = dx_out(ap, r, DX_R_SEL(pg, 0));
	if (!err)
		err = dx_out(ap, r, DX_R_SEL(pg, 1));
	if (!err)
		err = dx_write(ap, r, DX_REG_EN, DX_EN_READ);
	if (!err)
		err = sata_pmp_vendor_read(ap, DX_REG_IN, &raw);
	if (!err)
		err = dx_out(ap, r, DX_R_SEL(pg, 0));
	if (!err) {
		r->page[pg] = DX_DEC(raw);
		r->valid |= 1U << pg;
	}
	return err;
}

/* 0x3a0 and 0x3a4 back to what they were at the start, read back */
static unsigned int dx_restore(struct ata_port *ap, struct dx_req *r)
{
	unsigned int err;
	u32 out, en;

	err = dx_out(ap, r, r->out);
	if (!err)
		err = dx_write(ap, r, DX_REG_EN, r->en);
	if (!err)
		err = sata_pmp_vendor_read(ap, DX_REG_OUT, &out);
	if (!err)
		err = sata_pmp_vendor_read(ap, DX_REG_EN, &en);
	if (!err && (out != r->out || en != r->en))
		err = AC_ERR_OTHER;
	return err;
}

/* SYNOEBox9705WriteGpio: data word, W_CTL low pulse, data word; then read back */
static int dx_write_page(struct ata_port *ap, struct dx_req *r)
{
	int p = r->wpage, i;
	unsigned int err = 0;

	r->cur = r->page[p];
	if ((r->page[0] & 0x1f) != DX_UNIQUE_DX1215)
		return -ENODEV;
	if (p == 4) {
		if (r->page[0] != DX_UNIQUE_DX1215 || (r->cur & DX_P4_POWER_PULSE) ||
		    (r->wval & DX_P4_FAN) == DX_FAN_STOP)
			return -EPERM;
		r->new = ((r->cur & ~DX_P4_FAN) | (r->wval & DX_P4_FAN)) & ~DX_P4_POWER_PULSE;
	} else {
		if (r->cur & DX_P1_BUZZER)
			return -EPERM;
		r->new = ((r->cur & ~(r->wmask & DX_P1_CHANGEABLE)) |
			  (r->wval & r->wmask & DX_P1_CHANGEABLE)) & ~DX_P1_BUZZER;
	}
	if (r->new == r->cur)
		return 0;

	r->armed = p;
	for (i = 0; i < 3 && !err; i++)
		err = dx_out(ap, r, DX_R_DATA(p, r->new, i == 1));
	r->armed = -1;
	if (err || ata_port_is_frozen(ap))
		return -EIO;
	err = dx_restore(ap, r);
	if (!err)
		err = dx_read_page(ap, r, p);
	if (err)
		return -EIO;
	return r->page[p] == r->new ? 0 : -EIO;
}

static int dx_cycle_fn(struct ata_port *ap, void *data)
{
	struct dx_req *r = data;
	u32 *gscr = ap->link.device->gscr;
	unsigned int pages = r->pages, err;
	int pg, rc = 0;

	r->armed = -1;
	r->valid = 0;
	if (sata_pmp_gscr_vendor(gscr) != PCI_VENDOR_ID_MARVELL_EXT ||
	    sata_pmp_gscr_devid(gscr) != 0x9705)
		return -ENODEV;
	err = sata_pmp_vendor_read(ap, DX_REG_OUT, &r->out);
	if (!err)
		err = sata_pmp_vendor_read(ap, DX_REG_EN, &r->en);
	if (err)
		return -EIO;
	if (!DX_R_SELECT_OK(r->out) || (r->en != DX_EN_ALL_OUT && r->en != DX_EN_READ))
		return -EIO;	/* not a state we could put back */

	/* a write needs page 0 (unit id, EMID) and the page itself from this round */
	if (r->wpage >= 0)
		pages |= 1U << 0 | 1U << r->wpage;
	for (pg = 0; pg < DX_PAGES && !err; pg++)
		if (pages & (1U << pg))
			err = dx_read_page(ap, r, pg);
	if (!err && r->wpage >= 0)
		rc = dx_write_page(ap, r);
	if (ata_port_is_frozen(ap))
		return -EIO;
	if (dx_restore(ap, r) || err)
		return -EIO;
	return rc;
}

static int dx_cycle(struct ds2415p *ds, int i, struct dx_req *r)
{
	return sata_pmp_vendor_call(ds->pmp[i].ap, dx_cycle_fn, r);
}

/* caller holds dx_lock: master pages 0, 2, 3, 4 no older than refresh_s */
static int dx_master_fresh(struct ds2415p *ds)
{
	struct dx_req r = { .pages = 0x1d, .wpage = -1 };
	int ret;

	if (ds->master < 0)
		return -ENODEV;
	if (ds->mvalid && time_before(jiffies, ds->mstamp + max(refresh_s, 1U) * HZ))
		return 0;
	ret = dx_cycle(ds, ds->master, &r);
	if (!ret && r.page[0] != DX_UNIQUE_DX1215)
		ret = -ENODEV;
	ds->mvalid = !ret;
	if (ret)
		return ret;
	memcpy(ds->mpage, r.page, sizeof(ds->mpage));
	ds->mstamp = jiffies;
	return 0;
}

/* level write on the master; on any failure FULL once (as the fan-fail rule) */
static int dx_set_level(struct ds2415p *ds, unsigned int code)
{
	struct dx_req r = { .pages = 0x1d, .wpage = 4, .wmask = DX_P4_FAN, .wval = code };
	int ret;

	if (code > DX_FAN_LOW)
		return -EINVAL;
	mutex_lock(&ds->dx_lock);
	ret = ds->master < 0 ? -ENODEV : dx_cycle(ds, ds->master, &r);
	if (ret && ret != -ENODEV && code != DX_FAN_FULL) {
		struct dx_req full = { .pages = 0x1d, .wpage = 4, .wmask = DX_P4_FAN };

		dev_warn(ds->dev, "DX1215 fan level %u: %d, setting full\n", code, ret);
		if (!dx_cycle(ds, ds->master, &full))
			r = full;
	}
	ds->mvalid = false;
	if (r.valid == 0x1d && r.page[0] == DX_UNIQUE_DX1215) {
		memcpy(ds->mpage, r.page, sizeof(ds->mpage));
		ds->mstamp = jiffies;
		ds->mvalid = true;
	}
	mutex_unlock(&ds->dx_lock);
	return ret;
}

static int dx_hwmon_read(struct device *dev, enum hwmon_sensor_types type, u32 attr,
			 int channel, long *val)
{
	struct ds2415p *ds = dev_get_drvdata(dev);
	int ret;

	if (type == hwmon_pwm && attr == hwmon_pwm_enable) {
		*val = 1;
		return 0;
	}
	mutex_lock(&ds->dx_lock);
	ret = dx_master_fresh(ds);
	if (ret)
		ret = -ENODATA;
	else if (type == hwmon_fan)
		*val = (ds->mpage[2] >> channel) & 1;
	else
		*val = dx_level_pwm[ds->mpage[4] & DX_P4_FAN];
	mutex_unlock(&ds->dx_lock);
	return ret;
}

static int dx_hwmon_write(struct device *dev, enum hwmon_sensor_types type, u32 attr,
			  int channel, long val)
{
	struct ds2415p *ds = dev_get_drvdata(dev);

	if (attr == hwmon_pwm_enable)
		return val == 1 ? 0 : -EINVAL;
	if (val < 0 || val > 255)
		return -EINVAL;
	return dx_set_level(ds, val > 128 ? DX_FAN_FULL : val > 64 ? DX_FAN_MIDDLE : DX_FAN_LOW);
}

static umode_t dx_hwmon_visible(const void *data, enum hwmon_sensor_types type, u32 attr,
				int channel)
{
	if (type == hwmon_fan && attr == hwmon_fan_alarm)
		return 0444;
	if (type == hwmon_pwm && (attr == hwmon_pwm_input || attr == hwmon_pwm_enable))
		return 0644;
	return 0;
}

static const struct hwmon_ops dx_hwmon_ops = {
	.is_visible = dx_hwmon_visible,
	.read = dx_hwmon_read,
	.write = dx_hwmon_write,
};

static const struct hwmon_channel_info * const dx_hwmon_info[] = {
	HWMON_CHANNEL_INFO(fan, HWMON_F_ALARM, HWMON_F_ALARM),
	HWMON_CHANNEL_INFO(pwm, HWMON_PWM_INPUT | HWMON_PWM_ENABLE),
	NULL
};

static const struct hwmon_chip_info dx_hwmon_chip = {
	.ops = &dx_hwmon_ops,
	.info = dx_hwmon_info,
};

static int dx_led_set(struct led_classdev *cdev, enum led_brightness value)
{
	struct dx_led *led = container_of(cdev, struct dx_led, cdev);
	struct ds2415p *ds = led->ds;
	int emid = led->bay / DX_BAYS_PER_PMP, i, ret = -ENODEV;
	u8 bit = 1U << (led->bay % DX_BAYS_PER_PMP);

	mutex_lock(&ds->dx_lock);
	for (i = 0; i < DX_PMPS; i++) {
		struct dx_req r = { .pages = 0, .wpage = 1, .wmask = bit, .wval = value ? bit : 0 };

		if (ds->pmp[i].emid != emid)
			continue;
		ret = dx_cycle(ds, i, &r);
		break;
	}
	mutex_unlock(&ds->dx_lock);
	return ret;
}

/* caller holds dx_lock: which lanes carry a DX1215 PMP, its EMID, the master */
static int dx_scan(struct ds2415p *ds)
{
	int i, n = 0, nmaster = 0, ret;

	ds->master = -1;
	for (i = 0; i < DX_PMPS; i++) {
		struct dx_pmp *p = &ds->pmp[i];
		struct dx_req r = { .pages = 0x03, .wpage = -1 };

		p->emid = -1;
		if (!p->ap || !sata_pmp_attached(p->ap))
			continue;
		/* DSM turns the disk LEDs on: page 1 bit 6 = 0 */
		if (disk_leds) {
			r.wpage = 1;
			r.wmask = DX_P1_LED_MASK;
		}
		ret = dx_cycle(ds, i, &r);
		if (ret || !(r.valid & 1) || (r.page[0] & 0x1f) != DX_UNIQUE_DX1215) {
			dev_dbg(ds->dev, "ata%u: no DX1215 PMP (%d, page0 0x%02x)\n",
				p->ap->print_id, ret, r.page[0]);
			continue;
		}
		p->emid = r.page[0] >> 5;
		n++;
		if (!p->emid) {
			ds->master = i;
			nmaster++;
		}
		dev_info(ds->dev, "ata%u: DX1215 PMP, EMID %d, page 1 0x%02x\n",
			 p->ap->print_id, p->emid, r.page[1]);
	}
	if (nmaster != 1)
		ds->master = -1;
	ds->mvalid = false;
	return n && ds->master >= 0 ? 0 : -ENODEV;
}

static int dx_register(struct ds2415p *ds)
{
	struct device *hwmon;
	int i, ret;

	hwmon = devm_hwmon_device_register_with_info(ds->dev, "synology_dx1215", ds,
						     &dx_hwmon_chip, NULL);
	if (IS_ERR(hwmon))
		return PTR_ERR(hwmon);
	for (i = 0; i < DX_BAYS; i++) {
		struct dx_led *led = &ds->dx_led[i];

		led->ds = ds;
		led->bay = i;
		snprintf(led->name, sizeof(led->name), "syno-dx1:orange:disk%d", i + 1);
		led->cdev.name = led->name;
		led->cdev.max_brightness = 1;
		led->cdev.brightness_set_blocking = dx_led_set;
		led->cdev.flags = LED_RETAIN_AT_SHUTDOWN;
		ret = devm_led_classdev_register(ds->dev, &led->cdev);
		if (ret)
			return ret;
	}
	return 0;
}

/* The DX1215 may be powered on after the NAS: look again every 30 s until found. */
static void dx_work_fn(struct work_struct *work)
{
	struct ds2415p *ds = container_of(to_delayed_work(work), struct ds2415p, dx_work);
	int ret;

	mutex_lock(&ds->dx_lock);
	ret = dx_scan(ds);
	if (!ret && !ds->dx_registered) {
		ret = dx_register(ds);
		if (ret)
			dev_warn(ds->dev, "DX1215 hwmon/LEDs: %d\n", ret);
		ds->dx_registered = !ret;
		if (!ret)
			dev_info(ds->dev, "DX1215 on %s, master ata%u\n",
				 pci_name(ds2415p_9235), ds->pmp[ds->master].ap->print_id);
	}
	mutex_unlock(&ds->dx_lock);
	if (!ds->dx_registered)
		schedule_delayed_work(&ds->dx_work, 30 * HZ);
}

/* ---------------------------------------------------------------- sysfs */

static ssize_t dx_model_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct ds2415p *ds = dev_get_drvdata(dev);
	bool found;

	mutex_lock(&ds->dx_lock);
	found = ds->master >= 0;
	mutex_unlock(&ds->dx_lock);
	return sysfs_emit(buf, "%s\n", found ? "DX1215" : "none");
}
static DEVICE_ATTR_RO(dx_model);

static ssize_t dx_switch_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct ds2415p *ds = dev_get_drvdata(dev);
	const char *s;

	mutex_lock(&ds->dx_lock);
	if (dx_master_fresh(ds))
		s = "unknown";
	else
		s = ds->mpage[3] & DX_P3_DEFAULT ? "default" : "manual";
	mutex_unlock(&ds->dx_lock);
	return sysfs_emit(buf, "%s\n", s);
}
static DEVICE_ATTR_RO(dx_switch);

static ssize_t dx_ports_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct ds2415p *ds = dev_get_drvdata(dev);
	ssize_t n = 0;
	int i;

	mutex_lock(&ds->dx_lock);
	for (i = 0; i < DX_PMPS; i++)
		if (ds->pmp[i].ap && ds->pmp[i].emid >= 0)
			n += sysfs_emit_at(buf, n, "ata%u %d\n", ds->pmp[i].ap->print_id,
					   ds->pmp[i].emid);
	mutex_unlock(&ds->dx_lock);
	return n;
}
static DEVICE_ATTR_RO(dx_ports);

static struct attribute *ds2415p_attrs[] = {
	&dev_attr_dx_model.attr,
	&dev_attr_dx_switch.attr,
	&dev_attr_dx_ports.attr,
	NULL
};
ATTRIBUTE_GROUPS(ds2415p);

/* ---------------------------------------------------------------- probe */

static bool bound_to_ahci(struct pci_dev *pdev)
{
	return pdev->dev.driver && !strcmp(pdev->dev.driver->name, "ahci") &&
	       pci_get_drvdata(pdev);
}

static int ds2415p_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ds2415p *ds;
	int i, ret;

	/* the device links make the controllers' ahci bind first */
	for (i = 0; i < DS_CTRLS; i++)
		if (!bound_to_ahci(ds2415p_9215[i]))
			return dev_err_probe(dev, -ENODEV, "%s not bound to ahci\n",
					     pci_name(ds2415p_9215[i]));
	if (!bound_to_ahci(ds2415p_9235))
		return dev_err_probe(dev, -ENODEV, "%s not bound to ahci\n",
				     pci_name(ds2415p_9235));

	ds = devm_kzalloc(dev, sizeof(*ds), GFP_KERNEL);
	if (!ds)
		return -ENOMEM;
	ds->dev = dev;
	ds->master = -1;
	mutex_init(&ds->dx_lock);
	INIT_DELAYED_WORK(&ds->dx_work, dx_work_fn);
	platform_set_drvdata(pdev, ds);

	if (disk_leds) {
		ret = ds_bays_probe(ds);
		if (ret)
			return ret;
	}

	ds->dx_host = pci_get_drvdata(ds2415p_9235);
	for (i = 0; i < DX_PMPS && i < ds->dx_host->n_ports; i++) {
		ds->pmp[i].ap = ds->dx_host->ports[i];
		ds->pmp[i].emid = -1;
	}
	/* the first scan sends ATA commands: not from probe */
	schedule_delayed_work(&ds->dx_work, 0);
	dev_info(dev, "Synology DS2415+ bay LEDs %s\n", disk_leds ? "on" : "left alone");
	return 0;
}

static void ds2415p_remove(struct platform_device *pdev)
{
	struct ds2415p *ds = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&ds->dx_work);
	/* GPIO 49 is SoC state: back to what it was. The 9215 setup stays, as in DSM. */
	ds_pch_set(ds, false);
}

static int ds2415p_resume(struct device *dev)
{
	struct ds2415p *ds = dev_get_drvdata(dev);
	int i;

	/* ahci resets the controllers on resume: set the GPIO block up again */
	if (disk_leds) {
		for (i = 0; i < DS_CTRLS; i++)
			if (ds->ctrl[i].mmio)
				ds_ctrl_init(&ds->ctrl[i]);
		ds_pch_set(ds, true);
	}
	mod_delayed_work(system_wq, &ds->dx_work, 0);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(ds2415p_pm, NULL, ds2415p_resume);

static struct platform_driver ds2415p_driver = {
	.driver = {
		.name = DRV_NAME,
		.dev_groups = ds2415p_groups,
		.pm = pm_sleep_ptr(&ds2415p_pm),
	},
	.probe = ds2415p_probe,
	.remove = ds2415p_remove,
};

/*
 * The board: the DS2415+ BIOS (Insyde, also used by other Avoton units) has
 * placeholder DMI strings, so DMI alone is not enough. The PCI topology is
 * checked as well: the Avoton PCU 8086:1f38 at 00:1f.0, exactly three
 * 88SE9215 and one 88SE9235. A DS923+ (AMD, "Synology Inc." DMI) never
 * matches either.
 */
static const struct dmi_system_id ds2415p_dmi[] = {
	{
		.matches = {
			DMI_EXACT_MATCH(DMI_SYS_VENDOR, "Insyde"),
			DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "MohonPeak"),
			DMI_EXACT_MATCH(DMI_BOARD_NAME, "Type2 - Board Product Name1"),
		},
	},
	{ }
};
MODULE_DEVICE_TABLE(dmi, ds2415p_dmi);

static void ds2415p_put_pci(void)
{
	int i;

	for (i = 0; i < DS_CTRLS; i++) {
		pci_dev_put(ds2415p_9215[i]);
		ds2415p_9215[i] = NULL;
	}
	pci_dev_put(ds2415p_9235);
	ds2415p_9235 = NULL;
}

static bool ds2415p_find_pci(void)
{
	struct pci_dev *lpc, *p = NULL;
	int n = 0;

	lpc = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(0x1f, 0));
	if (!lpc || lpc->vendor != PCI_VENDOR_ID_INTEL || lpc->device != 0x1f38) {
		pci_dev_put(lpc);
		return false;
	}
	pci_dev_put(lpc);
	/* in bus order: 03:00.0, 05:00.0, 06:00.0 = bays 1-4, 5-8, 9-12 */
	while ((p = pci_get_device(PCI_VENDOR_ID_MARVELL_EXT, 0x9215, p))) {
		if (n == DS_CTRLS) {
			pci_dev_put(p);
			goto fail;
		}
		ds2415p_9215[n++] = pci_dev_get(p);
	}
	while ((p = pci_get_device(PCI_VENDOR_ID_MARVELL_EXT, 0x9235, p))) {
		if (ds2415p_9235) {
			pci_dev_put(p);
			goto fail;
		}
		ds2415p_9235 = pci_dev_get(p);
	}
	if (n == DS_CTRLS && ds2415p_9235)
		return true;
fail:
	ds2415p_put_pci();
	return false;
}

static int __init ds2415p_init(void)
{
	int i, ret;

	if (!dmi_check_system(ds2415p_dmi) || !ds2415p_find_pci())
		return -ENODEV;

	ds2415p_pdev = platform_device_register_simple(DRV_NAME, PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(ds2415p_pdev)) {
		ret = PTR_ERR(ds2415p_pdev);
		goto err_pci;
	}
	/* probe once ahci has bound the controllers, again after a rebind */
	for (i = 0; i < DS_CTRLS + 1; i++) {
		struct pci_dev *s = i < DS_CTRLS ? ds2415p_9215[i] : ds2415p_9235;

		if (!device_link_add(&ds2415p_pdev->dev, &s->dev, DL_FLAG_AUTOPROBE_CONSUMER)) {
			ret = -EINVAL;
			goto err_dev;
		}
	}
	ret = platform_driver_register(&ds2415p_driver);
	if (ret)
		goto err_dev;
	return 0;

err_dev:
	platform_device_unregister(ds2415p_pdev);	/* drops the links */
err_pci:
	ds2415p_put_pci();
	return ret;
}

static void __exit ds2415p_exit(void)
{
	platform_driver_unregister(&ds2415p_driver);
	platform_device_unregister(ds2415p_pdev);
	ds2415p_put_pci();
}

module_init(ds2415p_init);
module_exit(ds2415p_exit);

MODULE_DESCRIPTION("Synology DS2415+ bay LEDs and DX1215 expansion unit");
MODULE_LICENSE("GPL");
