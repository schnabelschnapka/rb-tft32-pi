#!/usr/bin/env python3
# spi-dash.py - zeichnet ein Systemdashboard in den SPI-Framebuffer (Standard: /dev/fb1).
import datetime, glob, mmap, os, socket, time
from PIL import Image, ImageDraw, ImageFont

try:
    import numpy as np
except ImportError:
    np = None

FB_DEV = os.environ.get("FB_DEV", "")          # leer = /dev/fb$FB_IDX
FB_IDX = os.environ.get("FB_IDX", "1")
FB_SYS = os.environ.get("FB_SYS", "/sys/class/graphics")
ROTATE = int(os.environ.get("ROTATE", "0"))
INTERVAL = float(os.environ.get("INTERVAL", "1"))
PREVIEW = os.environ.get("PREVIEW", "")        # PNG speichern und beenden
MAX_FRAMES = int(os.environ.get("MAX_FRAMES", "0"))

BG = (12, 16, 24)
GRID = (40, 50, 64)
DIM = (120, 135, 150)
WHITE = (235, 240, 245)
ACCENT = (90, 170, 255)
BAR_BG = (30, 38, 50)
FONT_PATHS = ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
LAST_Y = 0
LAST_H = 0
_fonts = {}
_prev = {}


def log(msg):
    print(datetime.datetime.now().strftime("%H:%M:%S"), msg, flush=True)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def font(size):
    if size not in _fonts:
        f = None
        for p in FONT_PATHS:
            if os.path.exists(p):
                f = ImageFont.truetype(p, size)
                break
        _fonts[size] = f or ImageFont.load_default()
    return _fonts[size]


def find_fb():
    if FB_DEV:
        return FB_DEV, f"{FB_SYS}/fb{FB_IDX}"
    for sysdir in sorted(glob.glob(f"{FB_SYS}/fb*")):
        name = read(f"{sysdir}/name")
        if name and "vc4" not in name.lower():
            return f"/dev/fb{os.path.basename(sysdir)[2:]}", sysdir
    return None, None


def fb_geometry(sysdir):
    try:
        w, h = [int(v) for v in read(f"{sysdir}/virtual_size", "").split(",")]
    except ValueError:
        w, h = 480, 320
    bpp = int(read(f"{sysdir}/bits_per_pixel", "16") or 16)
    return w, h, bpp


def cpu_usage():
    res = {}
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            p = line.split()
            v = [int(x) for x in p[1:]]
            total, idle = sum(v), v[3] + v[4]
            if p[0] in _prev:
                pt, pi = _prev[p[0]]
                dt, di = total - pt, idle - pi
                res[p[0]] = 100.0 * (1 - di / dt) if dt > 0 else 0.0
            else:
                res[p[0]] = 0.0
            _prev[p[0]] = (total, idle)
    total_pct = res.pop("cpu", 0.0)
    cores = [res[k] for k in sorted(res, key=lambda s: int(s[3:]))]
    return total_pct, cores


def ip_addr():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "-"


def metrics():
    cpu, cores = cpu_usage()
    mem = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        if v.strip():
            mem[k] = int(v.split()[0])
    total = mem.get("MemTotal", 1)
    avail = mem.get("MemAvailable", 0)
    st = os.statvfs("/")
    temp = int(read("/sys/class/thermal/thermal_zone0/temp", "0") or 0) / 1000
    freq = int(read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "0") or 0) / 1000
    up = int(float((read("/proc/uptime", "0").split() or ["0"])[0]))
    days, rem = divmod(up, 86400)
    hours, rem = divmod(rem, 3600)
    uptime = f"{days}d {hours}h {rem // 60}m" if days else f"{hours}h {rem // 60}m"
    return {
        "host": socket.gethostname(),
        "cpu": cpu,
        "cores": cores,
        "temp": temp,
        "freq": freq,
        "load": os.getloadavg(),
        "ram": 100.0 * (1 - avail / max(1, total)),
        "ram_txt": f"{(total - avail) / 1024:.0f}/{total / 1024:.0f} MB",
        "disk": 100.0 * (1 - st.f_bavail / max(1, st.f_blocks)),
        "disk_txt": f"{st.f_bavail * st.f_frsize / 1e9:.1f} GB frei",
        "uptime": uptime,
        "ip": ip_addr(),
    }


def color_for(pct):
    if pct < 60:
        return (60, 200, 120)
    if pct < 85:
        return (240, 190, 60)
    return (230, 80, 70)


def color_for_temp(t):
    if t < 60:
        return (60, 200, 120)
    if t < 70:
        return (240, 190, 60)
    return (230, 80, 70)


def bar(d, x, y, w, h, pct):
    pct = max(0.0, min(100.0, pct))
    d.rectangle([x, y, x + w, y + h], fill=BAR_BG)
    fill = int((w - 2) * pct / 100)
    if fill > 0:
        d.rectangle([x + 1, y + 1, x + 1 + fill, y + h - 1], fill=color_for(pct))


def lh(f):
    return f.getbbox("Ag")[3] + 3


