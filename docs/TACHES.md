# Tâches de fond avec alweb

`alweb.jobs` fait le travail qui ne doit pas retarder une réponse, ou qui doit avoir lieu plus tard ou
régulièrement : envoyer un courriel, produire un rapport, relancer un compte, faire le ménage chaque nuit. Les
tâches sont rangées dans la base de l'application : elles survivent à un redémarrage, sont partagées par tous les
processus ouvriers (et plusieurs serveurs sur la même base), et une tâche en échec est réessayée.

## Mise en place

```al
use alweb.jobs as jobs

func creer(cfg, dossier="."):
    app := alweb.App("Blog")
    app.provide("db", ouvrir_base, "app", fermer_base)
    q := jobs.Queue(app, jobs.DatabaseStore(() => app.value("db")))      # table alweb_jobs, créée au besoin

    @q.task("rapport")
    async func rapport(payload, job):
        db := job.app.value("db")
        ...                                         # une exception : nouvel essai plus tard
```

`jobs.MemoryStore()` (le défaut) garde les tâches en mémoire : un seul processus, perdues à l'arrêt — pour les
tests et les petits outils. La base peut être SQLite, PostgreSQL ou ALEX DB.

`run` et `run_workers` font tourner la file dans chaque processus qui sert, après le démarrage de l'application
(la base est ouverte). `"jobs": {"worker": false}` dans la configuration d'un processus : il ne fait que mettre
en file (par exemple des serveurs web d'un côté, un processus dédié aux tâches de l'autre).

## Mettre en file

```al
await app.jobs.enqueue("rapport", {"id": 3})                                    # dès que possible
await app.jobs.enqueue("rapport", {"id": 3}, {"delay": 3600})                   # dans une heure
await app.jobs.enqueue("rapport", {"id": 3}, {"at": horodatage, "attempts": 3})
await app.jobs.enqueue("rappel", {"id": u}, {"delay": 86400, "key": "rappel-" + str(u)})
```

La charge (`payload`) est une valeur JSON : identifiants plutôt qu'objets (relisez la base dans la tâche, elle a pu
changer). `key` : une seule tâche en attente pour cette clé ; un second `enqueue` avec la même clé rend `null`
tant que la première n'est pas finie. `enqueue` rend l'identifiant de la tâche.

La fonction reçoit `job` : `id`, `name`, `attempt` (1 au premier essai), `max_attempts`, `last_error`, `app`.

## Échecs et nouveaux essais

Une exception (ou un dépassement du délai `timeout`, 10 min par défaut) compte un essai. Le suivant a lieu après
30 s, puis 60 s, 120 s… (au plus 6 h entre deux essais) ; après 5 essais la tâche est **abandonnée** et gardée
7 jours avec sa dernière erreur. Les tâches réussies sont gardées 1 jour.

Une tâche est exécutée **au moins une fois** : si le processus meurt en pleine exécution, elle repart après
`timeout`. Écrivez des tâches qu'on peut rejouer sans dommage (vérifier avant d'agir : « déjà envoyé ? »).

| Option de `Queue` | Défaut | Rôle |
|---|---|---|
| `concurrency` | 4 | tâches à la fois dans chaque processus |
| `poll` | 1 s | intervalle entre deux relevés de la file |
| `timeout` | 600 s | durée maximale d'une exécution |
| `attempts` | 5 | essais avant abandon (`attempts` d'`enqueue` pour une tâche) |
| `backoff` | 30 s | premier délai entre deux essais (doublé ensuite) |
| `keep_done` / `keep_failed` | 1 j / 7 j | conservation des tâches finies |
| `utc` | false | expressions cron en heure locale du serveur (true : UTC) |

## Tâches planifiées

```al
@q.every("menage", "30 3 * * *")                 # chaque jour à 3 h 30
async func menage(payload, job): ...

q.every("pouls", 300, verifier)                  # toutes les 5 minutes
q.every("lettre", "0 8 * * 1", lettre)           # le lundi à 8 h
```

Expressions cron à 5 champs (minute, heure, jour du mois, mois, jour de la semaine — dimanche = 0 ou 7) avec `*`,
listes `1,15`, plages `1-5` et pas `*/10`. Chaque créneau n'est exécuté qu'**une fois**, quel que soit le nombre de
processus : le premier qui le voit le met en file sous une clé propre au créneau, les autres trouvent la clé prise.
Les créneaux manqués pendant un arrêt ne sont pas rattrapés.

## Courriels

Quand l'application a une file, `mailer.send_later` et `send_template_later` y passent (tâche `alweb.mail`) : un
serveur SMTP en panne ne perd plus le message, il est réessayé. Le gabarit est rendu tout de suite (erreur visible
dans la requête), l'envoi se fait dans la tâche. `"mail": {"queue": false}` pour envoyer directement.

## En ligne de commande

```sh
alweb jobs                    # état de la file, tâches en attente et abandonnées (avec leur erreur)
alweb jobs --retry <id>       # nouvel essai d'une tâche abandonnée (--retry tout : toutes)
alweb jobs --run              # exécute ce qui est dû, puis s'arrête
alweb jobs --env prod
```

## Dans l'administration

Avec [`alweb.admin`](ADMIN.md), la page `/admin/_taches` montre la file (compteurs, tâches en attente, en cours,
abandonnées avec leur erreur, faites), la fiche de chaque tâche, et permet de réessayer ou de supprimer. Option
`"jobs"` d'`Admin` : `false` pour la retirer, une liste de rôles pour la restreindre.

## Tests

La file ne tourne pas seule pendant les tests : on la fait avancer.

```al
await inscrire(c, "alice")
await at.run_jobs(c.app)                         # exécute ce qui est dû (et les courriels de send_later)
assert_eq(at.outbox(c.app)[0].subject, "Confirmez votre adresse")

c.app.jobs.clock = () => time.time() + 86401     # « le lendemain » : les tâches différées d'un jour sont dues
await at.run_jobs(c.app)
```

`await q.stats()` (`pending`, `running`, `done`, `failed`), `await q.list("failed")`, `await q.get(id)` et
`await q.retry_failed(id)` servent aussi dans une page d'administration.
