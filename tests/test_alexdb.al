# ALEX DB comme base d'alweb (phase 7) : pilote alexdb:// (database._aqlp) contre un vrai serveur ALEX DB,
# identifiants attribués par le serveur, erreurs typées, transactions d'un bloc, ORM et migrations dans le dialecte
# « alexdb », sessions, limites de débit et salons partagés par la base, application complète (le blog).
#
# Serveur : ALWEB_TEST_ALEXDB=alexdb://admin:mdp@127.0.0.1:5442/alexdb (super-utilisateur, base d'administration)
# pour un serveur déjà lancé ; sinon ALWEB_ALEXDB_HOME=/chemin/vers/AlexDB : un serveur jetable est lancé pour ce
# fichier (port libre, dossier temporaire) et arrêté par le dernier test. Sans l'une ni l'autre, les tests qui
# demandent un serveur rendent la main aussitôt (comme ceux de PostgreSQL sans ALWEB_TEST_POSTGRES).
use os
use asyncio as aio
use alweb
use alweb.orm as orm
use alweb.alexdb as axdb
use alweb.sessions as sessions
use alweb.ratelimit as rl
use alweb.realtime as rt
use alweb.testing as at
use database.async_database as adb
use database.connection as dc
from testing use assert_eq, assert_true, assert_null, assert_contains

SRV := [null, null]          # [axdb.Server ou null, URL d'administration]

func admin_url():
    if SRV[1] != null:
        return SRV[1]
    u := os.getenv("ALWEB_TEST_ALEXDB")
    if u != null:
        SRV[1] = u
        return u
    if os.getenv("ALWEB_ALEXDB_HOME") == null:
        return null
    s := axdb.Server()
    SRV[1] = s.start()
    SRV[0] = s
    return SRV[1]

# Base vide `name` sur le serveur de test ; null sans serveur.
func fresh(name):
    if admin_url() == null:
        return null
    adm := dc.Connection(admin_url())
    try:
        adm.execute("DROP DATABASE IF EXISTS " + name)
        adm.execute("CREATE DATABASE " + name)
    finally:
        adm.close()
    return axdb.with_database(admin_url(), name)

# ---------------------------------------------------------------- pilote

func test_url():
    p := axdb.parse("alexdb://app:m%40p@db.local:6000/ventes?lock_timeout=2")
    assert_eq(p["user"], "app")
    assert_eq(p["password"], "m@p")
    assert_eq(p["host"], "db.local")
    assert_eq(p["port"], 6000)
    assert_eq(p["database"], "ventes")
    assert_eq(p["lock_timeout"], 2.0)
    assert_eq(axdb.parse("alexdb://u@h")["port"], 5442)
    assert_eq(axdb.redact("alexdb://app:secret@h:1/b"), "alexdb://app@h:1/b")
    assert_eq(axdb.with_database("alexdb://a:b@h:1/x", "y"), "alexdb://a:b@h:1/y")
    assert_eq(axdb.with_database("alexdb://a:p%40ss@[::1]:1/x?lock_timeout=2", "y"), "alexdb://a:p%40ss@[::1]:1/y?lock_timeout=2")
    assert_true(axdb.is_url("alexdb://h/b") and not axdb.is_url("sqlite:x.db"))
    assert_eq(orm.dialect("alexdb://a@h/b"), "alexdb")
    assert_eq(orm.dialect("alexdb:notes.json"), "sqlite")           # moteur embarqué de la bibliothèque

func test_create_sql():
    t := orm.table("t", {"id": orm.pk(), "nom": orm.text(40, unique=true), "actif": orm.boolean(default=true), "vu": orm.timestamp(auto=true), "parent_id": orm.ref("t", true)})
    assert_eq(t.create_sql("alexdb"), "CREATE TABLE IF NOT EXISTS t (id INT PRIMARY KEY, nom VARCHAR(40) NOT NULL UNIQUE, actif INT NOT NULL DEFAULT 1, vu FLOAT, parent_id INT, FOREIGN KEY (parent_id) REFERENCES t (id))")

func test_connexion_et_identifiants():
    u := fresh("alweb_pilote")
    if u == null:
        return
    c := dc.Connection(u)
    assert_eq(c.backend, "alexdb-server")
    c.execute("CREATE TABLE notes (id INT PRIMARY KEY, titre TEXT NOT NULL, note FLOAT)")
    a := c.insert("notes", {"titre": "un"})
    b := c.insert("notes", {"titre": "deux", "note": 2})
    assert_eq([a, b], [1, 2])
    c.execute("DELETE FROM notes WHERE id = ?", [2])
    assert_eq(c.insert("notes", {"titre": "trois"}), 3)            # jamais réattribué
    assert_eq(c.insert("notes", {"id": 10, "titre": "dix"}), 10)
    assert_eq(c.insert("notes", {"titre": "onze"}), 11)
    assert_eq(c.scalar("SELECT COUNT(*) FROM notes"), 4)
    assert_eq(c.query("SELECT titre FROM notes WHERE id = :i", {"i": 3}), [{"titre": "trois"}])
    assert_true("notes" in c.tables())
    cols := c.columns("notes")
    assert_eq(cols[0]["name"], "id")
    assert_true(cols[0]["primary"])
    assert_true(cols[1]["not_null"])
    c.close()

