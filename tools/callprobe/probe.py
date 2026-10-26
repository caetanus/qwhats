#!/usr/bin/env python3
# qwhats-call phase-0 probe: WhatsApp Web in a QtWebEngine page of its own (separate profile, no login),
# to see whether its voip engine (the WASM and its modules) comes up without an account.
import json, os, sys, time
from PySide6.QtCore import QTimer, QUrl
from PySide6.QtWidgets import QApplication
from PySide6.QtWebEngineCore import QWebEngineProfile, QWebEnginePage
from PySide6.QtWebEngineWidgets import QWebEngineView

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = time.time()
def log(*a): print("[%6.2f]" % (time.time() - T0), *a, flush=True)

app = QApplication(sys.argv)
profile = QWebEngineProfile("qwhats-callprobe")
profile.setPersistentStoragePath(os.path.join(HERE, "profile"))
profile.setCachePath(os.path.join(HERE, "cache"))
profile.setHttpUserAgent(profile.httpUserAgent().replace(" QtWebEngine/6.11.2", "").split(" QtWebEngine/")[0] if False else
                         " ".join(t for t in profile.httpUserAgent().split(" ") if not t.startswith("QtWebEngine/")))
try:
    ch = profile.clientHints()
    full = ch.fullVersion()
    ch.setFullVersionList({"Google Chrome": full, "Chromium": full, "Not=A?Brand": "24.0.0.0"})
except Exception as e:
    log("client hints:", e)

class Page(QWebEnginePage):
    def javaScriptConsoleMessage(self, level, msg, line, src):
        if msg.startswith("PROBE"):
            log(msg)

page = Page(profile)
view = QWebEngineView()
view.setPage(page)
view.resize(1100, 750)
view.show()

PROBE = open(os.path.join(HERE, "probe.js")).read()
def run_probe():
    page.runJavaScript(PROBE, 0, lambda r: None)
page.loadFinished.connect(lambda ok: (log("loadFinished", ok), QTimer.singleShot(int(os.environ.get("PROBE_DELAY", "6000")), run_probe)))
QTimer.singleShot(int(os.environ.get("PROBE_TIMEOUT", "90000")), lambda: (log("timeout"), app.quit()))
log("UA", profile.httpUserAgent())
page.load(QUrl("https://web.whatsapp.com/"))
app.exec()
