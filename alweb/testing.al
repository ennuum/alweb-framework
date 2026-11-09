# alweb.testing — client de test en mémoire : appelle l'application sans réseau ni serveur.
#
#   use alweb.testing as at
#   use testing
#   use mon_app
#
#   async func test_accueil():
#       c := at.Client(mon_app.app)
#       r := await c.get("/notes/1")
#       testing.assert_eq(r.status, 200)
#       testing.assert_eq(r.json_value()["id"], 1)
#       r = await c.post("/notes", {"json": {"titre": "Été"}})
#       testing.assert_eq(r.status, 201)
#
# `alexc test` attend tout seul les fonctions `async func test_*`. Les méthodes du client sont async (une route
# peut l'être) : toujours les attendre avec await. Les fonctions de démarrage de l'application sont lancées à la
# première requête (ou par `await c.start()`), celles d'arrêt par `await c.stop()`.
#
# La requête passe par la même chaîne qu'en production (intergiciels, routeur, validation, erreurs) ; seuls le
# réseau et le protocole sont court-circuités. req.state["client_ip"] vaut "127.0.0.1", req.state["scheme"] "http".

from core use len, type
from collections use keys, append
use asyncio as _aio
use string as _s
use json as _json
use web.http.request as _request
use web.http.response as _response
use web.http.headers as _headers
use web.url.form_url_encoding as _form
use web.server.request_dispatch as _rd
use io as _io
use os as _os
use database.connection as _dc
use alweb.alexdb as _axdb

class Client:
    func init(app, base_headers=null):
        self.app = app
        self.base_headers = base_headers if base_headers != null else {}
        self.cookies = {}                # cookies reçus (Set-Cookie), renvoyés aux requêtes suivantes

    async func start():
        await self.app.start()
        return self

    async func stop():
        await self.app.stop()
        return self

    # Requête complète. opts (dictionnaire, toutes les clés facultatives) : json (valeur envoyée en JSON), form
    # (dict en application/x-www-form-urlencoded), body (corps brut), headers (dict), params (dict ajouté à la
    # chaîne de requête).
    async func request(method, path, opts=null):
        o := _check_opts(opts)
        if not self.app.started:
            await self.app.start()
        target := path
        params := _opt(o, "params")
        if params != null and len(params) > 0:
            target = target + ("&" if "?" in target else "?") + _form.encode(params)
        hs := {}
        for k in keys(self.base_headers):
            hs[k] = self.base_headers[k]
        headers := _opt(o, "headers")
        if headers != null:
            for k in keys(headers):
                hs[k] = headers[k]
        data := ""
        if _opt(o, "json") != null:
            data = _json.stringify(o["json"])
            if not _has(hs, "content-type"):
                hs["Content-Type"] = "application/json"
        elif _opt(o, "form") != null:
            data = _form.encode(o["form"])
            if not _has(hs, "content-type"):
                hs["Content-Type"] = "application/x-www-form-urlencoded"
        elif _opt(o, "body") != null:
            data = o["body"]
        if len(self.cookies) > 0 and not _has(hs, "cookie"):
            parts := []
            for k in keys(self.cookies):
                parts = parts + [k + "=" + self.cookies[k]]
            hs["Cookie"] = _join("; ", parts)
        if not _has(hs, "host"):
            hs["Host"] = "testserver"
        req := _request.Request(method, target, hs, data)
        req.remote_address = ("127.0.0.1", 0)
        req.state["client_ip"] = "127.0.0.1"
        req.state["scheme"] = "http"
        r := self.app.handle(req)
        if _aio.is_future(r):
            r = await r
        resp := _rd.to_response(r, req)
        if resp.body_file != null:       # fichier servi : son contenu (ou la plage demandée) devient le corps
            rng := resp.body_range
            resp.body = _s.byte_pack(_io.read_bytes(resp.body_file, rng[0] if rng != null else 0, rng[1] if rng != null else -1))
            resp.body_file = null
            resp.body_range = null
        self._keep_cookies(resp)
        return resp

    async func get(path, opts=null):
        return await self.request("GET", path, opts)

    async func delete(path, opts=null):
        return await self.request("DELETE", path, opts)

    async func head(path, opts=null):
        return await self.request("HEAD", path, opts)

    async func options(path, opts=null):
        return await self.request("OPTIONS", path, opts)

    async func post(path, opts=null):
        return await self.request("POST", path, opts)

    async func put(path, opts=null):
        return await self.request("PUT", path, opts)

    async func patch(path, opts=null):
        return await self.request("PATCH", path, opts)

    func _keep_cookies(resp):
        for line in resp.headers.get_all("set-cookie"):
            try:
                c := _response.parse_set_cookie(line)
                if c == null:
                    continue
                name := c["name"]
                attrs := c["attributes"]
                if c["value"] == "" or ("max-age" in attrs and attrs["max-age"] == "0"):
                    if name in self.cookies:
                        self.cookies = _without(self.cookies, name)
                else:
                    self.cookies[name] = c["value"]
            catch e:
                ignored := e

