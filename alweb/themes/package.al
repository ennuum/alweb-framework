# alweb.themes.package — archives de thème « .alwt » (ZIP, office.archive d'ALEX) : construction reproductible
# après validation, lecture bornée (noms, extensions, nombre, tailles vérifiés AVANT d'écrire quoi que ce soit),
# extraction, empreintes.
#
#   r := package.build("mon-theme", "dist")        # {"path": "dist/modern-business-1.0.0.alwt", sha256, size, files}
#   package.extract("x.alwt", "dossier")           # ThemeError si l'archive est refusée
#   package.tree_sha256("themes/modern-business")  # empreinte du contenu (chemins et octets, ordre fixe)

from core use len, type
from collections use append, keys
use os as _os
use io as _io
use string as _s
use office.archive as _zip
use network.security as _sec
use network.encoding as _enc
use alweb.themes.manifest as _manifest
use alweb.themes.validator as _validator

const EXTENSION := ".alwt"
const FIXED_TIME := {"year": 2026, "month": 1, "day": 1, "hour": 0, "minute": 0, "second": 0}

func _fail(message):
    raise("ThemeError", message)

func sha256_hex(data):
    return _enc.hex_encode(_sec.digest(data, "sha256"))

func file_sha256(path):
    return sha256_hex(_io.read_raw(path))

# Empreinte d'un dossier de thème : SHA-256 des lignes « chemin\0sha256 » triées (indépendante des dates).
func tree_sha256(root):
    lf := _validator.list_files(root)
    lines := ""
    for f in lf[0]:
        lines = lines + f + "\u0000" + file_sha256(_os.join(root, f)) + "\n"
    return sha256_hex(lines)

# Construit l'archive du thème (validé d'abord) dans out_dir ; rend {path, sha256, size, files, manifest}.
func build(root, out_dir=null):
    rep := _validator.check(root)
    m := rep["manifest"]
    z := _zip.new()
    z.fixed_time = FIXED_TIME
    for f in rep["files"]:
        z.write(f, _s.byte_unpack(_io.read_raw(_os.join(root, f))), _validator._ext(f) in [".html", ".css", ".js", ".json", ".md", ".txt", ".svg", ".xml", ".map", ""])
    data := _s.byte_pack(z.to_bytes())
    d := out_dir if out_dir != null else "."
    _os.mkdir_all(d)
    path := _os.join(d, m["slug"] + "-" + m["version"] + EXTENSION)
    _io.write_file(path, data)
    return {"path": path, "sha256": sha256_hex(data), "size": _s.byte_len(data), "files": len(rep["files"]), "manifest": m}

# Vérifie le contenu d'une archive sans l'extraire : rend l'objet office.archive ; ThemeError sinon.
func inspect(data):
    if _s.byte_len(data) > _validator.MAX_TOTAL + 1000000:
        _fail("archive trop volumineuse")
    a := null
    try:
        a = _zip.from_bytes(_s.byte_unpack(data))
    catch e:
        _fail("archive illisible : " + str(e.message))
    total := 0
    n := 0
    for e in a.entries():
        if e.is_dir:
            continue
        n += 1
        if e.encrypted:
            _fail(e.name + " : entrée chiffrée refusée")
        if not _manifest.safe_path(e.name):
            _fail(e.name + " : chemin refusé (absolu, « .. » ou caractère interdit)")
        base := _os.basename(e.name)
        ext := _validator._ext(base)
        if ext in _validator.FORBIDDEN or not (ext in _validator.ALLOWED or (base in _validator.BARE and not _s.contains(e.name, "/"))):
            _fail(e.name + " : type de fichier refusé")
        if e.size > _validator.MAX_FILE:
            _fail(e.name + " : trop volumineux")
        total += e.size
    if n > _validator.MAX_FILES:
        _fail("archive : trop de fichiers (" + str(n) + ")")
    if total > _validator.MAX_TOTAL:
        _fail("archive : contenu trop volumineux une fois décompressé (" + str(total) + " octets)")
    if not a.contains(_manifest.FILE):
        _fail("archive : " + _manifest.FILE + " absent à la racine")
    return a

# Extrait une archive (chemin ou octets) dans dest (créé) après inspection ; tailles réelles contrôlées.
func extract(source, dest):
    # octets d'archive ou chemin : un chemin n'a ni NUL ni plus de 4 096 octets
    is_path := _s.byte_len(source) < 4096 and not _s.contains(source, "\u0000") and _os.isfile(source)
    data := _io.read_raw(source) if is_path else source
    a := inspect(data)
    _os.mkdir_all(dest)
    for e in a.entries():
        if e.is_dir:
            continue
        octets := a.read(e.name)
        if len(octets) != e.size:
            _fail(e.name + " : taille annoncée fausse")
        p := _os.join(dest, e.name)
        _os.mkdir_all(_os.dirname(p))
        _io.write_file(p, _s.byte_pack(octets))
    return {"sha256": sha256_hex(data), "size": _s.byte_len(data)}
