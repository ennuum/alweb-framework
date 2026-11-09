# Modèle de données du blog : tables de l'ORM, migrations et schémas de validation (étape 2 du tutoriel).
use alweb.orm as orm
use serialization.schema as sch

UTILISATEURS := orm.table("utilisateurs", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(), "roles": orm.json(default=["auteur"]), "cree_le": orm.timestamp(auto=true), "courriel": orm.text(254, true), "confirme": orm.boolean(false)})
ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(120), "texte": orm.text(), "auteur_id": orm.ref("utilisateurs"), "cree_le": orm.timestamp(auto=true)})
COMMENTAIRES := orm.table("commentaires", {"id": orm.pk(), "article_id": orm.ref("articles"), "auteur_id": orm.ref("utilisateurs"), "texte": orm.text(2000), "cree_le": orm.timestamp(auto=true)})

MIGRATIONS := [
    orm.migration(1, "tables", [UTILISATEURS, ARTICLES, COMMENTAIRES]),
    orm.migration(2, "index", ["CREATE INDEX articles_auteur ON articles (auteur_id)", "CREATE INDEX commentaires_article ON commentaires (article_id)"]),
    # étape 9 : adresse de courriel (une base créée avant reçoit les colonnes ; une base neuve les a déjà)
    orm.migration(3, "courriel", [orm.add_column(UTILISATEURS, "courriel"), orm.add_column(UTILISATEURS, "confirme"), orm.index("utilisateurs_courriel", "utilisateurs", ["courriel"], true)])
]

COMPTE := sch.object({"nom": sch.string(3, 40), "courriel": sch.string(3, 254), "mdp": sch.string(8, 200)}, ["nom", "courriel", "mdp"])
OUBLI := sch.object({"courriel": sch.string(1, 254)}, ["courriel"])
NOUVEAU_MDP := sch.object({"mdp": sch.string(8, 200)}, ["mdp"])
IDENTIFIANTS := sch.object({"nom": sch.string(1, 40), "mdp": sch.string(1, 200)}, ["nom", "mdp"])
ARTICLE := sch.object({"titre": sch.string(1, 120), "texte": sch.string(1, 50000)}, ["titre", "texte"])
COMMENTAIRE := sch.object({"texte": sch.string(1, 2000)}, ["texte"])

# L'auteur de l'article et les administrateurs peuvent le modifier.
func peut_modifier(user, article):
    return user != null and article != null and (user["id"] == article["auteur_id"] or "admin" in user["roles"])
