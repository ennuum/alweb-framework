# ORM : déclaration, CREATE TABLE, migrations, insertion validée, requêtes composées, conversions, relations
# sans N+1, mise à jour, suppression, pagination, protections (colonnes inconnues, injection).
use os
use alweb
use alweb.orm as orm
use database.async_database as adb
use database.database as dbm
use alweb.testing as at
from testing use assert_eq, assert_true, assert_null, assert_contains

COMPTES := orm.table("comptes", {"id": orm.pk(), "nom": orm.text(40, unique=true), "admin": orm.boolean(), "cree_le": orm.timestamp(auto=true)})
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(100), "texte": orm.text(null_ok=true), "publie": orm.boolean(default=false), "auteur_id": orm.ref("comptes"), "tags": orm.json(default=[]), "note": orm.real(null_ok=true)})
COMMENTAIRES := orm.table("commentaires", {"id": orm.pk(), "article_id": orm.ref("articles"), "texte": orm.text(500)})

MIGRATIONS := [orm.migration(1, "tables", [COMPTES, ARTICLES, COMMENTAIRES]), orm.migration(2, "index", "CREATE INDEX articles_auteur ON articles (auteur_id)")]

# ALWEB_TEST_POSTGRES=postgres://... : mêmes tests sur PostgreSQL (tables recréées) ; ALWEB_TEST_ALEXDB=alexdb://...
# sur ALEX DB (base alweb_orm recréée) ; sinon SQLite en mémoire.
async func base():
    ax := at.alexdb_database("alweb_orm")
    pg := os.getenv("ALWEB_TEST_POSTGRES") if ax == null else null
    db := adb.open(ax if ax != null else (pg if pg != null else ("sqlite::memory:" if "sqlite" in dbm.backends() else "memory:")))
    if pg != null:
        await db.script("DROP TABLE IF EXISTS commentaires, articles, comptes, t4, alweb_migrations CASCADE")
    await orm.migrate(db, MIGRATIONS)
    return db

func test_create_sql():
    assert_eq(COMPTES.create_sql(), "CREATE TABLE IF NOT EXISTS comptes (id INTEGER PRIMARY KEY AUTOINCREMENT, nom TEXT NOT NULL UNIQUE, admin INTEGER NOT NULL DEFAULT 0, cree_le REAL)")
    assert_contains(ARTICLES.create_sql("postgres"), "id BIGSERIAL PRIMARY KEY, titre VARCHAR(100) NOT NULL")
    assert_contains(ARTICLES.create_sql("postgres"), "publie BOOLEAN NOT NULL DEFAULT FALSE")
    assert_contains(ARTICLES.create_sql(), "FOREIGN KEY (auteur_id) REFERENCES comptes (id)")
    ix := orm.index("m_salon", "messages", ["salon_id", "id"])
    assert_eq(ix.create_sql(), "CREATE INDEX IF NOT EXISTS m_salon ON messages (salon_id, id)")
    assert_eq(ix.create_sql("alexdb"), "CREATE INDEX IF NOT EXISTS m_salon ON messages (salon_id)")
    assert_eq(orm.index("u", "t", "c", true).create_sql("postgres"), "CREATE UNIQUE INDEX IF NOT EXISTS u ON t (c)")

async func test_migrations_idempotentes():
    db := await base()
    assert_eq(await orm.applied(db), [1, 2])
    assert_eq(await orm.migrate(db, MIGRATIONS), [])
    nouvelles := MIGRATIONS + [orm.migration(3, "colonne", "ALTER TABLE comptes ADD COLUMN bio TEXT")]
    assert_eq(await orm.migrate(db, nouvelles), [3])
    try:
        await orm.migrate(db, nouvelles + [orm.migration(4, "cassée", ["CREATE TABLE t4 (x INTEGER)", "SYNTAXE INVALIDE"])])
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "migration 4")
    assert_eq(await orm.applied(db), [1, 2, 3])                 # la migration ratée n'est pas enregistrée
    await db.close()

