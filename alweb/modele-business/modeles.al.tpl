# Modèle de données de {{Nom}} (site vitrine) : demandes de contact.
# Les migrations sont appliquées au démarrage (database.migrate) et par `alweb migrate`. Ajoutez-en à la fin de
# MIGRATIONS (versions strictement croissantes) ; ne modifiez jamais une migration déjà appliquée.
use alweb.orm as orm
use serialization.schema as sch

CONTACTS := orm.table("contacts", {"id": orm.pk(), "nom": orm.text(80), "courriel": orm.text(200), "message": orm.text(2000),
                                   "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "contacts", [CONTACTS])
]

CONTACT := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "message": sch.string(1, 2000)}, ["nom", "courriel", "message"])
