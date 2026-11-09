# alweb.ratelimit — limitation de débit par fenêtre glissante, en mémoire ou partagée entre processus par la base.
#
#   use alweb.ratelimit as rl
#   app.middleware(rl.limit(100, 60))                          # 100 requêtes par minute et par adresse IP
#   app.post("/connexion", connexion, {"middleware": rl.limit(5, 60, scope="connexion")})
#
#   store := rl.DatabaseStore(alweb.database("postgres://..."))   # partagé par tous les ouvriers et serveurs
#   api := app.group("/api", [rl.limit(1000, 3600, rl.by_header("Authorization"), store)])
#
# Algorithme : compteur de la fenêtre courante + part du compteur de la précédente (fenêtre glissante approchée,
# sans rafale double au changement de fenêtre). Réponses : en-têtes RateLimit-Limit, RateLimit-Remaining,
# RateLimit-Reset et RateLimit-Policy ; au-delà, 429 avec Retry-After (JSON ou HTML selon Accept).
#
# DatabaseStore : SQLite sur fichier (>= 3.24) ou PostgreSQL ; une table alweb_rate (clé, fenêtre, compte).
# Si la base ne répond pas, la requête passe (fail_open, par défaut) ou reçoit 503 (fail_open=false).

from core use len, type, to_int
from collections use keys, append, remove
use asyncio as _aio
use time as _time
use string as _s
use math as _math
use web.server.request_dispatch as _rd
use alweb.errors as _err
use alweb.orm as _orm

# ---------------------------------------------------------------- clés

# Adresse IP du client (celle donnée par le serveur, en tenant compte de trusted_proxies).
func by_ip():
    return (req) => req.state["client_ip"] if "client_ip" in req.state else null

# Valeur d'un en-tête (jeton d'API...) ; sans l'en-tête, repli sur l'adresse IP.
func by_header(name):
    return (req) => _header_or_ip(req, name)

func _header_or_ip(req, name):
    v := req.headers.get(name)
    if v != null and v != "":
        return "h:" + v
    return req.state["client_ip"] if "client_ip" in req.state else null

# ---------------------------------------------------------------- stockages

# Compteurs dans la mémoire du processus (un seul processus, ou une limite par ouvrier).
class MemoryStore:
    func init(max_keys=100000):
        self.counts = {}                 # clé -> {fenêtre: compte}
        self.max_keys = max_keys

    # Incrémente le compteur de (clé, fenêtre) ; rend [compte courant, compte de la fenêtre précédente].
    async func hit(key, window):
        if not (key in self.counts):
            if len(keys(self.counts)) >= self.max_keys:
                self._evict(window)
            self.counts[key] = {}
        c := self.counts[key]
        cur := (c[window] if window in c else 0) + 1
        prev := c[window - 1] if (window - 1) in c else 0
        self.counts[key] = {window: cur, window - 1: prev} if prev > 0 else {window: cur}
        return [cur, prev]

    func _evict(window):
        kept := {}
        for k in keys(self.counts):
            c := self.counts[k]
            if window in c or (window - 1) in c:
                kept[k] = c
        self.counts = kept

