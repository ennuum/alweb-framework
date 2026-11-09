# Modèle de données de {{Nom}} (blog) : articles et demandes de contact.
# Les migrations sont appliquées au démarrage (database.migrate) et par `alweb migrate`. Ajoutez-en à la fin de
# MIGRATIONS (versions strictement croissantes) ; ne modifiez jamais une migration déjà appliquée.
use alweb.orm as orm
use serialization.schema as sch

# publie_le : AAAA-MM-JJ (tri et affichage « 8 novembre 2026 ») ; rubrique : identifiant de la catégorie dans les URL.
ARTICLES := orm.table("articles", {"id": orm.pk(), "slug": orm.text(160, unique=true), "titre": orm.text(160),
                                   "resume": orm.text(300, default=""), "contenu": orm.text(default=""),
                                   "categorie": orm.text(60), "rubrique": orm.text(60), "image": orm.text(300, default=""),
                                   "auteur": orm.text(80, default=""), "publie_le": orm.text(10), "publie": orm.boolean(default=true),
                                   "cree_le": orm.timestamp(auto=true)})
CONTACTS := orm.table("contacts", {"id": orm.pk(), "nom": orm.text(80), "courriel": orm.text(200), "message": orm.text(2000),
                                   "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "blog", [ARTICLES, CONTACTS])
]

CONTACT := sch.object({"nom": sch.string(1, 80), "courriel": sch.string(3, 200), "message": sch.string(1, 2000)}, ["nom", "courriel", "message"])

# Articles d'exemple, insérés au premier démarrage si la table est vide (réglage « exemples » : false pour ne pas
# les insérer). Remplacez-les par les vôtres.
EXEMPLES := [
    {"slug": "une-semaine-dans-les-alpes", "titre": "Une semaine dans les Alpes", "resume": "Itinéraire, refuges et conseils pour une première randonnée en altitude.", "contenu": "Partir en altitude se prépare : un sac léger, des chaussures déjà faites à vos pieds et une météo vérifiée la veille.\n\nNous avons suivi un itinéraire de refuge en refuge, avec des étapes de cinq à six heures de marche.\n\nLe troisième jour, le col a demandé une heure de plus que prévu : partir tôt reste la meilleure assurance.",
     "categorie": "Voyages", "rubrique": "voyages", "image": "/static/articles/montagne.svg", "auteur": "Awa Koné", "publie_le": "2026-11-08", "publie": true},
    {"slug": "le-cafe-filtre", "titre": "Le café filtre, sans se tromper", "resume": "Mouture, température, temps d'infusion : la méthode pas à pas.", "contenu": "Comptez 60 grammes de café par litre d'eau.\n\nL'eau doit frémir sans bouillir : autour de 94 degrés.\n\nVersez en trois fois et laissez infuser quatre minutes en tout.",
     "categorie": "Cuisine", "rubrique": "cuisine", "image": "/static/articles/cafe.svg", "auteur": "Awa Koné", "publie_le": "2026-11-02", "publie": true},
    {"slug": "apprendre-a-coder-a-40-ans", "titre": "Apprendre à coder à 40 ans", "resume": "Ce qui a marché, ce qui m'a fait perdre du temps, et les ressources à garder.", "contenu": "J'ai commencé par un petit projet utile plutôt que par un cours complet.\n\nÉcrire un peu chaque jour a compté davantage que les longues séances du week-end.",
     "categorie": "Carrière", "rubrique": "carriere", "image": "/static/articles/code.svg", "auteur": "Awa Koné", "publie_le": "2026-10-27", "publie": true},
    {"slug": "dix-livres-pour-l-hiver", "titre": "Dix livres pour l'hiver", "resume": "Romans, essais et une bande dessinée : notre sélection de saison.", "contenu": "Une sélection éclectique, à lire au chaud.\n\nChaque titre est accompagné de quelques lignes pour vous aider à choisir.",
     "categorie": "Lectures", "rubrique": "lectures", "image": "/static/articles/livres.svg", "auteur": "Awa Koné", "publie_le": "2026-10-19", "publie": true},
    {"slug": "aller-au-travail-a-velo", "titre": "Aller au travail à vélo", "resume": "Équipement, itinéraire et sécurité : six mois de trajets quotidiens.", "contenu": "Un bon éclairage et un antivol solide sont les deux achats à ne pas négliger.\n\nRepérez votre itinéraire un dimanche, sans la circulation.",
     "categorie": "Vie pratique", "rubrique": "vie-pratique", "image": "/static/articles/velo.svg", "auteur": "Awa Koné", "publie_le": "2026-10-11", "publie": true},
    {"slug": "un-potager-sur-un-balcon", "titre": "Un potager sur un balcon", "resume": "Bacs, semis et arrosage : récolter des tomates en ville.", "contenu": "Six heures de soleil par jour suffisent aux tomates cerises.\n\nChoisissez des bacs profonds d'au moins trente centimètres.",
     "categorie": "Maison", "rubrique": "maison", "image": "/static/articles/jardin.svg", "auteur": "Awa Koné", "publie_le": "2026-10-03", "publie": true}
]

async func exemples(db):
    n := await ARTICLES.query().count(db)
    if n > 0:
        return
    for a in EXEMPLES:
        await ARTICLES.insert(db, a)
