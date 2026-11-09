# alweb.alexdb — ALEX DB (le SGBD écrit en ALEX, projet AlexDB) comme base d'une application alweb.
#
# Le pilote est celui de la bibliothèque standard (database._aqlp) : alweb.database("alexdb://…") donne une base
# attendue avec await comme SQLite ou PostgreSQL, utilisable par l'ORM et ses migrations (dialecte « alexdb »),
# les sessions, les limites de débit et les salons temps réel. Le pilote est écrit en ALEX : il fonctionne dans un
# exécutable natif (`alweb build`), où SQLite n'existe pas.
#
#   use alweb.alexdb as axdb
#   url := "alexdb://admin:mdp@127.0.0.1:5442/blog"
#   await axdb.ensure_database(url)                  # CREATE DATABASE IF NOT EXISTS blog (super-utilisateur)
#   db := alweb.database(url)                        # puis orm.migrate(db, MIGRATIONS)...
#
#   srv := axdb.Server("/chemin/vers/AlexDB")         # serveur jetable : données dans un dossier temporaire
#   url = srv.start("blog")                           # port libre, compte admin ; URL de la base « blog » créée
#   ...
#   srv.stop()                                        # arrêt du processus, dossier supprimé
#
# Base locale (alexdb+local:<dossier>[?base=nom]) : le serveur ALEX DB tourne DANS l'application, ses données dans
# <dossier>. Avec plusieurs processus (app.run_workers), le maître l'héberge et les ouvriers s'y connectent : une
# base partagée sans service à installer, y compris dans l'exécutable natif (qui n'a pas SQLite). Il faut le
# module alweb.alexdb_local (`use alweb.alexdb_local` dans le programme) et le projet AlexDB dans les sources
# (alex.toml : sources = ["…/AlexDB"]). Voir docs/ALEXDB.md.
#
#   db := alweb.database("alexdb+local:donnees")     # base « app » du serveur local
#
# Ce qui change par rapport à SQLite (voir docs/ALEXDB.md) : DDL réservé aux super-utilisateurs (migrations) ;
# une colonne par clé et par index ; pas d'ON CONFLICT ; booléens de l'ORM rangés en INT 0 / 1 ; pas de TLS
# (serveur sur 127.0.0.1, ou derrière un tunnel chiffré).
# Erreurs : ConnectionError (serveur injoignable, authentification), QueryError, IntegrityError, AlwebError.

from core use len, type, to_int
from collections use keys
use json as _json
use asyncio as _aio
use os as _os
use io as _io
use time as _time
use string as _s
use process as _process
use random as _random
use database.connection as _dc
use database._aqlp as _aqlp
use database.async_database as _adb
use alweb.errors as _err

# Vrai pour une URL de serveur ALEX DB.
func is_url(url):
    return type(url) == "str" and _s.starts_with(url, "alexdb://")

# ================================================================ base locale (alexdb+local:)

const LOCAL_PREFIX := "alexdb+local:"
const ENV_LOCAL := "ALWEB_ALEXDB_LOCAL"         # ouvriers : {dossier canonique: URL d'administration} en JSON
const LOCAL_DEFAULT_BASE := "app"

# provider : fabrique LocalServer(dossier) posée par alweb.alexdb_local ; servers : serveurs de ce processus.
_local := {"provider": null, "servers": {}}

func is_local(url):
    return type(url) == "str" and _s.starts_with(url, LOCAL_PREFIX)

# Appelé par alweb.alexdb_local à son import.
func register_local(provider):
    _local["provider"] = provider

func local_available():
    return _local["provider"] != null

# [dossier canonique, base] d'une URL alexdb+local:dossier[?base=nom].
func local_parts(url):
    rest := url[len(LOCAL_PREFIX):len(url)]
    base := LOCAL_DEFAULT_BASE
    q := _s.find(rest, "?")
    if q >= 0:
        for part in _s.split(rest[q + 1:len(rest)], "&"):
            if _s.starts_with(part, "base="):
                base = part[5:len(part)]
        rest = rest[0:q]
    if rest == "":
        _err.alweb_error("alexdb", "alexdb+local : dossier attendu (alexdb+local:donnees)")
    _ident(base)
    if _s.lower(base) == "alexdb":
        _err.alweb_error("alexdb", "alexdb+local : « alexdb » est la base d'administration, choisir un autre nom (?base=…)")
    return [_os.normalize(_os.absolute(rest)), base]

