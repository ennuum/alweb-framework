# Jalon de la phase 4 : la messagerie d'exemple sur un vrai port. Comptes et jetons, salons WebSocket (diffusion,
# présence, frappe), envoi par l'API REST, flux SSE repris par Last-Event-ID, historique par curseur, limitation
# de débit, description OpenAPI.   alexc test tests/test_chat_example.al
# Base : SQLite en mémoire ; ALWEB_TEST_POSTGRES=postgres://... : PostgreSQL (base alweb_chat_test, tables
# recréées) avec salons et limites partagés par la base (temps_reel.partage), comme en production.
use os
use json
use time
use string as s
use concurrency.thread as thread
use network.websocket as wsc
use network.tcp as tcp
use web.client as http
use alweb
use alweb.config as conf
use alweb.testing as at
use database.async_database as adb
use examples.chat_app as chat
from core use len
from collections use append

async func configuration():
    env := {}
    ax := at.alexdb_database("alweb_chat_test")
    pg := os.getenv("ALWEB_TEST_POSTGRES") if ax == null else null
    if ax != null:
        env["ALWEB_DATABASE__URL"] = ax
        env["ALWEB_TEMPS_REEL__PARTAGE"] = "true"
    elif pg != null:
        db := adb.open(pg)
        if (await db.scalar("SELECT COUNT(*) FROM pg_database WHERE datname = 'alweb_chat_test'")) == 0:
            await db.script("CREATE DATABASE alweb_chat_test")
        await db.close()
        k := s.find(pg, "?")
        base := pg if k < 0 else pg[0:k]
        i := len(base) - 1
        while i >= 0 and base[i:i + 1] != "/":
            i -= 1
        url := base[0:i + 1] + "alweb_chat_test" + ("" if k < 0 else pg[k:len(pg)])
        db = adb.open(url)
        await db.script("DROP TABLE IF EXISTS messages, salons, comptes, alweb_migrations, alweb_events, alweb_rate CASCADE")
        await db.close()
        env["ALWEB_DATABASE__URL"] = url
        env["ALWEB_TEMPS_REEL__PARTAGE"] = "true"
    return conf.load("examples/chat/config", "test", "ALWEB", env)

func url(port, chemin):
    return "http://127.0.0.1:" + str(port) + chemin

func post(port, chemin, corps, jeton=null):
    return http.post(url(port, chemin), json=corps, bearer=jeton, headers={"Accept": "application/json"})

func ws(port, salon, jeton):
    return wsc.connect("ws://127.0.0.1:" + str(port) + "/ws/" + salon + "?jeton=" + jeton)

# Prochain événement du type voulu (les autres sont ignorés).
func attendre(c, genre, delai=5.0):
    t0 := time.monotonic()
    while time.monotonic() - t0 < delai:
        m := c.receive(delai)
        if m == null:
            return null
        e := json.parse(m.text())
        if e["type"] == genre:
            return e
    return null

func sse(port, chemin, last_id, attendu):
    c := tcp.connect("127.0.0.1", port, 3.0)
    c.write("GET " + chemin + " HTTP/1.1\r\nHost: x\r\nLast-Event-ID: " + str(last_id) + "\r\n\r\n")
    recu := ""
    t0 := time.monotonic()
    while s.count(recu, "\n\n") < attendu and time.monotonic() - t0 < 5.0:
        d := c.socket.recv(65536, 1.0)
        if d == "":
            break
        recu = recu + d
    c.close()
    return recu