# Compteurs dans une table partagée : la même limite vaut pour tous les processus qui utilisent la base.
class DatabaseStore:
    # db : base, ou fonction sans argument qui la rend (base ouverte au démarrage : () => app.value("db")).
    func init(db, table="alweb_rate"):
        self.db = db
        self.table = table
        self.ready = false
        self.hits = 0

    async func setup():
        if self.ready:
            return
        if type(self.db) == "function":
            self.db = self.db()
        self.alexdb = _orm.dialect(self.db) == "alexdb"
        if self.alexdb:
            # AQL : ni clé composite ni ON CONFLICT ; clé « fenêtre|clé », incrément en une transaction d'un bloc
            await self.db.execute("CREATE TABLE IF NOT EXISTS " + self.table + " (id TEXT PRIMARY KEY, k TEXT NOT NULL, win BIGINT NOT NULL, n INTEGER NOT NULL)", [])
            await self.db.execute("CREATE INDEX IF NOT EXISTS " + self.table + "_k ON " + self.table + " (k)", [])
        else:
            await self.db.execute("CREATE TABLE IF NOT EXISTS " + self.table + " (k TEXT NOT NULL, win BIGINT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (k, win))", [])
        self.ready = true

    async func hit(key, window):
        await self.setup()
        if self.alexdb:
            id := str(window) + "|" + key
            await self.db.transaction([["INSERT INTO " + self.table + " (id, k, win, n) SELECT ?, ?, ?, 0 WHERE NOT EXISTS (SELECT 1 FROM " + self.table + " WHERE id = ?)", [id, key, window, id]],
                                       ["UPDATE " + self.table + " SET n = n + 1 WHERE id = ?", [id]]])
        else:
            await self.db.execute("INSERT INTO " + self.table + " (k, win, n) VALUES (?, ?, 1) ON CONFLICT (k, win) DO UPDATE SET n = " + self.table + ".n + 1", [key, window])
        rows := await self.db.query("SELECT win, n FROM " + self.table + " WHERE k = ? AND win >= ?", [key, window - 1])
        cur := 0
        prev := 0
        for r in rows:
            if to_int(r["win"]) == window:
                cur = to_int(r["n"])
            elif to_int(r["win"]) == window - 1:
                prev = to_int(r["n"])
        self.hits += 1
        if self.hits % 500 == 0:
            await self.db.execute("DELETE FROM " + self.table + " WHERE win < ?", [window - 1])
        return [cur, prev]

# ---------------------------------------------------------------- intergiciel

# rate requêtes par période de per secondes et par clé. key : fn(req) -> clé (by_ip() par défaut ; null : la
# requête n'est pas limitée) ; store : MemoryStore (défaut) ou DatabaseStore ; scope : nom qui sépare les
# compteurs de deux limites distinctes ; exempt : fn(req) -> vrai pour ne pas compter (contrôles de santé...).
func limit(rate, per=60, key=null, store=null, scope=null, fail_open=true, exempt=null, clock=null):
    if rate < 1 or per <= 0:
        _err.alweb_error("ratelimit.limit", "rate >= 1 et per > 0 attendus")
    cfg := {"rate": rate, "per": per * 1.0, "key": key if key != null else by_ip(), "store": store if store != null else MemoryStore(), "scope": scope if scope != null else (str(rate) + "/" + str(per)), "fail_open": fail_open, "exempt": exempt, "clock": clock if clock != null else _time.time, "denied": 0}
    return (req, nxt) => _limit(req, nxt, cfg)

async func _limit(req, nxt, cfg):
    if cfg["exempt"] != null and cfg["exempt"](req):
        return await nxt(req)
    k := cfg["key"](req)
    if _aio.is_future(k):
        k = await k
    if k == null:
        return await nxt(req)
    per := cfg["per"]
    now := cfg["clock"]()
    window := to_int(_math.floor(now / per))
    counts := null
    try:
        counts = await cfg["store"].hit(cfg["scope"] + ":" + str(k), window)
    catch e:
        if cfg["fail_open"]:
            return await nxt(req)
        return _rd.error_response(req, 503, "limitation de débit indisponible")
    into := (now - window * per) / per
    used := counts[1] * (1.0 - into) + counts[0]
    rate := cfg["rate"]
    reset := to_int(_math.ceil(per - (now - window * per)))
    if reset < 1:
        reset = 1
    remaining := to_int(_math.floor(rate - used))
    if remaining < 0:
        remaining = 0
    req.state["rate_limit"] = {"limit": rate, "remaining": remaining, "reset": reset}
    if used > rate:
        cfg["denied"] = cfg["denied"] + 1
        r := _rd.error_response(req, 429, "trop de requêtes : réessayez dans " + str(reset) + " s")
        r.headers.set("Retry-After", str(reset))
        _headers(r, rate, 0, reset, per)
        return r
    r := await nxt(req)
    _headers(r, rate, remaining, reset, per)
    return r

func _headers(r, rate, remaining, reset, per):
    r.headers.set("RateLimit-Limit", str(rate))
    r.headers.set("RateLimit-Remaining", str(remaining))
    r.headers.set("RateLimit-Reset", str(reset))
    r.headers.set("RateLimit-Policy", str(rate) + ";w=" + str(to_int(per)))
