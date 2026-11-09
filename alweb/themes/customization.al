# alweb.themes.customization — paramètres personnalisables d'un thème : schéma (config/theme.json du thème), choix
# du projet (config/theme.<slug>.json, gardés à part : une mise à jour du thème ne les écrase pas), valeurs
# vérifiées selon leur type, variables CSS.
#
# Schéma : dict imbriqué dont les feuilles sont {"type": …, "default": …[, "label", "options", "min", "max"]} :
#   color   « #e87524 », « #fff », « #e8752480 »          size    « 16px », « 1.2rem », « 80% », « 0 »
#   font    « Inter, system-ui, sans-serif »               text    texte court (sans < > { } ;), 500 car. au plus
#   bool    true / false                                    number  nombre (min, max)
#   choice  une des valeurs de « options »                 url     « https://… », « /chemin »
#   image   chemin dans static/ du thème, « media:clé » (alweb.storage) ou « https://… »
#   links   [{"label": …, "url": …}, …] (20 au plus)
#
#   v := customization.merge(schema, choix)    # valeurs fusionnées ; ThemeError (toutes les erreurs) sinon
#   customization.css(schema, v)               # « :root { --couleurs-primaire: #e87524; … } »

from core use len, type, to_int, to_float
from collections use append, keys
use string as _s

const TYPES := ["color", "size", "font", "text", "bool", "number", "choice", "url", "image", "links"]

func _fail(message):
    raise("ThemeError", message)

func is_leaf(node):
    return type(node) == "dict" and "type" in node and type(node["type"]) == "str"

