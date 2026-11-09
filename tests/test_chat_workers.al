# La messagerie sur deux processus ouvriers partageant une base SQLite (temps_reel.partage) : un message envoyé
# à un ouvrier arrive au client servi par l'autre, la présence est commune et la limite de connexion vaut pour
# les deux. Ce fichier est aussi le programme des ouvriers.   alexc test tests/test_chat_workers.al
use os
use string as s
use json
use time
use network.websocket as wsc
use web.client as http
use web.server.workers as workers
use database.async_database as adb
use alweb
use alweb.config as conf
use alweb.orm as orm
use alweb.auth as auth
use alweb.alexdb as axdb
use alweb.testing as at
use examples.chat_app as chat
from core use len
from collections use append

const BASE := "/tmp/alweb-chat-workers.db"
# ALWEB_TEST_POSTGRES=postgres://... : base PostgreSQL alweb_chat_workers (recréée) au lieu du fichier SQLite ; c'est
# aussi le seul choix possible pour un exécutable natif (sans FFI, donc sans SQLite).
func url_base():
    ax := os.getenv("ALWEB_TEST_ALEXDB")
    if ax != null:
        return axdb.with_database(ax, "alweb_chat_workers")       # recréée par le superviseur seulement
    pg := os.getenv("ALWEB_TEST_POSTGRES")
    if pg == null:
        return "sqlite:" + BASE
    k := s.find(pg, "?")
    b := pg if k < 0 else pg[0:k]
    i := len(b) - 1
    while i >= 0 and b[i:i + 1] != "/":
        i -= 1
    return b[0:i + 1] + "alweb_chat_workers" + ("" if k < 0 else pg[k:len(pg)])

ENV := {"ALWEB_DATABASE__URL": url_base(), "ALWEB_TEMPS_REEL__PARTAGE": "true"}

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

func bienvenue(c):
    m := c.receive(5.0)
    expect(m != null, "pas de message de bienvenue")
    e := json.parse(m.text())
    expect(e["type"] == "bienvenue", "bienvenue attendu : " + m.text())
    return e

# Prochain événement `genre` (du membre `pseudo` s'il est donné) : les connexions de bob refusées plus haut
# produisent elles aussi des join/leave, qu'il faut laisser passer.
func attendre(c, genre, pseudo=null):
    t0 := time.monotonic()
    while time.monotonic() - t0 < 5.0:
        m := c.receive(5.0)
        if m == null:
            return null
        e := json.parse(m.text())
        if e["type"] == genre and (pseudo == null or e["member"]["pseudo"] == pseudo):
            return e
    return null

# Chaque ouvrier refait la présence à partir des événements de l'autre, relus dans la base toutes les 50 ms : on
# attend que tous répondent `n` (10 réponses de suite), au plus 10 s, au lieu de regarder une seule fois trop tôt.
func presence_commune(base, n):
    vus := []
    t0 := time.monotonic()
    while time.monotonic() - t0 < 10.0:
        vus = []
        k := 0
        while k < 10:
            v := len(http.get(base + "/api/v1/salons/general/presence", headers={"Connection": "close"}).json())
            if not (v in vus):
                append(vus, v)
            k += 1
        if vus == [n]:
            return vus
        time.sleep(0.1)
    return vus

if workers.is_worker():
    cfg := conf.load("examples/chat/config", "test", "ALWEB", ENV)
    await chat.make_app(cfg, "examples/chat").run_workers("127.0.0.1", 0, 2)
else:
    for f in [BASE, BASE + "-journal", BASE + "-wal", BASE + "-shm"]:
        if os.exists(f):
            os.remove(f)
    pg := os.getenv("ALWEB_TEST_POSTGRES")
    if os.getenv("ALWEB_TEST_ALEXDB") != null:
        at.alexdb_database("alweb_chat_workers")
    elif pg != null:
        admin := adb.open(pg)
        if (await admin.scalar("SELECT COUNT(*) FROM pg_database WHERE datname = 'alweb_chat_workers'")) == 0:
            await admin.script("CREATE DATABASE alweb_chat_workers")
        await admin.close()
        prep := adb.open(ENV["ALWEB_DATABASE__URL"])
        await prep.script("DROP TABLE IF EXISTS messages, salons, comptes, alweb_migrations, alweb_events, alweb_rate CASCADE")
        await prep.close()
    # base préparée avant les ouvriers (migrations, comptes)
    db := adb.open(ENV["ALWEB_DATABASE__URL"])
    await orm.migrate(db, chat.MIGRATIONS)
    for p in ["ana", "bob"]:
        await chat.COMPTES.insert(db, {"pseudo": p, "mdp": await auth.hash_password("motdepasse8", 1000)})
    await db.close()

    sup := workers.Supervisor(2, "127.0.0.1", 0, null, ENV).start()
    expect(sup.wait_ready(30.0), "les ouvriers n'écoutent pas")
    base := "http://127.0.0.1:" + str(sup.port)
    ws := "ws://127.0.0.1:" + str(sup.port) + "/ws/general?jeton="
    jetons := {}
    for p in ["ana", "bob"]:
        jetons[p] = http.post(base + "/api/v1/jeton", json={"pseudo": p, "mot_de_passe": "motdepasse8"}, headers={"Connection": "close"}).json()["jeton"]

    # un client sur chaque ouvrier (la répartition des connexions est faite par le noyau)
    a := wsc.connect(ws + jetons["ana"])
    pid_a := bienvenue(a)["pid"]
    b := null
    pid_b := null
    essais := 0
    while pid_b == null and essais < 40:
        c := wsc.connect(ws + jetons["bob"])
        e := bienvenue(c)
        if e["pid"] != pid_a:
            b = c
            pid_b = e["pid"]
        else:
            c.close()
        essais += 1
    expect(b != null, "aucune connexion servie par le second ouvrier")

    expect(attendre(a, "join", "bob") != null, "arrivée de bob non vue par l'autre ouvrier")
    a.send_text(json.stringify({"texte": "d'un ouvrier à l'autre"}))
    m := attendre(b, "message")
    expect(m != null and m["data"]["texte"] == "d'un ouvrier à l'autre" and m["data"]["auteur"] == "ana", "message non reçu par l'autre ouvrier : " + str(m))
    # la présence est la même quel que soit l'ouvrier qui répond
    vus := presence_commune(base, 2)
    expect(vus == [2], "présence incohérente entre ouvriers : " + str(vus))

    # limite de connexion (5 / min en test) commune aux deux ouvriers : 2 jetons déjà demandés
    statuts := []
    k := 0
    while k < 4:
        append(statuts, http.post(base + "/api/v1/jeton", json={"pseudo": "ana", "mot_de_passe": "motdepasse8"}, headers={"Connection": "close"}).status)
        k += 1
    expect(statuts == [200, 200, 200, 429], "limite partagée : " + str(statuts))

    a.close()
    expect(attendre(b, "leave", "ana") != null, "départ d'ana non vu par l'autre ouvrier")
    expect(presence_commune(base, 1) == [1], "départ d'ana absent de la présence d'un ouvrier")
    b.close()
    sup.stop(10.0)
    expect(sup.alive_count() == 0, "ouvriers encore vivants")
    print("messagerie sur 2 ouvriers : OK (pid " + str(pid_a) + " et " + str(pid_b) + ")")
