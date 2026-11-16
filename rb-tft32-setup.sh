#!/usr/bin/env bash
# rb-tft32-setup.sh - richtet das Joy-IT RB-TFT3.2 V2 (3,2 Zoll, 320x240, SSD1289, Touch XPT2046) ein.
# Raeumt vorherige Versuche auf (Dienste, piscreen/joy-IT/fkms-Overlays, udev-Regel, Konfig-Bloecke)
# und installiert alles neu. Die Variante wird abgefragt: Dashboard oder Desktop-Spiegel.
#
#   sudo bash rb-tft32-setup.sh install                  (fragt die Variante ab)
#   sudo bash rb-tft32-setup.sh install --mode dashboard|mirror
#   sudo bash rb-tft32-setup.sh status
#   sudo bash rb-tft32-setup.sh uninstall                (entfernt alles, was dieses Skript angelegt hat)
#
# Falls der Download nicht klappt: Datei von https://joy-it.net/de/products/RB-TFT3.2V2 holen und
#   sudo OVERLAY_FILE=/pfad/joy-IT-Display-Driver-32b-overlay.zip bash rb-tft32-setup.sh install
set -uo pipefail

BOOT="${BOOT_DIR:-/boot/firmware}"
CFG="$BOOT/config.txt"
CMDLINE="$BOOT/cmdline.txt"
OVL_DIR="$BOOT/overlays"
OVL_NAME="joy-IT-Display-Driver-32b-overlay"
OVL_LINE="$OVL_NAME:rotate=270,swapxy=1"
PY_DASH="${PY_DASH:-/usr/local/bin/rb-tft32-dash.py}"
PY_MIRROR="${PY_MIRROR:-/usr/local/bin/rb-tft32-mirror.py}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
UNIT="$UNIT_DIR/rb-tft32.service"
TS="$(date +%Y%m%d-%H%M%S)"
TMPD=""
MODE=""
OVL_FOUND=""
TARGET_USER="${TARGET_USER:-}"

trap '[[ -n "$TMPD" ]] && rm -rf "$TMPD"' EXIT

die()  { echo "FEHLER: $*" >&2; exit 1; }
ok()   { echo "  [ok] $*"; }
warn() { echo "  [!!] $*"; }
info() { echo; echo "==> $*"; }

usage() { sed -n '2,12p' "$0"; }

need_root() { [[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."; }

check_platform() {
  if [[ "${FORCE:-0}" == 1 ]]; then warn "FORCE=1: Plattformpruefung uebersprungen"; return 0; fi
  [[ "$(uname -m)" == aarch64 ]] || die "Kein 64-bit-System erkannt (uname -m: $(uname -m))."
  local model
  model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
  [[ "$model" == *"Raspberry Pi"* ]] || die "Kein Raspberry Pi erkannt."
  ok "System: $model"
}

resolve_user() {
  [[ -n "$TARGET_USER" ]] || TARGET_USER="${SUDO_USER:-}"
  [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || TARGET_USER=$(getent passwd 1000 | cut -d: -f1)
  [[ -n "$TARGET_USER" ]] || die "Desktop-Benutzer nicht gefunden. Mit TARGET_USER=<name> starten."
  ok "Desktop-Benutzer: $TARGET_USER"
}

choose_mode() {
  if [[ -z "$MODE" ]]; then
    if [[ -t 0 ]]; then
      echo "Welche Variante soll auf dem 3,2-Zoll-Display laufen?"
      echo "  1) Dashboard  - CPU, Temperatur, RAM, Speicher, IP, Uhrzeit"
      echo "  2) Desktop    - Spiegel des HDMI-Desktops (langsam, etwa 1-2 Bilder pro Sekunde)"
      local ans=""
      read -r -p "Auswahl [1/2]: " ans
      case "$ans" in 2) MODE=mirror ;; *) MODE=dashboard ;; esac
    else
      MODE=dashboard
      warn "Kein Terminal: Variante 'dashboard' (andere mit --mode mirror)"
    fi
  fi
  case "$MODE" in
    dashboard|mirror) ;;
    *) die "Unbekannte Variante: $MODE (erlaubt: dashboard, mirror)" ;;
  esac
  ok "Variante: $MODE"
}