func scenario(port):
    r := {}
    mdp := "motdepasse8"
    r["inscription"] = post(port, "/api/v1/comptes", {"pseudo": "ana", "mot_de_passe": mdp}).status
    post(port, "/api/v1/comptes", {"pseudo": "bob", "mot_de_passe": mdp})
    r["doublon"] = post(port, "/api/v1/comptes", {"pseudo": "ana", "mot_de_passe": mdp}).status
    r["pseudo_invalide"] = post(port, "/api/v1/comptes", {"pseudo": "Ana!", "mot_de_passe": mdp}).status
    ja := post(port, "/api/v1/jeton", {"pseudo": "ana", "mot_de_passe": mdp}).json()["jeton"]
    jb := post(port, "/api/v1/jeton", {"pseudo": "bob", "mot_de_passe": mdp}).json()["jeton"]
    r["mauvais_mdp"] = post(port, "/api/v1/jeton", {"pseudo": "ana", "mot_de_passe": "autre-chose"}).status

    a := ws(port, "general", ja)
    r["bienvenue_a"] = attendre(a, "bienvenue")["membres"]
    b := ws(port, "general", jb)
    r["bienvenue_b"] = len(attendre(b, "bienvenue")["membres"])
    r["join_vu_par_a"] = attendre(a, "join")["member"]["pseudo"]
    a.send_text(json.stringify({"texte": "  bonjour à tous  "}))
    mb := attendre(b, "message")
    r["message_b"] = mb["data"]["texte"] + " / " + mb["data"]["auteur"]
    depart := mb["id"]
    attendre(a, "message")
    b.send_text(json.stringify({"type": "ecrit"}))
    b.send_text("pas du json")
    r["ecrit_vu_par_a"] = attendre(a, "ecrit")["member"]["pseudo"]
    rest := post(port, "/api/v1/salons/general/messages", {"texte": "par l'API"}, jb)
    r["envoi_rest"] = rest.status
    r["rest_vu_par_a"] = attendre(a, "message")["data"]["texte"]
    r["envoi_sans_jeton"] = post(port, "/api/v1/salons/general/messages", {"texte": "x"}).status
    r["salon_inconnu"] = post(port, "/api/v1/salons/nulle-part/messages", {"texte": "x"}, jb).status
    r["presence"] = len(http.get(url(port, "/api/v1/salons/general/presence")).json())
    # un lecteur SSE qui revient après le premier message reçoit ce qu'il a manqué : la frappe puis le message REST
    r["sse"] = sse(port, "/salons/general/evenements", depart, 2)

    # historique : 55 messages de plus, puis deux pages
    i := 0
    while i < 55:
        a.send_text(json.stringify({"texte": "n" + str(i)}))
        i += 1
    n := 0
    while n < 55 and attendre(b, "message") != null:
        n += 1
    r["recus_par_b"] = n
    p1 := http.get(url(port, "/api/v1/salons/general/messages"))
    d1 := p1.json()
    r["page1"] = [len(d1["items"]), d1["items"][0]["texte"], s.contains(p1.headers.get("Link"), "rel=\"next\"")]
    d2 := http.get(url(port, "/api/v1/salons/general/messages?cursor=" + d1["next"])).json()
    r["page2"] = [len(d2["items"]), d2["items"][len(d2["items"]) - 1]["texte"], d2["next"]]

    r["creer_salon"] = post(port, "/api/v1/salons", {"nom": "jeux", "sujet": "on joue"}, jb).status
    noms := []
    for x in http.get(url(port, "/api/v1/salons")).json():
        append(noms, x["nom"] + ":" + str(x["presents"]))
    r["salons"] = noms

    a.close()
    r["leave_vu_par_b"] = attendre(b, "leave")["member"]["pseudo"]
    time.sleep(0.1)
    r["presence_apres"] = len(http.get(url(port, "/api/v1/salons/general/presence")).json())
    b.close()

    intrus := ws(port, "general", "faux.jeton.x")
    r["ws_refuse"] = [intrus.receive(3.0), intrus.close_code]
    perdu := ws(port, "nulle-part", jb)
    r["ws_salon_inconnu"] = [perdu.receive(3.0), perdu.close_code]

    # connexion : 5 essais par minute en test (3 déjà faits)
    statuts := []
    k := 0
    while k < 3:
        append(statuts, post(port, "/api/v1/jeton", {"pseudo": "ana", "mot_de_passe": mdp}).status)
        k += 1
    r["limite_connexion"] = statuts
    lim := post(port, "/api/v1/jeton", {"pseudo": "ana", "mot_de_passe": mdp})
    r["retry_after"] = lim.headers.get("Retry-After") != null

    spec := http.get(url(port, "/openapi.json")).json()
    r["openapi"] = [spec["openapi"], "/api/v1/salons/{nom}/messages" in spec["paths"], "post" in spec["paths"]["/api/v1/salons/{nom}/messages"], spec["paths"]["/api/v1/jeton"]["post"]["responses"]["429"]["description"]]
    r["docs"] = http.get(url(port, "/docs")).status
    page := http.get(url(port, "/"))
    r["accueil"] = [page.status, s.contains(page.text(), "/static/chat.js")]
    r["js"] = http.get(url(port, "/static/chat.js")).status
    return r

async func drive(srv, t, limit=60.0):
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < limit:
        await srv.serve_for_async(0.02)

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

func egal(r, cle, attendu):
    expect(r[cle] == attendu, cle + " : obtenu " + str(r[cle]) + ", attendu " + str(attendu))

if thread.is_main():
    cfg := await configuration()
    app := chat.make_app(cfg, "examples/chat")
    await app.start()
    srv := app.server("127.0.0.1", 0).start()
    t := thread.spawn(scenario, [srv.port()])
    await drive(srv, t)
    r := t.join(5.0)
    srv.close()
    hub := app.state_hub
    await app.stop()
    expect(r != null, "scénario inachevé")
    egal(r, "inscription", 201)
    egal(r, "doublon", 409)
    egal(r, "pseudo_invalide", 422)
    egal(r, "mauvais_mdp", 401)
    egal(r, "bienvenue_a", [{"id": "1", "pseudo": "ana"}])
    egal(r, "bienvenue_b", 2)
    egal(r, "join_vu_par_a", "bob")
    egal(r, "message_b", "bonjour à tous / ana")
    egal(r, "ecrit_vu_par_a", "bob")
    egal(r, "envoi_rest", 201)
    egal(r, "rest_vu_par_a", "par l'API")
    egal(r, "envoi_sans_jeton", 401)
    egal(r, "salon_inconnu", 404)
    egal(r, "presence", 2)
    expect(s.contains(r["sse"], "event: ecrit\n") and s.contains(r["sse"], "\"texte\":\"par l'API\""), "reprise SSE : " + r["sse"])
    expect(not s.contains(r["sse"], "bonjour"), "la reprise ne doit pas rejouer le message déjà vu : " + r["sse"])
    egal(r, "recus_par_b", 55)
    egal(r, "page1", [50, "n54", true])
    egal(r, "page2", [7, "bonjour à tous", null])
    egal(r, "creer_salon", 201)
    egal(r, "salons", ["general:2", "jeux:0"])
    egal(r, "leave_vu_par_b", "ana")
    egal(r, "presence_apres", 1)
    egal(r, "ws_refuse", [null, 4401])
    egal(r, "ws_salon_inconnu", [null, 4404])
    egal(r, "limite_connexion", [200, 200, 429])
    egal(r, "retry_after", true)
    egal(r, "openapi", ["3.1.0", true, true, "trop d'essais"])
    egal(r, "docs", 200)
    egal(r, "accueil", [200, true])
    egal(r, "js", 200)
    expect(len(srv.errors) == 0, "erreurs du serveur : " + str(srv.errors))
    expect(len(hub.errors) == 0, "erreurs du concentrateur : " + str(hub.errors))
    print("messagerie d'exemple : OK")
