# alweb.themes.client — client d'une marketplace de thèmes (protocole : docs/MARKETPLACE_PROTOCOLE.md), utilisé par alweb theme :
# recherche, fiche, téléchargement vérifié (empreinte SHA-256 annoncée, signature de l'éditeur, clé épinglée
# dans alweb.lock à la première installation), installation et mise à jour dans un projet, publication signée.
#
#   c := client.Client("https://themes.exemple.org")            # ALWEB_MARKETPLACE (et ALWEB_MARKETPLACE_TOKEN)
#   c.search("business")                                         # [{slug, name, latest, …}]
#   client.install(registry.Registry("."), c, "modern-business", "^1.0.0")
#   client.updates(registry.Registry("."), c)                    # [{slug, installed, available}]
#   c.publish("dist/modern-business-1.0.0.alwt", signing.load_key("~/.alweb/editeur.json"))
#
# Les appels sont synchrones (commande). transport : fn(méthode, url, corps, en-têtes) -> {status, headers, body}
# pour les tests (les noms d'en-têtes de la réponse en minuscules).

from core use len, type
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use network.http_client as _hc
use network.security as _sec
use web.url.form_url_encoding as _form
use alweb.themes.manifest as _manifest
use alweb.themes.package as _package
use alweb.themes.signing as _signing
use alweb.themes.registry as _registry

const API := "/api/v1"

func _fail(message):
    raise("ThemeError", message)

func _http(method, url, body, headers, timeout):
    r := null
    try:
        r = _hc.request(method, url, null, body, null, headers, null, null, timeout)
    catch e:
        _fail("marketplace injoignable (" + url + ") : " + str(e.message))
    hs := {}
    for k in ["content-type", "x-alweb-sha256", "content-disposition", "x-alweb-review-token", "retry-after"]:
        v := r.headers.get(k)
        if v != null:
            hs[k] = v
    return {"status": r.status, "headers": hs, "body": r.body if r.body != null else ""}

# URL de la marketplace : argument, sinon ALWEB_MARKETPLACE.
func default_url(url=null):
    u := url if url != null and url != "" else _os.getenv("ALWEB_MARKETPLACE")
    if u == null or u == "":
        _fail("aucune marketplace configurée : --registre URL ou variable ALWEB_MARKETPLACE")
    if not (_s.starts_with(u, "https://") or _s.starts_with(u, "http://")):
        _fail("adresse de marketplace invalide : " + u)
    return u[0:len(u) - 1] if _s.ends_with(u, "/") else u

