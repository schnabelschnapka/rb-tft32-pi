#!/bin/bash
# rb-tft32-test.sh - Test fuer Tasten, Touch und GPIO am RB-TFT3.2V2
# Aufruf: sudo bash rb-tft32-test.sh   (Bericht: ~/rb-tft32-test.txt)
[ "$(id -u)" -eq 0 ] || { echo "sudo bash $0"; exit 1; }
if [ -n "${SUDO_USER:-}" ]; then
    REPORT="$(getent passwd "$SUDO_USER" | cut -d: -f6)/rb-tft32-test.txt"
else
    REPORT="$PWD/rb-tft32-test.txt"
fi
exec > >(tee "$REPORT") 2>&1
PYF=$(mktemp)
cleanup() {
    rm -f "$PYF"
    systemctl start rb-tft32 2>/dev/null
    sleep 0.5
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$REPORT" 2>/dev/null
}
trap cleanup EXIT
systemctl stop rb-tft32 2>/dev/null
command -v pinctrl >/dev/null && pinctrl set 12,16,18,17 pu
cat > "$PYF" <<'PY'
import mmap, os, re, select, struct, subprocess, sys, time

TTY = sys.stdin.isatty()
GPIO_DEV = os.environ.get("GPIOMEM", "/dev/gpiomem")
PROC_INPUT = os.environ.get("PROC_INPUT", "/proc/bus/input/devices")
BTN = [12, 16, 18]
PEN = 17
EV = struct.Struct("llHHi")
TYPES = {0: "SYN", 1: "KEY", 3: "ABS"}
STEPS = [
    "1. Taste drücken (antippen) (Zeitfenster 8 Sekunden)",
    "1. Taste drücken (Gedrückt halten) (Zeitfenster 8 Sekunden)",
    "2. Taste drücken (antippen) (Zeitfenster 8 Sekunden)",
    "2. Taste drücken (Gedrückt halten) (Zeitfenster 8 Sekunden)",
    "3. Taste drücken (antippen) (Zeitfenster 8 Sekunden)",
    "3. Taste drücken (Gedrückt halten) (Zeitfenster 8 Sekunden)",
]

if not TTY:
    print("Kein Terminal, Test uebersprungen.")
    sys.exit(0)

fd = os.open(GPIO_DEV, os.O_RDONLY | os.O_SYNC)
GM = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ)

def word():
    return struct.unpack_from("<I", GM, 0x34)[0]

def touch_dev():
    if os.environ.get("TOUCH_DEV"):
        return os.environ["TOUCH_DEV"], "manuell"
    try:
        txt = open(PROC_INPUT, encoding="utf-8", errors="replace").read()
    except OSError:
        return None, None
    for b in txt.split("\n\n"):
        n = re.search(r'N: Name="(.*)"', b)
        h = re.search(r"H: Handlers=(.*)", b)
        if n and h and re.search(r"ADS7846|touch", n.group(1), re.I):
            e = re.search(r"event\d+", h.group(1))
            if e:
                return "/dev/input/" + e.group(0), n.group(1)
    return None, None

def irq_no():
    r = subprocess.run("dmesg | grep -o 'ads7846.*irq [0-9]*' | grep -o '[0-9]*$' | tail -n 1",
                       shell=True, capture_output=True, text=True)
    return r.stdout.strip()

def irq_count(n):
    if not n:
        return None
    for line in open("/proc/interrupts"):
        if re.match(rf"\s*{n}:", line):
            s = 0
            for tok in line.split()[1:]:
                if not tok.isdigit():
                    break
                s += int(tok)
            return s
    return None

def window(sec, evf=None):
    t0 = time.monotonic()
    end = t0 + sec
    prev = word()
    edges, evc, presses, xs, ys = [], {}, 0, [], []
    while time.monotonic() < end:
        cur = word()
        if cur != prev:
            now = time.monotonic() - t0
            d = cur ^ prev
            for p in range(28):
                if d >> p & 1:
                    edges.append((now, p, cur >> p & 1))
            prev = cur
        if evf is not None and select.select([evf], [], [], 0)[0]:
            data = os.read(evf.fileno(), EV.size * 64)
            for off in range(0, len(data) - EV.size + 1, EV.size):
                _, _, typ, code, val = EV.unpack_from(data, off)
                evc[typ] = evc.get(typ, 0) + 1
                if typ == 3 and code == 0:
                    xs.append(val)
                elif typ == 3 and code == 1:
                    ys.append(val)
                elif typ == 1 and code == 0x14A and val == 1:
                    presses += 1
    return edges, evc, presses, xs, ys

def lows(edges, pin, gap=0.03, minlen=0.02):
    segs, t0 = [], None
    for t, p, lv in edges:
        if p != pin:
            continue
        if lv == 0 and t0 is None:
            t0 = t
        elif lv == 1 and t0 is not None:
            segs.append([t0, t])
            t0 = None
    merged = []
    for s_, e_ in segs:
        if merged and s_ - merged[-1][1] < gap:
            merged[-1][1] = e_
        else:
            merged.append([s_, e_])
    return [(s_, e_ - s_) for s_, e_ in merged if e_ - s_ >= minlen]

def fmt(L):
    s = ", ".join(f"{t:.2f} s / {d * 1000:.0f} ms" for t, d in L[:8])
    return s + (" ..." if len(L) > 8 else "")

def prompt(text):
    print(f"Enter drücken auf der Bash: {text}", end="", flush=True)
    sys.stdin.readline()
    print("Aufnahme laeuft ...", flush=True)

dev, name = touch_dev()
irq = irq_no()
print(f"Touch: {dev or 'nicht gefunden'} ({name or '-'}), IRQ {irq or '?'}")
print("Pegel jetzt: GPIO12/16/18 =", [(word() >> p) & 1 for p in BTN], " GPIO17 =", (word() >> PEN) & 1)

for text in STEPS:
    prompt(text)
    edges, _, _, _, _ = window(8)
    for p in BTN:
        L = lows(edges, p)
        print(f"  GPIO{p}: {len(L)}x  {fmt(L)}" if L else f"  GPIO{p}: keine Reaktion")
    print()

prompt("Touch Test")
evf = open(dev, "rb", buffering=0) if dev and os.path.exists(dev) else None
c0 = irq_count(irq)
edges, evc, presses, xs, ys = window(10, evf)
c1 = irq_count(irq)
L = lows(edges, PEN)
print(f"  Pen-Down GPIO17: {len(L)}x  {fmt(L)}" if L else "  Pen-Down GPIO17: keine Reaktion")
print("  Ereignisse:", ", ".join(f"{TYPES.get(k, k)}={v}" for k, v in sorted(evc.items())) or "keine")
print(f"  BTN_TOUCH-Druecke: {presses}")
print(f"  Koordinaten: X {min(xs)}..{max(xs)}  Y {min(ys)}..{max(ys)}" if xs and ys else "  Koordinaten: keine")
print(f"  IRQ {irq or '?'}: Zaehler {c0} -> {c1}")
print()

prompt("GPIO-Scan (alle Pins, 20 Sekunden)")
edges, _, _, _, _ = window(20)
found = False
for p in range(28):
    L = lows(edges, p)
    if L:
        found = True
        print(f"  GPIO{p}: {len(L)}x  {fmt(L)}")
if not found:
    print("  keine Reaktion auf irgendeinem GPIO")
PY
python3 "$PYF"