install_packages() {
  info "Pakete installieren"
  if [[ -n "${SKIP_APT:-}" ]]; then warn "SKIP_APT gesetzt: keine Paketinstallation"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  local pk=(python3-pil python3-numpy fonts-dejavu-core unzip curl ca-certificates)
  [[ "$MODE" == mirror ]] && pk+=(grim)
  apt-get update -qq >/dev/null 2>&1 || warn "Paketlisten konnten nicht aktualisiert werden, versuche Installation trotzdem"
  if apt-get install -y -qq "${pk[@]}" >/dev/null 2>&1; then
    ok "Pakete installiert: ${pk[*]}"
  else
    die "Paketinstallation fehlgeschlagen (Internet pruefen). Manuell: sudo apt-get install ${pk[*]}"
  fi
  if [[ "$MODE" == mirror ]]; then
    command -v grim >/dev/null 2>&1 || die "grim ist nach der Installation nicht verfuegbar."
  fi
}

fetch_overlay() {
  info "Treiber-Overlay besorgen"
  TMPD=$(mktemp -d) || die "mktemp fehlgeschlagen"
  local src="$TMPD/download" dtb="" got=""
  if [[ -n "${OVERLAY_FILE:-}" ]]; then
    cp "$OVERLAY_FILE" "$src" || die "OVERLAY_FILE nicht lesbar: $OVERLAY_FILE"
    got="lokale Datei $OVERLAY_FILE"
  else
    local urls=(
      "https://joy-it.net/files/files/Produkte/RB-TFT3.2-V2/joy-IT-Display-Driver-32b-overlay.zip"
      "http://joy-it.net/files/files/Produkte/RB-TFT3.2-V2/joy-IT-Display-Driver-32b-overlay.zip"
      "http://anleitung.joy-it.net/upload/joy-IT-Display-Driver-32b-overlay.dtb"
    )
    local u
    for u in "${urls[@]}"; do
      if curl -fsSL --max-time 90 -o "$src" "$u" 2>/dev/null && [[ -s "$src" ]]; then
        got="$u"
        break
      fi
    done
    [[ -n "$got" ]] || die "Overlay nicht herunterladbar. Datei manuell von https://joy-it.net/de/products/RB-TFT3.2V2 holen und mit OVERLAY_FILE=/pfad starten."
  fi
  ok "Quelle: $got"
  if [[ "$(head -c 2 "$src")" == "PK" ]]; then
    unzip -o -q "$src" -d "$TMPD/x" || die "ZIP konnte nicht entpackt werden."
    dtb=$(find "$TMPD/x" -type f \( -iname '*.dtbo' -o -iname '*.dtb' \) | head -n 1)
  else
    dtb="$src"
  fi
  [[ -n "$dtb" && -f "$dtb" ]] || die "Im Paket liegt keine .dtbo/.dtb-Datei."
  if [[ "$(od -An -tx1 -N4 "$dtb" | tr -d ' \n')" != "d00dfeed" ]]; then
    die "$(basename "$dtb") ist kein gueltiges Device-Tree-Overlay."
  fi
  OVL_FOUND="$dtb"
  ok "Overlay geprueft (gueltige Device-Tree-Datei)"
}

cleanup_old() {
  local action="$1"
  info "Alte Versuche aufraeumen"
  local s f
  if command -v systemctl >/dev/null 2>&1; then
    for s in spi-dash.service rb-tft32.service; do
      if systemctl disable --now "$s" >/dev/null 2>&1; then ok "Dienst gestoppt: $s"; fi
    done
  fi
  for f in "$UNIT_DIR/spi-dash.service" "$UNIT" /usr/local/bin/spi-dash.py "$PY_DASH" "$PY_MIRROR" /etc/udev/rules.d/99-tft35-touch.rules; do
    if [[ -e "$f" ]]; then
      rm -f "$f" && ok "entfernt: $f"
    fi
  done
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload >/dev/null 2>&1; fi
  if command -v udevadm >/dev/null 2>&1; then udevadm control --reload-rules >/dev/null 2>&1; fi

  if [[ -f "$CMDLINE" && ! -f "$CMDLINE.rb-tft32-orig" ]]; then
    cp -a "$CMDLINE" "$CMDLINE.rb-tft32-orig"
  fi
  cp -a "$CFG" "$CFG.rb-tft32-bak-$TS" && ok "config.txt gesichert: $CFG.rb-tft32-bak-$TS"

  python3 - "$CFG" "$OVL_LINE" "$action" <<'PYCFG'
import re, sys
path, ovl, action = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path, encoding="utf-8", errors="replace").read().splitlines()

