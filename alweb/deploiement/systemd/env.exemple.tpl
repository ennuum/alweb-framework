# Variables d'environnement de {{Nom}} en production. Copiez ce fichier en {{dossier}}/.env (chmod 600) ;
# ne le versionnez jamais. Toute clé de config/ se remplace par ALWEB_<CLÉ> (« __ » sépare les niveaux).
ALWEB_SECRET_KEY={{secret}}
# ALWEB_DATABASE__URL=postgres://{{nom}}:motdepasse@127.0.0.1:5432/{{nom}}
# ALWEB_SERVER__WORKERS=4
# Courriels (alweb.mail, docs/COURRIEL.md) et adresse publique des liens qu'ils contiennent :
# ALWEB_MAIL__URL=smtp://identifiant:motdepasse@smtp.example.org:587
# ALWEB_SITE_URL=https://{{domaine}}
# Fichiers téléversés (alweb.storage, docs/FICHIERS.md) : dossier du serveur ou stockage compatible S3
# ALWEB_STORAGE__URL=file:{{dossier}}/media
# ALWEB_STORAGE__URL=s3://CLE:SECRET@s3.fr-par.scw.cloud/{{nom}}?region=fr-par
