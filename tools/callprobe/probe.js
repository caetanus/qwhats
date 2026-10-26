(async function () {
  const out = (k, v) => console.log("PROBE " + k + " " + (typeof v === "string" ? v : JSON.stringify(v)));
  const overrides = { enable_web_calling: true };
  require("WAWebABProps").setGetABPropConfigValueImpl((name) => (name in overrides ? overrides[name] : null));
  const G = require("WAWebVoipGatingUtils");
  out("gating", { calling: G.isCallingEnabled(), download: G.isVoipDownloadEnabled() });
  const t0 = performance.now();
  try {
    const si = await Promise.race([require("WAWebVoipStackInterface").getVoipStackInterface(), new Promise((_, r) => setTimeout(() => r("timeout 40s"), 40000))]);
    const names = (o) => { const s = new Set(); for (let p = o; p && p !== Object.prototype; p = Object.getPrototypeOf(p)) Object.getOwnPropertyNames(p).forEach((n) => s.add(n)); return [...s]; };
    out("stack", { ms: Math.round(performance.now() - t0), isNull: si == null, ctor: si && si.constructor ? si.constructor.name : null });
    if (si) out("stack names", names(si).filter((n) => n !== "constructor").slice(0, 200));
    window.__qwStack = si;
  } catch (e) { out("stack FAIL", String(e && e.stack || e).slice(0, 600)); }
  out("done", "");
})();