class Client:
    func init(url=null, options=null):
        o := options if options != null else {}
        self.url = default_url(url)
        self.token = o["token"] if "token" in o and o["token"] != null else _os.getenv("ALWEB_MARKETPLACE_TOKEN")
        self.transport = o["transport"] if "transport" in o else null
        self.timeout = o["timeout"] if "timeout" in o else 60.0
        self.last_review_token = null     # reçu d'installation du dernier téléchargement (avis)

    func _call(method, path, body=null, headers=null):
        u := self.url + API + path
        hs := headers if headers != null else {}
        if not ("Accept" in hs):
            hs["Accept"] = "application/json"
        if self.transport != null:
            return self.transport(method, u, body, hs)
        return _http(method, u, body, hs, self.timeout)

    func _decode(r, what):
        d := null
        try:
            d = _json.parse(r["body"])
        catch e:
            _fail(what + " : réponse illisible de la marketplace (statut " + str(r["status"]) + ") : " + str(e.message))
        if r["status"] >= 400:
            msg := d["error"] if type(d) == "dict" and "error" in d else "statut " + str(r["status"])
            if type(d) == "dict" and "errors" in d:
                msg = msg + " : " + _s.join(" ; ", d["errors"])
            _fail(what + " : " + msg)
        return d

    func search(q="", category=null, alweb_version=null, sort=null):
        params := {"q": q}
        if sort != null and sort != "":
            params["sort"] = sort
        if category != null and category != "":
            params["category"] = category
        if alweb_version != null:
            params["alweb"] = alweb_version
        return self._decode(self._call("GET", "/themes?" + _form.encode(params)), "recherche")["items"]

    # Fiche d'un thème, ou null s'il n'existe pas.
    func theme(slug):
        if not _manifest.valid_slug(slug):
            _fail("identifiant de thème invalide : " + str(slug))
        r := self._call("GET", "/themes/" + slug)
        if r["status"] == 404:
            return null
        return self._decode(r, "fiche de « " + slug + " »")

    # Archive d'une version, vérifiée : taille et SHA-256 annoncés par la fiche, signature de l'éditeur avec la
    # clé donnée (celle de la fiche, ou celle épinglée dans le projet). Rend les octets.
    func download(details, version_entry, public_key):
        slug := details["slug"]
        v := version_entry["version"]
        r := self._call("GET", "/themes/" + slug + "/" + v + "/archive", null, {"Accept": "application/vnd.alweb.theme+zip"})
        if r["status"] == 429:
            wait := r["headers"]["retry-after"] if "retry-after" in r["headers"] else "?"
            _fail("téléchargement de " + slug + " " + v + " : trop de téléchargements depuis cette adresse, réessayez dans " + str(wait) + " s")
        if r["status"] != 200:
            _fail("téléchargement de " + slug + " " + v + " : statut " + str(r["status"]))
        data := r["body"]
        if _s.byte_len(data) != version_entry["size"]:
            _fail(slug + " " + v + " : taille reçue " + str(_s.byte_len(data)) + " au lieu de " + str(version_entry["size"]) + " (téléchargement altéré)")
        sha := _package.sha256_hex(data)
        if sha != version_entry["sha256"]:
            _fail(slug + " " + v + " : empreinte SHA-256 différente de celle publiée (archive altérée)")
        if public_key == null or not _signing.verify(public_key, slug, v, sha, version_entry["signature"]):
            _fail(slug + " " + v + " : signature de l'éditeur invalide")
        self.last_review_token = r["headers"]["x-alweb-review-token"] if "x-alweb-review-token" in r["headers"] else null
        return data

    func _post_json(path, value, what):
        return self._decode(self._call("POST", path, _json.stringify(value), {"Content-Type": "application/json"}), what)

    # Avis visibles d'un thème : {items, total, rating, count}.
    func reviews(slug, page=1):
        return self._decode(self._call("GET", "/themes/" + slug + "/reviews?page=" + str(page)), "avis de « " + slug + " »")

    # Donne (ou remplace) l'avis de cette installation ; values : {rating, title, body, author}.
    func review(slug, token, values, version=null):
        d := {"token": token}
        for k in keys(values):
            d[k] = values[k]
        if version != null:
            d["version"] = version
        return self._post_json("/themes/" + slug + "/reviews", d, "avis sur « " + slug + " »")

    func delete_review(slug, token):
        return self._post_json("/themes/" + slug + "/reviews/delete", {"token": token}, "suppression de l'avis")

    func publish(archive_path, key):
        if self.token == null or self.token == "":
            _fail("jeton d'éditeur absent : --jeton ou variable ALWEB_MARKETPLACE_TOKEN")
        data := _io.read_raw(archive_path)
        a := _package.inspect(data)
        m := _manifest.check(_json.parse(_s.byte_pack(a.read(_manifest.FILE))))
        if len(m[1]) > 0:
            _fail("alweb-theme.json : " + _s.join(" ; ", m[1]))
        mf := m[0]
        sig := _signing.sign(key["private"], mf["slug"], mf["version"], _package.sha256_hex(data))
        r := self._call("POST", "/themes", data, {"Authorization": "Bearer " + self.token, "Content-Type": "application/vnd.alweb.theme+zip",
                                                  "X-Alweb-Signature": sig, "X-Alweb-Public-Key": key["public"]})
        return self._decode(r, "publication de " + mf["slug"] + " " + mf["version"])

    func yank(slug, version, undo=false):
        if self.token == null or self.token == "":
            _fail("jeton d'éditeur absent : --jeton ou variable ALWEB_MARKETPLACE_TOKEN")
        return self._decode(self._call("POST", "/themes/" + slug + "/" + version + ("/unyank" if undo else "/yank"), "", {"Authorization": "Bearer " + self.token}), "retrait")

# « modern-business@^1.2.0 » -> ["modern-business", "^1.2.0"] ; sans « @ » : contrainte null.
func parse_spec(spec):
    i := _s.find(spec, "@")
    if i < 0:
        return [spec, null]
    return [spec[0:i], spec[i + 1:len(spec)]]

# Version à installer : la plus récente non retirée, compatible avec cet ALWEB et satisfaisant la contrainte
# (une version exacte retirée reste installable si elle est demandée explicitement).
func choose(details, constraint=null):
    b := null
    for v in details["versions"]:
        exact := constraint != null and constraint == v["version"]
        if v["yanked"] and not exact:
            continue
        try:
            if not _manifest.satisfies(_registry.ALWEB_VERSION, v["framework_version"]):
                continue
            if constraint != null and not _manifest.satisfies(v["version"], constraint):
                continue
        catch e:
            _fail(str(e.message))
        if b == null or _manifest.compare(v["version"], b["version"]) > 0:
            b = v
    return b

