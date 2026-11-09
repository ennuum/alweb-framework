# alweb.acme — certificat HTTPS obtenu et renouvelé tout seul (ACME, RFC 8555 : Let's Encrypt), sans certbot ni
# mandataire inverse. Activé par la configuration, sans code :
#
#   "server": {"port": 443, "tls": {"acme": {"domains": ["exemple.fr", "www.exemple.fr"],
#                                            "email": "admin@exemple.fr", "agree_tos": true}}}
#
# Clés de server.tls.acme :
#   domains      noms à couvrir (requis ; le premier nomme le dossier du certificat)
#   agree_tos    true : acceptation des conditions de l'autorité (requis, https://letsencrypt.org/repository/)
#   email        contact pour les avis d'expiration (facultatif)
#   directory    "letsencrypt" (défaut), "staging" (essais, certificats non reconnus) ou URL d'un annuaire ACME
#   dir          dossier des clés, certificats et défis ("acme" ; relatif à la racine du projet si ALWEB_ROOT)
#   http_port    port du défi http-01 et de la redirection vers HTTPS (80)
#   http_host    adresse d'écoute de ce port (celle du serveur HTTPS par défaut)
#   redirect     false : pas de redirection HTTP -> HTTPS sur http_port (404 hors défis)
#   renew_days   renouvellement quand il reste moins de renew_days jours (30)
#   ca_file      autorités de confiance pour joindre l'annuaire (tests : Pebble)
# server.tls.cert / key (facultatifs) : sinon <dir>/<premier nom>/cert.pem et key.pem.
#
# Au premier démarrage, un certificat d'attente auto-signé permet au serveur HTTPS de démarrer ; le vrai le
# remplace dès qu'il est délivré (relu à la connexion suivante, sans redémarrage). La demande tourne sur un fil :
# le service continue pendant la validation. Vérification au démarrage puis toutes les 12 heures ; après un échec,
# nouvel essai 5 min, 15 min, 1 h puis toutes les 6 h plus tard. En multi-processus (run_workers), c'est le maître
# qui écoute sur http_port et renouvelle ; les ouvriers voient le nouveau certificat par le disque.
from core use len, type, to_int
from collections use append
use os as _os
use io as _io
use time as _time
use string as _s
use asyncio as _aio
use thread.offload as _offload
use network.acme as _acme
use crypto.x509 as _x509
use web.server as _server
use web.http.response as _response
use alweb.errors as _err

const CHECK_EVERY := 43200.0
const RETRY := [300.0, 900.0, 3600.0, 21600.0]

# Annuaire ACME à partir de la valeur de server.tls.acme.directory.
func directory_url(value):
    if value == null or value == "" or value == "letsencrypt":
        return _acme.LETSENCRYPT
    if value == "staging" or value == "letsencrypt-staging":
        return _acme.LETSENCRYPT_STAGING
    if _s.starts_with(value, "https://") or _s.starts_with(value, "http://"):
        return value
    _err.alweb_error("server.tls.acme", "directory : « letsencrypt », « staging » ou une URL (obtenu " + str(value) + ")")

# Réglages lus dans la configuration (dict server.tls.acme) ; cert / key : chemins imposés ou null.
class Settings:
    func init(opts, cert=null, key=null, root=null):
        if type(opts) != "dict":
            _err.alweb_error("server.tls.acme", "un objet est attendu ({\"domains\": [...], \"agree_tos\": true})")
        d := opts["domains"] if "domains" in opts else null
        if type(d) == "str":
            d = [d]
        if type(d) != "list" or len(d) == 0:
            _err.alweb_error("server.tls.acme", "domains : au moins un nom est requis")
        for n in d:
            if type(n) != "str" or n == "" or _s.contains(n, "/") or _s.contains(n, " ") or _s.starts_with(n, "*"):
                _err.alweb_error("server.tls.acme", "nom invalide : " + str(n) + " (pas de joker avec le défi http-01)")
        if not ("agree_tos" in opts and opts["agree_tos"] == true):
            _err.alweb_error("server.tls.acme", "agree_tos : true est requis (conditions de l'autorité : https://letsencrypt.org/repository/)")
        self.domains = d
        self.directory = directory_url(opts["directory"] if "directory" in opts else null)
        self.email = opts["email"] if "email" in opts else null
        base := opts["dir"] if "dir" in opts and opts["dir"] != null else "acme"
        if root != null and not _os.is_absolute(base):
            base = _os.join(root, base)
        self.dir = base
        self.cert = cert if cert != null else _os.join(base, d[0] + "/cert.pem")
        self.key = key if key != null else _os.join(base, d[0] + "/key.pem")
        self.account_key = _os.join(base, "account.key")
        self.challenges = _os.join(base, "challenges")
        self.http_port = opts["http_port"] if "http_port" in opts else 80
        self.http_host = opts["http_host"] if "http_host" in opts else null
        self.redirect = not ("redirect" in opts and opts["redirect"] == false)
        self.renew_days = opts["renew_days"] if "renew_days" in opts else 30
        self.ca_file = opts["ca_file"] if "ca_file" in opts else null

    # Dossiers créés ; certificat d'attente auto-signé (7 jours) si aucun certificat n'est encore là, pour que le
    # serveur HTTPS puisse démarrer avant la première délivrance.
    func prepare():
        _os.mkdir_all(self.challenges)
        if _os.exists(self.cert) and _os.exists(self.key):
            return false
        pair := _x509.self_signed(self.domains[0], self.domains, 7)
        _acme.write_private(self.key, pair[1])
        _acme.write_public(self.cert, pair[0])
        return true

