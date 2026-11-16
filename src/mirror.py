#!/usr/bin/env python3
# rb-tft32-mirror.py - spiegelt den Wayland-Desktop (labwc) per grim in den SPI-Framebuffer.
import datetime, glob, io, mmap, os, subprocess, time
from PIL import Image

FB_DEV = os.environ.get("FB_DEV", "")
FB_SYS = os.environ.get("FB_SYS", "/sys/class/graphics")
FB_SYSDIR = os.environ.get("FB_SYSDIR", "")
ROTATE = int(os.environ.get("ROTATE", "0"))
SCALE = os.environ.get("GRIM_SCALE", "0.5")
INTERVAL = float(os.environ.get("INTERVAL", "0.5"))
MAX_FRAMES = int(os.environ.get("MAX_FRAMES", "0"))
GRIM = os.environ.get("GRIM", "grim")

try:
    import numpy as np
except ImportError:
    np = None


def log(msg):
    print(datetime.datetime.now().strftime("%H:%M:%S"), msg, flush=True)


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def find_fb():
    if FB_DEV:
        return FB_DEV, FB_SYSDIR or os.path.join(FB_SYS, "fb" + FB_DEV[-1])
    for sysdir in sorted(glob.glob(f"{FB_SYS}/fb*")):
        name = read(f"{sysdir}/name")
        if name and "vc4" not in name.lower():
            return f"/dev/fb{os.path.basename(sysdir)[2:]}", sysdir
    return None, None


def geometry(sysdir):
    try:
        w, h = [int(v) for v in read(f"{sysdir}/virtual_size", "").split(",")]
    except ValueError:
        w, h = 320, 240
    bpp = int(read(f"{sysdir}/bits_per_pixel", "16") or 16)
    return w, h, bpp


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


def capture():
    try:
        res = subprocess.run([GRIM, "-s", SCALE, "-t", "ppm", "-"], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"grim nicht ausfuehrbar: {e}")
    if res.returncode != 0 or not res.stdout:
        msg = res.stderr.decode(errors="replace").strip() or f"Exit-Code {res.returncode}"
        raise RuntimeError(f"grim fehlgeschlagen: {msg}")
    return Image.open(io.BytesIO(res.stdout)).convert("RGB")


def fit(img, W, H):
    if ROTATE in (90, 270):
        img = img.rotate(ROTATE, expand=True)
    # Seitenverhaeltnis erhalten, auch vergroessern (thumbnail() wuerde nur verkleinern)
    scale = min(W / img.width, H / img.height)
    nw = max(1, round(img.width * scale))
    nh = max(1, round(img.height * scale))
    img = img.resize((nw, nh), Image.BILINEAR)
    canvas = Image.new("RGB", (W, H), (0, 0, 0))
    canvas.paste(img, ((W - nw) // 2, (H - nh) // 2))
    return canvas


def main():
    dev, sysdir = find_fb()
    while not dev:
        log("Kein SPI-Framebuffer gefunden. Neuer Versuch in 5 s.")
        time.sleep(5)
        dev, sysdir = find_fb()
    W, H, bpp = geometry(sysdir)
    size = W * H * bpp // 8
    log(f"Desktop-Spiegel auf {dev}: {W}x{H}, {bpp} bpp, Drehung {ROTATE}, grim-Skalierung {SCALE}")
    n = 0
    errs = 0
    with open(dev, "r+b", buffering=0) as f:
        mm = mmap.mmap(f.fileno(), size)
        try:
            while True:
                try:
                    frame = fit(capture(), W, H)
                    mm[:size] = to_bytes(frame, bpp)
                    mm.flush()
                    errs = 0
                except Exception as e:
                    errs += 1
                    if errs in (1, 10) or errs % 60 == 0:
                        log(f"Fehler ({errs}x): {e}")
                    time.sleep(5 if errs > 1 else 1)
                    continue
                n += 1
                if MAX_FRAMES and n >= MAX_FRAMES:
                    break
                time.sleep(INTERVAL)
        finally:
            mm.close()


if __name__ == "__main__":
    main()
