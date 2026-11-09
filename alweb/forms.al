# alweb.forms — formulaires HTML : lecture (urlencoded et multipart), validation avec erreurs par champ pour
# réafficher le formulaire, fichiers téléversés contrôlés.
#
#   ARTICLE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(1, 20000)}, ["titre", "texte"])
#
#   @app.post("/articles")
#   async func creer(req):
#       f := alweb.validate_form(req, ARTICLE)
#       if not f.valid:
#           return alweb.render(req, "article_form.html", {"form": f}, 422)    # f.values, f.errors["titre"]
#       photo := alweb.form(req).file("photo")
#       if photo != null:
#           forms.check_upload(photo, 5000000, ["image/png", "image/jpeg"])     # UploadError -> 400
#           photo.save(os.join(DOSSIER, forms.unique_name(photo)))
#       ...
#
# form(req) : Form (fields, files) mis en cache dans la requête ; un corps qui n'est pas un formulaire donne un
# formulaire vide. Limite de taille du corps multipart : MAX_BODY (modifiable : forms.configure(octets)).
# check_upload vérifie la taille et le TYPE RÉEL d'après les premiers octets (PNG, JPEG, GIF, WebP, PDF), pas
# d'après le nom ou l'en-tête Content-Type envoyés par le client.
#
# Messages d'erreur : rédigés pour le visiteur (« Ce champ est obligatoire. », « Au moins 3 caractères. ») dans la
# langue de la requête si l'application a une alweb.i18n (sinon en français) ; f.codes[champ] donne [code,
# paramètres] (required, too_short {n}, too_long {n}, not_integer, too_small {min}…) et f.details[champ] le
# message technique du schéma. Un message de sch.custom(…, message) est traduit comme une clé du catalogue.

from core use len, type, to_int
from collections use append, keys
use string as _s
use os as _os
use network.http_multipart as _mp
use network.security as _sec
use alweb.i18n as _i18n

_LIMITS := {"max_body": 20000000, "max_parts": 200}

func configure(max_body=null, max_parts=null):
    if max_body != null:
        _LIMITS["max_body"] = max_body
    if max_parts != null:
        _LIMITS["max_parts"] = max_parts

class Form:
    func init(fields, files):
        self.fields = fields             # nom -> liste de valeurs (texte)
        self.files = files               # nom -> liste de network.http_multipart.UploadedFile

    func get(name, default=null):
        return self.fields[name][0] if name in self.fields and len(self.fields[name]) > 0 else default

    func get_list(name):
        return self.fields[name] if name in self.fields else []

    func has(name):
        return name in self.fields

    # Fichier téléversé (premier de ce nom), ou null si absent ou vide (champ fichier laissé vide).
    func file(name):
        if not (name in self.files):
            return null
        for f in self.files[name]:
            if f.filename != null and f.filename != "" and f.size() > 0:
                return f
        return null

    func file_list(name):
        out := []
        for f in (self.files[name] if name in self.files else []):
            if f.filename != null and f.filename != "" and f.size() > 0:
                append(out, f)
        return out

    # Champs à valeur unique sous forme de dict (première valeur de chaque champ).
    func to_dict():
        out := {}
        for k in keys(self.fields):
            out[k] = self.fields[k][0] if len(self.fields[k]) > 0 else ""
        return out

# Formulaire de la requête (analysé une fois).
func form(req):
    if "form" in req.state:
        return req.state["form"]
    f := _parse(req)
    req.state["form"] = f
    return f

