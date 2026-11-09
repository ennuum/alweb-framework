# Lance {{Nom}} :  alweb run   (ou  alexc run [-- port])   puis http://127.0.0.1:8000/
# Profil : ALWEB_ENV (dev par défaut, test, prod) ; configuration dans config/ : base.json < <profil>.json <
# local.json < variables ALWEB_* (par exemple ALWEB_SERVER__PORT=9000).
#   dev   debug, gabarits relus, rechargement à chaud à chaque modification d'un .al
#   prod  un processus par cœur (server.workers), journal JSON ; ALWEB_SECRET_KEY exigée
from core use len, to_int
use os
use alweb
use application

# Racine du projet (config/, templates/, static/) : ALWEB_ROOT, sinon le dossier de ce fichier, sinon le dossier
# courant (exécutable construit par `alweb build`, rangé dans dist/ et lancé depuis la racine).
ici := os.getenv("ALWEB_ROOT", os.dirname(os.absolute(os.argv()[0])))
if not os.isdir(os.join(ici, "config")):
    ici = os.cwd()
cfg := alweb.load_config(os.join(ici, "config"))
host := cfg.get("server.host", "127.0.0.1")
port := to_int(os.args()[0]) if len(os.args()) > 0 else cfg.get("server.port", 8000)
app := application.creer(cfg, ici)
if cfg.is_dev():
    await app.run_dev(host, port)
elif cfg.is_prod():
    await app.run_workers(host, port, cfg.get("server.workers", 0))
else:
    await app.run(host, port)
