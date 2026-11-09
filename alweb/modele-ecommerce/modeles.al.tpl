# Modèle de données de {{Nom}} (boutique en ligne) : produits, commandes et leurs lignes, demandes de contact.
# Les migrations sont appliquées au démarrage (database.migrate) et par `alweb migrate`. Ajoutez-en à la fin de
# MIGRATIONS (versions strictement croissantes) ; ne modifiez jamais une migration déjà appliquée.
# Prix en centimes (entiers) : pas d'erreur d'arrondi.
use alweb.orm as orm
use serialization.schema as sch

PRODUITS := orm.table("produits", {"id": orm.pk(), "slug": orm.text(120, unique=true), "nom": orm.text(120),
                                   "resume": orm.text(300, default=""), "description": orm.text(default=""),
                                   "prix": orm.integer(), "prix_barre": orm.integer(null_ok=true), "image": orm.text(300, default=""),
                                   "categorie": orm.text(60), "rayon": orm.text(60), "stock": orm.integer(default=0),
                                   "vedette": orm.boolean(default=false), "cree_le": orm.timestamp(auto=true)})
COMMANDES := orm.table("commandes", {"id": orm.pk(), "nom": orm.text(80), "courriel": orm.text(200), "telephone": orm.text(40, default=""),
                                     "adresse": orm.text(500), "total": orm.integer(), "statut": orm.text(20, default="nouvelle"),
                                     "cree_le": orm.timestamp(auto=true)})
LIGNES := orm.table("lignes_commande", {"id": orm.pk(), "commande_id": orm.ref("commandes"), "produit_id": orm.ref("produits"),
                                        "nom": orm.text(120), "prix": orm.integer(), "quantite": orm.integer()})
CONTACTS := orm.table("contacts", {"id": orm.pk(), "nom": orm.text(80), "courriel": orm.text(200), "message": orm.text(2000),
                                   "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "boutique", [PRODUITS, COMMANDES, LIGNES, CONTACTS])
]

COMMANDE := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "telephone": sch.string(0, 40),
                        "adresse": sch.string(5, 500)}, ["nom", "courriel", "adresse"])
CONTACT := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "message": sch.string(1, 2000)}, ["nom", "courriel", "message"])

# Produits d'exemple, insérés au premier démarrage si la table est vide (réglage « exemples » : false pour ne pas
# les insérer). Remplacez-les par les vôtres.
EXEMPLES := [
    {"slug": "mug-ceramique", "nom": "Mug céramique", "resume": "Grès émaillé à la main, 35 cl.", "description": "Fabriqué dans un petit atelier.\nPasse au lave-vaisselle et au micro-ondes.",
     "prix": 1800, "image": "/static/produits/mug.svg", "categorie": "Cuisine", "rayon": "cuisine", "stock": 24, "vedette": true},
    {"slug": "sac-en-toile", "nom": "Sac en toile", "resume": "Un grand sac en coton épais, pour le marché comme pour la plage.", "description": "Coton biologique 340 g/m².\nAnses renforcées, poche intérieure.\nLavable en machine à 30 °C.",
     "prix": 3490, "prix_barre": 4200, "image": "/static/produits/sac.svg", "categorie": "Accessoires", "rayon": "accessoires", "stock": 3, "vedette": true},
    {"slug": "plante-interieur", "nom": "Plante d'intérieur", "resume": "Facile à vivre, livrée avec son pot en terre cuite.", "description": "Lumière indirecte, un arrosage par semaine.",
     "prix": 2450, "image": "/static/produits/plante.svg", "categorie": "Maison", "rayon": "maison", "stock": 10, "vedette": true},
    {"slug": "bougie-parfumee", "nom": "Bougie parfumée", "resume": "Cire végétale, 40 heures de combustion.", "description": "Parfum figue et bois de cèdre.\nMèche en coton.",
     "prix": 1690, "image": "/static/produits/bougie.svg", "categorie": "Maison", "rayon": "maison", "stock": 15, "vedette": true},
    {"slug": "carnet-ligne", "nom": "Carnet ligné", "resume": "A5, 160 pages, papier 90 g.", "description": "Couverture rigide, élastique et marque-page.",
     "prix": 1200, "image": "/static/produits/carnet.svg", "categorie": "Papeterie", "rayon": "papeterie", "stock": 40, "vedette": true},
    {"slug": "casquette-brodee", "nom": "Casquette brodée", "resume": "Coton lavé, taille réglable.", "description": "Broderie ton sur ton.\nAttache métal à l'arrière.",
     "prix": 2200, "prix_barre": 2750, "image": "/static/produits/casquette.svg", "categorie": "Accessoires", "rayon": "accessoires", "stock": 0, "vedette": true}
]

async func exemples(db):
    n := await PRODUITS.query().count(db)
    if n > 0:
        return
    for p in EXEMPLES:
        await PRODUITS.insert(db, p)