func test_erreurs_typees():
    u := fresh("alweb_erreurs")
    if u == null:
        return
    c := dc.Connection(u)
    c.execute("CREATE TABLE u (id INT PRIMARY KEY, nom TEXT NOT NULL UNIQUE)")
    c.insert("u", {"nom": "a"})
    try:
        c.insert("u", {"nom": "a"})
        assert_true(false, "IntegrityError attendue")
    catch e:
        assert_eq(e.type, "IntegrityError")
        assert_contains(e.message, "ConstraintError")
    try:
        c.execute("SELEC 1")
        assert_true(false, "QueryError attendue")
    catch e:
        assert_eq(e.type, "QueryError")
        assert_contains(e.message, "SyntaxError")
    try:
        dc.Connection(axdb.with_database(admin_url(), "alweb_erreurs") + "x")
        assert_true(false, "ConnectionError attendue")
    catch e:
        assert_eq(e.type, "ConnectionError")
    c.close()

func test_transactions():
    url := fresh("alweb_tx")
    if url == null:
        return
    c := dc.Connection(url)
    c.execute("CREATE TABLE k (id INT PRIMARY KEY, v INT NOT NULL)")
    c.begin()
    assert_true(c.in_transaction())
    c.insert("k", {"v": 1})
    c.rollback()
    assert_eq(c.scalar("SELECT COUNT(*) FROM k"), 0)
    # pendant la transaction d'une autre connexion, l'écriture attend (LockError réessayé) puis passe
    d := dc.Connection(url)
    c.begin()
    c.insert("k", {"v": 2})
    try:
        dc.Connection(url + "?lock_timeout=0.2").insert("k", {"v": 3})
        assert_true(false, "verrou attendu")
    catch e:
        assert_contains(e.message, "LockError")
    c.commit()
    assert_eq(d.insert("k", {"v": 4}), 2)
    # bloc : tout ou rien, en une requête
    r := c.batch([["INSERT INTO k (v) VALUES (?)", [5]], ["UPDATE k SET v = v + ? WHERE v = ?", [10, 5]]])
    assert_eq(r[0]["lastrowid"], 3)
    assert_eq(r[1]["rowcount"], 1)
    try:
        c.batch([["INSERT INTO k (v) VALUES (?)", [6]], ["INSERT INTO k (v) VALUES (?)", [null]]])
        assert_true(false, "erreur attendue")
    catch e:
        assert_eq(e.type, "IntegrityError")
    assert_eq(c.scalar("SELECT COUNT(*) FROM k"), 3)              # la première insertion du bloc est annulée
    assert_true(not c.in_transaction())
    c.close()
    d.close()

async func test_base_async():
    u := fresh("alweb_async")
    if u == null:
        return
    neuve := axdb.with_database(u, "alweb_neuve")
    adm := dc.Connection(admin_url())
    adm.execute("DROP DATABASE IF EXISTS alweb_neuve")
    adm.close()
    assert_true(axdb.check(neuve) != null)                         # base absente : refusée
    assert_eq(await axdb.ensure_database(neuve), "alweb_neuve")
    assert_eq(await axdb.ensure_database(neuve), "alweb_neuve")    # déjà là : rien à faire
    assert_null(axdb.check(neuve))
    db := alweb.database(u)
    await db.script("CREATE TABLE n (id INT PRIMARY KEY, t TEXT)")
    id := await db.insert("n", {"t": "été"})
    assert_eq(id, 1)
    assert_eq(await db.query_one("SELECT t FROM n WHERE id = ?", [id]), {"t": "été"})
    r := await db.transaction([["INSERT INTO n (t) VALUES (?)", ["a"]], ["INSERT INTO n (t) VALUES (?)", ["b"]]])
    assert_eq(r[1]["lastrowid"], 3)
    assert_eq(await db.scalar("SELECT COUNT(*) FROM n"), 3)
    await db.close()

# ---------------------------------------------------------------- ORM et migrations

COMPTES := orm.table("comptes", {"id": orm.pk(), "nom": orm.text(40, unique=true), "admin": orm.boolean(), "cree_le": orm.timestamp(auto=true)})
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(100), "publie": orm.boolean(default=false), "auteur_id": orm.ref("comptes"), "tags": orm.json(default=[]), "note": orm.real(null_ok=true)})
MIGRATIONS := [orm.migration(1, "tables", [COMPTES, ARTICLES]), orm.migration(2, "index", "CREATE INDEX articles_publie ON articles (publie)")]

