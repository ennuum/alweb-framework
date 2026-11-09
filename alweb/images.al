# alweb.images — vignettes et dimensions d'images (JPEG, PNG, GIF, WebP, BMP), et enregistrement d'une image avec
# ses variantes dans un stockage alweb.storage.
#
#   use alweb.images as images
#   v := await images.thumbnail(octets, 400, 400)              # {data, width, height, format, content_type,
#                                                              #  source_width, source_height}
#   v := await images.thumbnail(octets, 200, 200, {"mode": "cover", "format": "jpeg", "quality": 80})
#   d := await images.info(octets)                             # {width, height} (orientation Exif appliquée)
#   r := await images.store(app.storage, alweb.form(req).file("photo"), {"prefix": "photos/",
#            "sizes": {"vignette": [200, 200, "cover"], "grande": [1600, 1600]}, "max_bytes": 15000000})
#   # r : {key, width, height, content_type, variants: {"vignette": clé, "grande": clé}}
#   await images.remove(app.storage, r)
#
# Le travail est fait par un petit programme natif écrit en ALEX (alweb/outils/vignette.al, module image.encode
# d'ALEX) lancé dans un processus à part, sur un fil (thread.offload) : le serveur continue de servir, une image
# malformée ou piégée ne peut pas le faire tomber, et un délai (30 s) borne chaque appel. Ce programme est compilé
# au premier usage (alex build --native, quelques secondes) dans .alweb/outils/ ; `alweb build` le produit à côté
# de l'exécutable. ALWEB_IMAGES_HELPER=chemin : programme déjà construit. Orientation Exif appliquée (photos de
# téléphones), jamais d'agrandissement ; « fit » : tient dans le cadre ; « cover » : remplit le cadre, recadré au
# centre ; format « auto » : PNG s'il reste de la transparence, sinon JPEG.
#
# Erreurs : ImageError (image illisible, trop grande : 50 Mpx au plus), StorageError ; store : UploadError pour un
# fichier refusé ou une image illisible (réponse 400 dans un gestionnaire).

from core use len, type, to_int
from collections use append, keys
use os as _os
use io as _io
use string as _s
use time as _time
use thread.offload as _offload
use network.security as _sec
use alweb.forms as _forms
use alweb.storage as _storage

const VERSION := "1"                     # à changer quand vignette.al change : nouveau programme compilé
const TIMEOUT := 30.0

_state := {"helper": null, "building": null}

func _fail(message):
    raise("ImageError", message)

# Chemin du programme natif à utiliser (sans le construire) : ALWEB_IMAGES_HELPER, à côté de l'exécutable
# (application construite par `alweb build`), ou .alweb/outils/vignette-<version>.
func helper_path():
    e := _os.getenv("ALWEB_IMAGES_HELPER")
    if e != null and e != "":
        return e
    a := _os.argv()
    if len(a) > 0:
        nxt := _os.join(_os.dirname(_os.absolute(a[0])), "alweb-vignette")
        if _os.isfile(nxt):
            return nxt
    return _os.absolute(_os.join(".alweb", "outils", "vignette-" + VERSION))

# Source du programme : ALWEB_HOME, puis paquet alweb installé (alex_packages/alweb) ou dépôt d'alweb, cherchés
# depuis le dossier courant et ses parents (programme lancé depuis un sous-dossier, comme examples/).
func helper_source():
    cands := []
    h := _os.getenv("ALWEB_HOME")
    if h != null and h != "":
        append(cands, _os.join(h, "alweb", "outils", "vignette.al"))
    d := _os.absolute(".")
    k := 0
    while k < 6:
        append(cands, _os.join(d, "alex_packages", "alweb", "outils", "vignette.al"))
        append(cands, _os.join(d, "alweb", "outils", "vignette.al"))
        up := _os.dirname(d)
        if up == d or up == "":
            break
        d = up
        k += 1
    for c in cands:
        if _os.isfile(c):
            return c
    _fail("source du programme des vignettes introuvable (alex_packages/alweb/outils/vignette.al ; ALWEB_HOME)")

