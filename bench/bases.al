# Coût des opérations de l'ORM selon la base (phase 7) : insertion, lecture par clé, page de 20, transaction d'un
# bloc ; à travers database.async_database comme dans une application.
#   alexc run bench/bases.al                                           # SQLite (fichier) seul
#   ALWEB_BENCH_ALEXDB=alexdb://admin:mdp@127.0.0.1:5442/alexdb alexc run bench/bases.al
#   ALWEB_BENCH_POSTGRES=postgres://… alexc run bench/bases.al
use os
use time
use alweb
use alweb.orm as orm
use alweb.alexdb as axdb
use database.connection as dc
use database.database as dbm

NOTES := orm.table("bench_notes", {"id": orm.pk(), "titre": orm.text(80), "texte": orm.text(), "publie": orm.boolean(), "cree_le": orm.timestamp(auto=true)})
N := 300

async func mesure(nom, url):
    db := alweb.database(url)
    await db.script("DROP TABLE IF EXISTS bench_notes")
    await db.script(NOTES.create_sql(orm.dialect(db)))
    t0 := time.monotonic()
    ids := []
    i := 0
    while i < N:
        ids = ids + [await NOTES.insert(db, {"titre": "note " + str(i), "texte": "texte de la note " + str(i), "publie": i % 2 == 0})]
        i += 1
    t1 := time.monotonic()
    for id in ids:
        await NOTES.get(db, id)
    t2 := time.monotonic()
    k := 0
    while k < 50:
        await NOTES.where("publie", true).order_by("-id").paginate(db, 1 + k % 5, 20)
        k += 1
    t3 := time.monotonic()
    k = 0
    while k < 50:
        await db.transaction([["UPDATE bench_notes SET titre = ? WHERE id = ?", ["maj", ids[k]]], ["UPDATE bench_notes SET publie = ? WHERE id = ?", [1, ids[k + 1]]]])
        k += 1
    t4 := time.monotonic()
    print(nom + " : insertion " + us(t1 - t0, N) + ", lecture par clé " + us(t2 - t1, N) + ", page de 20 (avec total) " + us(t3 - t2, 50) + ", transaction de 2 UPDATE " + us(t4 - t3, 50))
    await db.script("DROP TABLE bench_notes")
    await db.close()

func us(dt, n):
    return str((dt / n * 1000000.0) // 1 / 1000.0) + " ms"

f := "/tmp/alweb-bench-bases.db"
if os.exists(f):
    os.remove(f)
if "sqlite" in dbm.backends():
    await mesure("SQLite (fichier)", "sqlite:" + f)
ax := os.getenv("ALWEB_BENCH_ALEXDB")
if ax != null:
    c := dc.Connection(ax)
    c.execute("CREATE DATABASE IF NOT EXISTS alweb_bench")
    c.close()
    await mesure("ALEX DB (serveur local)", axdb.with_database(ax, "alweb_bench"))
pg := os.getenv("ALWEB_BENCH_POSTGRES")
if pg != null:
    await mesure("PostgreSQL", pg)
