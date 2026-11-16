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
  local pk=(python3-pil python3-numpy fonts-dejavu-core unzip CURL_PKG CA_PKG)
  [[ "$MODE" == mirror ]] && pk+=(grim)
  PKG_MGR update -qq >/dev/null 2>&1 || warn "Paketlisten konnten nicht aktualisiert werden, versuche Installation trotzdem"
  if PKG_MGR install -y -qq "${pk[@]}" >/dev/null 2>&1; then
    ok "Pakete installiert: ${pk[*]}"
  else
    die "Paketinstallation fehlgeschlagen (Internet pruefen). Manuell: sudo PKG_MGR install ${pk[*]}"
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
      if CURL_BIN -fsSL --max-time 90 -o "$src" "$u" 2>/dev/null && [[ -s "$src" ]]; then
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
@@DASH@@
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
@@MIRROR@@
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
