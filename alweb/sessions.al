# alweb.sessions — sessions de navigateur : données par visiteur, gardées d'une requête à l'autre, et messages
# flash (affichés une seule fois, après une redirection).
#
#   use alweb.sessions as sessions
#   app.middleware(sessions.middleware(cfg.require("secret_key")))                 # cookie signé (défaut)
#   app.middleware(sessions.middleware(secret, sessions.DatabaseStore(db)))        # données côté serveur
#
#   @app.post("/connexion")
#   async func connexion(req):
#       s := alweb.session(req)
#       s.regenerate()                       # nouvel identifiant à la connexion (fixation de session)
#       s.set("user_id", compte["id"])
#       s.flash("Bienvenue !", "succes")
#       return alweb.redirect("/")
#
# Stockage :
#   CookieStore (défaut)  données JSON dans le cookie, signées (HMAC) et datées : intègres, NON chiffrées (pas de
#                         secret dedans), 4 Ko au plus ; rien à stocker côté serveur, fonctionne avec plusieurs
#                         processus.
#   MemoryStore           côté serveur, dans le processus (développement, un seul processus).
#   DatabaseStore(db)     côté serveur, table alweb_sessions d'une database.async_database (plusieurs processus).
#   Les deux derniers ne mettent dans le cookie qu'un identifiant aléatoire signé.
#
# Le cookie n'est envoyé que si la session a changé (pas de cookie pour un visiteur sans session). Options :
# cookie (nom), max_age (secondes, 14 jours), secure (null : seulement si la requête est en HTTPS), same_site
# ("Lax"), path. Session expirée, signature invalide ou identifiant inconnu : session vide, sans erreur.

from core use len, type, to_int
from collections use append, keys
use time as _time
use json as _json
use asyncio as _aio
use network.security as _sec
use web.http.response as _response

const DEFAULT_MAX_AGE := 1209600
const COOKIE_LIMIT := 4000
const FLASH_KEY := "_flashes"

class Session:
    func init(id=null, data=null, is_new=true):
        self.id = id
        self.data = data if data != null else {}
        self.is_new = is_new
        self.modified = false
        self.old_id = null               # identifiant à supprimer du stockage (regenerate / invalidate)

    func get(key, default=null):
        return self.data[key] if key in self.data else default

    func has(key):
        return key in self.data

    func set(key, value):
        self.data[key] = value
        self.modified = true

    func pop(key, default=null):
        if not (key in self.data):
            return default
        v := self.data[key]
        kept := {}
        for k in keys(self.data):
            if k != key:
                kept[k] = self.data[k]
        self.data = kept
        self.modified = true
        return v

    func clear():
        self.data = {}
        self.modified = true

    func is_empty():
        return len(self.data) == 0

    # Nouvel identifiant, mêmes données (à la connexion : empêche la fixation de session).
    func regenerate():
        if self.id != null and self.old_id == null:
            self.old_id = self.id
        self.id = _sec.random_token(32)
        self.modified = true

    # Déconnexion : données effacées et nouvel identifiant.
    func invalidate():
        self.clear()
        self.regenerate()

    # Message affiché une fois (après une redirection) : category libre (« succes », « erreur »...).
    func flash(message, category="info"):
        lst := self.get(FLASH_KEY, [])
        self.set(FLASH_KEY, lst + [{"message": message, "category": category}])

    # Messages flash en attente (retirés de la session).
    func pop_flashes():
        return self.pop(FLASH_KEY, [])

    # Copie des messages flash sans les retirer.
    func peek_flashes():
        return self.get(FLASH_KEY, [])

# ================================================================ stockages

class CookieStore:
    func init():
        self.server_side = false

class MemoryStore:
    func init():
        self.server_side = true
        self.items = {}                  # id -> [données, expiration]

    func load(id):
        e := self.items[id] if id in self.items else null
        if e == null or e[1] < _time.time():
            return _done(null)
        return _done(_copy(e[0]))

    func save(id, data, max_age):
        self.items[id] = [_copy(data), _time.time() + max_age]
        return _done(null)

    func delete(id):
        if id in self.items:
            kept := {}
            for k in keys(self.items):
                if k != id:
                    kept[k] = self.items[k]
            self.items = kept
        return _done(null)