# Clé publique à utiliser pour un thème : celle épinglée dans alweb.lock si le thème vient déjà de la
# marketplace (une clé différente annoncée est refusée, sauf accept_new_key), sinon celle de la fiche.
func _key_for(reg, details, accept_new_key):
    pk := details["publisher"]["public_key"]
    if pk == null:
        _fail("« " + details["slug"] + " » : l'éditeur n'a pas de clé publique")
    lock := reg.lock()
    if details["slug"] in lock["themes"]:
        e := lock["themes"][details["slug"]]
        if "publisher_key" in e and e["publisher_key"] != null and e["publisher_key"] != pk and not accept_new_key:
            _fail("« " + details["slug"] + " » : la clé de l'éditeur a changé (épinglée " + _signing.fingerprint(e["publisher_key"]) + ", annoncée " +
                  _signing.fingerprint(pk) + ") ; vérifiez auprès de l'éditeur puis relancez avec --nouvelle-cle")
    return pk

# Télécharge, vérifie et installe ; rend l'entrée du verrou (avec la provenance et la clé épinglée).
func install(reg, client, slug, constraint=null, force=false, accept_new_key=false):
    d := client.theme(slug)
    if d == null:
        _fail("thème « " + slug + " » introuvable sur " + client.url)
    v := choose(d, constraint)
    if v == null:
        _fail("« " + slug + " » : aucune version compatible avec ALWEB " + _registry.ALWEB_VERSION + (" et " + constraint if constraint != null else ""))
    pk := _key_for(reg, d, accept_new_key)
    data := client.download(d, v, pk)
    a := _package.inspect(data)
    m := _manifest.check(_json.parse(_s.byte_pack(a.read(_manifest.FILE))))[0]
    if m["slug"] != slug or m["version"] != v["version"]:
        _fail("archive incohérente : " + str(m["slug"]) + " " + str(m["version"]) + " au lieu de " + slug + " " + v["version"])
    _os.mkdir_all(_os.join(reg.dir, ".telechargements"))
    tmp := _os.join(reg.dir, ".telechargements", slug + "-" + v["version"] + "-" + _sec.random_hex(4) + ".alwt")
    _io.write_file(tmp, data)
    entry := null
    try:
        entry = reg.install(tmp, force)
    catch e:
        _os.remove(tmp)
        raise(e)
    _os.remove(tmp)
    lock := reg.lock()
    e2 := lock["themes"][slug]
    e2["source"] = "marketplace:" + client.url
    e2["publisher"] = d["publisher"]["name"]
    e2["publisher_key"] = pk
    e2["signature"] = v["signature"]
    if client.last_review_token != null:
        e2["review_token"] = client.last_review_token          # reçu d'installation : droit à un avis
    reg.save(lock)
    return e2

# Reçu d'installation d'un thème venu de cette marketplace (pour un avis).
func review_token_for(reg, client, slug):
    lock := reg.lock()
    if not (slug in lock["themes"]):
        _fail("« " + slug + " » n'est pas installé dans ce projet")
    e := lock["themes"][slug]
    if not ("source" in e) or e["source"] != "marketplace:" + client.url:
        _fail("« " + slug + " » n'a pas été installé depuis " + client.url)
    if not ("review_token" in e) or e["review_token"] == null:
        _fail("pas de reçu d'installation pour « " + slug + " » (marketplace sans avis, ou thème installé avant leur ouverture : réinstallez-le avec --force)")
    return [e["review_token"], e["version"]]

# Mises à jour disponibles pour les thèmes venus de cette marketplace : [{slug, installed, available}].
func updates(reg, client, only=null):
    out := []
    lock := reg.lock()
    for slug in keys(lock["themes"]):
        e := lock["themes"][slug]
        if only != null and slug != only:
            continue
        if not ("source" in e) or not _s.starts_with(e["source"], "marketplace:"):
            if only != null:
                _fail("« " + slug + " » n'a pas été installé depuis une marketplace")
            continue
        d := client.theme(slug)
        if d == null:
            continue
        v := choose(d)
        if v != null and _manifest.compare(v["version"], e["version"]) > 0:
            append(out, {"slug": slug, "installed": e["version"], "available": v["version"]})
    return out
