# Lance la messagerie d'exemple :  alexc run examples/chat.al [port]   puis http://127.0.0.1:8000/
# Documentation de l'API : http://127.0.0.1:8000/docs (description : /openapi.json).
# Configuration : examples/chat/config (base.json + <profil>.json + local.json, puis variables ALWEB_*) :
#   ALWEB_ENV=dev  (défaut) debug, un processus, rechargement à chaud ; SQLite (chat.db)
#   ALWEB_ENV=prod un processus par cœur ; salons et limites partagés par la base (temps_reel.partage) ;
#                  la clé doit venir de l'environnement : ALWEB_SECRET_KEY=...
#   PostgreSQL :   ALWEB_DATABASE__URL=postgres://utilisateur:mdp@hote:5432/chat
from core use len, to_int
use os
use alweb
use examples.chat_app as chat

# dossier de l'exemple : à côté du script (alexc run), sinon examples/chat (exécutable natif lancé depuis la racine)
ici := os.join(os.dirname(os.absolute(os.argv()[0])), "chat")
if not os.exists(os.join(ici, "config")):
    ici = os.absolute("examples/chat")
cfg := alweb.load_config(os.join(ici, "config"))
host := cfg.get("server.host", "127.0.0.1")
port := to_int(os.args()[0]) if len(os.args()) > 0 else cfg.get("server.port", 8000)
app := chat.make_app(cfg, ici)
if cfg.is_dev():
    await app.run_dev(host, port)
elif cfg.is_prod():
    await app.run_workers(host, port, cfg.get("server.workers", 0))
else:
    await app.run(host, port)