# Construit le programme natif (bloquant ; appelé sur un fil). Rend [chemin, null] ou [null, erreur].
func build_helper(source, target, alex):
    try:
        _os.mkdir_all(_os.dirname(target))
        tmp := target + ".tmp-" + str(_os.pid())
        r := _os.run(alex, ["build", "--native", source, "-o", tmp])
        if r["code"] != 0 or not _os.isfile(tmp):
            return [null, "compilation du programme des vignettes : " + _s.trim(r["stderr"] + " " + r["stdout"])]
        _os.move(tmp, target)
        return [target, null]
    catch e:
        return [null, str(e.type) + " : " + str(e.message)]

func _alex():
    e := _os.executable()
    return e if e != null and e != "" else "alex"

# Programme prêt (construit au besoin, une seule fois même si plusieurs requêtes le demandent ensemble).
async func helper():
    if _state["helper"] != null:
        return _state["helper"]
    p := helper_path()
    if _os.isfile(p):
        _state["helper"] = p
        return p
    if _state["building"] == null:
        _state["building"] = _offload.run(build_helper, [helper_source(), p, _alex()])
    r := await _state["building"]
    _state["building"] = null
    if r[0] == null:
        _fail(r[1])
    _state["helper"] = r[0]
    return r[0]

# Exécute le programme sur un fil : [code, sortie d'erreur] ; tué après timeout secondes.
func run_helper(program, args, timeout):
    try:
        pid := _os.spawn(program, args)
        code := _os.wait(pid, timeout)
        if code == null:
            _os.kill(pid, "KILL")
            _os.wait(pid, 5.0)
            return [-1, "délai dépassé (" + str(timeout) + " s)"]
        return [code, ""]
    catch e:
        return [-2, str(e.type) + " : " + str(e.message)]

func _tmpdir():
    d := _os.join(_os.tmp_dir(), "alweb-images-" + str(_os.pid()))
    _os.mkdir_all(d)
    return d

func _cleanup(paths):
    for p in paths:
        try:
            if _os.isfile(p):
                _os.remove(p)
        catch e:
            ignored := e

async func _call(data, w, h, mode, fmt, quality):
    if type(data) != "str" or _s.byte_len(data) == 0:
        _fail("image vide")
    prog := await helper()
    d := _tmpdir()
    base := _os.join(d, _sec.random_hex(8))
    src := base + ".in"
    out := base + ".out"
    _io.write_file(src, data)
    res := null
    err := null
    try:
        r := await _offload.run(run_helper, [prog, [src, out, str(w), str(h), mode, fmt, str(quality)], TIMEOUT])
        info := out + ".info"
        if r[0] != 0 or not _os.isfile(info):
            msg := r[1]
            if _os.isfile(out + ".err"):
                msg = _last_line(_io.read_file(out + ".err"))
            err = "image illisible" + (" : " + msg if msg != "" else "")
        else:
            f := _s.split(_s.trim(_io.read_file(info)), " ")
            res = {"source_width": to_int(f[0]), "source_height": to_int(f[1]), "width": to_int(f[2]), "height": to_int(f[3]), "format": f[4]}
            if mode != "none":
                res["data"] = _io.read_raw(out)
                res["content_type"] = "image/png" if f[4] == "png" else "image/jpeg"
    catch e:
        err = str(e.type) + " : " + str(e.message)
    _cleanup([src, out, out + ".info", out + ".err"])
    if err != null:
        _fail(err)
    return res

func _last_line(text):
    lines := [l for l in _s.split(_s.trim(text), "\n") if _s.trim(l) != ""]
    return _s.trim(lines[len(lines) - 1]) if len(lines) > 0 else ""

