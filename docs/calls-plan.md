# Chamadas de voz e vídeo no QWhats: estudo e plano

Fontes: os bundles do WhatsApp Web (rev 1051067427, em `~/.cache/qml-whats-build/waweb/`; resumo da
sinalização em `sections/05-groups-channels-status-calls.md` §4), o código do whatsmeow (`call.go`) e
os repositórios `~/lab/d-webrtc-v3` / `~/lab/libp2p-dlang`. "Visto" = lido no bundle/código;
"inferido" = dedução.

## 1. Como o WhatsApp Web faz chamadas

**Tudo roda num WebAssembly do próprio WhatsApp** (`wa_voip_shared.wasm`, Emscripten com pthreads e
memória compartilhada; carregado por `WAWebVoipWebWasmLoader`, endereço
`/wasm/whatsapp/versioned/<sha256>/wa_voip_shared.wasm`). Visto. O WASM faz a máquina de estados da
chamada, a criptografia da mídia, jitter buffer, estimativa de banda (um modelo de ML) e os codecs
(Opus inferido; H.264 visto, por WebCodecs ou openh264 dentro do WASM). O JS só:

- leva a sinalização entre o WASM e o socket (`sendSignalingXMPP_js_sync` → `<call>`);
- cifra/decifra a **chave da chamada** com Signal;
- captura/toca áudio (AudioWorklets), captura vídeo/tela (`getUserMedia`/`getDisplayMedia`), desenha
  o vídeo (WebCodecs/WebGL);
- abre o **cano de datagramas** até o relay.

### Sinalização (visto)

- O WASM gera os nós binários (`offer`, `accept`, `reject`, `terminate`, `transport`, `relaylatency`,
  `preaccept`, `enc_rekey`, `mute_v2`, `video`, `group_info`, … — enum `WAWebVoipSignalingEnums.TYPE`,
  23 tipos); o JS embrulha em `<call to=<device> id>` e devolve o `<ack class="call">` ao WASM.
- **Chave da chamada**: no `offer`/`enc_rekey`/`transfer` o WASM põe a chave crua num `<enc>`; o JS a
  embrulha em `Message{call:{callKey}}`, cifra com Signal por aparelho → `<enc v=2 type=msg|pkmsg>`
  (+ `<device-identity>` no pkmsg). Na volta (`WAWebVoipValidateAndDecryptEnc`) decifra e devolve a
  chave crua ao WASM. Em grupo, um `<enc>` por aparelho dentro de `<destination>`.
- `offer`/`accept`/`reject`/`enc_rekey` → `<receipt>`; os outros → `<ack class="call" type=…>`.
- **Relays**: o ack do offer traz `<relay>` com `<te2 …>`; o WASM os lê e devolve ao JS
  `relay_key`, `relay_tokens`, `auth_tokens` e `relays[{relay_name, domain_name, addresses[ipv4/ipv6,
  port]}]`. Os nomes exatos dos atributos de `<te2>` não aparecem no JS (o WASM os lê).

### Transporte (visto)

O RTCPeerConnection do navegador é **só um cano de datagramas** até um relay do WhatsApp — sem
RTP/SRTP do WebRTC:

- DataChannel pré-negociado (`id 0`, não ordenado, sem retransmissão) sobre DTLS/SCTP;
- SDP do outro lado **inventado** pelo JS: `ice-ufrag` = token de autenticação, `ice-pwd` =
  `relay_key`, `setup:passive`, fingerprint DTLS **fixo** do relay
  (`F9:CA:0C:98:A3:CC:71:D6:42:CE:5A:E2:53:D2:15:20:D3:1B:BA:D8:57:A4:F0:AF:BE:0B:FB:F3:6B:0C:A0:68`),
  um candidato host `<ip do relay> 3480/udp` (TCP 3478 de reserva);
- dentro do canal vão os pacotes do WASM: alocação/ligação estilo STUN no relay e (inferido) a mídia
  cifrada. Alternativas atrás de flags: WebTransport (`https://<relay>/webtransport?token&auth`) e P2P.

### Liberação (visto)

`isCallingEnabled`: no app Windows sempre; no navegador só com `SharedArrayBuffer`/isolamento e a
ABProp **`enable_web_calling`** (padrão `false`, o servidor liga por conta). Grupo:
`enable_web_group_calling`; P2P, WebTransport, links de chamada e compartilhar tela têm suas props.

### O que o whatsmeow já tem

