# Modèle de données de {{Nom}} (portfolio) : projets et demandes de contact.
# Les migrations sont appliquées au démarrage (database.migrate) et par `alweb migrate`. Ajoutez-en à la fin de
# MIGRATIONS (versions strictement croissantes) ; ne modifiez jamais une migration déjà appliquée.
use alweb.orm as orm
use serialization.schema as sch

# rubrique : identifiant de la catégorie dans les URL ; images : liste d'adresses (galerie) ; ordre : tri à
# l'affichage (petit d'abord) ; vedette : sur la page d'accueil.
PROJETS := orm.table("projets", {"id": orm.pk(), "slug": orm.text(160, unique=true), "titre": orm.text(160),
                                 "resume": orm.text(300, default=""), "description": orm.text(default=""),
                                 "categorie": orm.text(60), "rubrique": orm.text(60), "client": orm.text(120, default=""),
                                 "annee": orm.integer(null_ok=true), "image": orm.text(300, default=""), "images": orm.json(default=[]),
                                 "lien": orm.text(300, default=""), "ordre": orm.integer(default=0), "vedette": orm.boolean(default=false),
                                 "cree_le": orm.timestamp(auto=true)})
CONTACTS := orm.table("contacts", {"id": orm.pk(), "nom": orm.text(80), "courriel": orm.text(200), "message": orm.text(2000),
                                   "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "portfolio", [PROJETS, CONTACTS])
]

CONTACT := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "message": sch.string(1, 2000)}, ["nom", "courriel", "message"])

# Projets d'exemple, insérés au premier démarrage si la table est vide (réglage « exemples » : false pour ne pas
# les insérer). Remplacez-les par les vôtres.
EXEMPLES := [
    {"slug": "atelier-mira", "titre": "Atelier Mira", "resume": "Logo, couleurs et papeterie pour un atelier de céramique.",
     "description": "L'atelier voulait une identité aussi simple que ses pièces : un monogramme tracé d'un seul geste, une palette tirée des émaux et une typographie sobre.\n\nLe système se décline sur les étiquettes, le papier à en-tête et le site.",
     "categorie": "Identité visuelle", "rubrique": "identite", "client": "Atelier Mira, Lyon", "annee": 2026, "image": "/static/projets/identite.svg",
     "images": ["/static/projets/identite.svg", "/static/projets/edition.svg"], "ordre": 1, "vedette": true},
    {"slug": "festival-lumen", "titre": "Festival Lumen", "resume": "Série d'affiches pour un festival de musique électronique.",
     "description": "Trois affiches, une par soirée, construites sur la même grille.\n\nLes formes simples restent lisibles de loin, sur les murs comme sur les écrans.",
     "categorie": "Affiche", "rubrique": "affiche", "client": "Association Lumen", "annee": 2026, "image": "/static/projets/affiche.svg", "ordre": 2, "vedette": true},
    {"slug": "appli-velo", "titre": "Appli Vélo+", "resume": "Application de location de vélos : parcours, écrans et prototype.",
     "description": "Des entretiens avec des usagers ont guidé un parcours de location en trois écrans.\n\nLe prototype a servi aux tests avant le développement.",
     "categorie": "Interface", "rubrique": "interface", "client": "Vélo+", "annee": 2025, "image": "/static/projets/appli.svg", "ordre": 3, "vedette": true},
    {"slug": "revue-terrain", "titre": "Revue Terrain", "resume": "Maquette d'une revue trimestrielle de 96 pages.",
     "description": "Une grille à douze colonnes, deux familles de caractères et des ouvertures de rubrique en pleine page.",
     "categorie": "Édition", "rubrique": "edition", "client": "Éditions Terrain", "annee": 2025, "image": "/static/projets/edition.svg", "ordre": 4, "vedette": true},
    {"slug": "the-sauvage", "titre": "Thé Sauvage", "resume": "Boîtes et étiquettes pour une gamme de thés bio.",
     "description": "Une couleur par infusion, des illustrations au trait et des boîtes réutilisables.",
     "categorie": "Packaging", "rubrique": "packaging", "client": "Thé Sauvage", "annee": 2024, "image": "/static/projets/packaging.svg", "ordre": 5},
    {"slug": "studio-rosa", "titre": "Studio Rosa", "resume": "Site vitrine d'un studio de danse, réservation en ligne.",
     "description": "Un site léger, centré sur le planning des cours et la réservation.",
     "categorie": "Site web", "rubrique": "site-web", "client": "Studio Rosa", "annee": 2024, "image": "/static/projets/site.svg",
     "lien": "https://exemple.fr", "ordre": 6}
]

async func exemples(db):
    n := await PROJETS.query().count(db)
    if n > 0:
        return
    for p in EXEMPLES:
        await PROJETS.insert(db, p)