func _hex(c):
    return (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")

func _no_specials(v, extra=""):
    for ch in v:
        c := str(ch)
        if c < " " or c in ["<", ">", "{", "}", ";", "\\", "\"", "`"] or _s.contains(extra, c):
            return false
    return true

func _url_ok(v):
    if type(v) != "str" or len(v) > 2000 or not _no_specials(v, "'() "):
        return false
    return _s.starts_with(v, "https://") or _s.starts_with(v, "http://") or (_s.starts_with(v, "/") and not _s.starts_with(v, "//"))

# Message d'erreur pour la valeur d'une feuille, ou null si elle convient.
func check_value(spec, v):
    t := spec["type"]
    if t == "color":
        if type(v) != "str" or not _s.starts_with(v, "#") or not (len(v) in [4, 5, 7, 9]):
            return "couleur « #rrggbb » attendue"
        for ch in v[1:len(v)]:
            if not _hex(str(ch)):
                return "couleur « #rrggbb » attendue"
        return null
    if t == "size":
        if type(v) != "str" or len(v) > 20:
            return "taille attendue (16px, 1.2rem, 80%)"
        if v == "0":
            return null
        unit := null
        for u in ["px", "rem", "em", "%", "vw", "vh", "ch"]:
            if unit == null and _s.ends_with(v, u):
                unit = u
        if unit == null:
            return "taille attendue (16px, 1.2rem, 80%)"
        num := v[0:len(v) - len(unit)]
        if num == "":
            return "taille attendue (16px, 1.2rem, 80%)"
        for ch in num:
            c := str(ch)
            if not ((c >= "0" and c <= "9") or c == "."):
                return "taille attendue (16px, 1.2rem, 80%)"
        return null
    if t == "font":
        if type(v) != "str" or v == "" or len(v) > 200 or not _no_specials(v, "():/"):
            return "nom de police attendu (« Inter, system-ui, sans-serif »)"
        return null
    if t == "text":
        if type(v) != "str" or len(v) > 500 or not _no_specials(v):
            return "texte court attendu (500 caractères, sans < > { } ; \\ \" `)"
        return null
    if t == "bool":
        return null if type(v) == "bool" else "true ou false attendu"
    if t == "number":
        if type(v) != "int" and type(v) != "float":
            return "nombre attendu"
        if "min" in spec and v < spec["min"]:
            return "au moins " + str(spec["min"])
        if "max" in spec and v > spec["max"]:
            return "au plus " + str(spec["max"])
        return null
    if t == "choice":
        opts := spec["options"] if "options" in spec else []
        return null if v in opts else "une valeur parmi " + str(opts) + " attendue"
    if t == "url":
        return null if _url_ok(v) else "adresse https://… ou /chemin attendue"
    if t == "image":
        if type(v) != "str" or v == "":
            return "image attendue (chemin du thème, media:clé ou https://…)"
        if _s.starts_with(v, "media:"):
            return null if len(v) > 6 and _no_specials(v) and not _s.contains(v, "..") else "clé de stockage invalide"
        if _s.starts_with(v, "http"):
            return null if _url_ok(v) else "adresse invalide"
        if _s.starts_with(v, "/") or _s.contains(v, "..") or _s.contains(v, "\\") or not _no_specials(v, "'() "):
            return "chemin dans static/ du thème attendu (« images/logo.svg »)"
        return null
    if t == "links":
        if type(v) != "list" or len(v) > 20:
            return "liste de liens [{\"label\": …, \"url\": …}] attendue (20 au plus)"
        for l in v:
            if type(l) != "dict" or not ("label" in l) or not ("url" in l) or type(l["label"]) != "str" or len(l["label"]) > 80 or not _url_ok(l["url"]):
                return "liste de liens [{\"label\": …, \"url\": …}] attendue (adresses https://… ou /chemin)"
        return null
    return "type inconnu « " + str(t) + " » (" + _s.join(", ", TYPES) + ")"

# Erreurs du schéma lui-même (types, valeurs par défaut).
func check_schema(schema, prefix="", errors=null):
    errs := errors if errors != null else []
    if type(schema) != "dict":
        append(errs, (prefix if prefix != "" else "paramètres") + " : objet attendu")
        return errs
    for k in keys(schema):
        node := schema[k]
        name := prefix + k
        if not _valid_key(k):
            append(errs, name + " : nom invalide (lettres, chiffres, _)")
        elif is_leaf(node):
            if not (node["type"] in TYPES):
                append(errs, name + " : type inconnu « " + node["type"] + " » (" + _s.join(", ", TYPES) + ")")
            elif not ("default" in node):
                append(errs, name + " : valeur par défaut (« default ») manquante")
            else:
                m := check_value(node, node["default"])
                if m != null:
                    append(errs, name + " : valeur par défaut : " + m)
        elif type(node) == "dict":
            check_schema(node, name + ".", errs)
        else:
            append(errs, name + " : {\"type\": …, \"default\": …} ou groupe attendu")
    return errs

func _valid_key(k):
    if type(k) != "str" or k == "" or len(k) > 40:
        return false
    for ch in k:
        c := str(ch)
        if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_"):
            return false
    return true

func _merge(schema, choices, prefix, errs):
    out := {}
    if choices != null and type(choices) != "dict":
        append(errs, (prefix if prefix != "" else "choix") + " : objet attendu")
        choices = null
    if choices != null:
        for k in keys(choices):
            if not (k in schema):
                append(errs, prefix + k + " : paramètre inconnu du thème")
    for k in keys(schema):
        node := schema[k]
        has := choices != null and k in choices
        if is_leaf(node):
            v := choices[k] if has else node["default"]
            m := check_value(node, v)
            if m != null:
                append(errs, prefix + k + " : " + m)
                v = node["default"]
            out[k] = v
        else:
            out[k] = _merge(node, choices[k] if has else null, prefix + k + ".", errs)
    return out

# Valeurs fusionnées (défauts du thème, remplacés par les choix du projet) ; ThemeError si un choix est invalide.
func merge(schema, choices=null):
    errs := []
    v := _merge(schema, choices, "", errs)
    if len(errs) > 0:
        _fail("personnalisation du thème : " + _s.join(" ; ", errs))
    return v

# Valeur d'un chemin « couleurs.primaire » dans des valeurs fusionnées (null si absente).
func get(values, path):
    cur := values
    for part in _s.split(path, "."):
        if type(cur) != "dict" or not (part in cur):
            return null
        cur = cur[part]
    return cur

# Variables CSS des feuilles « color », « size », « font » et « number » : --groupe-nom (« _ » -> « - »).
func css(schema, values):
    lines := []
    _css(schema, values, "", lines)
    return ":root {\n" + _s.join("", lines) + "}\n"

func _css(schema, values, prefix, lines):
    for k in keys(schema):
        node := schema[k]
        name := _s.replace(prefix + k, "_", "-")
        if is_leaf(node):
            if node["type"] in ["color", "size", "font", "number"]:
                append(lines, "  --" + name + ": " + str(values[k]) + ";\n")
        else:
            _css(node, values[k], name + "-", lines)