Recebe `offer`, `offer_notice`, `accept`, `preaccept`, `transport`, `relaylatency`, `terminate`,
`reject` (com o nó cru) e envia `reject`. Falta: decifrar/cifrar o `<enc>` da chave, o `<receipt>`
de chamada, acks com `type`, e tudo de relay e mídia.

## 2. O que já temos

| Peça | Onde | Serve? |
|---|---|---|
| ICE + STUN (host/srflx, checks, nomeação) | `d-webrtc-v3` `ice/`, `stun/` | Sim |
| DTLS 1.2 (OpenSSL, P-256, fingerprint fixado) | `d-webrtc-v3` `dtls/` | Sim — é o mesmo papel do navegador |
| SCTP + DataChannel (DCEP, canais negociados) | `d-webrtc-v3` `sctp/`, `datachannel/` | **Sim — é exatamente o cano que o WA Web usa** |
| Conexão montada, sans-io (o chamador dá socket e relógio) | `d-webrtc-v3` `connection/` | Sim, num fiber UDP de vibe-core como o `transport/webrtc` da libp2p |
| Sinal, protocolo WA, criptografia | core Go (whatsmeow) e `wa/` (D) | Sinalização e chave da chamada |
| RTP/SRTP, TURN, jitter buffer, Opus/H.264, PipeWire, cancelamento de eco | — | Não temos |

A boa notícia: o caminho do navegador é **DataChannel sobre DTLS/SCTP com SDP inventado** — o que o
`d-webrtc-v3` já faz (e já fala com rust/go-libp2p). Não precisamos de RTP/SRTP do WebRTC.

## 3. O problema central: o motor de mídia

O protocolo de mídia (o que vai dentro do cano: alocação no relay, cifra da mídia, codecs, controle
de banda) **não está no JS** — está no WASM do WhatsApp. Três caminhos:

**A. Rodar o WASM do WhatsApp nativamente** (wasmtime/WAMR com threads) e implementar em D/C as
funções que ele importa (sinalização, captura/reprodução, vídeo, aleatoriedade, os stubs do
Emscripten), com o cano do relay pelo `d-webrtc-v3`.
Prós: compatibilidade total, o WhatsApp mantém o protocolo por nós. Contras: superfície do glue
Emscripten (168 KB de JS) — pthreads/memória compartilhada fora do navegador; baixar o WASM em tempo
de execução (como o navegador; nunca versionar — é artefato deles); cada versão nova pode mudar os
imports.

**B. Rodar o motor web num QtWebEngine escondido** só para a chamada: uma página nossa,
isolada (COOP/COEP), com o loader e os módulos de voip do WhatsApp e shims para o resto, falando
com o core pela ponte Qt.
Prós: o navegador já dá WebRTC, AudioWorklet, WebCodecs, getUserMedia. Contras: volta o Chromium
(~centenas de MB só durante a chamada); os módulos de voip dependem de muitos outros módulos do WA
Web (o sistema `__d`), e recriar esse contexto é trabalho de engenharia reversa frágil.

**C. Reimplementar o protocolo de mídia** (como os apps móveis falam com os relays por UDP direto,
inferido): engenharia reversa do WASM (alocação no relay, cifra e framing da mídia, negociação de
codec, BWE). Prós: nativo e leve. Contras: o maior esforço e o mais incerto; sem documentação.

**Decisão (2026-10-22): caminho B**, com o Chromium vivo **só durante a chamada**:

- um processo à parte, `qwhats-call` (D + QtWebEngine), lançado pelo app quando uma chamada começa
  (ao chegar a oferta, enquanto toca — dá tempo de carregar antes de atender; ao ligar, no clique) e
  **morto** quando ela termina (terminate/reject/timeout), com um vigia que o mata se o app morrer ou
  ele travar; matar o processo devolve toda a memória;
- a página carrega o WhatsApp Web da origem real (os cabeçalhos COOP/COEP dão o isolamento que o
  `SharedArrayBuffer` do WASM exige), **sem fazer login**: um script nosso pega o motor de voip pelo
  `require` do próprio WA Web, liga a flag de chamada no lado do cliente e troca o transporte de
  sinalização pelo nosso — o core (que é o aparelho que recebe a oferta) decifra a chave e repassa o
  nó; o que o motor emite volta pelo core;
- o cache de disco do perfil do QtWebEngine guarda os bundles e o WASM: da segunda vez sobe rápido.

C continua como evolução de longo prazo.

## 4. Plano

### Fase 0 — sondagens (poucos dias)
1. **A conta pode ligar pelo web?** Ler as ABProps da conta pelo core (`enable_web_calling` = código
   15461, `enable_web_group_calling` = 20924, `enable_web_voip_p2p` = 25621,
   `enable_web_voip_webtransport` = 29764, `is_guest_calling_eligible` = 35115; IQ `abt`
   `<props protocol="1"/>`, feito em `core/abprops.go`, só leitura, vai para o log).
