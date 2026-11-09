# Appel HTTP sortant async dans un gestionnaire (network.async_client) : la route /relais appelle /cible sur le
# MÊME serveur, ce qui n'aboutit que si le serveur continue de servir pendant l'attente.
#   alexc test tests/test_outbound.al
use time
use asyncio as aio
use concurrency.thread as thread
use network.async_client as ac
use web.client as http
use alweb

PORT := [0]

func make_app():
    app := alweb.App("relais")

    @app.get("/cible")
    async func cible(req):
        await aio.sleep(0.1)
        return {"depuis": "cible"}

    @app.get("/relais")
    async func relais(req):
        r := await ac.get("http://127.0.0.1:" + str(PORT[0]) + "/cible")
        return {"relayé": r.json(), "statut": r.status}

    return app

func client(port):
    t0 := time.monotonic()
    r := http.get("http://127.0.0.1:" + str(port) + "/relais")
    return [r.status, r.json(), time.monotonic() - t0]

if thread.is_main():
    srv := make_app().server("127.0.0.1", 0).start()
    PORT[0] = srv.port()
    t := thread.spawn(client, [srv.port()])
    t0 := time.monotonic()
    while t.is_alive() and time.monotonic() - t0 < 15.0:
        await srv.serve_for_async(0.05)
    r := t.join(5.0)
    srv.close()
    if r[0] != 200 or r[1] != {"relayé": {"depuis": "cible"}, "statut": 200}:
        raise("AssertionError", "réponse du relais : " + str(r))
    if r[2] > 2.0:
        raise("AssertionError", "relais trop lent : " + str(r[2]))
    print("appel HTTP sortant async : OK (" + str(r[2]) + " s)")
