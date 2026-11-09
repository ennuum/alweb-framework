# alweb.themes.validator — un thème est une ressource NON FIABLE tant qu'il n'est pas validé : manifeste, structure,
# extensions permises, fichiers interdits (code ALEX, exécutables, liens symboliques), tailles bornées, gabarits
# analysables et cibles de leurs extends / include / import présentes, SVG sans script, paramètres valides.
#
#   r := validator.validate("themes/modern-business")
#   r["errors"], r["warnings"], r["manifest"], r["files"] (chemins relatifs triés), r["size"]
#   validator.check("…")            # ThemeError avec toutes les erreurs, sinon le rapport

from core use len, type
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use alweb.templates as _tpl
use alweb.themes.manifest as _manifest
use alweb.themes.customization as _custom

const MAX_FILES := 2000
const MAX_FILE := 20000000
const MAX_TOTAL := 50000000

# Extensions permises (en minuscules). Aucune ne contient de code exécuté par le serveur : un gabarit n'appelle
# que les fonctions que l'application met dans son contexte.
const ALLOWED := [".html", ".htm", ".txt", ".md", ".json", ".css", ".js", ".mjs", ".map", ".svg", ".png", ".jpg",
                  ".jpeg", ".gif", ".webp", ".avif", ".ico", ".woff", ".woff2", ".ttf", ".otf", ".eot", ".mp4",
                  ".webm", ".mp3", ".ogg", ".pdf", ".xml", ".webmanifest"]
const FORBIDDEN := [".al", ".albc", ".meta", ".so", ".dll", ".dylib", ".exe", ".bin", ".sh", ".bash", ".bat", ".cmd",
                    ".ps1", ".py", ".pyc", ".php", ".phtml", ".rb", ".pl", ".cgi", ".jar", ".class", ".wasm", ".htaccess"]
# noms sans extension tolérés à la racine
const BARE := ["LICENSE", "LICENCE", "README", "NOTICE", "CHANGELOG", "AUTHORS"]
const IGNORED := [".git", ".svn", ".hg", ".DS_Store", "Thumbs.db", "node_modules", ".alweb", "dist"]

func _ext(name):
    k := -1
    i := 0
    for ch in name:
        if str(ch) == ".":
            k = i
        i += 1
    return _s.lower(name[k:len(name)]) if k > 0 else ""

# Fichiers du dossier (relatifs, triés) ; erreurs pour les liens symboliques et les noms non sûrs.
func list_files(root, rel="", out=null, errors=null):
    files := out if out != null else []
    errs := errors if errors != null else []
    d := root if rel == "" else _os.join(root, rel)
    names := _os.list_dir(d)
    _sort(names)
    for n in names:
        if n in IGNORED:
            continue
        r := n if rel == "" else rel + "/" + n
        p := _os.join(root, r)
        if _os.islink(p):
            append(errs, r + " : lien symbolique refusé")
            continue
        if not _manifest.safe_path(r):
            append(errs, r + " : nom de fichier refusé")
            continue
        if _os.isdir(p):
            list_files(root, r, files, errs)
        else:
            append(files, r)
    return [files, errs]

func _sort(xs):
    i := 1
    while i < len(xs):
        x := xs[i]
        j := i - 1
        while j >= 0 and xs[j] > x:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = x
        i += 1
    return xs

# Cibles littérales des balises extends / include / import d'un gabarit.
func references(source):
    out := []
    i := 0
    while true:
        a := _s.find(source[i:len(source)], "{%")
        if a < 0:
            return out
        a = a + i
        b := _s.find(source[a:len(source)], "%}")
        if b < 0:
            return out
        tag := _s.trim(source[a + 2:a + b])
        if _s.starts_with(tag, "-"):
            tag = _s.trim(tag[1:len(tag)])
        for kw in ["extends ", "include ", "import "]:
            if _s.starts_with(tag, kw):
                rest := _s.trim(tag[len(kw):len(tag)])
                q := rest[0:1]
                if q == "\"" or q == "'":
                    e := _s.find(rest[1:len(rest)], q)
                    if e >= 0:
                        append(out, rest[1:e + 1])
        i = a + b + 2

func _env(root, m):
    return _tpl.Environment([_os.join(root, m["templates"]), [m["components"] + "/", _os.join(root, m["components"])]])

