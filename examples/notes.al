# Lance l'exemple « notes » :  alexc run examples/notes.al [port]
#   curl localhost:8000/api/notes
#   curl -X POST localhost:8000/api/notes -H 'Content-Type: application/json' -d '{"titre": "Courses", "texte": "pain"}'
# Configuration : examples/config (base.json + <profil>.json + local.json, puis variables ALWEB_*). Profil :
#   ALWEB_ENV=dev  (défaut) debug, rechargement à chaud à chaque modification d'un .al du projet
#   ALWEB_ENV=prod plusieurs processus (server.workers ; 0 : un par cœur), journal JSON
#   ALWEB_ENV=test stockage en mémoire
from core use len, to_int
use os
use alweb
use examples.notes_app as notes

cfg := alweb.load_config(os.join(os.dirname(os.absolute(os.argv()[0])), "config"))
host := cfg.get("server.host", "127.0.0.1")
port := to_int(os.args()[0]) if len(os.args()) > 0 else cfg.get("server.port", 8000)
app := notes.make_app(cfg)
if cfg.is_dev():
    await app.run_dev(host, port)
elif cfg.is_prod():
    await app.run_workers(host, port, cfg.get("server.workers", 0))
else:
    await app.run(host, port)