2. **Registrar ofertas reais**: gravar o `<call>` cru (offer, ack com `<relay>/<te2>`) num arquivo de
   diagnóstico, sem conteúdo de mensagens.
3. **Inventariar o WASM**: baixar `wa_voip_shared.wasm` para `~/.cache` (não versionar) e listar
   imports/exports (`wasm-objdump -x`): tamanho do que A exige.
4. **Cano até o relay**: com o token/`relay_key` de uma oferta real, abrir ICE+DTLS (fingerprint
   fixo)+SCTP+DataChannel até `relay:3480` com o `d-webrtc-v3`. Provar que o cano nativo funciona é
   pré-requisito de A e de C.
5. **(B) O motor sobe sem login?** Um protótipo de `qwhats-call` abre o WA Web num QtWebEngine e
   confere: `crossOriginIsolated`, `require` acessível, `WAWebVoipStackInterfaceWeb` e o WASM
   carregando, e quanto tempo isso leva (frio e com cache). Medir memória e confirmar que matar o
   processo a devolve.

### Fase 1 — sinalização no core (independe do caminho)
- Chamada recebida: decifrar o `<enc>` (Signal, `Message.call.callKey`), `<receipt>`/acks corretos,
  tocar/avisar na UI (já existe `Call:offer`), recusar, encerrar, "chamada perdida" correta.
- Chamada feita: montar o `offer` (vem do motor de mídia), cifrar a chave por aparelho, fan-out.
- UI: tela de chamada no estilo do WA Web (entrando/tocando/em chamada, mudo, vídeo, desligar).

### Fase 2 — motor de mídia (A ou B, conforme a fase 0)
- A: runtime WASM com threads + glue mínimo em D; cano pelo `d-webrtc-v3` num fiber UDP.
- B: página isolada no QtWebEngine com o loader do WA e shims; ponte com o core.
- Critério de pronto: uma chamada de **áudio 1:1** completa com o celular.

### Fase 3 — áudio e vídeo nativos (se A)
- Áudio: PipeWire (captura/reprodução), reamostragem, cancelamento de eco (WebRTC APM ou speexdsp).
- Vídeo: câmera por PipeWire/V4L2, H.264 (openh264/ffmpeg), desenho num item Qt Quick.

### Fase 4 — além do 1:1
Chamadas em grupo, links de chamada (`link_create` → `call.whatsapp.com/...`), compartilhar tela.

## 5. Riscos
- **Liberação por conta**: sem `enable_web_calling`, um aparelho web pode não poder atender.
- **Termos de uso**: rodar o WASM do WhatsApp fora do navegador (A) ou recriar o protocolo (C) é
  além do que o cliente oficial faz; risco de bloqueio da conta. Testar numa conta secundária.
- **Mudanças de versão**: o WASM e os imports mudam com o WA Web; A e B precisam acompanhar.
- **Nada de artefatos deles no repositório**: WASM e bundles só em `~/.cache`.

## 6. Resultados da fase 0 (2026-10-22)

**Flags da conta** (`core/abprops.go`): `enable_web_calling = 0`, `enable_web_group_calling = 0`,
`enable_web_voip_p2p` e `enable_web_voip_webtransport` não enviadas (padrão), `is_guest_calling_eligible = 1`.
A trava é do cliente; falta saber se o servidor entrega ofertas completas (com `<relay>`) a um
aparelho web — o core grava as stanzas `<call>` em `~/.cache/qml-whats-build/calls/` (0600) para a
primeira chamada recebida.

**O motor sobe sem login** (sonda `tools/callprobe/`, PySide6 + QtWebEngine 6.11, perfil próprio,
num sway headless isolado):

- página do WA Web carregada em ~2,5 s; `require` e os módulos de voip disponíveis antes do login;
- o WA Web manda `Document-Isolation-Policy: isolate-and-require-corp` (mecanismo do Chrome 137+),
  que o QtWebEngine não aplica (`crossOriginIsolated = false`, mesmo com
  `--enable-features=DocumentIsolationPolicy`); **`--enable-features=SharedArrayBuffer`** resolve:
  o WA só confere `SharedArrayBuffer` e `Atomics`;
- `loadVoipWasmVariant("prod-nonlab")` baixa e instancia o `wa_voip_shared.wasm` em ~0,5 s (com
  cache), com pthreads;
