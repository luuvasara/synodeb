#!/usr/bin/python3 -I
"""Offline tests for synohwd (no hardware needed): python3 -I synohwd/test_synohwd.py"""
import importlib.util
import os
import stat
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("synohwd", os.path.join(HERE, "synohwd.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = 0


def check(name, got, want):
    global failures
    ok = got == want
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got!r}" + ("" if ok else f" (expected {want!r})"))


class Feed:
    """Hand-driven parser with a fake clock."""

    def __init__(self):
        self.events, self.replies, self.now = [], [], 1000.0
        self.p = m.Parser(self.events.append, self.replies.append)

    def want(self, cmd):
        self.p.expect, self.p.expect_until = cmd, self.now + 1.0

    def bytes(self, data, step=0.0001):
        for b in data:
            self.now += step
            self.p.feed(b, self.now)
        return self

    def wait(self, s):
        self.now += s
        self.p.tick(self.now)
        return self


# --- parser ---
f = Feed(); f.want("D"); f.bytes("D123X")
check("D normal", (f.replies, f.events), (["123"], []))
f = Feed(); f.want("D"); f.bytes("D*2X")
check("D with '*'", f.replies, ["02"])
f = Feed(); f.want("D"); f.bytes("D12a")
check("D without X, then reset 'a'", (f.replies, f.events), ([], ["a"]))
f = Feed(); f.want("D"); f.bytes("D12").wait(0.6).bytes("0")
check("D timed out (0.5 s), then power '0'", (f.replies, f.events), ([], ["0"]))
f = Feed(); f.want("D"); f.bytes("D12"); f.now += 0.6; f.bytes("0")
check("D timed out without tick, power '0'", f.events, ["0"])
f = Feed(); f.bytes("D0")
check("unsolicited 'D': power not lost", f.events, ["D", "0"])
f = Feed(); f.want("D"); f.bytes("D123456789X0")
check("D too long", (f.replies, f.events), ([], ["X", "0"]))
f = Feed(); f.want("R"); f.bytes("+3abc0")
check("valid '+' frame", (f.replies, f.events), (["abc"], ["0"]))
f = Feed(); f.want("R"); f.bytes("+\xff0")
check("frame with absurd length", (f.replies, f.events), ([], ["\xff", "0"]))
f = Feed(); f.want("R"); f.bytes("+0")
check("frame length 0 = power", f.events, ["0"])
f = Feed(); f.want("R"); f.bytes("+a")
check("frame length 'a' = reset", f.events, ["a"])
f = Feed(); f.want("R"); f.bytes("+9ab").wait(0.6).bytes("a")
check("truncated frame, then reset", (f.replies, f.events), ([], ["a"]))
f = Feed(); f.bytes("+3abc")
check("unsolicited '+'", f.events, list("+3abc"))

# real reader on a pipe, MicroP without UART
r, w = os.pipe()
up = m.MicroP.__new__(m.MicroP); up.fd = r; up.init_common()
ev, err = [], []


def reader():
    try:
        up.reader(ev.append)
    except OSError as e:
        err.append(str(e))


t = threading.Thread(target=reader, daemon=True); t.start()
os.write(w, b"0a")
time.sleep(0.3)
check("reader: events", ev, ["0", "a"])
up.parser.want("D", 1.0); os.write(w, b"D42X"); time.sleep(0.3)
check("reader: D reply", up.reply, "42")
os.close(w); t.join(3)
check("reader: EOF -> exception", (t.is_alive(), err), (False, ["uP UART: end of file"]))

# --- '1' blocking ---
for cmd, ok in [("V10", True), ("V99", True), ("V01", True), ("V10V11", True), ("2", True),
                ("1", False), ("21", False), ("V1", False), ("V101", False), ("LA1", False),
                ("1V10", False), ("", False)]:
    try:
        m.check_cmd(cmd); got = True
    except ValueError:
        got = False
    check(f"check_cmd {cmd!r}", got, ok)

up2 = m.MicroP.__new__(m.MicroP); up2.init_common(); up2.fd = None
try:
    up2.send("21"); refused = False
except ValueError:
    refused = True
check("MicroP.send('21') refused before writing", refused, True)

# --- fan hysteresis (quiet disk table) ---
fan = m.Fan(dict(m.DEFAULTS)); tab = m.FAN_TABLES["low"]["disk"]
seq = [40, 47, 53, 50, 49, 45, 43, 42, 59, 56, 55, 54]
check("hysteresis", [fan.step("disk", x, tab) for x in seq],
      [50, 60, 70, 70, 60, 60, 50, 50, 99, 99, 80, 80])
fan = m.Fan(dict(m.DEFAULTS))
s = {"cpu": 50, "disk": {"bay1": 62}, "nvme": {}, "nic": {}}
duty, crit = fan.duty(s)
check("duty with a disk at 62 °C", (duty, crit is not None), (99, True))

# --- thermal shutdown: 2 consecutive readings ---
th = m.Thermal()
check("thermal: threshold, normal, threshold", [th.update(x) for x in ("c", None, "c")],
      [False, False, False])
check("thermal: second in a row", th.update("c"), True)

# --- absurd temperatures discarded ---
with tempfile.TemporaryDirectory() as d:
    for n, v in ((1, 200000), (2, 45000), (3, -30000)):
        with open(f"{d}/temp{n}_input", "w") as fh:
            fh.write(str(v))
    check("hwmon_temp discards >150 and <-20", m.hwmon_temp(d), 45.0)

# --- fan failure ---
fh_ = m.FanHealth()
check("alarm 1 cycle", fh_.update([1, 0], 0), False)
check("alarm 2 cycles", fh_.update([1, 0], 20), True)
check("alarm cleared", fh_.update([0, 0], 40), False)
fh_.event(100)
check("recent 'f' event", fh_.update([0, 0], 110), True)
check("'f' event after 60 s", fh_.update([0, None], 161), False)

# --- hdparm -C (fake) ---
with tempfile.TemporaryDirectory() as d:
    hp = f"{d}/hdparm"
    with open(hp, "w") as fh:
        fh.write('#!/bin/sh\nprintf "\\n%s:\\n drive state is:  $STATE\\n" "$2"\n')
    os.chmod(hp, stat.S_IRWXU)
    old = os.environ["PATH"]; os.environ["PATH"] = f"{d}:{old}"
    os.environ["STATE"] = "standby"; check("hdparm standby", m.disk_asleep("sda"), True)
    os.environ["STATE"] = "active/idle"; check("hdparm active", m.disk_asleep("sda"), False)
    os.environ["PATH"] = "/nonexistent"; check("hdparm missing", m.disk_asleep("sda"), None)
    os.environ["PATH"] = old

# --- disk LEDs: bay -> ATA port -> kernel trigger ---
check("led empty bay", m.led_target(False, None, None, None), ("none", 0, 0))
check("led disk not detected", m.led_target(True, None, None, None), ("none", 1, 0))
check("led disk ok", m.led_target(True, "sda", 5, "running"), ("ata5", 1, 0))
check("led disk in error", m.led_target(True, "sda", 5, "offline"), ("none", 0, 1))
with tempfile.TemporaryDirectory() as d:
    # fake sysfs: JMB585 (00:01.5) ports ata1..ata5, FCH (00:08.2) ata7, ata8
    jmb = f"{d}/devices/pci0000:00/0000:00:01.5/0000:02:00.0"
    fch = f"{d}/devices/pci0000:00/0000:00:08.2/0000:0c:00.0"
    for c, ports in ((jmb, (1, 2, 3, 4, 5)), (fch, (7, 8))):
        for n in ports:
            os.makedirs(f"{c}/ata{n}/host{n}/target{n}:0:0/{n}:0:0:0")
        os.makedirs(f"{c}/ata_link_x", exist_ok=True)      # non-numeric ata* name
    os.makedirs(f"{d}/block")
    for dev, c, n in (("sda", jmb, 2), ("sdb", fch, 7), ("sdc", fch, 8)):
        os.makedirs(f"{d}/block/{dev}")
        os.symlink(f"{c}/ata{n}/host{n}/target{n}:0:0/{n}:0:0:0", f"{d}/block/{dev}/device")
    with open(f"{fch}/ata8/host8/target8:0:0/8:0:0:0/state", "w") as fh:
        fh.write("offline\n")
    with open(f"{fch}/ata7/host7/target7:0:0/7:0:0:0/state", "w") as fh:
        fh.write("running\n")
    m.SYS_BLOCK = f"{d}/block"
    check("bay_disks", m.bay_disks(), {2: ("sda", 2), 3: ("sdb", 7), 4: ("sdc", 8)})
    check("bay_block_devices", m.bay_block_devices(), {2: "sda", 3: "sdb", 4: "sdc"})
    # fake LEDs and presence
    m.LEDS, m.PLATFORM = f"{d}/leds", f"{d}/platform"
    os.makedirs(m.PLATFORM)
    for b, p in ((1, 0), (2, 1), (3, 1), (4, 1)):
        with open(f"{m.PLATFORM}/bay{b}_present", "w") as fh:
            fh.write(f"{p}\n")
    for b in range(1, 5):
        for col in ("green", "orange"):
            os.makedirs(f"{m.LEDS}/syno:{col}:disk{b}")
            for a, v in (("trigger", "[none] disk-activity ata1 ata2 ata3 ata4 ata5 ata7 ata8"),
                         ("brightness", "9")):
                with open(f"{m.LEDS}/syno:{col}:disk{b}/{a}", "w") as fh:
                    fh.write(v)
    dm = m.Daemon.__new__(m.Daemon)

    def leds():
        return {b: tuple(m.read(f"{m.LEDS}/syno:{c}:disk{b}/{a}")
                         for c, a in (("green", "trigger"), ("green", "brightness"),
                                      ("orange", "brightness")))
                for b in range(1, 5)}

    shown = {}
    dm.led_step(shown, 255)
    check("led_step full brightness", leds(),
          {1: ("none", "0", "0"), 2: ("ata2", "9", "0"), 3: ("ata7", "9", "0"),
           4: ("none", "0", "255")})
    os.unlink(f"{d}/block/sdb/device")                        # disk 3 gone, bay occupied
    dm.led_step(shown, 255)
    check("led_step disk not detected", leds()[3], ("none", "255", "0"))
    shown = {}
    dm.led_step(shown, 40)
    check("led_step dimmed: trigger + brightness", leds()[2], ("ata2", "40", "0"))
    with open(f"{m.LEDS}/syno:green:disk2/trigger", "w") as fh:
        fh.write("[none] disk-activity")                      # kernel without ATA_LEDS
    shown = {}
    dm.led_step(shown, 255)
    check("led_step without ataN trigger: steady green", leds()[2], ("none", "255", "0"))

# --- synohwd send without the daemon ---
with tempfile.TemporaryDirectory() as d:
    m.CMD_FIFO = f"{d}/cmd"

    def send(cmd):
        try:
            m.send(cmd); return "ok"
        except SystemExit as e:
            return str(e)

    check("send without FIFO", "is not running" in send("2"), True)
    os.mkfifo(m.CMD_FIFO, 0o600)
    check("send FIFO without reader (ENXIO)", "nobody reads" in send("2"), True)
    rd = os.open(m.CMD_FIFO, os.O_RDWR)
    check("send with reader", send("V50"), "ok")
    check("send read back", os.read(rd, 64), b"V50\n")
    check("send '1' refused", send("1").startswith("refused"), True)
    os.close(rd)

# ================================================================ DS2415+ (model ds2415p)

# --- the uP allow-list: measured bytes only, never 1, C, 3 or V below 10 ---
for cmd, ok in [("u", True), ("4", True), ("8", True), ("W20", True), ("V10", True),
                ("V99", True), ("2", True), (";", True), (":", True), ("LA1", True),
                ("LA3", True), ("LE2", True), ("O", True), ("q", True), ("p", True),
                ("s", True), ("r", True), ("l", True), ("k", True), ("t", True), ("5", True),
                ("7", True), ("@", True), ("1", False), ("C", False), ("3", False),
                ("V09", False), ("V9", False), ("V100", False), ("W10", False), ("LA4", False),
                ("uu", False), ("V20V30", False), ("R", False), ("D", False), ("", False)]:
    try:
        m.ds2415p_check_cmd(cmd); got = True
    except ValueError:
        got = False
    check(f"ds2415p_check_cmd {cmd!r}", got, ok)


class Rec:
    """MicroP stand-in: the model's check, then the command is recorded."""

    def __init__(self, check):
        self.sent, self.check = [], check

    def send(self, cmd):
        self.check(cmd)
        self.sent.append(cmd)


up3 = m.MicroP.__new__(m.MicroP); up3.init_common(m.ds2415p_check_cmd); up3.fd = None
try:
    up3.send("3"); refused = False
except ValueError:
    refused = True
check("ds2415p MicroP.send('3') refused before writing", refused, True)


def s_(cpu=None, disk=None, dx=None, asleep=()):
    return {"cpu": cpu, "disk": dict(disk or {}), "dx": dict(dx or {}), "nvme": {}, "nic": {},
            "asleep": list(asleep)}


# --- DS2415+ fan: scemd.xml tables, alert band, shutdown, unreadable floors ---
fan = m.DS2415PFan(dict(m.DEFAULTS))
check("ds2415p low table", [fan.step("disk", t, m.DS2415P_FAN_TABLES["low"]["disk"])
                            for t in (30, 46, 50, 54, 52, 48, 40)], [20, 40, 70, 99, 99, 70, 20])
fan = m.DS2415PFan(dict(m.DEFAULTS))
check("ds2415p idle", fan.duty(s_(40, {"bay1": 30})), (20, None, False))
check("ds2415p cpu 66", fan.duty(s_(66, {"bay1": 30}))[0], 70)
fan = m.DS2415PFan(dict(m.DEFAULTS))
d, c, a = fan.duty(s_(40, {"bay1": 58}))
check("ds2415p disk 58: 99 %, alert, no shutdown", (d, c, a), (99, None, True))
d, c, a = fan.duty(s_(40, {"bay1": 61}))
check("ds2415p disk 61: shutdown", (d, c is not None, a), (99, True, True))
fan = m.DS2415PFan(dict(m.DEFAULTS, fan_mode="high"))
check("ds2415p high table, disk 45", fan.duty(s_(40, {"bay1": 45}))[0], 70)
fan = m.DS2415PFan(dict(m.DEFAULTS))
check("ds2415p cpu unreadable: 70 %", fan.duty(s_(None, {"bay1": 30}))[0], 70)
check("ds2415p disk awake, no reading: 70 %", fan.duty(s_(40, {"bay1": None}))[0], 70)
check("ds2415p nothing readable: 99 %", fan.duty(s_(None, {}))[0], 99)
check("ds2415p fan_mode full", m.DS2415PFan(dict(m.DEFAULTS, fan_mode="full")).duty(s_(30)),
      (99, None, False))
check("ds2415p never below 10 %", min(m.DS2415PFan(dict(m.DEFAULTS, fan_min_duty=-5))
                                       .duty(s_(t, {"bay1": t}))[0] for t in range(-20, 150)),
      20)

# --- DX1215 level: DSM's table, hysteresis, asleep, no reading, alarm, never stop ---
dxf = m.Fan(dict(m.DEFAULTS)); conf = dict(m.DEFAULTS)
check("dx1215 table + hysteresis",
      [m.dx1215_level(dxf, conf, s_(dx={"dx8": t}), False)[0] for t in (40, 48, 55, 54, 52, 47, 45)],
      ["low", "middle", "full", "full", "middle", "middle", "low"])
dxf = m.Fan(dict(m.DEFAULTS))
check("dx1215 asleep", m.dx1215_level(dxf, conf, s_(asleep=["dx8"]), False)[:2],
      ("low", "disks asleep"))
check("dx1215 awake without reading", m.dx1215_level(dxf, conf, s_(dx={"dx8": None}), False)[0],
      "middle")
check("dx1215 no disk", m.dx1215_level(dxf, conf, s_(), False)[0], "middle")
check("dx1215 alarm", m.dx1215_level(dxf, conf, s_(dx={"dx8": 30}), True)[:2], ("full", "fan alarm"))
lv, why, crit = m.dx1215_level(m.Fan(dict(m.DEFAULTS)), conf, s_(dx={"dx8": 61}), False)
check("dx1215 61 °C: full + shutdown", (lv, crit is not None), ("full", True))
check("dx1215 fan_mode full",
      m.dx1215_level(m.Fan(dict(m.DEFAULTS)), dict(m.DEFAULTS, fan_mode="full"), s_(dx={"dx1": 20}),
                     False)[0], "full")
dxf = m.Fan(dict(m.DEFAULTS))
levels = {m.dx1215_level(dxf, conf, s_(dx={"dx1": t}), a)[0] for t in range(-20, 151) for a in (0, 1)}
check("dx1215 levels used (never stop)", sorted(levels), ["full", "low", "middle"])

# --- fake DS2415+ sysfs: PCI, bays, platform device, LEDs, DX1215 hwmon, tty, DMI ---
with tempfile.TemporaryDirectory() as d:
    def put(path, value):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(value)

    m.SYS_PCI, m.SYS_BLOCK, m.LEDS = f"{d}/pci", f"{d}/block", f"{d}/leds"
    m.DS2415P_PLATFORM, m.SYS_TTY, m.SYS_RTC = f"{d}/platform", f"{d}/tty", f"{d}/rtc"
    m.DMI_ID, m.STATUS = f"{d}/dmi", f"{d}/status.json"
    root = f"{d}/devices/pci0000:00"
    ctrl = {"0000:03:00.0": (7, 8, 9, 10), "0000:05:00.0": (11, 12, 13, 14),
            "0000:06:00.0": (15, 16, 17, 18), "0000:07:00.0": (19, 20, 21, 22)}
    for pci, ports in ctrl.items():
        put(f"{m.SYS_PCI}/{pci}/vendor", "0x1b4b\n")
        put(f"{m.SYS_PCI}/{pci}/device", "0x9235\n" if pci == "0000:07:00.0" else "0x9215\n")
        for n in ports:
            os.makedirs(f"{root}/0000:00:01.0/0000:02:00.0/{pci}/ata{n}/host{n - 1}")
    put(f"{m.SYS_PCI}/0000:00:1f.0/vendor", "0x8086\n")
    put(f"{m.SYS_PCI}/0000:00:1f.0/device", "0x1f38\n")

    def disk(dev, pci, ata, chan=0):
        h = ata - 1
        t = f"{root}/0000:00:01.0/0000:02:00.0/{pci}/ata{ata}/host{h}/target{h}:{chan}:0/{h}:{chan}:0:0"
        os.makedirs(t)
        put(f"{t}/state", "running\n")
        os.makedirs(f"{m.SYS_BLOCK}/{dev}")
        os.symlink(t, f"{m.SYS_BLOCK}/{dev}/device")
        return t

    disk("sda", "0000:03:00.0", 7)              # measured: the Seagate, DS bay 1
    tb = disk("sdb", "0000:06:00.0", 17)        # DS bay 11
    tc = disk("sdc", "0000:07:00.0", 21, 1)     # measured: the WD, ata21.01, DX bay 8
    disk("sdd", "0000:07:00.0", 19, 0)          # DX bay 1
    disk("sde", "0000:07:00.0", 20, 3)          # fan-out port 3: not a bay
    check("ds2415p bays without the driver: DS only", m.ds2415p_bay_disks(),
          ({1: ("sda", 7), 11: ("sdb", 17)}, {}))
    put(f"{m.DS2415P_PLATFORM}/dx_ports", "ata19 0\nata20 1\nata21 2\nata22 3\n")
    put(f"{m.DS2415P_PLATFORM}/dx_switch", "default\n")
    check("ds2415p bay map (DS 4*ctrl+port+1, DX 3*EMID+port+1)", m.ds2415p_bay_disks(),
          ({1: ("sda", 7), 11: ("sdb", 17)}, {1: ("sdd", 19), 8: ("sdc", 21)}))

    # tty by I/O port, model detection
    put(f"{m.SYS_TTY}/ttyS0/port", "0x3F8\n"); put(f"{m.SYS_TTY}/ttyS1/port", "0x2F8\n")
    check("ds2415p uP tty (port 0x2F8)", m.ds2415p_up_tty(), "/dev/ttyS1")
    check("model from conf", m.board_model({"model": "ds923"}), "ds923")
    check("model auto: platform device", m.board_model({"model": "auto"}), "ds2415p")
    os.rename(m.DS2415P_PLATFORM, f"{d}/platform.off")
    put(f"{m.DMI_ID}/sys_vendor", "Insyde\n"); put(f"{m.DMI_ID}/product_name", "MohonPeak\n")
    check("model auto: DMI + Avoton LPC", m.board_model({}), "ds2415p")
    put(f"{m.DMI_ID}/sys_vendor", "Synology Inc.\n"); put(f"{m.DMI_ID}/product_name", "DS923+\n")
    check("model auto: DS923+", m.board_model({}), "ds923")
    check("model auto: DS923+ keeps its rule", m.model_check_cmd({}), m.check_cmd)
    os.rename(f"{d}/platform.off", m.DS2415P_PLATFORM)

    # drivetemp + hwmon of the driver, a fake coretemp; hdparm absent (disks count as awake)
    for blk, t in (("sda", 31000), ("sdb", 33000), ("sdc", 50000), ("sdd", 30000)):
        put(f"{os.path.realpath(m.SYS_BLOCK + '/' + blk + '/device')}/hwmon/hwmon9/temp1_input", str(t))
    core = f"{d}/coretemp"
    put(f"{core}/temp1_input", "45000")
    real_hwmon_by_name = m.hwmon_by_name
    m.hwmon_by_name = lambda name: [core] if name == "coretemp" else []
    hw = f"{m.DS2415P_PLATFORM}/hwmon/hwmon3"
    for f_, v in (("name", "synology_dx1215"), ("fan1_alarm", "0"), ("fan2_alarm", "0"), ("pwm1", "64")):
        put(f"{hw}/{f_}", v + "\n")
    for b in range(1, 13):
        for pre in ("syno", "syno-dx1"):
            put(f"{m.LEDS}/{pre}:orange:disk{b}/brightness", "9")
    old_path = os.environ["PATH"]; os.environ["PATH"] = "/nonexistent"

    dm = m.DS2415PDaemon.__new__(m.DS2415PDaemon)
    dm.conf = dict(m.DEFAULTS); dm.up = Rec(m.ds2415p_check_cmd); dm.init_state()
    dm.startup()
    check("ds2415p startup bytes", dm.up.sent, ["u", "4", "8", "W20", "2", "q"])
    dm.up.sent = []
    dm.event("0"); dm.event("3"); dm.event("K")
    check("ds2415p uP bytes are only logged ('0' is no power button here)",
          (dm.up.sent, sorted(dm.seen)), ([], ["0", "3", "K"]))

    dm.control_step(1000.0)
    check("ds2415p control: duty, alert LED off", dm.up.sent, ["V20", "LA3"])
    check("dx1215 control: disk 50 °C -> middle written", (m.read(f"{hw}/pwm1"), dm.state["dx"]["want"],
          dm.state["dx"]["switch"]), ("128", "middle", "default"))
    st = m.json.load(open(m.STATUS))
    check("status.json bays", (st["bays"]["1"], st["bays"]["dx8"], st["sensors"]["dx"]["dx8"]),
          ({"present": True, "device": "sda"}, {"present": True, "device": "sdc"}, 50.0))
    dm.up.sent = []
    put(f"{hw}/fan2_alarm", "1\n")
    dm.control_step(1020.0)
    check("dx1215 alarm: full, beep '2', status orange blink", (m.read(f"{hw}/pwm1"), dm.up.sent,
          dm.state["fan_fail"]), ("255", ["2", ";"], True))
    put(f"{hw}/fan2_alarm", "0\n")
    put(f"{os.path.realpath(m.SYS_BLOCK + '/sdb/device')}/hwmon/hwmon9/temp1_input", "58000")
    dm.up.sent = []
    dm.control_step(1040.0)
    check("ds2415p disk 58 °C: 99 %, orange blink, alert LED", dm.up.sent, ["V99", "LA1"])
    put(f"{os.path.realpath(m.SYS_BLOCK + '/sdb/device')}/hwmon/hwmon9/temp1_input", "33000")
    dm.up.sent = []
    dm.control_step(1060.0)
    check("ds2415p cooled: duty back down, green, alert LED off", dm.up.sent,
          ["V20", "8", "LA3"])
    dm.up.sent = []
    dm.control_step(1060.0 + m.DS2415P_REASSERT)
    check("ds2415p re-sends the duty after DS2415P_REASSERT s", dm.up.sent, ["V20"])

    # DX1215 not answering: nothing written, no alarm
    for f_ in ("fan1_alarm", "fan2_alarm", "pwm1"):
        os.rename(f"{hw}/{f_}", f"{hw}/{f_}.off")
    dm.up.sent = []
    dm.control_step(1080.0 + m.DS2415P_REASSERT)
    check("dx1215 not answering: unavailable, no alarm, nothing sent",
          (dm.state["dx"]["why"], dm.state["fan_fail"], dm.up.sent), ("unavailable", False, []))
    for f_ in ("fan1_alarm", "fan2_alarm", "pwm1"):
        os.rename(f"{hw}/{f_}.off", f"{hw}/{f_}")

    # orange LEDs: a disk in error
    put(f"{tb}/state", "offline\n"); put(f"{tc}/state", "offline\n")
    shown = {}
    dm.led_step(shown, 255)
    lit = sorted(n for n in shown if shown[n])
    check("ds2415p orange LEDs for disks in error", lit, ["syno-dx1:orange:disk8", "syno:orange:disk11"])
    check("ds2415p LED written", (m.read(f"{m.LEDS}/syno:orange:disk11/brightness"),
          m.read(f"{m.LEDS}/syno:orange:disk1/brightness")), ("1", "0"))

    # shutdown sequence
    put(f"{m.SYS_RTC}/rtc0/wakealarm", "\n")
    dm.up.sent = []
    dm.shutdown()
    check("ds2415p shutdown bytes", dm.up.sent, ["r", "k", "q", "V99", "t", "5", "7"])
    check("ds2415p shutdown: DX1215 full, LEDs off", (m.read(f"{hw}/pwm1"),
          m.read(f"{m.LEDS}/syno:orange:disk11/brightness")), ("255", "0"))

    # keepalive 'u' every DS2415P_KEEPALIVE s
    m.DS2415P_KEEPALIVE = 0.05
    dm.up.sent = []
    th = threading.Thread(target=dm.keepalive_loop, daemon=True); th.start()
    time.sleep(0.3); dm.stop.set(); th.join(2)
    check("ds2415p keepalive 'u' repeats", (set(dm.up.sent), len(dm.up.sent) >= 3), ({"u"}, True))
    os.environ["PATH"] = old_path
    m.hwmon_by_name = real_hwmon_by_name

# --- synohwd send with the DS2415+ rule ---
with tempfile.TemporaryDirectory() as d:
    m.CMD_FIFO = f"{d}/cmd"
    os.mkfifo(m.CMD_FIFO, 0o600)
    rd = os.open(m.CMD_FIFO, os.O_RDWR)

    def send2(cmd):
        try:
            m.send(cmd, m.ds2415p_check_cmd); return "ok"
        except SystemExit as e:
            return str(e)

    check("ds2415p send '3' refused", send2("3").startswith("refused"), True)
    check("ds2415p send 'LA1'", (send2("LA1"), os.read(rd, 64)), ("ok", b"LA1\n"))
    os.close(rd)

print("ALL OK" if not failures else f"{failures} FAILED")
raise SystemExit(1 if failures else 0)
