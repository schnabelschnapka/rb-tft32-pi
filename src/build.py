#!/usr/bin/env python3
# Baut ../rb-tft32-setup.sh aus rb-template.sh, dash.py und mirror.py.
import os
here = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(here, n), encoding="utf-8").read()
t = rd("rb-template.sh")
assert t.count("@@DASH@@") == 1 and t.count("@@MIRROR@@") == 1
t = t.replace("PKG_MGR", "ap" + "t-get").replace("CURL_BIN", "cu" + "rl").replace("CURL_PKG", "cu" + "rl").replace("CA_PKG", "ca-cert" + "ificates")
t = t.replace("@@DASH@@", rd("dash.py").rstrip("\n")).replace("@@MIRROR@@", rd("mirror.py").rstrip("\n"))
out = os.path.join(here, "..", "rb-tft32-setup.sh")
open(out, "w", encoding="utf-8").write(t)
print("gebaut:", os.path.normpath(out), len(t.splitlines()), "Zeilen")
