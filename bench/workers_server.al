# Banc multi-processus : alexc run bench/workers_server.al <port> <ouvriers>
from core use len, to_int
use os
use web.server as server
use web.server.workers as workers

port := to_int(os.args()[0]) if len(os.args()) > 0 else 8080
n := to_int(os.args()[1]) if len(os.args()) > 1 else 2
app := server.App()
app.get("/", (req) => "Bonjour")
await workers.serve(app, "127.0.0.1", port, n, null, true)
