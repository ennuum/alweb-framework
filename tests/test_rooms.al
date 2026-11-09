# Salons temps réel (alweb.realtime) sans réseau : diffusion, présence, historique ; deux concentrateurs sur la même
# base (comme deux processus) partagent messages et présence.
use os
use json
use asyncio as aio
use alweb.realtime as rt
use database.async_database as adb
use database.database as dbm
use alweb.testing as at
from core use len
from collections use append
from testing use assert_eq, assert_true

# Session WebSocket factice : garde ce qu'on lui envoie.
class FauxWs:
    func init():
        self.closed = false
        self.recu = []

    func send_text(t):
        append(self.recu, json.parse(t))
        return null

func types(ws):
    out := []
    for m in ws.recu:
        append(out, m["type"])
    return out

async func test_diffusion_et_presence():
    hub := rt.Hub()
    await hub.start()
    room := hub.room("general")
    a := FauxWs()
    b := FauxWs()
    await room.join(a, {"id": "ana", "nom": "Ana"})
    await room.join(b, {"id": "bob"})
    await room.join(FauxWs(), {"id": "ana"})            # deuxième onglet d'Ana : compté une fois
    assert_eq(room.count(), 2)
    id := await room.broadcast({"texte": "salut"}, {"id": "ana"})
    dernier := a.recu[len(a.recu) - 1]
    assert_eq(dernier["type"], "message")
    assert_eq(dernier["data"], {"texte": "salut"})
    assert_eq(dernier["id"], id)
    assert_eq(dernier["room"], "general")
    assert_eq(types(b), ["join", "message"])            # le join du 2e onglet d'Ana (pas le sien), puis le message
    assert_eq(types(a), ["join", "join", "message"])
    await room.leave(a)
    assert_eq(room.count(), 2)                          # Ana reste présente par son autre onglet
    await room.leave(b)
    assert_eq(room.count(), 1)
    assert_eq(room.members()[0]["id"], "ana")
    assert_eq(await room.leave(b), null)                # déjà parti : rien n'est publié

async func test_session_fermee_retiree():
    hub := rt.Hub()
    room := hub.room("x")
    a := FauxWs()
    await room.join(a, "a")
    a.closed = true
    await room.broadcast("rien")
    assert_eq(len(room.sockets), 0)

async func test_historique():
    hub := rt.Hub(rt.MemoryBroker(3))
    i := 0
    while i < 5:
        await hub.publish("h", "message", i)
        i += 1
    h := await hub.history("h", 0)
    assert_eq(len(h), 3)                               # seuls les 3 derniers sont gardés
    assert_eq(h[0]["data"], 2)
    assert_eq(len(await hub.history("h", h[1]["id"])), 1)
    assert_eq(await hub.history("vide", 0), [])

async func test_deux_processus_par_la_base():
    ax := at.alexdb_database("alweb_rooms_t")
    pg := os.getenv("ALWEB_TEST_POSTGRES") if ax == null else null
    url := ax if ax != null else (pg if pg != null else "sqlite:/tmp/alweb-test-rooms.db")
    if ax == null and pg == null and not ("sqlite" in dbm.backends()):
        # deux concentrateurs doivent voir la même base : le moteur embarqué n'est pas partagé entre connexions
        raise("SkipTest", "SQLite indisponible (exécutable natif sans FFI, ou libsqlite3 absente)")
    if ax != null:
        pass
    elif pg == null:
        if os.exists("/tmp/alweb-test-rooms.db"):
            os.remove("/tmp/alweb-test-rooms.db")
    else:
        await adb.open(pg).execute("DROP TABLE IF EXISTS alweb_events_t", [])
    db1 := adb.open(url)
    db2 := adb.open(url)
    h1 := rt.Hub(rt.DatabaseBroker(db1, 0.02, 3600, "alweb_events_t"))
    h2 := rt.Hub(rt.DatabaseBroker(db2, 0.02, 3600, "alweb_events_t"))
    await h1.start()
    await h2.start()
    w1 := FauxWs()
    w2 := FauxWs()
    await h1.room("r").join(w1, {"id": "un"})
    await h2.room("r").join(w2, {"id": "deux"})
    await h1.room("r").broadcast("bonjour", {"id": "un"})
    await aio.sleep(0.3)
    assert_eq(types(w2), ["message"])                  # message publié par l'autre processus
    assert_eq(w2.recu[0]["data"], "bonjour")
    assert_eq(types(w1), ["join", "message"])          # arrivée de « deux », puis le message : ordre des identifiants
    assert_eq(w1.recu[0]["id"] < w1.recu[1]["id"], true)
    assert_eq(h1.room("r").count(), 2)
    assert_eq(h2.room("r").count(), 2)
    # un troisième processus qui démarre retrouve la présence et l'historique
    h3 := rt.Hub(rt.DatabaseBroker(adb.open(url), 0.02, 3600, "alweb_events_t"))
    await h3.start()
    assert_eq(h3.room("r").count(), 2)
    assert_eq(len(await h3.history("r", 0)), 3)
    await h2.room("r").leave(w2)
    await aio.sleep(0.3)
    assert_eq(h1.room("r").count(), 1)
    assert_eq(h3.room("r").count(), 1)
    await h1.stop()
    await h2.stop()
    await h3.stop()
    assert_eq(h1.errors + h2.errors + h3.errors, [])
