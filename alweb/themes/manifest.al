# alweb.themes.manifest — fichier alweb-theme.json d'un thème : lecture, champs requis et types, clés inconnues
# refusées, versions sémantiques et contraintes de version.
#
#   m := manifest.load("themes/modern-business")        # dict normalisé (défauts posés) ; ThemeError sinon
#   manifest.parse_version("1.2.0-beta.1")               # [1, 2, 0, "beta.1"]
#   manifest.satisfies("1.4.2", ">=1.2.0, <2.0.0")       # true ; aussi ^1.2.0, ~1.2.0, =1.2.0, 1.2.0, *

from core use len, type, to_int
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s

const FILE := "alweb-theme.json"

const CATEGORIES := ["business", "ecommerce", "education", "dashboard", "portfolio", "blog", "real-estate", "health",
                     "finance", "saas", "landing", "webapp", "community", "organization", "other"]

# champ -> [type, requis, défaut]
const FIELDS := {
    "name": ["str", true, null], "slug": ["slug", true, null], "version": ["version", true, null],
    "description": ["str", false, ""], "author": ["str", false, ""], "framework": ["framework", true, null],
    "framework_version": ["constraint", true, null], "alex_version": ["constraint", false, null],
    "category": ["category", false, "other"], "license": ["str", true, null], "entry": ["path", true, null],
    "templates": ["path", false, "templates"], "components": ["path", false, "components"],
    "assets": ["path", false, "static"], "settings": ["path", false, "config/theme.json"],
    "responsive": ["bool", false, true], "languages": ["strlist", false, []], "dependencies": ["deps", false, []],
    "screenshots": ["pathlist", false, []], "homepage": ["url", false, null], "keywords": ["strlist", false, []]}

func _fail(message):
    raise("ThemeError", message)

# ---------------------------------------------------------------- versions

# [majeur, mineur, correctif, pré-version ("" si aucune)] ou null si le texte n'est pas une version.
func parse_version(text):
    if type(text) != "str" or text == "" or len(text) > 64:
        return null
    t := text
    k := _s.find(t, "+")
    if k >= 0:
        t = t[0:k]
    pre := ""
    k = _s.find(t, "-")
    if k >= 0:
        pre = t[k + 1:len(t)]
        t = t[0:k]
        if pre == "":
            return null
    parts := _s.split(t, ".")
    if len(parts) != 3:
        return null
    out := []
    for p in parts:
        if p == "" or len(p) > 9 or not _digits(p) or (len(p) > 1 and p[0:1] == "0"):
            return null
        append(out, to_int(p))
    append(out, pre)
    return out

func _digits(p):
    for ch in p:
        c := str(ch)
        if c < "0" or c > "9":
            return false
    return true

# -1, 0 ou 1. Une pré-version passe avant la version finale (1.0.0-beta < 1.0.0).
func compare(a, b):
    va := parse_version(a) if type(a) == "str" else a
    vb := parse_version(b) if type(b) == "str" else b
    i := 0
    while i < 3:
        if va[i] != vb[i]:
            return -1 if va[i] < vb[i] else 1
        i += 1
    if va[3] == vb[3]:
        return 0
    if va[3] == "":
        return 1
    if vb[3] == "":
        return -1
    return -1 if va[3] < vb[3] else 1

func _clause(v, clause):
    c := _s.trim(clause)
    if c == "" or c == "*":
        return true
    for op in [">=", "<=", "==", ">", "<", "=", "^", "~"]:
        if _s.starts_with(c, op):
            w := _s.trim(c[len(op):len(c)])
            pw := parse_version(w)
            if pw == null:
                _fail("contrainte de version invalide : " + clause)
            d := compare(v, pw)
            if op == ">=":
                return d >= 0
            if op == "<=":
                return d <= 0
            if op == ">":
                return d > 0
            if op == "<":
                return d < 0
            if op == "=" or op == "==":
                return d == 0
            if op == "^":
                # même majeur (0.x : même mineur), au moins w
                if d < 0:
                    return false
                return v[0] == pw[0] and (pw[0] != 0 or v[1] == pw[1])
            # ~ : même majeur et mineur, au moins w
            return d >= 0 and v[0] == pw[0] and v[1] == pw[1]
    pw := parse_version(c)
    if pw == null:
        _fail("contrainte de version invalide : " + clause)
    return compare(v, pw) == 0

# La version satisfait-elle la contrainte (« >=0.9.0 », « >=0.9.0, <2.0.0 », « ^1.2.0 », « ~1.2.0 », « 1.2.0 ») ?
func satisfies(version, constraint):
    v := parse_version(version)
    if v == null:
        _fail("version invalide : " + str(version))
    for clause in _s.split(constraint, ","):
        if not _clause(v, clause):
            return false
    return true

func valid_constraint(constraint):
    if type(constraint) != "str" or constraint == "" or len(constraint) > 120:
        return false
    try:
        satisfies("1.0.0", constraint)
        return true
    catch e:
        return false

