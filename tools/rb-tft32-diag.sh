#!/bin/bash
# rb-tft32-diag.sh - Diagnose fuer Touch und Tasten am RB-TFT3.2V2 (nur lesend)
#
# Aufruf auf dem Pi:
#   sudo bash rb-tft32-diag.sh
#
# Schreibt die komplette Ausgabe zusaetzlich nach ~/rb-tft32-diag.txt und das
# dekompilierte Overlay nach ~/joy-IT-overlay.dts. Beide Dateien kannst du mir schicken.
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte mit sudo starten: sudo bash $0"
    exit 1
fi

USER_NAME="${SUDO_USER:-root}"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
USER_HOME="${USER_HOME:-/root}"
REPORT="$USER_HOME/rb-tft32-diag.txt"
DTS_OUT="$USER_HOME/joy-IT-overlay.dts"
PROC_INPUT="${PROC_INPUT:-/proc/bus/input/devices}"
TOUCH_DEV="${TOUCH_DEV:-}"
BOOTDIR="${BOOTDIR:-/boot/firmware}"
[ -d "$BOOTDIR/overlays" ] || BOOTDIR=/boot
OVL="$BOOTDIR/overlays/joy-IT-Display-Driver-32b-overlay.dtbo"
CFG="$BOOTDIR/config.txt"

: > "$REPORT"
exec > >(tee -a "$REPORT") 2>&1

PYDIR=$(mktemp -d)
trap 'rm -rf "$PYDIR"' EXIT

sec() { echo; echo "===== $1 ====="; }

sec "System"
echo "Modell:  $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unbekannt)"
echo "Kernel:  $(uname -r)"
echo "System:  $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
echo "Datum:   $(date '+%Y-%m-%d %H:%M:%S')"

sec "1) Overlays mit 'joy' im Namen"
ls "$BOOTDIR/overlays/" 2>/dev/null | grep -i joy || echo "keine gefunden"

sec "2) config.txt (Display-relevante Zeilen)"
grep -n -E 'dtoverlay|dtparam=spi|^\[' "$CFG" 2>/dev/null || echo "config.txt nicht gefunden: $CFG"

sec "3) Overlay dekompiliert (Touch-Knoten)"
if [ ! -f "$OVL" ]; then
    echo "Overlay fehlt: $OVL"
elif ! command -v dtc >/dev/null 2>&1; then
    echo "dtc fehlt. Nachinstallieren: Paket device-tree-compiler"
else
    dtc -I dtb -O dts "$OVL" > "$DTS_OUT" 2>/dev/null
    if [ -s "$DTS_OUT" ]; then
        echo "Vollstaendige Ausgabe: $DTS_OUT ($(wc -l < "$DTS_OUT") Zeilen)"
        grep -n -i -E 'compatible|ads|xpt|irq|pendown|touch|gpio' "$DTS_OUT" || echo "keine Treffer"
    else
        echo "dtc konnte das Overlay nicht lesen"
    fi
fi

sec "4) Textbausteine im Overlay (Fallback ohne dtc)"
if [ -f "$OVL" ]; then
    cat > "$PYDIR/strings.py" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
hits = []
for m in re.findall(rb"[\x20-\x7e]{4,}", data):
    s = m.decode()
    if re.search(r"xpt|ads7846|touch|irq|pendown|gpio|ti,", s, re.I):
        hits.append(s)
print("\n".join(dict.fromkeys(hits)) or "keine Treffer")
PY
    python3 "$PYDIR/strings.py" "$OVL"
else
    echo "Overlay fehlt"
fi

sec "5) Eingabegeraete (/proc/bus/input/devices)"
if [ -r "$PROC_INPUT" ]; then cat "$PROC_INPUT"; else echo "nicht lesbar: $PROC_INPUT"; fi
echo "--- /dev/input:"
ls -l /dev/input/ 2>/dev/null || echo "kein /dev/input"