def build(W, H):
    global LAST_Y, LAST_H
    m = metrics()
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    pad = max(4, W // 60)
    f_s = font(max(9, H // 23))
    f_m = font(max(11, H // 17))
    f_l = font(max(16, H // 7))
    x0, x1 = pad, W - pad
    cw = (x1 - x0 - pad) // 2
    y = pad

    # Kopfzeile
    d.text((x0, y), m["host"], font=f_m, fill=DIM)
    clock = datetime.datetime.now().strftime("%H:%M:%S")
    d.text((x1 - d.textlength(clock, font=f_m), y), clock, font=f_m, fill=WHITE)
    y += lh(f_m)
    d.line([x0, y, x1, y], fill=GRID)
    y += pad

    # CPU gesamt
    d.text((x0, y), "CPU", font=f_m, fill=ACCENT)
    txt = f"{m['cpu']:.0f} %"
    d.text((x1 - d.textlength(txt, font=f_l), y), txt, font=f_l, fill=color_for(m["cpu"]))
    y += lh(f_l)
    bh = max(6, H // 36)
    bar(d, x0, y, x1 - x0, bh, m["cpu"])
    y += bh + pad

    # Kerne, zwei Spalten
    lw = int(d.textlength("C0 ", font=f_s)) + 2
    tw = int(d.textlength("100%", font=f_s))
    for i, c in enumerate(m["cores"]):
        cx = x0 + (i % 2) * (cw + pad)
        cy = y + (i // 2) * (lh(f_s) + 2)
        d.text((cx, cy), f"C{i}", font=f_s, fill=DIM)
        bar(d, cx + lw, cy + 3, cw - lw - tw - pad, lh(f_s) - 6, c)
        pct_txt = f"{c:.0f}%"
        d.text((cx + cw - d.textlength(pct_txt, font=f_s), cy), pct_txt, font=f_s, fill=WHITE)
    rows = (len(m["cores"]) + 1) // 2
    y += rows * (lh(f_s) + 2) + pad // 2

    # Werte
    info = [
        ("Temperatur", f"{m['temp']:.1f} °C", color_for_temp(m["temp"])),
        ("Takt", f"{m['freq']:.0f} MHz", WHITE),
        ("Last 1/5/15", " ".join(f"{v:.2f}" for v in m["load"]), WHITE),
        ("Laufzeit", m["uptime"], WHITE),
    ]
    for label, value, col in info:
        d.text((x0, y), label, font=f_s, fill=DIM)
        d.text((x1 - d.textlength(value, font=f_s), y), value, font=f_s, fill=col)
        y += lh(f_s)
    y += pad // 2

    # RAM und Speicher
    for label, pct, detail in [("RAM", m["ram"], m["ram_txt"]), ("Speicher", m["disk"], m["disk_txt"])]:
        d.text((x0, y), label, font=f_s, fill=DIM)
        d.text((x1 - d.textlength(detail, font=f_s), y), detail, font=f_s, fill=WHITE)
        y += lh(f_s)
        bar(d, x0, y, x1 - x0, max(5, bh // 2 + 1), pct)
        y += max(5, bh // 2 + 1) + pad // 2

    # Fusszeile
    foot_y = H - pad - lh(f_s)
    d.text((x0, foot_y), f"IP {m['ip']}", font=f_s, fill=DIM)
    d.text((x1 - d.textlength("Pi 3", font=f_s), foot_y), "Pi 3", font=f_s, fill=DIM)
    LAST_Y, LAST_H = y, H
    return img


def frame(fw, fh):
    if ROTATE in (90, 270):
        img = build(fh, fw).rotate(ROTATE, expand=True)
    else:
        img = build(fw, fh)
    if img.size != (fw, fh):
        img = img.resize((fw, fh))
    return img


def to_bytes(img, bpp):
    if bpp == 32:
        r, g, b = img.split()
        return Image.merge("RGBA", (b, g, r, Image.new("L", img.size, 255))).tobytes()
    if np is not None:
        a = np.asarray(img, dtype=np.uint16)
        v = ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)
        return v.astype("<u2").tobytes()
    data = img.tobytes()
    out = bytearray(len(data) // 3 * 2)
    for i in range(len(data) // 3):
        r, g, b = data[3 * i], data[3 * i + 1], data[3 * i + 2]
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        out[2 * i] = v & 0xFF
        out[2 * i + 1] = v >> 8
    return bytes(out)


def run_fb(dev, sysdir):
    fw, fh, bpp = fb_geometry(sysdir)
    log(f"Framebuffer {dev}: {fw}x{fh}, {bpp} bpp, Drehung {ROTATE}")
    size = fw * fh * bpp // 8
    n = 0
    with open(dev, "r+b", buffering=0) as f:
        # mmap statt write(): der Treiber (fbdefio) aktualisiert das Panel nur bei Seitenzugriffen
        try:
            mm = mmap.mmap(f.fileno(), size)
            log("Schreibweg: mmap")
        except (OSError, ValueError) as e:
            mm = None
            log(f"mmap nicht moeglich ({e}), nutze write()")
        while True:
            data = to_bytes(frame(fw, fh), bpp)
            if mm is not None:
                mm[:len(data)] = data
                mm.flush()
            else:
                f.seek(0)
                f.write(data)
            n += 1
            if MAX_FRAMES and n >= MAX_FRAMES:
                if mm is not None:
                    mm.close()
                return
            time.sleep(INTERVAL)


def main():
    if PREVIEW:
        fw = int(os.environ.get("PREVIEW_W", "480"))
        fh = int(os.environ.get("PREVIEW_H", "320"))
        frame(fw, fh).save(PREVIEW)
        log(f"Vorschau gespeichert: {PREVIEW} (Inhalt endet bei y={LAST_Y} von {LAST_H})")
        return
    log("SPI-Dashboard startet")
    while True:
        dev, sysdir = find_fb()
        if dev and os.path.exists(dev) and os.path.isdir(sysdir):
            try:
                run_fb(dev, sysdir)
            except OSError as e:
                log(f"Schreibfehler auf {dev}: {e}. Neuer Versuch in 5 s.")
        else:
            log("Kein SPI-Framebuffer gefunden (fb1). Overlay aktiv und Neustart erfolgt? Neuer Versuch in 5 s.")
        if MAX_FRAMES:
            return
        time.sleep(5)


if __name__ == "__main__":
    main()