# ---------------------------------------------------------------- chemins

# Chemin relatif sûr (pas absolu, pas de « .. », de « \ », de caractère de contrôle).
func safe_path(p):
    if type(p) != "str" or p == "" or len(p) > 255:
        return false
    if _s.starts_with(p, "/") or _s.contains(p, "\\") or _s.contains(p, ":"):
        return false
    for ch in p:
        c := str(ch)
        if c < " " or c == "\u007f":
            return false
    for part in _s.split(p, "/"):
        if part == ".." or part == "." or part == "":
            return false
    return true

func valid_slug(s):
    if type(s) != "str" or len(s) < 2 or len(s) > 60:
        return false
    i := 0
    for ch in s:
        c := str(ch)
        ok := (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or (c == "-" and i > 0 and i < len(s) - 1)
        if not ok:
            return false
        i += 1
    return not _s.contains(s, "--")

# ---------------------------------------------------------------- vérification

func _check(name, kind, v, errors):
    if kind == "str":
        if type(v) != "str" or len(v) > 2000:
            append(errors, name + " : texte attendu")
        elif v == "" and FIELDS[name][1]:
            append(errors, name + " : ne doit pas être vide")
    elif kind == "slug":
        if not valid_slug(v):
            append(errors, name + " : minuscules, chiffres et tirets (2 à 60 caractères), ex. « modern-business »")
    elif kind == "version":
        if parse_version(v) == null:
            append(errors, name + " : version sémantique attendue (ex. « 1.0.0 »)")
    elif kind == "framework":
        if v != "ALWEB":
            append(errors, name + " : « ALWEB » attendu")
    elif kind == "constraint":
        if not valid_constraint(v):
            append(errors, name + " : contrainte de version invalide (ex. « >=0.9.0 »)")
    elif kind == "category":
        if not (v in CATEGORIES):
            append(errors, name + " : catégorie inconnue « " + str(v) + " » (" + _s.join(", ", CATEGORIES) + ")")
    elif kind == "path":
        if not safe_path(v):
            append(errors, name + " : chemin relatif attendu, sans « .. » : " + str(v))
    elif kind == "bool":
        if type(v) != "bool":
            append(errors, name + " : true ou false attendu")
    elif kind == "strlist":
        if type(v) != "list":
            append(errors, name + " : liste de textes attendue")
        else:
            for x in v:
                if type(x) != "str":
                    append(errors, name + " : liste de textes attendue")
    elif kind == "pathlist":
        if type(v) != "list":
            append(errors, name + " : liste de chemins attendue")
        else:
            for x in v:
                if not safe_path(x):
                    append(errors, name + " : chemin invalide : " + str(x))
    elif kind == "url":
        if v != null and (type(v) != "str" or not (_s.starts_with(v, "https://") or _s.starts_with(v, "http://"))):
            append(errors, name + " : adresse http(s) attendue")
    elif kind == "deps":
        if type(v) != "list":
            append(errors, name + " : liste attendue")
        else:
            for d in v:
                if type(d) != "dict" or not ("slug" in d) or not valid_slug(d["slug"]) or ("version" in d and not valid_constraint(d["version"])):
                    append(errors, name + " : éléments {\"slug\": …, \"version\": \">=1.0.0\"} attendus")

# Vérifie un manifeste déjà lu ; rend [manifeste normalisé, erreurs].
func check(data):
    errors := []
    if type(data) != "dict":
        return [null, [FILE + " : objet JSON attendu"]]
    out := {}
    for k in keys(data):
        if not (k in FIELDS):
            append(errors, "clé inconnue « " + str(k) + " » (permises : " + _s.join(", ", keys(FIELDS)) + ")")
    for k in keys(FIELDS):
        spec := FIELDS[k]
        if k in data and data[k] != null:
            _check(k, spec[0], data[k], errors)
            out[k] = data[k]
        elif spec[1]:
            append(errors, "champ requis manquant : " + k)
        else:
            out[k] = spec[2]
    if "entry" in out and "templates" in out and out["entry"] != null and not _s.starts_with(str(out["entry"]), str(out["templates"]) + "/"):
        append(errors, "entry : doit être dans le dossier des gabarits (" + str(out["templates"]) + "/)")
    return [out, errors]

# Manifeste du thème du dossier ; ThemeError (toutes les erreurs) s'il est absent ou invalide.
func load(directory):
    p := _os.join(directory, FILE)
    if not _os.isfile(p):
        _fail(FILE + " absent de " + directory)
    data := null
    try:
        data = _json.parse(_io.read_file(p))
    catch e:
        _fail(FILE + " : JSON invalide : " + str(e.message))
    r := check(data)
    if len(r[1]) > 0:
        _fail(FILE + " : " + _s.join(" ; ", r[1]))
    return r[0]
