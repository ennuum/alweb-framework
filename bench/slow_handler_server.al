# Banc « gestionnaire lent » : /lent attend 100 ms (time.sleep en mode sync, asyncio.sleep en mode async),
# /rapide répond tout de suite. Mesure l'effet d'un gestionnaire lent sur les requêtes rapides.
#   alexc run bench/slow_handler_server.al <port> sync|async
from core use len, to_int
use os
use time
use asyncio as aio
use web.server as server

port := to_int(os.args()[0]) if len(os.args()) > 0 else 8080
mode := os.args()[1] if len(os.args()) > 1 else "async"

func lent_sync(req):
    time.sleep(0.1)
    return "lent"

async func lent_async(req):
    await aio.sleep(0.1)
    return "lent"

app := server.App()
app.get("/", (req) => "Bonjour")
app.get("/rapide", (req) => "rapide")
app.get("/lent", lent_async if mode == "async" else lent_sync)
cfg := server.config("127.0.0.1", port)
cfg.access_log = false
srv := server.Server(app, cfg).start()
if mode == "async":
    await srv.serve_forever_async()
else:
    srv.serve_forever()