# Serveur local de ce processus pour un dossier (démarré au premier appel).
func local_server(directory):
    if directory in _local["servers"]:
        return _local["servers"][directory]
    if _local["provider"] == null:
        _err.alweb_error("alexdb", "alexdb+local demande le module alweb.alexdb_local : ajouter `use alweb.alexdb_local` au programme, et le projet AlexDB aux sources (alex.toml : sources = [\"…/AlexDB\"])")
    srv := _local["provider"](directory)
    _local["servers"][directory] = srv
    return srv

# URL alexdb:// réelle d'une base locale. Dans un ouvrier : le serveur du maître (variable ALWEB_ALEXDB_LOCAL).
# Sinon : serveur démarré dans ce processus, servi par une tâche de la boucle async (pump).
func resolve_local(url):
    parts := local_parts(url)
    shared := _os.getenv(ENV_LOCAL)
    if shared != null and shared != "":
        m := _json_parse(shared)
        if parts[0] in m:
            return with_database(m[parts[0]], parts[1])
    srv := local_server(parts[0])
    srv.ensure(parts[1])
    if not srv.pumping:
        srv.pumping = true
        _pump(srv)                                   # tâche de fond (pas d'await)
    return with_database(srv.admin_url(), parts[1])

async func _pump(srv):
    while srv.pumping:
        srv.step(0.0)
        await _aio.sleep(0.002)

# Maître de plusieurs processus : démarre le serveur local de l'URL (s'il en est une), crée sa base, et rend
# [services pour web.server.workers, variables d'environnement des ouvriers] ; [[], {}] sinon.
func master_setup(url):
    if not is_local(url):
        return [[], {}]
    parts := local_parts(url)
    srv := local_server(parts[0])
    srv.ensure(parts[1])
    env := {}
    env[ENV_LOCAL] = _json_text({parts[0]: srv.admin_url()})
    return [[srv], env]

# Arrête les serveurs locaux de ce processus (tests).
func stop_local():
    for d in keys(_local["servers"]):
        s := _local["servers"][d]
        s.pumping = false
        try:
            s.shutdown()
        catch e:
            ignored := e
    _local["servers"] = {}

func _json_parse(t):
    return _json.parse(t)

func _json_text(v):
    return _json.stringify(v)

# Composants d'une URL : {host, port, user, password, database, timeout, lock_timeout}.
func parse(url):
    return _aqlp.parse_url(url)

# URL sans mot de passe (journaux).
func redact(url):
    return _aqlp.redact(url)

# URL de la base `name` sur le même serveur, avec les mêmes identifiants et réglages (?lock_timeout=…).
func with_database(url, name):
    p := parse(url)
    host := "[" + p["host"] + "]" if _s.find(p["host"], ":") >= 0 else p["host"]
    q := _s.find(url, "?")
    return "alexdb://" + _pct(p["user"]) + ":" + _pct(p["password"]) + "@" + host + ":" + str(p["port"]) + "/" + _pct(name) + (url[q:len(url)] if q >= 0 else "")

# Crée la base de l'URL si elle n'existe pas (connexion à la base d'administration « alexdb » avec les mêmes
# identifiants, qui doivent être ceux d'un super-utilisateur). Rend le nom de la base.
async func ensure_database(url):
    p := parse(url)
    if _s.lower(p["database"]) == "alexdb":
        return p["database"]
    adm := _adb.open(with_database(url, "alexdb"))
    try:
        await adm.execute("CREATE DATABASE IF NOT EXISTS " + _ident(p["database"]))
        return p["database"]
    finally:
        await adm.close()

# Vérifie qu'un serveur répond (connexion, authentification) ; message d'erreur, ou null.
func check(url):
    try:
        c := _dc.Connection(url)
        c.close()
        return null
    catch e:
        return str(e.message)

func _ident(name):
    for ch in name:
        c := str(ch)
        ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (c >= "0" and c <= "9")
        if not ok:
            _err.alweb_error("alexdb", "nom de base invalide : " + name)
    if len(name) == 0 or len(name) > 63:
        _err.alweb_error("alexdb", "nom de base invalide : " + name)
    return name

func _pct(s):
    out := ""
    for ch in s:
        c := str(ch)
        if c == "%" or c == "@" or c == ":" or c == "/" or c == "?" or c == "&" or c == "#" or c == " ":
            o := _s.ord(c)
            out = out + "%" + _hex2(o)
        else:
            out = out + c
    return out

func _hex2(n):
    d := "0123456789ABCDEF"
    return d[(n >> 4) & 15:((n >> 4) & 15) + 1] + d[n & 15:(n & 15) + 1]

# ================================================================ serveur jetable (tests, développement)