# Service ACME : écoute HTTP (défis, redirection) et renouvellement. step(délai) / shutdown() : service du maître
# de web.server.workers ; run() le fait tourner dans la boucle async (tâche de fond).
class Manager:
    func init(settings, https_port=443, host="0.0.0.0", quiet=false):
        self.s = settings
        self.https_port = https_port
        self.host = settings.http_host if settings.http_host != null else host
        self.quiet = quiet
        self.http = null
        self.job = null
        self.next_check = 0.0
        self.failures = 0
        self.last_error = null
        self.issued = 0
        self.stopped = false

    func log(text):
        if not self.quiet:
            print("alweb acme : " + text)
            _io.flush()

    # Ouvre le port des défis (sans lui, aucune validation possible : erreur immédiate et claire).
    func start():
        if self.s.prepare():
            self.log("certificat d'attente auto-signé écrit dans " + self.s.cert)
        if self.http == null and self.s.http_port != null and self.s.http_port != false:
            c := _server.config(self.host, self.s.http_port)
            c.access_log = false
            self.http = _server.Server((req) => self.handle(req), c)
            try:
                self.http.start()
            catch e:
                self.http = null
                _err.alweb_error("server.tls.acme", "impossible d'écouter sur le port " + str(self.s.http_port) + " (défi http-01) : " + str(e.message))
        return self

    func http_port():
        return self.http.port() if self.http != null else null

    # Requête sur le port HTTP : jeton de défi, sinon redirection permanente vers HTTPS (même hôte, même chemin).
    func handle(req):
        p := req.path()
        if _s.starts_with(p, _acme.CHALLENGE_PATH):
            tok := _s.slice(p, len(_acme.CHALLENGE_PATH), len(p))
            f := _os.join(self.s.challenges, tok)
            if _acme.valid_token(tok) and _os.exists(f):
                return _response.response(200, _io.read_raw(f), {"Content-Type": "application/octet-stream"})
            return _response.not_found()
        if not self.s.redirect:
            return _response.not_found()
        h := req.host()
        if h == null or h == "":
            h = self.s.domains[0]
        if _s.contains(h, ":"):
            h = "[" + h + "]"
        port := "" if self.https_port == 443 else ":" + str(self.https_port)
        return _response.redirect("https://" + h + port + req.target, 301)

    # Un tour : demande en cours relevée, vérification si l'heure est venue, puis attente sur le port HTTP.
    func step(timeout=0.05):
        self.tick()
        if self.http != null:
            self.http.step(timeout)
        elif timeout > 0:
            _time.sleep(timeout)

    func tick():
        if self.job != null:
            _offload.poll()
            if not _aio.done(self.job):
                return
            j := self.job
            self.job = null
            try:
                out := _aio.result(j)
                if out[0] != "ok":
                    raise(out[1], out[2])
                r := out[1]
                self.issued += 1
                self.failures = 0
                self.last_error = null
                self.next_check = _time.monotonic() + CHECK_EVERY
                self.log("certificat délivré pour " + _s.join(", ", r["domains"]) + " (valable jusqu'au " + r["not_after"] + ")")
            catch e:
                wait := RETRY[self.failures] if self.failures < len(RETRY) else RETRY[len(RETRY) - 1]
                self.failures += 1
                self.last_error = str(e.type) + " : " + str(e.message)
                self.next_check = _time.monotonic() + wait
                self.log("échec de la demande (" + self.last_error + ") ; nouvel essai dans " + str(to_int(wait / 60.0)) + " min")
            return
        if self.stopped or _time.monotonic() < self.next_check:
            return
        if not _acme.needs_renewal(self.s.cert, self.s.domains, self.s.renew_days):
            self.next_check = _time.monotonic() + CHECK_EVERY
            return
        self.log("demande d'un certificat pour " + _s.join(", ", self.s.domains) + " auprès de " + self.s.directory)
        s := self.s
        self.job = _offload.submit(_issue, [s.directory, s.account_key, s.cert, s.key, s.domains, s.challenges, s.email, s.ca_file, true, 300.0])

    # Vrai pendant une demande.
    func busy():
        return self.job != null

    # Tâche de fond de run() : un tour toutes les 50 ms au plus (le port HTTP attend sans bloquer la boucle).
    async func loop():
        while not self.stopped:
            self.step(0)
            await _aio.sleep(0.02 if self.job != null else 0.05)

    func shutdown():
        self.stopped = true
        if self.http != null:
            self.http.close()
            self.http = null

# Sur un fil : la demande complète ; l'erreur revient comme valeur (type et message intacts dans le journal).
func _issue(directory, account_key, cert, key, domains, challenges, email, ca_file, verify, max_wait):
    try:
        return ["ok", _acme.issue(directory, account_key, cert, key, domains, challenges, email, ca_file, verify, max_wait)]
    catch e:
        return ["err", str(e.type), str(e.message)]
