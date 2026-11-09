# Serveur de référence pour les bancs d'essai : web.server seul, sans alweb.
#   alexc run bench/baseline_server.al [port]
from core use len, to_int
use os
use web.server as server

port := 8080
if len(os.args()) > 0:
    port = to_int(os.args()[0])

app := server.App()
app.get("/", (req) => "Bonjour")
app.get("/json", (req) => {"message": "Bonjour", "n": 42})
cfg := server.config("127.0.0.1", port)
cfg.access_log = false
server.serve(app, "127.0.0.1", port, cfg)