async func test_orm():
    u := fresh("alweb_orm")
    if u == null:
        return
    db := alweb.database(u)
    assert_eq(await orm.migrate(db, MIGRATIONS), [1, 2])
    assert_eq(await orm.migrate(db, MIGRATIONS), [])
    try:
        await orm.migrate(db, MIGRATIONS + [orm.migration(3, "cassée", ["CREATE TABLE t3 (x INT)", "SYNTAXE"])])
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "migration 3")
    assert_eq(await orm.applied(db), [1, 2])                       # DDL transactionnel : t3 n'existe pas
    assert_true(not ("t3" in await db.tables()))
    a := await COMPTES.insert(db, {"nom": "awa", "admin": true})
    b := await COMPTES.insert(db, {"nom": "ben", "admin": false})
    for i in 0..5:
        await ARTICLES.insert(db, {"titre": "A" + str(i), "auteur_id": a if i % 2 == 0 else b, "publie": i > 1, "tags": ["t" + str(i)], "note": i * 1.5})
    c := await COMPTES.get(db, a)
    assert_eq(c["admin"], true)
    assert_true(c["cree_le"] > 1700000000.0)
    publies := await ARTICLES.where("publie", true).order_by("-id").with_one(COMPTES, "auteur_id", "auteur").all(db)
    assert_eq([x["titre"] for x in publies], ["A4", "A3", "A2"])
    assert_eq(publies[1]["auteur"]["nom"], "ben")
    assert_eq(publies[0]["tags"], ["t4"])
    avec := await COMPTES.query().order_by("id").with_many(ARTICLES, "auteur_id", "articles", "id").all(db)
    assert_eq(len(avec[0]["articles"]), 3)
    assert_eq(await ARTICLES.where("titre", "like", "A%").count(db), 5)
    assert_eq(await ARTICLES.where("id", "in", [1, 2, 99]).count(db), 2)
    assert_eq(await ARTICLES.where("auteur_id", b).update(db, {"publie": false}), 2)
    page := await ARTICLES.query().order_by("id").paginate(db, 2, 2)
    assert_eq([x["titre"] for x in page["items"]], ["A2", "A3"])
    assert_eq(page["pages"], 3)
    try:
        await ARTICLES.insert(db, {"titre": "orphelin", "auteur_id": 99})
        assert_true(false, "clé étrangère attendue")
    catch e:
        assert_eq(e.type, "IntegrityError")
    assert_eq(await ARTICLES.where("id", 5).delete(db), 1)
    assert_eq(await ARTICLES.insert(db, {"titre": "A5", "auteur_id": a}), 6)
    await db.close()

# ---------------------------------------------------------------- sessions, limites, salons

func incrementer(req):
    s := alweb.session(req)
    n := s.get("n")
    s.set("n", (n if n != null else 0) + 1)
    return {"ok": true}

async func test_sessions_en_base():
    u := fresh("alweb_sessions")
    if u == null:
        return
    db := alweb.database(u)
    store := sessions.DatabaseStore(db)
    app := alweb.App("s")
    app.middleware(sessions.middleware("0123456789abcdef0123456789abcdef", store))
    app.post("/n", incrementer)
    app.get("/n", (req) => {"n": alweb.session(req).get("n")})
    c := at.Client(app)
    await c.post("/n")
    await c.post("/n")
    assert_eq((await c.get("/n")).json_value()["n"], 2)
    assert_eq(await db.scalar("SELECT COUNT(*) FROM alweb_sessions"), 1)
    await db.close()

HORLOGE := [5000.0]

func horloge():
    return HORLOGE[0]

func appli(store):
    app := alweb.App("rl")
    app.middleware(rl.limit(2, 10, null, store, "t", true, null, horloge))
    app.get("/", (req) => "ok")
    return app

async func test_limites_partagees():
    url := fresh("alweb_rate")
    if url == null:
        return
    c1 := at.Client(appli(rl.DatabaseStore(alweb.database(url))))
    c2 := at.Client(appli(rl.DatabaseStore(alweb.database(url))))          # deux processus, une limite
    assert_eq((await c1.get("/")).status, 200)
    assert_eq((await c2.get("/")).status, 200)
    assert_eq((await c1.get("/")).status, 429)
    assert_eq((await c2.get("/")).status, 429)
    HORLOGE[0] = 5030.0
    assert_eq((await c2.get("/")).status, 200)

async func test_salons_par_la_base():
    url := fresh("alweb_rooms")
    if url == null:
        return
    h1 := rt.Hub(rt.DatabaseBroker(alweb.database(url), 0.02))
    h2 := rt.Hub(rt.DatabaseBroker(alweb.database(url), 0.02))
    await h1.start()
    await h2.start()
    e1 := await h1.publish("r", "message", "bonjour")
    e2 := await h2.publish("r", "message", "salut")
    assert_true(e2 > e1)
    await aio.sleep(0.3)
    h := await h1.history("r", 0)
    assert_eq([x["data"] for x in h], ["bonjour", "salut"])
    await h1.stop()
    await h2.stop()

async func test_zz_arret_du_serveur():
    if SRV[0] != null:
        SRV[0].stop()
        assert_true(not SRV[0].running())
        SRV[0] = null
