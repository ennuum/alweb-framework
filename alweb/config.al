# alweb.config — configuration par environnement : fichiers JSON superposés, variables d'environnement,
# conversion de types, validation, secrets masqués.
#
#   config/base.json      réglages communs                  {"debug": false, "database": {"url": "sqlite:app.db"}}
#   config/dev.json       profil de développement           {"debug": true}
#   config/test.json      profil des tests                  {"database": {"url": "memory:"}}
#   config/prod.json      profil de production              {"server": {"workers": 0}}
#   config/local.json     surcharge locale, hors dépôt git  (ignorée en profil test)
#
#   use alweb.config as conf
#   cfg := conf.load("config")                  # profil : variable ALWEB_ENV, sinon "dev"
#   cfg.get("database.url")                     # chemin pointé ; get(chemin, défaut)
#   cfg.require("secret_key")                   # ConfigError si absent ou vide
#   app.configure(cfg)                          # app.config, mode debug repris de « debug »
#
# Ordre de priorité, du plus faible au plus fort : base.json, <profil>.json, local.json, puis les variables
# d'environnement ALWEB_<CHEMIN> où « __ » sépare les niveaux : ALWEB_DATABASE__URL=postgres://... remplace
# database.url, ALWEB_DEBUG=false remplace debug. La valeur est convertie selon le type de la valeur déjà
# présente (bool : true/false/1/0/yes/no/on/off ; int ; float ; list / dict : JSON) ; une clé nouvelle reste
# une chaîne, sauf si elle s'écrit en JSON (nombre, true / false, [..], {..}).
#
# schema (serialization.schema) : validation de l'ensemble, avec conversion et valeurs par défaut ; ConfigError
# qui liste les erreurs sinon. safe_dict() : copie où les valeurs des clés sensibles (secret, password, mot_de_passe,
# token, jeton, key, cle... comme mot de la clé : api_key, db_password, mot_de_passe) sont masquées, pour
# l'affichage ou les journaux.

from core use len, type, to_int, to_float
from collections use keys, append
use os as _os
use io as _io
use json as _json
use string as _s

const PROFILE_VAR_SUFFIX := "_ENV"
# Mots (séparés par « _ » ou « - ») qui rendent une clé sensible : api_key, db_password, mot_de_passe, apiKey...
const SENSITIVE := ["secret", "secrets", "password", "passwords", "passwd", "passe", "token", "tokens", "jeton", "key", "keys", "apikey", "secretkey", "cle", "clé", "credential", "credentials", "private"]

class Config:
    func init(data, profile="dev", sources=null):
        self.data = data
        self.profile = profile
        self.sources = sources if sources != null else []     # fichiers et variables lus, dans l'ordre

    # Valeur à un chemin pointé (« database.url »), ou default si absente.
    func get(path, default=null):
        v := self.data
        for part in _s.split(path, "."):
            if type(v) != "dict" or not (part in v):
                return default
            v = v[part]
        return v

    func has(path):
        return self.get(path, _MISSING) != _MISSING

    # Valeur obligatoire : ConfigError si absente, null ou chaîne vide.
    func require(path):
        v := self.get(path)
        if v == null or v == "":
            raise("ConfigError", "configuration : « " + path + " » est requis (profil " + self.profile + ", sources : " + _join(self.sources) + ")")
        return v

    # Sous-configuration (dict) à un chemin.
    func section(path):
        v := self.get(path, {})
        return Config(v if type(v) == "dict" else {}, self.profile, self.sources)

    func is_dev():
        return self.profile == "dev"

    func is_test():
        return self.profile == "test"

    func is_prod():
        return self.profile == "prod"

    # Copie affichable : valeurs des clés sensibles remplacées par « *** ».
    func safe_dict():
        return _mask(self.data)

_MISSING := "\u0000alweb-absent\u0000"