func _parse(req):
    ct := req.header("content-type", "")
    low := _s.lower(ct)
    if _s.starts_with(low, "multipart/form-data"):
        if _s.byte_len(req.body) > _LIMITS["max_body"]:
            raise("UploadError", "formulaire trop volumineux (" + str(_s.byte_len(req.body)) + " octets, " + str(_LIMITS["max_body"]) + " au plus)")
        fd := _mp.parse(req.body, ct, _LIMITS["max_body"], _LIMITS["max_parts"])
        fields := {}
        for pair in fd.fields:
            if not (pair[0] in fields):
                fields[pair[0]] = []
            append(fields[pair[0]], pair[1])
        files := {}
        for f in fd.files:
            if not (f.name in files):
                files[f.name] = []
            append(files[f.name], f)
        return Form(fields, files)
    if _s.starts_with(low, "application/x-www-form-urlencoded"):
        fields := {}
        for pair in req.form().pairs():
            if not (pair[0] in fields):
                fields[pair[0]] = []
            append(fields[pair[0]], pair[1])
        return Form(fields, {})
    return Form({}, {})

# ================================================================ validation

class FormResult:
    func init(valid, values, data, errors, codes=null, details=null):
        self.valid = valid
        self.values = values             # valeurs saisies (texte), pour réafficher le formulaire
        self.data = data                 # valeurs validées et converties (si valid)
        self.errors = errors             # champ -> message pour le visiteur ; "" -> erreurs sans champ
        self.codes = codes if codes != null else {}          # champ -> [code, paramètres]
        self.details = details if details != null else {}    # champ -> message technique du schéma

    func error(name):
        return self.errors[name] if name in self.errors else null

# Valide les champs du formulaire avec un schéma serialization.schema. Les champs vides sont considérés absents
# (un champ obligatoire vide est une erreur « requis »).
func validate(req, schema):
    values := form(req).to_dict()
    data := {}
    for k in keys(values):
        v := _s.trim(values[k])
        if v != "" and k != "csrf_token":          # le jeton CSRF ne fait pas partie des données
            data[k] = v
    try:
        data = schema.coerce(data)
    catch e:
        ignored := e
    errs := schema.validate(data)
    errors := {}
    codes := {}
    details := {}
    tr := _i18n.translator_for(req) if len(errs) > 0 else null
    for msg in errs:
        name := _field_of(msg)
        if not (name in errors):
            d := describe(msg)
            codes[name] = [d[1], d[2]]
            details[name] = msg
            errors[name] = message(tr, d[1], d[2])
    return FormResult(len(errs) == 0, values, data if len(errs) == 0 else null, errors, codes, details)

# Message pour le visiteur d'un code d'erreur (traducteur tr d'alweb.i18n, ou null : français).
func message(tr, code, params=null):
    t := tr if tr != null else _i18n.default_translator()
    p := params if params != null else {}
    if code == "custom":
        return t.t(p["message"])
    if "n" in p:
        return t.n("alweb.form." + code, p["n"], p)
    return t.t("alweb.form." + code, p)

# Message d'un schéma (serialization.schema) -> [champ, code, paramètres].
func describe(msg):
    field := _field_of(msg)
    k := _s.find(msg, " : ")
    rest := _s.trim(msg[k + 3:len(msg)]) if k >= 0 else _s.trim(msg)
    if rest == "champ obligatoire absent" or _s.starts_with(rest, "valeur requise"):
        return [field, "required", {}]
    if _s.starts_with(rest, "longueur "):
        if _s.contains(rest, " < "):
            return [field, "too_short", {"n": _last_int(rest, " < ")}]
        return [field, "too_long", {"n": _last_int(rest, " > ")}]
    if _s.starts_with(rest, "ne correspond pas au motif"):
        return [field, "invalid_format", {}]
    if _s.ends_with(rest, " caractères au plus"):                       # messages de l'ORM (alweb.orm)
        return [field, "too_long", {"n": _last_int(" " + _s.split(rest, " ")[0], " ")}]
    if rest in ["entier attendu", "nombre attendu", "booléen attendu", "texte attendu"] or _s.contains(rest, " attendu (obtenu ") or _s.contains(rest, " attendue (obtenu "):
        label := _s.split(rest, " ")[0]
        code := {"entier": "not_integer", "nombre": "not_number", "texte": "not_text", "booléen": "not_boolean"}
        return [field, code[label] if label in code else "invalid", {}]
    if _s.contains(rest, " éléments < "):
        return [field, "too_few", {"n": _last_int(rest, " < ")}]
    if _s.contains(rest, " éléments > "):
        return [field, "too_many", {"n": _last_int(rest, " > ")}]
    if _s.contains(rest, " n'est pas parmi "):
        return [field, "invalid_choice", {}]
    if rest == "champ inattendu":
        return [field, "unexpected", {}]
    if rest == "ne correspond à aucune des formes permises":
        return [field, "invalid", {}]
    if _s.contains(rest, " < "):
        return [field, "too_small", {"min": _after(rest, " < ")}]
    if _s.contains(rest, " > "):
        return [field, "too_large", {"max": _after(rest, " > ")}]
    return [field, "custom", {"message": rest}]

