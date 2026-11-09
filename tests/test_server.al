# Test de bout en bout : une application alweb servie sur un vrai port par web.server (boucle async), des
# clients web.client dans des fils. Vérifie que la chaîne complète (protocole, intergiciels async, routes async,
# validation) se comporte comme avec le client en mémoire, et que les requêtes lentes ne bloquent pas les autres.
#   alexc test tests/test_server.al
use time
use asyncio as aio
use concurrency.thread as thread
use web.client as http
use serialization.schema as sch
use alweb
use alweb.middleware as mw
from core use len

func make_app():
    app := alweb.App("e2e")
    app.middleware([mw.request_id(), mw.timing(), mw.security_headers()])

    @app.get("/lent")
    async func lent(req):
        await aio.sleep(0.5)
        return {"lent": true}

    @app.get("/rapide")
    func rapide(req):
        return "rapide"

    @app.post("/echo", {"body": sch.object({"n": sch.integer()}, ["n"])})
    async func echo(req):
        return ({"double": alweb.data(req)["n"] * 2}, 201)

    return app

func client_lent(port):
    t0 := time.monotonic()
    r := http.get("http://127.0.0.1:" + str(port) + "/lent")
    return [r.status, r.json()["lent"], time.monotonic() - t0, r.header("x-request-id") != null, r.header("server-timing") != null]

func client_rapides(port):
    time.sleep(0.1)
    t0 := time.monotonic()
    ok := 0
    i := 0
    while i < 5:
        r := http.get("http://127.0.0.1:" + str(port) + "/rapide")
        if r.status == 200 and r.text() == "rapide" and r.header("x-content-type-options") == "nosniff":
            ok += 1
        i += 1
    return [ok, time.monotonic() - t0]

func client_echo(port):
    base := "http://127.0.0.1:" + str(port)
    a := http.post(base + "/echo", json={"n": 21})
    b := http.post(base + "/echo", json={"n": "x"})
    return [a.status, a.json(), b.status]

async func drive(srv, threads, limit=15.0):
    t0 := time.monotonic()
    while time.monotonic() - t0 < limit:
        alive := false
        for t in threads:
            if t.is_alive():
                alive = true
        if not alive:
            return
        await srv.serve_for_async(0.05)

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

if thread.is_main():
    app := make_app()
    await app.start()
    srv := app.server("127.0.0.1", 0).start()
    port := srv.port()
    ta := thread.spawn(client_lent, [port])
    tb := thread.spawn(client_rapides, [port])
    tc := thread.spawn(client_echo, [port])
    await drive(srv, [ta, tb, tc])
    ra := ta.join(5.0)
    rb := tb.join(5.0)
    rc := tc.join(5.0)
    srv.close()
    await app.stop()

    expect(ra[0] == 200 and ra[1] == true, "réponse de /lent : " + str(ra))
    expect(ra[2] >= 0.45, "/lent doit durer ~0,5 s : " + str(ra[2]))
    expect(ra[3] and ra[4], "intergiciels request_id et timing absents de /lent")
    expect(rb[0] == 5, "5 réponses rapides attendues : " + str(rb))
    expect(rb[1] < 0.35, "les requêtes rapides ont attendu la requête lente : " + str(rb[1]) + " s")
    expect(rc[0] == 201 and rc[1] == {"double": 42}, "POST /echo valide : " + str(rc))
    expect(rc[2] == 422, "POST /echo invalide doit donner 422 : " + str(rc[2]))
    expect(len(srv.errors) == 0, "erreurs serveur : " + str(srv.errors))
    print("alweb sur web.server (bout en bout) : OK")
