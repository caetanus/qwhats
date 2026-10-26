// qwhats-call: the page side. WhatsApp Web's voip engine (its modules and wa_voip_shared.wasm), told it
// is our device, wired to the core through the helper's QWebChannel (docs/calls-plan.md):
//   core → page  hello (who we are), in (a <call> child for us: offer / message), ack (for a send)
//   page → core  send (a node the engine emits for a peer), log, state
// Binary nodes travel as base64 stanzas (flags byte + WhatsApp's binary XML), as WAWap reads them.
(function () {
  if (window.__qwCall) return;
  window.__qwCall = true;
  let B = null;
  const log = (...a) => {
    const msg = a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ");
    console.log("QWCALL " + msg);
    if (B) B.toCore(JSON.stringify({ t: "log", msg: msg }));
  };
  const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const toB64 = (u) => { let s = ""; const b = u instanceof Uint8Array ? u : new Uint8Array(u); for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s); };
  const decode = (bytes) => require("WAWap").decodeStanza(bytes, (x) => Promise.resolve(x));
  const parsable = (n) => require("WAWebVoipWapNodeUtils").toVoipParsableWapNode(n);

  let si = null;              // the engine's stack interface
  let ready = false;
  const early = [];           // what came before the engine was up
  const acks = {};            // send id → resolve
  let seq = 0;
  let call = null;            // the call in progress: {id, creator, peer}

  async function hello(m) {
    // the calling flags: WhatsApp's own hook; the account's say no to the web, the engine needs yes
    const flags = { enable_web_calling: true };
    require("WAWebABProps").setGetABPropConfigValueImpl((name) => (name in flags ? flags[name] : null));
    const W = require("WAWebWidFactory");
    const me = require("WAWebUserPrefsMeUser");
    me.setMe(W.createWid(m.mePn));
    if (m.meLid) me.setMeLid(W.createWid(m.meLid));
    if (m.pushName && me.setMeDisplayName) me.setMeDisplayName(m.pushName);
    // what the engine sends goes to the core (which wraps, sends, and returns the ack)
    require("WAWebVoipSendSignalingXmpp").sendWAWebVoipSignalingXmpp = async function (e) {
      const id = ++seq;
      const payload = typeof e.xmlPayload === "string" ? e.xmlPayload : toB64(e.xmlPayload);
      const peer = String(e.peerJid);
      const got = new Promise((res) => (acks[id] = res));
      B.toCore(JSON.stringify({ t: "send", id: id, peerJid: peer, payload: payload }));
      const ack = await got;
      if (!ack.node) { log("send failed", ack.error); return; }
      const node = await decode(fromB64(ack.node));
      await si.handleIncomingSignalingAck({ ackInfoError: ack.error || "0", ackInfoType: ack.type || "", peerJid: peer, tcToken: null, xmlNode: parsable(node) });
    };
    const t0 = performance.now();
    await require("WAWebVoipInit").initWAWebVoip("intent");
    si = await require("WAWebVoipStackInterface").getVoipStackInterface();
    const inited = require("WAWebVoipInit").VoipInitEventEmitter.getIsVoipInited();
    log("engine up", { ms: Math.round(performance.now() - t0), inited: inited, stack: !!si });
    ready = true;
    for (const x of early.splice(0)) await incoming(x);
  }

  async function incoming(m) {
    if (!ready) { early.push(m); return; }
    const node = await decode(fromB64(m.node));
    const p = parsable(node);
    if (m.kind === "offer") {
      call = { id: p.maybeAttrString("call-id"), creator: p.maybeAttrString("call-creator"), peer: m.peerJid };
      log("offer", { call: call.id });
      await si.handleIncomingSignalingOffer(p, m.platform, m.version, null, m.ts, !!m.offline, false, m.peerJid, null, Date.now());
      state("ringing");
    } else {
      log("in", node.tag);
      await si.handleIncomingSignalingMessage({ msgE: null, msgOffline: !!m.offline, msgPlatform: m.platform, msgT: m.ts, msgVersion: m.version, peerJid: m.peerJid, tcToken: null, xmlNode: p });
      if (node.tag === "terminate" || node.tag === "reject") state("ended");
    }
  }

  function state(s) { log("state", s); if (B) B.toCore(JSON.stringify({ t: "state", state: s, call: call && call.id })); }

  // the helper's buttons
  window.qwAccept = async () => { log("accept"); await si.acceptCall(true, true, undefined); state("active"); };
  window.qwReject = async () => { log("reject"); await si.rejectCall(); state("ended"); };
  window.qwEnd = async () => { log("end"); await si.endCall(require("WAWebVoipSignalingEnums").EndCallReason.Self, true); state("ended"); };
  window.qwMute = async (on) => { await si.setCallMute(on); log("mute", on); };

  new QWebChannel(qt.webChannelTransport, (ch) => {
    B = ch.objects.bridge;
    B.fromCore.connect(async (s) => {
      let m;
      try { m = JSON.parse(s); } catch (e) { return; }
      try {
        if (m.t === "hello") await hello(m);
        else if (m.t === "in") await incoming(m);
        else if (m.t === "ack" && acks[m.id]) { acks[m.id](m); delete acks[m.id]; }
      } catch (e) { log("error", String(e && e.stack || e).slice(0, 600)); }
    });
    log("page ready");
    B.pageReady();
  });
})();