# 1) Eigene Bloecke aus frueheren Laeufen entfernen
out, skip = [], False
for line in raw:
    s = line.strip()
    if s.startswith(("# >>> spi-dash", "# >>> rb-tft32")):
        skip = True
        continue
    if s.startswith(("# <<< spi-dash", "# <<< rb-tft32")):
        skip = False
        continue
    if not skip:
        out.append(line)

# 2) Display- und SPI-Zeilen aus alten Versuchen entfernen (aktiv oder auskommentiert)
conflict = re.compile(r"^\s*#?\s*(dtoverlay\s*=\s*(vc4-fkms-v3d|piscreen|joy-?it|ads7846|fbtft|flexfb|pitft|waveshare|rpi-display|tft35)|dtparam\s*=\s*spi\s*=)", re.I)
hdmi_ign = re.compile(r"^\s*hdmi_ignore_edid\b")
kept, removed = [], []
for line in out:
    if conflict.match(line) or hdmi_ign.match(line):
        removed.append(line.strip())
        continue
    kept.append(line)

# 3) vc4-kms-v3d sicherstellen (fuer den HDMI-Desktop)
has_kms = any(re.match(r"^\s*dtoverlay\s*=\s*vc4-kms-v3d\b", l) for l in kept)
if not has_kms:
    for i, l in enumerate(kept):
        if re.match(r"^\s*#\s*dtoverlay\s*=\s*vc4-kms-v3d\b", l):
            kept[i] = "dtoverlay=vc4-kms-v3d"
            has_kms = True
            break

# 4) Ende aufraeumen
while kept and not kept[-1].strip():
    kept.pop()
if kept and kept[-1].strip() == "[all]":
    kept.pop()
    while kept and not kept[-1].strip():
        kept.pop()

if action == "install":
    body = ["dtparam=spi=on", f"dtoverlay={ovl}"]
    if not has_kms:
        body.insert(0, "dtoverlay=vc4-kms-v3d")
    block = ["# >>> rb-tft32 (rb-tft32-setup.sh) >>>"] + body + ["# <<< rb-tft32 (rb-tft32-setup.sh) <<<"]
    result = kept + ["", "[all]"] + block
else:
    result = kept
    if not has_kms:
        # Ins globale Segment (vor dem ersten [Abschnitt]), sonst gilt die Zeile nur fuer ein Modell
        idx = next((i for i, l in enumerate(kept) if l.strip().startswith("[")), len(kept))
        result = kept[:idx] + ["dtoverlay=vc4-kms-v3d"] + kept[idx:]

open(path, "w", encoding="utf-8").write("\n".join(result) + "\n")
for r in removed:
    print(f"  entfernt: {r}")
print(f"  vc4-kms-v3d: {'vorhanden' if has_kms else 'ergaenzt'}")
if action == "install":
    print(f"  gesetzt: dtoverlay={ovl}")
PYCFG

  if [[ -f "$CMDLINE" ]]; then
    python3 - "$CMDLINE" <<'PYCMD'
import re, sys
p = sys.argv[1]
tokens = open(p, encoding="utf-8").read().split()
new = [t for t in tokens if not re.match(r"^fbcon=", t)]
if new != tokens:
    open(p, "w", encoding="utf-8").write(" ".join(new) + "\n")
    print("  fbcon-Eintraege aus cmdline.txt entfernt")
else:
    print("  cmdline.txt unveraendert")
PYCMD
  fi
}