sec "6) Kernel-Meldungen zu SPI, Touch und Display"
dmesg 2>/dev/null | grep -i -E 'ads7846|xpt|touch|fbtft|ssd1289|spi|joy' | tail -n 40 || true
echo "--- SPI-Geraete:"
ls /sys/bus/spi/devices/ 2>/dev/null || echo "keine"

sec "7) Tasten GPIO 12, 16, 18 (plus Touch-Pin GPIO 17)"
cat > "$PYDIR/buttons.py" <<'PY'
import os, re, shutil, subprocess, sys, time

BTN = [12, 16, 18]          # drei Tasten
WATCH = [17]                # Pen-Down des Touch-Controllers (XPT2046)
PULL = os.environ.get("BTN_PULL", "pu")   # pu, pd oder no
HAVE_PINCTRL = shutil.which("pinctrl") is not None

def pinctrl_line(p):
    r = subprocess.run(["pinctrl", "get", str(p)], capture_output=True, text=True)
    return r.stdout.strip()

def level_from(line):
    m = re.search(r"\|\s*(hi|lo)", line)
    if not m:
        raise RuntimeError("unerwartete pinctrl-Ausgabe: " + line)
    return 1 if m.group(1) == "hi" else 0

def read_levels(pins):
    if HAVE_PINCTRL:
        return [level_from(pinctrl_line(p)) for p in pins]
    if shutil.which("gpioget"):
        # libgpiod 2.x braucht -c fuer den Chip, libgpiod 1.x nicht
        last_err = ""
        for base in (["gpioget", "--bias=pull-up", "-c", "gpiochip0"],
                     ["gpioget", "--bias=pull-up", "gpiochip0"]):
            r = subprocess.run(base + [str(p) for p in pins], capture_output=True, text=True)
            if r.returncode != 0:
                last_err = r.stderr.strip()
                continue
            vals = []
            for tok in r.stdout.split():
                v = tok.split("=")[-1]
                vals.append({"active": "1", "inactive": "0"}.get(v, v))
            if len(vals) == len(pins) and all(v in ("0", "1") for v in vals):
                return [int(v) for v in vals]
            last_err = "unerwartete Ausgabe: " + r.stdout.strip()
        raise RuntimeError("gpioget: " + last_err)
    raise RuntimeError("weder pinctrl noch gpioget gefunden")

print("Erwartung: Taste zieht den Pin gegen Masse. Dann braucht der Pin einen Pull-up,")
print("sonst bleibt er bei 0 und jeder Druck ist unsichtbar.")
if HAVE_PINCTRL:
    r = subprocess.run(["pinctrl", "set", ",".join(map(str, BTN)), PULL], capture_output=True, text=True)
    if r.returncode == 0:
        print(f"Interner Pull der Tasten-Pins auf '{PULL}' gesetzt (gilt bis zum Neustart).")
    else:
        print("pinctrl set fehlgeschlagen:", r.stderr.strip())
    for p in BTN + WATCH:
        print("  " + pinctrl_line(p))
try:
    idle = read_levels(BTN + WATCH)
except RuntimeError as e:
    print("Lesefehler:", e)
    sys.exit(0)
print("Pegel ohne Druck   GPIO12 GPIO16 GPIO18 | GPIO17:", idle[:3], "|", idle[3:])

if not sys.stdin.isatty():
    print("Kein Terminal, Tastentest uebersprungen.")
    sys.exit(0)

print("Enter druecken, dann 15 s Aufnahme. 1) Jede Taste 2 s halten, Reihenfolge merken "
      "(z. B. links, Mitte, rechts). 2) Danach 5 s lang auf das Display tippen. ",
      end="", flush=True)
sys.stdin.readline()
print("Aufnahme laeuft ...", flush=True)

pins = BTN + WATCH
last = idle
changes = []
changed = set()
start = time.time()
while time.time() - start < 15:
    try:
        cur = read_levels(pins)
    except RuntimeError as e:
        print("Lesefehler:", e)
        break
    t = time.time() - start
    for p, a, b in zip(pins, last, cur):
        if a != b:
            changes.append(f"  t={t:5.2f}s  GPIO{p}: {a} -> {b}")
            changed.add(p)
    last = cur
    time.sleep(0.03)
