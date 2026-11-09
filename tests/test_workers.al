# alweb sur plusieurs processus (app.run_workers) : ce fichier est aussi le programme des ouvriers.
#   alexc test tests/test_workers.al
use os
use time
use web.client as http
use web.server.workers as workers
use alweb
from core use len
from collections use append

DEMARRAGES := [0]

func make_app():
    app := alweb.App("multi")
    app.get("/pid", (req) => {"pid": os.pid(), "demarrages": DEMARRAGES[0]})

    @app.on_startup
    func demarrer():
        DEMARRAGES[0] = DEMARRAGES[0] + 1

    return app

func expect(cond, what):
    if not cond:
        raise("AssertionError", what)

if workers.is_worker():
    await make_app().run_workers("127.0.0.1", 0, 2)
else:
    sup := workers.Supervisor(2, "127.0.0.1", 0).start()
    expect(sup.wait_ready(30.0), "les ouvriers n'écoutent pas")
    vus := []
    i := 0
    while i < 40:
        r := http.get("http://127.0.0.1:" + str(sup.port) + "/pid", headers={"Connection": "close"})
        d := r.json()
        expect(d["demarrages"] == 1, "on_startup doit s'exécuter une fois par ouvrier : " + str(d))
        if not (d["pid"] in vus):
            append(vus, d["pid"])
        i += 1
    sup.stop(10.0)
    expect(len(vus) == 2, "2 ouvriers attendus, vus : " + str(vus))
    expect(sup.alive_count() == 0, "ouvriers encore vivants")
    print("alweb run_workers : OK")
