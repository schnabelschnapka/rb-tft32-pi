# RB-TFT3.2 V2 am Raspberry Pi 3B+

Installation des Joy-IT **RB-TFT3.2 V2** (3,2 Zoll, 320×240, Controller SSD1289, Touch XPT2046) an einem Raspberry Pi 3B+ mit Raspberry Pi OS Trixie (Kernel 6.18). Der HDMI-Desktop bleibt parallel nutzbar.

## Status

| Funktion | Status |
|---|---|
| Display (`/dev/fb1`, 320×240) | funktioniert |
| Modus Desktop-Spiegel | funktioniert |
| Modus Dashboard | funktioniert |
| Tasten GPIO 12, 16, 18 | nur GPIO 18 reagiert, 12 und 16 offen |
| Touch (PENIRQ auf GPIO 17) | kein Signal vom Controller, Ursache offen |

## Installation

```
sudo bash rb-tft32-setup.sh install                    # fragt den Modus ab
sudo bash rb-tft32-setup.sh install --mode mirror      # Desktop-Spiegel
sudo bash rb-tft32-setup.sh install --mode dashboard   # Dashboard
sudo bash rb-tft32-setup.sh status
sudo bash rb-tft32-setup.sh uninstall
```

Danach den Pi neu starten: `sudo reboot`

Das Skript lädt das Joy-IT-Overlay selbst herunter. Schlägt der Download fehl, die Datei von [joy-it.net](https://joy-it.net/de/products/RB-TFT3.2V2) holen und angeben:

```
sudo OVERLAY_FILE=/pfad/joy-IT-Display-Driver-32b-overlay.zip bash rb-tft32-setup.sh install
```

Das Overlay ist nicht im Repository enthalten.

## Repository

| Pfad | Inhalt |
|---|---|
| `rb-tft32-setup.sh` | Installer, fertig zum Ausführen (wird aus `src/` gebaut) |
| `src/rb-template.sh` | Installer-Vorlage: Konfiguration, Dienste, Modi |
| `src/dash.py` | Dashboard: CPU, Temperatur, Takt, Last, RAM, Speicher, IP, Laufzeit |
| `src/mirror.py` | Desktop-Spiegel über `grim` in den Framebuffer |
| `src/build.py` | Baut `rb-tft32-setup.sh` aus den Teilen in `src/` |
| `tools/rb-tft32-test.sh` | Geführter Test für Tasten und Touch, Bericht als `rb-tft32-test.txt` |
| `tools/rb-tft32-diag.sh` | Systemdiagnose für Overlay, Touch, Tasten und GPIO, Bericht als `rb-tft32-diag.txt` |

Änderungen an Installer oder Modi nur in `src/` vornehmen und danach neu bauen:

```
python3 src/build.py
```

## Diagnose

```
sudo bash tools/rb-tft32-test.sh
```

Der Test fragt jeden Schritt per Enter ab: drei Tasten jeweils antippen und halten, danach Touch und ein GPIO-Scan. Der Display-Dienst ist während des Tests gestoppt.