# Rapport de validation du thème du dossier (ne lève pas).
func validate(root):
    rep := {"errors": [], "warnings": [], "manifest": null, "files": [], "size": 0}
    if not _os.isdir(root):
        append(rep["errors"], "dossier introuvable : " + root)
        return rep
    m := null
    try:
        m = _manifest.load(root)
    catch e:
        append(rep["errors"], e.message)
    rep["manifest"] = m
    lf := list_files(root)
    files := lf[0]
    rep["files"] = files
    for e in lf[1]:
        append(rep["errors"], e)
    if len(files) > MAX_FILES:
        append(rep["errors"], str(len(files)) + " fichiers : " + str(MAX_FILES) + " au plus")
    total := 0
    for f in files:
        p := _os.join(root, f)
        sz := _os.size(p)
        total += sz
        base := _os.basename(f)
        ext := _ext(base)
        if sz > MAX_FILE:
            append(rep["errors"], f + " : " + str(sz) + " octets (" + str(MAX_FILE) + " au plus)")
        if ext in FORBIDDEN or base in [".htaccess"]:
            append(rep["errors"], f + " : type de fichier interdit dans un thème (code ou exécutable)")
        elif not (ext in ALLOWED) and not (base in BARE and not _s.contains(f, "/")):
            append(rep["errors"], f + " : extension non permise (" + (ext if ext != "" else "sans extension") + ")")
        elif ext == ".svg":
            low := _s.lower(_io.read_file(p))
            if _s.contains(low, "<script") or _s.contains(low, "javascript:") or _s.contains(low, " on") and _has_handler(low):
                append(rep["errors"], f + " : SVG avec script ou gestionnaire d'évènement")
    rep["size"] = total
    if total > MAX_TOTAL:
        append(rep["errors"], "taille totale " + str(total) + " octets (" + str(MAX_TOTAL) + " au plus)")
    if m == null:
        return rep
    for d in [m["templates"], m["assets"]]:
        if not _os.isdir(_os.join(root, d)):
            append(rep["errors"], "dossier « " + d + "/ » absent")
    if not _os.isfile(_os.join(root, m["entry"])):
        append(rep["errors"], "entry : " + m["entry"] + " absent")
    if not ("README.md" in files):
        append(rep["warnings"], "README.md absent")
    if not ("LICENSE" in files) and not ("LICENSE.md" in files) and not ("LICENCE" in files):
        append(rep["warnings"], "LICENSE absent (conditions d'utilisation du thème)")
    for s in m["screenshots"]:
        if not (s in files):
            append(rep["errors"], "screenshots : " + s + " absent")
        elif not (_ext(s) in [".png", ".jpg", ".jpeg", ".webp", ".gif"]):
            append(rep["errors"], "screenshots : " + s + " : image PNG, JPEG, WebP ou GIF attendue")
    if len(m["screenshots"]) == 0:
        append(rep["warnings"], "aucune capture d'écran (screenshots) : ajoutez des images dans preview/ (alweb theme preview pour voir les pages)")
    # paramètres
    schema := null
    if m["settings"] in files:
        try:
            schema = _json.parse(_io.read_file(_os.join(root, m["settings"])))
            for e in _custom.check_schema(schema):
                append(rep["errors"], m["settings"] + " : " + e)
        catch e:
            append(rep["errors"], m["settings"] + " : JSON invalide : " + str(e.message))
    # gabarits : analysés, cibles présentes
    if _os.isdir(_os.join(root, m["templates"])):
        env := _env(root, m)
        for f in files:
            name := null
            if _s.starts_with(f, m["templates"] + "/"):
                name = f[len(m["templates"]) + 1:len(f)]
            elif _s.starts_with(f, m["components"] + "/"):
                name = f
            if name == null or not (_ext(f) in [".html", ".htm", ".txt", ".xml"]):
                continue
            try:
                env.get(name)
                for ref in references(_io.read_file(_os.join(root, f))):
                    if not env.exists(ref):
                        append(rep["errors"], f + " : gabarit « " + ref + " » introuvable")
            catch e:
                append(rep["errors"], f + " : " + str(e.message))
    for w in _compat_warnings(root, m, files, schema):
        append(rep["warnings"], w)
    return rep

func _has_handler(low):
    for h in [" onload", " onclick", " onerror", " onmouseover", " onfocus", " onbegin", " onend", " onanimation"]:
        if _s.contains(low, h + "=") or _s.contains(low, h + " ="):
            return true
    return false

# Ce que les pages d'une application (dont l'accueil du modèle de projet) attendent d'un thème : un base.html avec un
# bloc « contenu », les réglages site.nom et site.slogan, et les classes CSS de mise en page. Leur absence ne casse
# rien (valeur vide, page sans style) : ce sont des remarques.
const PAGE_CLASSES := ["hero", "conteneur", "section", "carte", "formulaire", "bouton", "titre-section"]

func _compat_warnings(root, m, files, schema):
    out := []
    base := m["templates"] + "/base.html"
    if not (base in files):
        append(out, base + " absent : les pages de l'application ne prendront pas la mise en page du thème")
    else:
        src := _io.read_file(_os.join(root, base))
        if not _s.contains(src, "block contenu"):
            append(out, base + " : pas de {% block contenu %} : le contenu des pages de l'application ne s'affichera pas")
    site := schema["site"] if schema != null and type(schema) == "dict" and "site" in schema and type(schema["site"]) == "dict" else {}
    for k in ["nom", "slogan"]:
        if not (k in site):
            append(out, m["settings"] + " : réglage site." + k + " absent (titre et bandeau des pages de l'application)")
    css := ""
    for f in files:
        if _s.starts_with(f, m["assets"] + "/") and _ext(f) == ".css":
            css = css + _io.read_file(_os.join(root, f)) + "\n"
    missing := []
    for c in PAGE_CLASSES:
        if not _s.contains(css, "." + c + " ") and not _s.contains(css, "." + c + "{") and not _s.contains(css, "." + c + ",") and not _s.contains(css, "." + c + ".") and not _s.contains(css, "." + c + ":") and not _s.contains(css, "." + c + "\n"):
            append(missing, c)
    if len(missing) > 0:
        append(out, "classes CSS absentes (" + _s.join(", ", missing) + ") : les pages de l'application seront sans mise en forme")
    return out

# Rapport si le thème est valide ; ThemeError avec toutes les erreurs sinon.
func check(root):
    r := validate(root)
    if len(r["errors"]) > 0:
        raise("ThemeError", "thème invalide : " + _s.join(" ; ", r["errors"]))
    return r
