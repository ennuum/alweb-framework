# alweb.themes.signing — signature des archives de thème publiées sur une marketplace : ECDSA P-256 (crypto.ec
# d'ALEX, nonce déterministe RFC 6979), SHA-256.
#
#   k := signing.generate()                         # {"private": hex, "public": hex, "fingerprint": "…"}
#   signing.save_key("~/.alweb/editeur.json", k)    # fichier lisible par son seul propriétaire (0600)
#   sig := signing.sign(k["private"], "modern-business", "1.0.0", sha256_hex)
#   signing.verify(k["public"], "modern-business", "1.0.0", sha256_hex, sig)   # vrai / faux
#
# Le message signé lie l'identifiant, la version et l'empreinte de l'archive (« alweb-theme/1 »…) : une signature
# ne peut pas être reprise pour une autre version ou un autre thème. Clé publique : point non compressé (65
# octets, 04‖x‖y) en hexadécimal ; empreinte : 32 premiers caractères hexadécimaux de son SHA-256, groupés par 4.

from core use len, type
use os as _os
use io as _io
use json as _json
use string as _s
use crypto.ec as _ec
use network.security as _sec
use network.encoding as _enc
use security.random_secure as _rnd

const CURVE := "P-256"
const CONTEXT := "alweb-theme/1"

func _fail(message):
    raise("ThemeError", message)

func _hex(octets):
    return _enc.hex_encode(_s.byte_pack(octets))

func _unhex(h):
    if type(h) != "str" or len(h) % 2 != 0:
        _fail("clé ou signature : hexadécimal attendu")
    try:
        return _s.byte_unpack(_enc.hex_decode(h))
    catch e:
        _fail("clé ou signature : hexadécimal attendu")

func fingerprint(public_hex):
    h := _enc.hex_encode(_sec.digest(_s.lower(public_hex), "sha256"))[0:32]
    out := ""
    i := 0
    while i < 32:
        out = out + (":" if i > 0 else "") + h[i:i + 4]
        i += 4
    return out

func generate():
    c := _ec.curve(CURVE)
    while true:
        try:
            k := _ec.private_key(c, _rnd.random_bytes(32))
            pub := _hex(k.public_bytes())
            return {"curve": CURVE, "private": _hex(k.to_bytes()), "public": pub, "fingerprint": fingerprint(pub)}
        catch e:
            ignored := e                            # scalaire hors de [1, n-1] : on tire à nouveau

func message(slug, version, sha256_hex):
    return CONTEXT + "\n" + slug + "\n" + version + "\n" + _s.lower(sha256_hex)

func _private(private_hex):
    return _ec.private_key(_ec.curve(CURVE), _unhex(private_hex))

func public_of(private_hex):
    return _hex(_private(private_hex).public_bytes())

# Signature DER en hexadécimal.
func sign(private_hex, slug, version, sha256_hex):
    der := _ec.sign_der(_private(private_hex), _s.byte_unpack(message(slug, version, sha256_hex)), "sha256")
    return _hex(der)

func verify(public_hex, slug, version, sha256_hex, signature_hex):
    try:
        pub := _ec.public_key(_ec.curve(CURVE), _unhex(public_hex))
        return _ec.verify_der(pub, _s.byte_unpack(message(slug, version, sha256_hex)), _unhex(signature_hex), "sha256") == true
    catch e:
        return false

func valid_public(public_hex):
    try:
        _ec.public_key(_ec.curve(CURVE), _unhex(public_hex))
        return true
    catch e:
        return false

func save_key(path, key):
    _os.mkdir_all(_os.dirname(path) if _os.dirname(path) != "" else ".")
    data := {"curve": CURVE, "private": key["private"], "public": key["public"], "fingerprint": key["fingerprint"]}
    _io.write_file(path, _json.pretty(data) + "\n")
    try:
        _os.chmod(path, 384)                         # 0600
    catch e:
        ignored := e
    return path

func load_key(path):
    if not _os.isfile(path):
        _fail("clé d'éditeur introuvable : " + path + " (alweb theme keygen)")
    k := _json.parse(_io.read_file(path))
    if type(k) != "dict" or not ("private" in k):
        _fail(path + " : clé d'éditeur invalide")
    pub := public_of(k["private"])
    return {"curve": CURVE, "private": k["private"], "public": pub, "fingerprint": fingerprint(pub)}