print("Pegelwechsel:")
print("\n".join(changes) or "  keine erkannt")
for p in BTN:
    print(f"  GPIO{p} (Taste): {'reagiert' if p in changed else 'keine Reaktion'}")
print(f"  GPIO17 (Touch Pen-Down): {'reagiert' if 17 in changed else 'keine Reaktion (kein Signal vom Touch-Controller)'}")
PY
python3 "$PYDIR/buttons.py"

sec "8) Touch"
cat > "$PYDIR/touch.py" <<'PY'
import os, re, select, shutil, struct, subprocess, sys, time

dev_arg, proc_path = sys.argv[1], sys.argv[2]
DURATION = 10
PEN_PIN = 17                # Pen-Down-Leitung des XPT2046
TOUCH_RE = re.compile(r"touch|ads7846|xpt|pen|stylus|ti,", re.I)
HAVE_PINCTRL = shutil.which("pinctrl") is not None

def pen_level():
    if not HAVE_PINCTRL:
        return None
    r = subprocess.run(["pinctrl", "get", str(PEN_PIN)], capture_output=True, text=True)
    m = re.search(r"\|\s*(hi|lo)", r.stdout)
    return m.group(1) if m else None

try:
    text = open(proc_path, encoding="utf-8", errors="replace").read()
except OSError as e:
    print("Eingabegeraete nicht lesbar:", e)
    text = ""

devs = []
for block in text.split("\n\n"):
    name = re.search(r'N: Name="(.*)"', block)
    hand = re.search(r"H: Handlers=(.*)", block)
    if not name or not hand:
        continue
    ev = re.search(r"event\d+", hand.group(1))
    if ev:
        devs.append((name.group(1), "/dev/input/" + ev.group(0)))

print("Eingabegeraete mit event-Knoten:")
for n, p in devs:
    print(f"  {p:20s} {n}")
if not devs:
    print("Keine Eingabegeraete. Der Touch-Treiber erzeugt offenbar kein Eingabegeraet.")
    sys.exit(0)

if dev_arg:
    target = dev_arg
else:
    cands = [p for n, p in devs if TOUCH_RE.search(n)]
    if not cands:
        print("Kein Touch-Geraet erkannt. Mit TOUCH_DEV=/dev/input/eventX gezielt testen.")
        sys.exit(0)
    target = cands[0]
print("Teste:", target)

if sys.stdin.isatty():
    print(f"Enter druecken, dann {DURATION} s den Stift fest auf das Display druecken und halten "
          f"(nicht nur tippen): ", end="", flush=True)
    sys.stdin.readline()
print(f"Aufnahme {DURATION} s laeuft ...", flush=True)

EV = struct.Struct("llHHi")
SZ = EV.size
try:
    f = open(target, "rb", buffering=0)
except OSError as e:
    print("Kann Geraet nicht oeffnen:", e)
    sys.exit(0)

types, presses, xs, ys, log = {}, 0, [], [], []
pen_changes = []
x = y = None
start = time.time()
end = start + DURATION
pen_last = pen_level()
pen_start = pen_last
with f:
    while time.time() < end:
        lvl = pen_level()
        if lvl is not None and lvl != pen_last:
            pen_changes.append(f"  t={time.time() - start:5.2f}s  GPIO{PEN_PIN}: {pen_last} -> {lvl}")
            pen_last = lvl
        r, _, _ = select.select([f], [], [], 0.02)
        if not r:
            continue
        data = os.read(f.fileno(), SZ * 64)
        if not data:
            break
        for off in range(0, len(data) - SZ + 1, SZ):
            _, _, typ, code, val = EV.unpack_from(data, off)
            types[typ] = types.get(typ, 0) + 1
            t = time.time() - start
            if typ == 3 and code == 0:
                x = val
                xs.append(val)
            elif typ == 3 and code == 1:
                y = val
                ys.append(val)
            elif typ == 1 and code == 0x14A:
                if val == 1:
                    presses += 1
                if len(log) < 40:
                    log.append(f"  t={t:5.2f}s  {'Druck   ' if val == 1 else 'Loslassen'}  X={x} Y={y}")

