#!/usr/bin/env python3
# qwhats-call (prototype): WhatsApp Web's voip engine in a Chromium page that lives only for one call.
# Connects to the core's call bridge (a Unix socket; QWHATS_CALL_SOCK, else the newest
# $XDG_RUNTIME_DIR/qwhats-call-*.sock), loads WhatsApp Web (no login) with SharedArrayBuffer on, injects
# call.js, and relays JSON lines between the core and the page. Quits when the call ends, when the core
# goes away, or when nothing happens for a while. Buttons: answer / reject / hang up / mute.
import glob, json, os, sys, time
from PySide6.QtCore import QObject, QFile, QIODevice, QTimer, QUrl, Signal, Slot
from PySide6.QtNetwork import QLocalSocket
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile, QWebEngineScript
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWidgets import QApplication, QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "") + " --enable-features=SharedArrayBuffer").strip()
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "qwhats-call")
T0 = time.time()
def log(*a): print("[%6.2f] qwhats-call:" % (time.time() - T0), *a, flush=True)

def socket_path():
    p = os.environ.get("QWHATS_CALL_SOCK")
    if p:
        return p
    run = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    socks = sorted(glob.glob(os.path.join(run, "qwhats-call-*.sock")), key=os.path.getmtime)
    return socks[-1] if socks else ""

app = QApplication(sys.argv)

class Bridge(QObject):
    fromCore = Signal(str)
    def __init__(self):
        super().__init__()
        self.ready = False
        self.buffered = []
    @Slot(str)
    def toCore(self, s):
        m = json.loads(s)
        if m.get("t") == "log":
            log("page:",