func _after(text, sep):
    parts := _s.split(text, sep)
    return parts[len(parts) - 1]

func _last_int(text, sep):
    try:
        return to_int(_s.trim(_after(text, sep)))
    catch e:
        return 0

# « titre : longueur... » ou « $.titre : ... » -> « titre ».
func _field_of(msg):
    k := _s.find(msg, ":")
    if k <= 0:
        return ""
    name := _s.trim(msg[0:k])
    if _s.starts_with(name, "$."):
        name = name[2:len(name)]
    if _s.starts_with(name, "$"):
        name = name[1:len(name)]
    j := _s.find(name, ".")
    if j > 0:
        name = name[0:j]
    j = _s.find(name, "[")
    if j > 0:
        name = name[0:j]
    return name

# ================================================================ fichiers

# Signatures en octets bruts (un littéral "\x89" serait le caractère U+0089, deux octets en UTF-8).
SIGNATURES := [["image/png", _s.byte_pack([137, 80, 78, 71, 13, 10, 26, 10])], ["image/jpeg", _s.byte_pack([255, 216, 255])], ["image/gif", "GIF87a"], ["image/gif", "GIF89a"], ["application/pdf", "%PDF-"]]

# Type réel d'après les premiers octets, ou null si inconnu.
func sniff(data):
    for s in SIGNATURES:
        n := _s.byte_len(s[1])
        if _s.byte_len(data) >= n and _s.byte_slice(data, 0, n) == s[1]:
            return s[0]
    if _s.byte_len(data) >= 12 and _s.byte_slice(data, 0, 4) == "RIFF" and _s.byte_slice(data, 8, 12) == "WEBP":
        return "image/webp"
    return null

# Vérifie un fichier téléversé : taille maximale (octets) et types réels permis (null : tout type) ; rend le type
# réel. UploadError sinon.
func check_upload(file, max_bytes=null, allowed=null):
    if file == null:
        raise("UploadError", "aucun fichier")
    if max_bytes != null and file.size() > max_bytes:
        raise("UploadError", "fichier trop volumineux (" + str(file.size()) + " octets, " + str(max_bytes) + " au plus)")
    real := sniff(file.data)
    if allowed != null and not (real in allowed):
        raise("UploadError", "type de fichier refusé" + (" (" + real + ")" if real != null else ""))
    return real

# Nom de fichier unique et sûr pour l'enregistrement : aléa + extension déduite du type réel (ou du nom nettoyé).
func unique_name(file):
    real := sniff(file.data)
    ext := ""
    if real == "image/png":
        ext = ".png"
    elif real == "image/jpeg":
        ext = ".jpg"
    elif real == "image/gif":
        ext = ".gif"
    elif real == "image/webp":
        ext = ".webp"
    elif real == "application/pdf":
        ext = ".pdf"
    else:
        safe := file.safe_filename()
        k := _last_dot(safe)
        ext = safe[k:len(safe)] if k > 0 and len(safe) - k <= 8 else ""
    return _sec.random_hex(16) + ext

func _last_dot(s):
    i := len(s) - 1
    while i >= 0:
        if s[i:i + 1] == ".":
            return i
        i -= 1
    return -1
