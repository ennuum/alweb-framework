# Site vitrine d'exemple avec le thème « Modern Business » et la page « Apparence » :
#   alexc run examples/vitrine.al [port]          puis http://127.0.0.1:8000/  et  http://127.0.0.1:8000/admin
# Variables : ALWEB_VITRINE_DIR (dossier du projet, défaut examples/vitrine-site : thème installé, réglages,
# fichiers envoyés), ALWEB_VITRINE_ADMIN (mot de passe de l'administration, défaut « vitrine-locale » :
# uniquement pour un essai sur votre machine) et ALWEB_SECRET_KEY (clé des sessions).
from core use len, to_int
use os
use network.security as sec
use examples.vitrine_app as vitrine

ici := os.dirname(os.absolute(os.argv()[0]))
args := os.args()
port := to_int(args[0]) if len(args) > 0 else 8000

func env(nom, defaut):
    v := os.getenv(nom)
    return v if v != null and v != "" else defaut

dossier := env("ALWEB_VITRINE_DIR", os.join(ici, "vitrine-site"))
mdp := env("ALWEB_VITRINE_ADMIN", "vitrine-locale")
app := vitrine.make_app(dossier, os.join(ici, "..", "alweb", "modele-theme"), mdp, env("ALWEB_SECRET_KEY", sec.random_token(32)))
print("site      : http://127.0.0.1:" + str(port) + "/")
print("apparence : http://127.0.0.1:" + str(port) + "/admin/_apparence  (mot de passe : " + mdp + ")")
print("projet    : " + dossier + " (thème dans themes/, réglages dans config/theme.modern-business.json)")
await app.run("127.0.0.1", port)