# Sessions dans une table de database.async_database (créée au premier usage).
class DatabaseStore:
    func init(db, table="alweb_sessions"):
        self.server_side = true
        self.db = db
        self.table = table
        self.ready = false

    async func _init():
        if not self.ready:
            await self.db.script("CREATE TABLE IF NOT EXISTS " + self.table + " (id TEXT PRIMARY KEY, data TEXT NOT NULL, expires DOUBLE PRECISION NOT NULL)")
            self.ready = true

    async func load(id):
        await self._init()
        row := await self.db.query_one("SELECT data, expires FROM " + self.table + " WHERE id = ?", [id])
        if row == null or row["expires"] < _time.time():
            return null
        return _json.parse(row["data"])

    async func save(id, data, max_age):
        await self._init()
        await self.db.transaction([["DELETE FROM " + self.table + " WHERE id = ?", [id]], ["INSERT INTO " + self.table + " (id, data, expires) VALUES (?, ?, ?)", [id, _json.stringify(data), _time.time() + max_age]]])

    async func delete(id):
        await self._init()
        await self.db.execute("DELETE FROM " + self.table + " WHERE id = ?", [id])

    # Supprime les sessions expirées (à lancer de temps en temps).
    async func purge():
        await self._init()
        r := await self.db.execute("DELETE FROM " + self.table + " WHERE expires < ?", [_time.time()])
        return r["rowcount"]

# ================================================================ intergiciel

class Options:
    func init(secret, store, cookie, max_age, secure, same_site, path):
        if secret == null or len(str(secret)) < 16:
            raise("ConfigError", "sessions : clé secrète d'au moins 16 caractères requise (configuration secret_key)")
        self.secret = str(secret)
        self.store = store if store != null else CookieStore()
        self.cookie = cookie
        self.max_age = max_age
        self.secure = secure
        self.same_site = same_site
        self.path = path

func middleware(secret, store=null, cookie="alweb_session", max_age=DEFAULT_MAX_AGE, secure=null, same_site="Lax", path="/"):
    o := Options(secret, store, cookie, max_age, secure, same_site, path)
    return (req, nxt) => _handle(req, nxt, o)

async func _handle(req, nxt, o):
    s := await _load(req, o)
    req.state["session"] = s
    req.state["session_secret"] = o.secret
    r := await nxt(req)
    if s.modified:
        await _save(req, r, s, o)
    return r

async func _load(req, o):
    raw := req.cookie(o.cookie)
    if raw == null or raw == "":
        return Session(null, null, true)
    value := null
    try:
        value = _sec.unsign_value(raw, o.secret, o.max_age, null, "alweb.session")
    catch e:
        return Session(null, null, true)        # signature invalide ou expirée : nouvelle session
    if not o.store.server_side:
        try:
            d := _json.parse(value)
            if type(d) == "dict" and "i" in d and "d" in d:
                return Session(d["i"], d["d"], false)
        catch e:
            ignored := e
        return Session(null, null, true)
    data := await o.store.load(value)
    if data == null:
        return Session(null, null, true)
    return Session(value, data, false)

async func _save(req, r, s, o):
    if s.old_id != null and o.store.server_side:
        await o.store.delete(s.old_id)
    if s.is_empty():
        if not s.is_new:
            if o.store.server_side and s.id != null:
                await o.store.delete(s.id)
            _set_cookie(req, r, o, "", 0)
        return
    if s.id == null:
        s.id = _sec.random_token(32)
    value := s.id
    if not o.store.server_side:
        value = _json.stringify({"i": s.id, "d": s.data})
    else:
        await o.store.save(s.id, s.data, o.max_age)
    token := _sec.sign_value(value, o.secret, null, "alweb.session")
    if len(token) > COOKIE_LIMIT:
        raise("SessionError", "session trop grande pour un cookie (" + str(len(token)) + " octets) : utiliser un stockage côté serveur")
    _set_cookie(req, r, o, token, o.max_age)

func _set_cookie(req, r, o, value, max_age):
    if value == "":
        r.delete_cookie(o.cookie, o.path)
        return
    secure := o.secure
    if secure == null:
        secure = req.secure or ("scheme" in req.state and req.state["scheme"] == "https")
    r.set_cookie(o.cookie, value, max_age, o.path, null, secure, true, o.same_site)

func _copy(d):
    return _json.parse(_json.stringify(d))

func _done(v):
    f := _aio.future()
    _aio.resolve(f, v)
    return f

# Session de la requête (exige l'intergiciel).
func get(req):
    if not ("session" in req.state):
        raise("AlwebError", "session : ajouter l'intergiciel alweb.sessions.middleware(secret)")
    return req.state["session"]