# Un serveur ALEX DB lancé comme processus enfant (`alexc run alexdb.al -- serve`), sur 127.0.0.1 et un port
# libre, avec ses données dans un dossier temporaire (ou `data`). home : dossier du projet AlexDB (celui
# d'alexdb.al) ; null : variable ALWEB_ALEXDB_HOME. alexc : exécutable ALEX (défaut : celui qui tourne).
class Server:
    func init(home=null, data=null, user="admin", password=null, alexc=null):
        h := home if home != null else _os.getenv("ALWEB_ALEXDB_HOME")
        if h == null or not _os.exists(_os.join(h, "alexdb.al")):
            _err.alweb_error("alexdb.Server", "dossier du projet AlexDB introuvable (argument home ou ALWEB_ALEXDB_HOME) : " + str(h))
        self.home = _os.absolute(h)
        self.temporary = data == null
        self.data = data if data != null else _os.join(_os.tmp_dir(), "alweb_alexdb_" + str(_os.pid()) + "_" + str(_random.randint(100000, 999999)))
        self.user = user
        self.password = password if password != null else "t" + str(_random.randint(10000000, 99999999)) + "x" + str(_random.randint(10000000, 99999999))
        self.alexc = alexc if alexc != null else _os.executable()
        self.proc = null
        self.port = 0
        self.log = self.data + ".log"

    func _run(args):
        r := _process.Command(self.alexc).args(["run", "alexdb.al", "--"] + args).cwd(self.home).env({"ALEX_QUIET_RUN": "1"}).stdin("null").run(null, 300.0)
        if not r.ok():
            _err.alweb_error("alexdb.Server", "alexdb " + args[0] + " : " + _s.trim(str(r.stdout) + " " + str(r.stderr)))
        return r

    # Démarre le serveur (initialise le dossier au besoin) ; rend l'URL de la base `database` (créée si besoin),
    # ou celle de la base d'administration.
    func start(database=null, timeout=120.0):
        if self.proc != null:
            return self.url(database)
        if not _os.exists(_os.join(self.data, "alexdb.adb")):
            self._run(["init", "--data", self.data, "--user", self.user, "--password", self.password])
        self.proc = _process.Command(self.alexc).args(["run", "alexdb.al", "--", "serve", "--data", self.data, "--port", "0", "--log", self.log]).cwd(self.home).env({"ALEX_QUIET_RUN": "1"}).stdin("null").stdout("pipe").stderr("pipe").spawn()
        out := ""
        t0 := _time.monotonic()
        while self.port == 0:
            if _time.monotonic() - t0 > timeout:
                self.stop()
                _err.alweb_error("alexdb.Server", "le serveur n'a pas démarré en " + str(timeout) + " s : " + out)
            chunk := self.proc.read("stdout", 4096, 5.0)
            if chunk == null or chunk == "":
                if not self.proc.running():
                    e := self.proc.read_all("stderr")
                    self.proc = null
                    _err.alweb_error("alexdb.Server", "le serveur s'est arrêté au démarrage : " + _s.trim(out + " " + str(e)))
                continue
            out = out + chunk
            k := _s.find(out, "127.0.0.1:")
            if k >= 0:
                digits := ""
                for ch in _s.slice(out, k + 10):
                    o := _s.ord(ch)
                    if o < 48 or o > 57:
                        break
                    digits = digits + str(ch)
                if len(digits) > 0 and _s.find(_s.slice(out, k + 10 + len(digits)), "\n") >= 0:
                    self.port = to_int(digits)
        if database != null:
            self.create_database(database)
        return self.url(database)

    func url(database=null):
        return "alexdb://" + _pct(self.user) + ":" + _pct(self.password) + "@127.0.0.1:" + str(self.port) + "/" + (database if database != null else "alexdb")

    # CREATE DATABASE IF NOT EXISTS (connexion synchrone : utilisable hors de la boucle async).
    func create_database(name):
        c := _dc.Connection(self.url())
        try:
            c.execute("CREATE DATABASE IF NOT EXISTS " + _ident(name))
        finally:
            c.close()
        return self.url(name)

    # Supprime puis recrée une base (tests).
    func reset_database(name):
        c := _dc.Connection(self.url())
        try:
            c.execute("DROP DATABASE IF EXISTS " + _ident(name))
            c.execute("CREATE DATABASE " + _ident(name))
        finally:
            c.close()
        return self.url(name)

    func running():
        return self.proc != null and self.proc.running()

    # Arrête le processus ; supprime le dossier de données s'il était temporaire.
    func stop():
        if self.proc != null:
            try:
                self.proc.stop(3.0)
            catch e:
                ignored := e
            self.proc = null
        self.port = 0
        if self.temporary and _os.exists(self.data):
            try:
                _os.rmdir(self.data, true)
                if _os.exists(self.log):
                    _os.remove(self.log)
            catch e:
                ignored := e
        return null