async func test_insertion_et_conversions():
    db := await base()
    a := await COMPTES.insert(db, {"nom": "awa", "admin": true})
    c := await COMPTES.get(db, a)
    assert_eq(c["nom"], "awa")
    assert_eq(c["admin"], true)
    assert_true(c["cree_le"] > 1700000000.0)
    id := await ARTICLES.insert(db, {"titre": "Été", "auteur_id": a, "tags": ["voyage", "mer"]})
    art := await ARTICLES.get(db, id)
    assert_eq(art["tags"], ["voyage", "mer"])
    assert_eq(art["publie"], false)
    assert_null(art["texte"])
    assert_null(await ARTICLES.get(db, 999))
    await db.close()

async func test_validation():
    db := await base()
    for cas in [[{"auteur_id": 1}, "titre : valeur requise"], [{"titre": "x" * 101, "auteur_id": 1}, "100 caractères"], [{"titre": "ok", "auteur_id": "un"}, "entier attendu"], [{"titre": "ok", "auteur_id": 1, "publie": "oui"}, "booléen attendu"]]:
        try:
            await ARTICLES.insert(db, cas[0])
            assert_true(false, "erreur attendue : " + cas[1])
        catch e:
            assert_eq(e.type, "ValidationError")
            assert_contains(e.message, cas[1])
    try:
        await ARTICLES.insert(db, {"titre": "ok", "auteur_id": 1, "pirate": 1})
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "colonne inconnue")
    await db.close()

async func peupler(db):
    a := await COMPTES.insert(db, {"nom": "awa"})
    k := await COMPTES.insert(db, {"nom": "kofi"})
    i := 1
    while i <= 25:
        await ARTICLES.insert(db, {"titre": "Article " + str(i), "auteur_id": a if i % 2 == 1 else k, "publie": i % 3 != 0, "note": i * 0.5})
        i += 1
    for t in ["bravo", "merci"]:
        await COMMENTAIRES.insert(db, {"article_id": 1, "texte": t})
    await COMMENTAIRES.insert(db, {"article_id": 2, "texte": "bof"})
    return [a, k]

async func test_requetes():
    db := await base()
    ids := await peupler(db)
    assert_eq(await ARTICLES.where("publie", true).count(db), 17)
    lst := await ARTICLES.where("publie", true).where("note", ">=", 10.0).order_by("-note").limit(3).all(db)
    assert_eq([x["titre"] for x in lst], ["Article 25", "Article 23", "Article 22"])
    assert_eq(len(await ARTICLES.where("id", "in", [1, 2, 99]).all(db)), 2)
    assert_eq(await ARTICLES.where("texte", "is null").count(db), 25)
    assert_eq(await ARTICLES.where("titre", "like", "Article 1%").count(db), 11)
    assert_eq((await ARTICLES.order_by("id").offset(24).all(db))[0]["titre"], "Article 25")
    assert_eq(await ARTICLES.where("auteur_id", ids[1]).update(db, {"publie": false}), 12)
    assert_eq(await ARTICLES.where("publie", true).count(db), 9)
    assert_eq(await ARTICLES.where("id", ">", 20).delete(db), 5)
    assert_true(await ARTICLES.where("id", 1).exists(db))
    p := await ARTICLES.query().order_by("id").paginate(db, 2, 8)
    assert_eq([p["page"], p["total"], p["pages"], p["has_prev"], p["has_next"], len(p["items"])], [2, 20, 3, true, true, 8])
    assert_eq(p["items"][0]["titre"], "Article 9")
    await db.close()

async func test_relations():
    db := await base()
    await peupler(db)
    lst := await ARTICLES.where("id", "<=", 3).order_by("id").with_one(COMPTES, "auteur_id", "auteur").with_many(COMMENTAIRES, "article_id", "commentaires", "id").all(db)
    assert_eq([x["auteur"]["nom"] for x in lst], ["awa", "kofi", "awa"])
    assert_eq([len(x["commentaires"]) for x in lst], [2, 1, 0])
    assert_eq(lst[0]["commentaires"][1]["texte"], "merci")
    await db.close()

async func test_injection_impossible():
    db := await base()
    await peupler(db)
    assert_eq(await COMPTES.where("nom", "awa' OR '1'='1").count(db), 0)
    try:
        ARTICLES.where("titre; DROP TABLE comptes", 1)
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "colonne inconnue")
    try:
        ARTICLES.order_by("id; DROP TABLE comptes")
        assert_true(false, "erreur attendue")
    catch e:
        assert_contains(e.message, "colonne inconnue")
    assert_eq(await COMPTES.query().count(db), 2)
    await db.close()
