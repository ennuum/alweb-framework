# Courriels avec alweb

`alweb.mail` envoie des courriels depuis une application : SMTP (STARTTLS ou TLS implicite, authentification),
affichage dans la console en développement, boîte en mémoire pour les tests, fichiers `.eml`. Les corps s'écrivent
en gabarits (texte et HTML). `alweb.auth` fournit les jetons des liens « confirmer votre adresse » et « mot de passe
oublié ». Le tout est écrit en ALEX : il fonctionne aussi dans l'exécutable natif (STARTTLS par `network.tls13`).

## Configuration

```json
{"site_url": "https://blog.example.org",
 "mail": {"url": "smtp://noreply%40example.org:mot-de-passe@smtp.example.org:587",
          "from": "Blog <noreply@example.org>"}}
```

En production, gardez le mot de passe hors du dépôt : `ALWEB_MAIL__URL=smtp://…` et `ALWEB_SITE_URL=https://…`
dans l'environnement (ou `.env`, droits 600). Les caractères spéciaux de l'identifiant et du mot de passe
s'écrivent en `%XX` (`@` → `%40`, `:` → `%3A`).

| `mail.url` | Envoi |
|---|---|
| `smtp://hôte[:port]` | port 587 par défaut ; STARTTLS dès que le serveur le propose, jamais d'authentification en clair. `?starttls=true` exige TLS, `?starttls=false` pour un relais local sans TLS (port 25, sans identifiants), `?timeout=10`, `?verify=false` (tests seulement) |
| `smtps://hôte[:port]` | TLS dès la connexion (465) |
| `console` | message affiché dans le terminal ; **défaut en mode debug** sans réglage |
| `memory` | gardé dans `app.mail().outbox` : pour les tests (`at.outbox(app)`) |
| `file:dossier` | un fichier `.eml` par message (à ouvrir dans un client de messagerie) |

Autres clés : `from` (expéditeur, requis pour SMTP), `reply_to`, `timeout`, `ca_file` (autorité d'un serveur de
test). Sans `mail.url` hors mode debug, un envoi lève une erreur : rien ne part en silence.

`site_url` fait les liens absolus des courriels (`mail.absolute_url(req, chemin)`). En mode debug, à défaut,
l'hôte de la requête est pris ; en production c'est refusé, car l'en-tête `Host` vient du client : un lien de
réinitialisation pourrait pointer vers le site d'un attaquant.

## Envoyer

```al
use alweb
use alweb.mail as mail

m := alweb.mailer(req)                                     # ou app.mail()
await m.send("alice@example.org", "Bonjour", "Texte brut", "<p>Version <b>HTML</b></p>")
await m.send(["a@x.org", "b@x.org"], "Rapport", "Ci-joint.", null, {"cc": "chef@x.org", "bcc": ["archive@x.org"], "reply_to": "support@x.org", "headers": {"X-Campagne": "nov"}, "attachments": ["rapport.pdf", ["notes.txt", "contenu", "text/plain"]]})
m.send_later(…)                                            # sans attendre : une erreur est journalisée, pas levée
```

`send` rend le `Message-ID`. L'envoi SMTP part sur un fil (`thread.offload`) : la boucle du serveur continue
pendant la conversation avec le serveur de courrier. Les adresses sont vérifiées (une adresse saisie par un
visiteur ne peut glisser ni destinataire ni en-tête), l'objet doit tenir sur une ligne ; `mail.valid_address(texte)`
sert à valider un champ de formulaire. Si le serveur refuse tous les destinataires : `SmtpError` ; certains
seulement : journalisé. `send_later` convient aux courriels d'une requête web (inscription) : un serveur de courrier
en panne ne la fait pas échouer. Si l'application a une file de tâches ([`alweb.jobs`](TACHES.md)), `send_later`
y passe : le message est gardé en base et réessayé jusqu'à ce qu'il parte (`"mail": {"queue": false}` pour
envoyer directement) ; sans file, un envoi en échec est seulement journalisé.

## Gabarits

```al
await m.send_template(u["courriel"], "Confirmez votre adresse", "confirmation", {"nom": u["nom"], "lien": lien})
```

lit `templates/emails/confirmation.txt` (texte, **sans** échappement HTML) et `templates/emails/confirmation.html`
(échappé comme les pages) ; l'un des deux suffit. Variables toujours là : `app_name`, `site_url`, `url_for`.

```
Bonjour {{ nom }},

Pour confirmer l'adresse de votre compte sur {{ app_name }}, ouvrez ce lien :

{{ lien }}
```

## Liens à usage unique

```al
use alweb.auth as auth
secret := cfg.require("secret_key")

# confirmation d'adresse (3 jours) : le jeton porte l'adresse, il ne confirme que celle-là
jeton := auth.confirm_token(secret, u["id"], u["courriel"])
c := auth.read_confirm_token(secret, jeton)               # {"id", "email"} ou null

# mot de passe oublié (1 heure) : le jeton porte une empreinte du mot de passe haché du moment
jeton := auth.reset_token(secret, u["id"], u["mdp"])
id := auth.reset_token_user(secret, jeton)                # null : faux ou expiré
auth.check_reset_token(secret, jeton, u["mdp"])           # faux une fois le mot de passe changé
```

Rien n'est enregistré en base : les jetons sont signés (HMAC-SHA256 sous la clé secrète), datés et liés à leur
usage (un jeton de confirmation ne sert pas de jeton de réinitialisation). Changer la clé secrète les invalide tous.
`auth.signed_token(secret, usage, données, durée)` / `auth.read_token(secret, usage, jeton)` pour d'autres liens
(désabonnement, invitation).

Le blog du tutoriel montre le parcours complet (`docs/tutoriel/blog/comptes.al`, étape 9) : adresse demandée à
l'inscription et confirmée par lien, rappel tant qu'elle ne l'est pas, « mot de passe oublié » qui répond pareil
que l'adresse soit connue ou non (on ne révèle pas qui a un compte) et limité à 5 demandes par quart d'heure.

## Tests

Profil test : `"mail": {"url": "memory"}` et un `site_url` fictif.

```al
use alweb.testing as at

m := at.outbox(app)[0]                       # alweb.mail.Sent : to, cc, bcc, sender, subject, text, html, raw
assert_eq(m.to, ["alice@blog.test"])
lien := at.links(m.text)[0]                  # liens http(s) du corps
at.outbox(app, true)                         # lit puis vide la boîte
```

## Fournisseurs

Tout serveur SMTP de soumission convient : celui de l'hébergeur, ou un service d'envoi (Brevo, Mailjet, Postmark,
Amazon SES, Mailgun…) avec ses identifiants SMTP, port 587. Pour que les messages arrivent ailleurs que dans les
indésirables, le domaine de l'expéditeur doit publier SPF et DKIM (et idéalement DMARC) : c'est un réglage DNS
chez le fournisseur, pas dans alweb.
