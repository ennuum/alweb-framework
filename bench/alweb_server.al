# Banc alweb : même « hello » que baseline_server.al, servi par alweb.
#   alexc run bench/alweb_server.al <port> nu|mw
#   nu : aucune intergiciel (route synchrone, chemin direct) ; mw : request_id + timing + security_headers
from core use len, to_int
use os
use alweb
use alweb.middleware as mw

port := to_int(os.args()[0]) if len(os.args()) > 0 else 8000
mode := os.args()[1] if len(os.args()) > 1 else "nu"
app := alweb.App("bench")
if mode == "mw":
    app.middleware([mw.request_id(), mw.timing(), mw.security_headers()])
app.get("/", (req) => "Bonjour")
app.get("/json", (req) => {"message": "Bonjour", "n": 42})
await app.run("127.0.0.1", port, null, true)