write_mode_files() {
  if [[ "$MODE" == dashboard ]]; then
    cat > "$PY_DASH" <<'PYDASH'
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
PYDASH
    chmod 755 "$PY_DASH"
    cat > "$UNIT" <<EOF
[Unit]
Description=RB-TFT3.2 Systemdashboard (rb-tft32-setup.sh)
After=multi-user.target

[Service]
Environment=ROTATE=0
Environment=INTERVAL=1
ExecStart=/usr/bin/python3 $PY_DASH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Dashboard geschrieben: $PY_DASH"
  else
    local uid sock
    uid=$(id -u "$TARGET_USER" 2>/dev/null) || die "Benutzer $TARGET_USER unbekannt."
    sock=$(ls "/run/user/$uid" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n 1)
    sock="${sock:-wayland-0}"
    cat > "$PY_MIRROR" <<'PYMIRROR'
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
PYMIRROR
    chmod 755 "$PY_MIRROR"
    cat > "$UNIT" <<EOF
[Unit]
Description=RB-TFT3.2 Desktop-Spiegel (rb-tft32-setup.sh)
After=multi-user.target

[Service]
User=$TARGET_USER
Group=video
Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=WAYLAND_DISPLAY=$sock
Environment=GRIM_SCALE=0.5
Environment=INTERVAL=0.5
ExecStart=/usr/bin/python3 $PY_MIRROR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Desktop-Spiegel geschrieben: $PY_MIRROR (Benutzer $TARGET_USER, Socket $sock)"
  fi
  ok "Dienst geschrieben: $UNIT"
}

cmd_install() {
  need_root
  [[ -f "$CFG" ]] || die "$CFG nicht gefunden."
  [[ -d "$OVL_DIR" ]] || die "$OVL_DIR nicht gefunden."
  info "System pruefen"
  check_platform
  choose_mode
  if [[ "$MODE" == mirror ]]; then resolve_user; fi
  install_packages
  fetch_overlay
  cleanup_old install
  info "Overlay und Dienst einrichten"
  cp -f "$OVL_FOUND" "$OVL_DIR/$OVL_NAME.dtbo" && ok "Overlay installiert: $OVL_DIR/$OVL_NAME.dtbo"
  write_mode_files
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable rb-tft32.service >/dev/null 2>&1 && ok "Dienst aktiviert (startet nach dem Neustart)"
  fi
  info "Fertig"
  echo "  Variante:          $MODE"
  echo "  Jetzt neu starten: sudo reboot"
  echo "  Danach pruefen:    sudo bash $0 status"
}

cmd_uninstall() {
  need_root
  info "Entfernen"
  cleanup_old uninstall
  rm -f "$OVL_DIR/$OVL_NAME.dtbo" && ok "Overlay entfernt"
  echo "  Bitte neu starten: sudo reboot"
}

cmd_status() {
  info "Framebuffer"
  local f
  for f in /sys/class/graphics/fb*; do
    [[ -e "$f" ]] || continue
    echo "  $(basename "$f"): name=$(cat "$f/name" 2>/dev/null) size=$(cat "$f/virtual_size" 2>/dev/null) bpp=$(cat "$f/bits_per_pixel" 2>/dev/null)"
  done
  info "config.txt"
  grep -n -E '^(dtoverlay|dtparam=spi|hdmi_ignore)' "$CFG" 2>/dev/null | sed 's/^/  /' || true
  info "Overlay"
  ls -l "$OVL_DIR/$OVL_NAME.dtbo" 2>&1 | sed 's/^/  /'
  info "Dienst"
  if [[ -f "$UNIT" ]]; then
    systemctl --no-pager status rb-tft32.service 2>/dev/null | head -n 12 || true
  else
    echo "  nicht installiert"
  fi
  info "Letzte Logzeilen"
  journalctl -u rb-tft32.service -b --no-pager 2>/dev/null | tail -n 8 | sed 's/^/  /' || true
  info "Kernel-Meldungen"
  dmesg 2>/dev/null | grep -i -E 'fb_|fbtft|ssd1289|joy|flexfb|xpt|ads7846|spi0' | tail -n 12 | sed 's/^/  /' || true
}

case "${1:-}" in
  install)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        *) die "Unbekannte Option: $1" ;;
      esac
    done
    cmd_install
    ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
