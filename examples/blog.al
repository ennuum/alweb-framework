# Lance le blog d'exemple :  alexc run examples/blog.al [port]   puis http://127.0.0.1:8000/
# Configuration : examples/blog/config (base.json + <profil>.json + local.json, puis variables ALWEB_*) :
#   ALWEB_ENV=dev  (défaut) debug, gabarits relus, rechargement à chaud ; SQLite (blog.db)
#   ALWEB_ENV=prod plusieurs processus ; la clé doit venir de l'environnement : ALWEB_SECRET_KEY=...
#   PostgreSQL :   ALWEB_DATABASE__URL=postgres://utilisateur:mdp@hote:5432/blog
# Le premier compte inscrit est administrateur.
from core use len, to_int
use os
use alweb
use examples.blog_app as blog

ici := os.join(os.dirname(os.absolute(os.argv()[0])), "blog")
cfg := alweb.load_config(os.join(ici, "config"))
host := cfg.get("server.host", "127.0.0.1")
port := to_int(os.args()[0]) if len(os.args()) > 0 else cfg.get("server.port", 8000)
app := blog.make_app(cfg, ici)
if cfg.is_dev():
    await app.run_dev(host, port)
elif cfg.is_prod():
    await app.run_workers(host, port, cfg.get("server.workers", 0))
else:
    await app.run(host, port)
