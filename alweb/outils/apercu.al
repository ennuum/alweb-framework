# Aperçu d'un dossier de thème (alweb theme preview) : chaque page avec les données de preview/data.json, et
# /_apercu : vues ordinateur, tablette et mobile côte à côte.
#   alexc run <paquet alweb>/outils/apercu.al -- <dossier du thème> [port]
from core use len, to_int
use os
use alweb.themes as themes

a := os.args()
dossier := os.absolute(a[0] if len(a) > 0 else ".")
port := to_int(a[1]) if len(a) > 1 else 8001
app := themes.preview_app(dossier)
print("Aperçu du thème « " + app.theme.manifest["name"] + " » : http://127.0.0.1:" + str(port) + "/_apercu  (Ctrl+C pour arrêter)")
await app.run("127.0.0.1", port, null, true)