# Charge la configuration du dossier directory pour un profil (null : variable <PREFIXE>_ENV, sinon "dev").
# env : dict des variables (null : environnement du processus) ; schema : validation facultative.
func load(directory="config", profile=null, prefix="ALWEB", env=null, schema=null):
    vars := env if env != null else _os.env()
    p := profile
    if p == null:
        p = vars[prefix + PROFILE_VAR_SUFFIX] if (prefix + PROFILE_VAR_SUFFIX) in vars and vars[prefix + PROFILE_VAR_SUFFIX] != "" else "dev"
    data := {}
    sources := []
    names := ["base.json", p + ".json"]
    if p != "test":
        names = names + ["local.json"]
    for n in names:
        f := _os.join(directory, n)
        if _os.exists(f):
            loaded := null
            try:
                loaded = _json.parse(_io.read_file(f))
            catch e:
                raise("ConfigError", "configuration : " + f + " n'est pas du JSON valide : " + str(e.message))
            if type(loaded) != "dict":
                raise("ConfigError", "configuration : " + f + " doit contenir un objet JSON")
            data = merge(data, loaded)
            append(sources, f)
    data = _apply_env(data, vars, prefix, sources)
    if schema != null:
        errs := schema.validate(data)
        if len(errs) > 0:
            raise("ConfigError", "configuration invalide (profil " + p + ") : " + _join(errs))
        try:
            data = schema.coerce(data)
        catch e:
            ignored := e
    return Config(data, p, sources)

# Configuration à partir d'un dict (tests, outils).
func from_dict(data, profile="test"):
    return Config(data, profile, ["dict"])

# Fusion profonde : les dict sont fusionnés clé par clé, le reste est remplacé par la valeur de b.
func merge(a, b):
    out := {}
    for k in keys(a):
        out[k] = a[k]
    for k in keys(b):
        if k in out and type(out[k]) == "dict" and type(b[k]) == "dict":
            out[k] = merge(out[k], b[k])
        else:
            out[k] = b[k]
    return out

func _apply_env(data, vars, prefix, sources):
    out := data
    start := prefix + "_"
    profile_var := prefix + PROFILE_VAR_SUFFIX
    for name in keys(vars):
        if name == profile_var or not _s.starts_with(name, start) or len(name) <= len(start):
            continue
        parts := _s.split(_s.lower(name[len(start):len(name)]), "__")
        out = _set_path(out, parts, vars[name])
        append(sources, "$" + name)
    return out

func _set_path(d, parts, raw):
    out := {}
    for k in keys(d):
        out[k] = d[k]
    head := parts[0]
    if len(parts) == 1:
        out[head] = _convert(raw, out[head] if head in out else _MISSING)
        return out
    inner := out[head] if head in out and type(out[head]) == "dict" else {}
    out[head] = _set_path(inner, parts[1:len(parts)], raw)
    return out

# Convertit la chaîne d'une variable d'environnement selon le type de la valeur existante.
func _convert(raw, current):
    t := type(current) if current != _MISSING else null
    if t == "bool":
        v := _s.lower(_s.trim(raw))
        if v in ["true", "1", "yes", "on", "oui", "vrai"]:
            return true
        if v in ["false", "0", "no", "off", "non", "faux", ""]:
            return false
        raise("ConfigError", "configuration : valeur booléenne attendue, obtenu « " + raw + " »")
    if t == "int":
        try:
            return to_int(_s.trim(raw))
        catch e:
            raise("ConfigError", "configuration : entier attendu, obtenu « " + raw + " »")
    if t == "float":
        try:
            return to_float(_s.trim(raw))
        catch e:
            raise("ConfigError", "configuration : nombre attendu, obtenu « " + raw + " »")
    if t == "list" or t == "dict":
        try:
            return _json.parse(raw)
        catch e:
            raise("ConfigError", "configuration : JSON attendu (" + t + "), obtenu « " + raw + " »")
    if t == "str":
        return raw
    # clé nouvelle (ou valeur null) : JSON si la chaîne en est, sinon texte
    trimmed := _s.trim(raw)
    if trimmed == "true" or trimmed == "false" or trimmed == "null" or (len(trimmed) > 0 and (trimmed[0:1] in ["[", "{", "-"] or _is_digit(trimmed[0:1]))):
        try:
            return _json.parse(trimmed)
        catch e:
            return raw
    return raw

func _is_digit(c):
    return c >= "0" and c <= "9"

func _mask(v):
    if type(v) == "dict":
        out := {}
        for k in keys(v):
            out[k] = "***" if _sensitive(k) and v[k] != null and type(v[k]) != "dict" else _mask(v[k])
        return out
    if type(v) == "list":
        return [_mask(x) for x in v]
    return v

func _sensitive(key):
    k := _s.replace(_s.lower(str(key)), "-", "_")
    for word in _s.split(k, "_"):
        if word in SENSITIVE:
            return true
    return false

func _join(items):
    out := ""
    for x in items:
        out = out + (", " if out != "" else "") + str(x)
    return out