names = {0: "SYN", 1: "KEY", 3: "ABS"}
print("Ereignisse:", ", ".join(f"{names.get(k, k)}={v}" for k, v in sorted(types.items())) or "keine")
print("Druecke (BTN_TOUCH):", presses)
if log:
    print("Protokoll (X/Y = letzte bekannte Rohkoordinaten):")
    print("\n".join(log))
if xs and ys:
    print(f"Rohkoordinaten: X {min(xs)}..{max(xs)}   Y {min(ys)}..{max(ys)}")
else:
    print("Keine Koordinaten empfangen.")
if HAVE_PINCTRL:
    print(f"GPIO{PEN_PIN} (Pen-Down): Start {pen_start}, Ende {pen_last}, Wechsel {len(pen_changes)}")
    print("\n".join(pen_changes[:20]) or f"  keine Wechsel: GPIO{PEN_PIN} hat sich nicht bewegt")
PY
command -v pinctrl >/dev/null && pinctrl set 17 "${PEN_PULL:-pu}" && echo "Pull-up auf GPIO 17 gesetzt (bis Neustart)"
IRQNUM=$(dmesg 2>/dev/null | grep -o 'ads7846.*irq [0-9]*' | grep -o '[0-9]*$' | tail -n 1)
irq_count() {
    [ -n "$IRQNUM" ] || { echo "?"; return; }
    grep -E "^ *${IRQNUM}:" /proc/interrupts 2>/dev/null \
        | awk '{s=0; for(i=2;i<=NF;i++){ if($i ~ /^[0-9]+$/) s+=$i; else break }; print s}'
}
echo "Touch-Interrupt: ${IRQNUM:-nicht gefunden}, Zaehler vorher: $(irq_count)"
python3 "$PYDIR/touch.py" "$TOUCH_DEV" "$PROC_INPUT"
echo "Touch-Interrupt Zaehler nachher: $(irq_count)"
echo "(Steigt der Zaehler, kommt das Pen-Down-Signal am Treiber an. Bleibt er gleich, wurde nichts gedrueckt oder die Leitung ist offen.)"

sec "9) Alle GPIO 0-27 (Display-Dienst kurz gestoppt)"
if [ -t 0 ]; then
    systemctl stop rb-tft32 2>/dev/null
    read -r -p "Enter, dann 20 s: Stift 5 s fest druecken, danach Tasten je 2 s: " _
    cat > "$PYDIR/scan.py" <<'PY'
import re, subprocess, time
def lv(p):
    m = re.search(r"\|\s*(hi|lo)", subprocess.run(["pinctrl", "get", str(p)], capture_output=True, text=True).stdout)
    return m.group(1) if m else "?"
P = range(28)
last = {p: lv(p) for p in P}
ch, t0 = {}, time.time()
while time.time() - t0 < 20:
    for p in P:
        v = lv(p)
        if v != last[p]:
            ch.setdefault(p, []).append(round(time.time() - t0, 1))
            last[p] = v
for p in P:
    if p in ch:
        print(f"GPIO{p}: {len(ch[p])} Wechsel, bei s {ch[p][:8]}")
print("Keine Wechsel" if not ch else "Ende")
PY
    python3 "$PYDIR/scan.py"
    systemctl start rb-tft32 2>/dev/null
else
    echo "Kein Terminal, Scan uebersprungen."
fi

sec "Fertig"
sleep 0.5
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$REPORT" "$DTS_OUT" 2>/dev/null
echo "Bericht: $REPORT"
[ -f "$DTS_OUT" ] && echo "Overlay-Dump: $DTS_OUT"
exit 0