const OPTIONS := ["json", "form", "body", "headers", "params"]

func _check_opts(opts):
    if opts == null:
        return {}
    if type(opts) != "dict":
        raise("AlwebError", "Client : options attendues sous forme de dictionnaire (json, form, body, headers, params)")
    for k in keys(opts):
        if not (k in OPTIONS):
            raise("AlwebError", "Client : option inconnue « " + str(k) + " »")
    return opts

func _opt(o, k):
    return o[k] if k in o else null

func _has(hs, name):
    for k in keys(hs):
        if _s.lower(k) == name:
            return true
    return false

func _join(sep, parts):
    out := ""
    i := 0
    while i < len(parts):
        if i > 0:
            out = out + sep
        out = out + parts[i]
        i += 1
    return out

func _without(d, name):
    out := {}
    for k in keys(d):
        if k != name:
            out[k] = d[k]
    return out

# Base vide `name` sur le serveur ALEX DB des tests (ALWEB_TEST_ALEXDB : URL d'un super-utilisateur, par exemple
# alexdb://admin:mdp@127.0.0.1:5442/alexdb ; voir tools/test_alexdb.sh) ; null sans cette variable. La base est
# supprimée puis recréée : chaque appel part de zéro.
#   url := at.alexdb_database("monapp_test")      # alexdb://admin:mdp@127.0.0.1:5442/monapp_test, ou null
func alexdb_database(name):
    u := _os.getenv("ALWEB_TEST_ALEXDB")
    if u == null or u == "":
        return null
    adm := _dc.Connection(_axdb.with_database(u, "alexdb"))
    try:
        adm.execute("DROP DATABASE IF EXISTS " + name)
        adm.execute("CREATE DATABASE " + name)
    finally:
        adm.close()
    return _axdb.with_database(u, name)

# ---------------------------------------------------------------- courriels (alweb.mail, url "memory")

# Courriels envoyés par l'application (mail.url = "memory", profil test) : liste d'alweb.mail.Sent (to, subject,
# text, html, raw…), du plus ancien au plus récent. clear : vide la liste après lecture.
#   m := at.outbox(app)[0] ; assert_eq(m.to, ["alice@exemple.org"]) ; lien := at.links(m.text)[0]
func outbox(app, clear=false):
    mb := app.mail()
    if mb.kind != "memory":
        raise("ConfigError", "at.outbox : mail.url doit valoir \"memory\" (obtenu " + mb.describe() + ")")
    out := mb.outbox
    if clear:
        mb.outbox = []
    return out

# Liens http(s) d'un texte (corps d'un courriel), dans l'ordre.
func links(text):
    out := []
    if text == null:
        return out
    i := 0
    n := len(text)
    while i < n:
        j := _s.find(_s.slice(text, i, n), "http")
        if j < 0:
            break
        k := i + j
        rest := _s.slice(text, k, n)
        if _s.starts_with(rest, "http://") or _s.starts_with(rest, "https://"):
            e := k
            while e < n and not (_s.slice(text, e, e + 1) in [" ", "\n", "\r", "\t", "\"", "'", "<", ">", ")"]):
                e += 1
            append(out, _s.slice(text, k, e))
            i = e
        else:
            i = k + 4
    return out

# ---------------------------------------------------------------- tâches de fond (alweb.jobs)

# Exécute les tâches dues de la file de l'application (app.jobs), y compris les courriels de send_later ; rend
# le nombre d'exécutions. La file ne tourne pas seule dans les tests : on la fait avancer ici.
async func run_jobs(app):
    if app.jobs == null:
        return 0
    return await app.jobs.run_pending()
