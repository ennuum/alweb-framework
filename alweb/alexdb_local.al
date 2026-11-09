# alweb.alexdb_local — serveur ALEX DB embarqué dans l'application (URL alexdb+local:<dossier>[?base=nom]).
#
#   use alweb.alexdb_local                         # une ligne dans le programme : active alexdb+local:
#   db := alweb.database("alexdb+local:donnees")   # base « app » ; ?base=blog pour une autre
#
# Le projet AlexDB doit être dans les sources du projet (alex.toml, section [package] : sources = ["…/AlexDB"]) :
# ce module importe son moteur et son serveur. Tout est écrit en ALEX : l'exécutable natif (`alweb build
# --native`) emporte la base avec lui, sans SQLite ni service à installer.
#
# Un processus : le serveur tourne dans l'application, servi par une tâche de la boucle async. Plusieurs processus
# (app.run_workers) : le maître l'héberge pendant qu'il surveille les ouvriers, qui s'y connectent par 127.0.0.1 ;
# un ouvrier relancé (ou rechargé en développement) retrouve la base telle quelle.
#
# Premier lancement : <dossier> est créé avec un super-utilisateur « alweb » et un mot de passe tiré au hasard,
# gardé dans <dossier>/alweb-local.json (lisible par le seul propriétaire). Le serveur n'écoute que sur
# 127.0.0.1, sur un port libre ; toute connexion s'authentifie. Journal : <dossier>/alexdb.log.
# Mêmes garanties que le serveur ALEX DB (transactions, journal WAL, récupération) : voir AlexDB/docs.

from core use len
use os as _os
use io as _io
use json as _json
use security.random_secure as _rnd
use alexdb.core.config as _cfg
use alexdb.server.server as _srv
use alweb.alexdb as _axdb
use alweb.errors as _err

const USER := "alweb"
const CREDENTIALS := "alweb-local.json"

class LocalServer:
    func init(directory):
        self.dir = directory
        self.pumping = false
        cfg := _cfg.defaults()
        cfg["data_dir"] = directory
        cfg["host"] = "127.0.0.1"
        cfg["port"] = 0
        cfg["idle_timeout"] = 86400.0      # connexions gardées par les réserves des ouvriers
        cfg["max_connections"] = 512
        cfg["log_file"] = _os.join(directory, "alexdb.log")
        self.config = cfg
        cred := _os.join(directory, CREDENTIALS)
        if _os.exists(cred):
            d := _json.parse(_io.read_file(cred))
            self.user = d["user"]
            self.password = d["password"]
        else:
            if _os.exists(_os.join(directory, _srv.ADMIN_DB + ".adb")):
                _err.alweb_error("alexdb_local", directory + " contient déjà un serveur ALEX DB sans " + CREDENTIALS + " : choisir un autre dossier, ou y écrire {\"user\": …, \"password\": …}")
            _os.mkdir_all(directory)
            self.user = USER
            self.password = _rnd.token_hex(24)
            _srv.init_dir(cfg, self.user, self.password)
            _io.write_file(cred, _json.stringify({"user": self.user, "password": self.password}))
            try:
                _os.chmod(cred, 384)                # 0600
            catch e:
                ignored := e
        self.server = _srv.Server(cfg)
        self.port = self.server.start()

    # URL de la base d'administration (super-utilisateur) ; alweb.alexdb.with_database en tire celle d'une base.
    func admin_url():
        return "alexdb://" + self.user + ":" + self.password + "@127.0.0.1:" + str(self.port) + "/" + _srv.ADMIN_DB

    # Crée la base si elle manque (directement, sans passer par le réseau : le serveur ne peut pas se répondre à
    # lui-même) ; l'utilisateur « alweb » en est super-utilisateur (migrations).
    func ensure(name):
        if not _os.exists(self.server.db_path(name)):
            self.server.create_database(name, self.user)
        return name

    # Un tour de boucle du serveur (au plus timeout secondes d'attente) : web.server.workers l'appelle dans le
    # maître, alweb.alexdb._pump dans un processus seul.
    func step(timeout):
        self.server.step(timeout)

    func shutdown():
        self.pumping = false
        self.server.shutdown()

func _make(directory):
    return LocalServer(directory)

_axdb.register_local(_make)