# Vignette d'une image (octets). options : mode ("fit" | "cover"), format ("auto" | "jpeg" | "png"), quality (82).
async func thumbnail(data, width, height, options=null):
    o := options if options != null else {}
    mode := o["mode"] if "mode" in o else "fit"
    if not (mode in ["fit", "cover"]):
        _fail("mode inconnu : " + str(mode) + " (fit ou cover)")
    fmt := o["format"] if "format" in o else "auto"
    if not (fmt in ["auto", "jpeg", "png"]):
        _fail("format inconnu : " + str(fmt) + " (auto, jpeg ou png)")
    q := o["quality"] if "quality" in o else 82
    if to_int(width) < 1 or to_int(height) < 1 or to_int(width) > 10000 or to_int(height) > 10000:
        _fail("taille de vignette invalide : " + str(width) + "x" + str(height))
    return await _call(data, to_int(width), to_int(height), mode, fmt, to_int(q))

# Dimensions d'une image (orientation Exif appliquée).
async func info(data):
    r := await _call(data, 1, 1, "none", "auto", 0)
    return {"width": r["source_width"], "height": r["source_height"]}

func _ext(content_type):
    return ".png" if content_type == "image/png" else ".jpg"

# Enregistre une image (UploadedFile ou octets) et ses variantes. options : prefix, sizes ({nom: [l, h, mode,
# format]}), max_bytes, quality, keep_original (true : l'original tel quel ; false : seulement les variantes).
async func store(st, upload, options=null):
    o := options if options != null else {}
    data := upload
    real := null
    if type(upload) != "str":
        real = _forms.check_upload(upload, o["max_bytes"] if "max_bytes" in o else null, ["image/png", "image/jpeg", "image/gif", "image/webp"])
        data = upload.data
    elif "max_bytes" in o and _s.byte_len(upload) > o["max_bytes"]:
        raise("UploadError", "fichier trop volumineux")
    prefix := o["prefix"] if "prefix" in o else ""
    stem := prefix + _sec.random_hex(16)
    dims := null                            # refuse ce qui n'est pas une image lisible avant d'enregistrer
    try:
        dims = await info(data)
    catch e:
        if e.type == "ImageError" and _s.starts_with(e.message, "image illisible"):
            raise("UploadError", e.message)
        raise(e)
    result := {"key": null, "width": dims["width"], "height": dims["height"], "content_type": real, "variants": {}}
    written := []
    try:
        if not ("keep_original" in o) or o["keep_original"] != false:
            ct := real if real != null else _sniff_type(data)
            k := await st.put(stem + _ext_of(ct), data, {"content_type": ct})
            append(written, k)
            result["key"] = k
            result["content_type"] = ct
        sizes := o["sizes"] if "sizes" in o else {}
        for name in keys(sizes):
            s := sizes[name]
            if not _valid_name(name):
                _fail("nom de variante invalide : " + str(name))
            v := await thumbnail(data, s[0], s[1], {"mode": s[2] if len(s) > 2 else "fit", "format": s[3] if len(s) > 3 else "auto", "quality": o["quality"] if "quality" in o else 82})
            k := await st.put(stem + "-" + name + _ext(v["content_type"]), v["data"], {"content_type": v["content_type"]})
            append(written, k)
            result["variants"][name] = k
    catch e:
        for k in written:
            try:
                await st.delete(k)
            catch e2:
                ignored := e2
        raise(e.type, e.message)
    return result

# Supprime une image enregistrée par store (original et variantes).
async func remove(st, stored):
    if stored == null:
        return
    if stored["key"] != null:
        await st.delete(stored["key"])
    for name in keys(stored["variants"]):
        await st.delete(stored["variants"][name])

func _valid_name(n):
    if type(n) != "str" or n == "" or len(n) > 40:
        return false
    for ch in n:
        c := str(ch)
        if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"):
            return false
    return true

func _sniff_type(data):
    t := _forms.sniff(data)
    return t if t != null else "application/octet-stream"

func _ext_of(ct):
    return {"image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp"}[ct] if ct in ["image/png", "image/jpeg", "image/gif", "image/webp"] else ""
