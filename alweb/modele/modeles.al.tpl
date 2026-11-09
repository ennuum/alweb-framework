# Modèle de données de {{Nom}} : tables de l'ORM, migrations et schémas de validation.
# Les migrations sont appliquées au démarrage (database.migrate) et par `alweb migrate`. Ajoutez-en à la fin de
# MIGRATIONS (versions strictement croissantes) ; ne modifiez jamais une migration déjà appliquée.
use alweb.orm as orm
use serialization.schema as sch

MESSAGES := orm.table("messages", {"id": orm.pk(), "auteur": orm.text(40), "texte": orm.text(500), "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "messages", [MESSAGES])
]

MESSAGE := sch.object({"auteur": sch.string(1, 40), "texte": sch.string(1, 500)}, ["auteur", "texte"])