- o WASM expõe (Embind) uma API de alto nível: `initVoipStack`, `setABPropBool/Int/String`,
  `setOwnOtherDeviceJids`, `handleIncomingSignalingOffer/Message/Ack/Receipt`, `acceptCall`,
  `rejectCall`, `endCall`, `startVoipCall`, `startVoipGroupCall`, `setCallMute`,
  `setCallVideoMute`, `startScreenShare`, `joinCallLink`, `onAudioDataFromJs`,
  `requestAudioDataFromWasmVoip`, `onVideoDataFromJs`, `handleOnMessage` (o que chega do relay),
  `markRelayConnected`, `initSctpRingBuffer`… — o motor é dirigível de fora;
- `getVoipStackInterface()` devolve `null` sem login (as ABProps não estão prontas e a chamada está
  desligada) — próximo passo: dar as ABProps pelo `WAWebABProps.setGetABPropConfigValueImpl`;
- memória: o conjunto (processo + QtWebEngineProcess) ~1,3 GB de RSS com o motor carregado
  (RSS conta memória compartilhada mais de uma vez) — aceitável só durante a chamada.

**Interface do motor obtida**: com `WAWebABProps.setGetABPropConfigValueImpl(n => n ===
"enable_web_calling" ? true : null)`, `getVoipStackInterface()` devolve em ~0,2 s o objeto do WA Web
com `voipInit`, `startCall`, `startGroupCall`, `acceptCall`, `rejectCall`, `endCall`,
`handleIncomingSignalingOffer/Message/Ack/Receipt`, `handleOnTransportMessage`, `markRelayConnected`,
`setCallMute`, `setCallVideoMute`, `startScreenShare`, `joinCallLink`, `handleDeviceJidList`,
`callbacks`… O `voipInit` (módulo `WAWebVoipInit`) só exige a identidade do aparelho
(`WAWebUserPrefsMeUser.getMaybeMeDeviceLid()`; há `setMe`/`setMeLid`): daremos a do **nosso** aparelho
(o core), que é quem recebe as ofertas. A saída de sinalização é uma função só,
`WAWebVoipSendSignalingXmpp.sendWAWebVoipSignalingXmpp` — o código compilado a chama pelo objeto do
módulo a cada uso, então trocá-la pela ponte com o core basta (o core cifra o `<enc>` com as sessões
Signal do whatsmeow e envia; acks e recibos voltam pelo `handleIncomingSignalingAck/Receipt`).

**Próximos passos (fase 0 → 1):**
1. `setMe/setMeLid` com o aparelho do core e `voipInit`; confirmar o motor inicializado.
2. Achar os pontos de troca: a saída de sinalização (`WAWebVoipSendSignalingXmpp`) e a entrada
   (`WAWebHandleVoipCall` / `WAWebVoipValidateAndDecryptEnc`) — substituí-los por uma ponte com o
   core (QWebChannel ou um socket local).
3. Com uma oferta real gravada: injetá-la (chave já decifrada pelo core) e ver o motor responder
   (preaccept/receipt) e tentar conectar ao relay.

**Chamada real recebida (2026-10-22): o servidor entrega a oferta COMPLETA ao nosso aparelho**, mesmo
com `enable_web_calling = 0`. Estrutura (valores omitidos; o arquivo cru fica em
`~/.cache/qml-whats-build/calls/`, 0600):

```
<offer call-creator call-id caller_country_code caller_pn device_class joinable=1>
  <audio enc=opus rate=16000/> <audio enc=opus rate=8000/>
  <capability ver>…7 bytes</capability>
  <enc type=msg v=2>…146 bytes</enc>          ← a chave da chamada, cifrada (Signal) para o nosso aparelho
  <encopt keygen/> <metadata …/> <net medium/> <rte>…6</rte> <uploadfieldstat/> <userrate/>
  <voip_settings uncompressed>…13,7 KB</voip_settings>
  <relay attribute_padding peer_pid self_pid uuid>
    <participant jid pid/>
    <token id>…192</token> ×2   <auth_token id>…70</auth_token>   <key>…24</key>
    <te2 relay_id relay_name domain_name token_id auth_token_id c2r_rtt>…6 (IPv4:porta) | 18 (IPv6:porta)</te2> ×4
    <hbh_key>…40</hbh_key>
  </relay>
</offer>
```

Depois: três `relaylatency` (`<te latency relay_name>`), o `accept` do celular (`<te priority>` ×2, `audio`,
`net`, `encopt`) e `terminate reason=accepted_elsewhere`. Ou seja: tudo o que o motor precisa para
atender chega ao core — o caminho B está aberto.
