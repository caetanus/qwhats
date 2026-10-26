/// This device's identity, as WhatsApp Web keeps it (WAWebUserPrefsKeys / signal store): the noise
/// key that opens the connection, the Signal identity key, a signed pre-key, the registration id,
/// the ADV secret shown in the QR, and — once paired — the account's JID.
module wa.device;

import wa.crypto;

struct SignedPreKey {
    uint id;
    KeyPair key;
    ubyte[64] signature;   // XEdDSA by the identity key over the key's serialized form (0x05 ‖ pub)
}

/// Signal's serialized public key: the DJB type byte, then the 32 bytes.
enum ubyte djbType = 5;
ubyte[] serializedKey(const ubyte[32] pub) { return [djbType] ~ pub[]; }

struct Device {
    KeyPair noiseKey;
    KeyPair identityKey;
    SignedPreKey signedPreKey;
    uint registrationId;
    ubyte[32] advSecret;
    string jid;            // empty until paired ("5511…:3@s.whatsapp.net")
    string lid;
    string pushName;
    /// The account's signed identity for this device (ADVSignedDeviceIdentity with the account key,
    /// the account signature and ours) — sent as <device-identity> alongside pre-key messages.
    ubyte[] account;

    /// A new, unpaired device.
    static Device create() {
        Device d;
        d.noiseKey = KeyPair.generate();
        d.identityKey = KeyPair.generate();
        d.signedPreKey.id = 1;
        d.signedPreKey.key = KeyPair.generate();
        d.signedPreKey.signature = xeddsaSign(d.identityKey.priv, serializedKey(d.signedPreKey.key.pub));
        auto r = randomBytes(2);
        d.registrationId = ((r[0] << 8) | r[1]) & 0x3fff;   // 14 bits, as libsignal
        if (d.registrationId == 0) d.registrationId = 1;
        d.advSecret = randomBytes(32)[0 .. 32];
        return d;
    }

    bool paired() const { return jid.length > 0; }
}
