# alweb.mail — envoi de courriels : SMTP (STARTTLS ou TLS implicite, authentification), console, mémoire (tests),
# fichiers .eml ; messages texte et HTML écrits en gabarits. L'envoi SMTP part sur un fil : le serveur continue.
#
# Configuration (clé « mail ») :
#   {"mail": {"url": "smtp://utilisateur:mot%20de%20passe@smtp.exemple.org:587", "from": "Blog <noreply@exemple.org>"}}
#   url      smtp://hôte[:port]   587 par défaut, STARTTLS dès que le serveur le propose ; l'authentification
#                                 n'est jamais faite en clair (?starttls=true l'exige, ?starttls=false pour un relais
#                                 local sans TLS, ?timeout=10, ?verify=false)
#            smtps://hôte[:port]  TLS dès la connexion (465)
#            console              message affiché (développement : défaut en mode debug)
#            memory               gardé dans mailer.outbox (tests)
#            file:dossier         un fichier .eml par message
#   from     expéditeur (requis pour SMTP)    reply_to   adresse de réponse    ca_file   autorités (tests)
# ALWEB_MAIL__URL=… et ALWEB_MAIL__FROM=… en production (le mot de passe hors du dépôt).
#
#   m := alweb.mailer(req)                   # ou app.mail()
#   await m.send("ami@exemple.org", "Bonjour", "Texte", "<p>HTML</p>")
#   await m.send_template(u["courriel"], "Confirmez votre adresse", "confirmation", {"lien": lien})
#       # gabarits emails/confirmation.txt (texte, sans échappement) et/ou emails/confirmation.html
#   m.send_later(...)                        # sans attendre : erreur journalisée, pas levée ; par la file de
#                                            # tâches si l'application en a une (alweb.jobs : réessayé)
#   lien := mail.absolute_url(req, "/reinitialisation/" + jeton)    # site_url de la configuration
#
# Options (dict) : cc, bcc, reply_to, headers ({nom: valeur}), attachments ([chemin] ou [[nom, octets, type]]).
# Liens absolus : la clé site_url (« https://blog.exemple.org ») fait foi ; en mode debug, à défaut, l'hôte de la
# requête. En production sans site_url : erreur, car l'en-tête Host vient du client (lien de réinitialisation
# détourné vers un autre site).
from core use len, type, to_int, to_float
from collections use append, keys
use os as _os
use io as _io
use time as _time
use string as _s
use asyncio as _aio
use thread.offload as _offload
use network.email as _email
use network.smtp as _smtp
use network.url as _url
use network.encoding as _enc
use alweb.errors as _err
use alweb.templates as _tpl

# Un message envoyé (backend memory) : champs lus par les tests.
class Sent:
    func init(message, raw):
        self.message = message
        self.to = _addresses(message.to)
        self.cc = _addresses(message.cc)
        self.bcc = _addresses(message.bcc)
        self.sender = message.sender.email
        self.subject = message.subject
        self.text = message.text
        self.html = message.html
        self.raw = raw
        self.message_id = message.message_id

    func str():
        return "Sent(" + self.subject + " -> " + _s.join(", ", self.to) + ")"

func _addresses(lst):
    out := []
    for a in lst:
        append(out, a.email)
    return out

class Mailer:
    # options : dict de la clé mail ; app : alweb.App (gabarits, nom, site_url) ou null.
    func init(options=null, debug=false, app=null):
        o := options if options != null else {}
        if type(o) != "dict":
            _err.alweb_error("mail", "un objet est attendu ({\"url\": …, \"from\": …})")
        self.app = app
        self.debug = debug
        url := o["url"] if "url" in o and o["url"] != null else ""
        if url == "":
            url = "console" if debug else ""
        self.url = url
        self.sender = o["from"] if "from" in o else null
        self.reply_to = o["reply_to"] if "reply_to" in o else null
        self.ca_file = o["ca_file"] if "ca_file" in o else null
        self.queue = not ("queue" in o and o["queue"] == false)
        self.outbox = []
        self.sent = 0
        self.failed = 0
        self.text_env = null
        self.smtp = null
        self.dir = null
        self.kind = self._parse(url, o)

    func _parse(url, o):
        if url == "":
            return "none"
        if url == "console" or url == "memory":
            return url
        if _s.starts_with(url, "file:"):
            self.dir = _s.slice(url, 5, len(url))
            if self.dir == "":
                _err.alweb_error("mail", "file: demande un dossier (file:build/courriels)")
            return "file"
        u := null
        try:
            u = _url.parse(url)
        catch e:
            _err.alweb_error("mail", "url illisible : " + str(e.message))
        if u.scheme != "smtp" and u.scheme != "smtps":
            _err.alweb_error("mail", "url : smtp://, smtps://, console, memory ou file:dossier (obtenu " + u.scheme + "://)")
        if u.host == null or u.host == "":
            _err.alweb_error("mail", "url : hôte manquant")
        q := _url.parse_qs(u.query) if u.query != null else {}
        starttls := "auto"
        if "starttls" in q:
            v := q["starttls"][0]
            starttls = true if v == "true" or v == "1" else (false if v == "false" or v == "0" else "auto")
        ssl := u.scheme == "smtps"
        timeout := to_float(q["timeout"][0]) if "timeout" in q else (to_float(o["timeout"]) if "timeout" in o else 30.0)
        port := u.port if u.port != null else (465 if ssl else 587)
        self.smtp = {"host": u.host, "port": port, "ssl": ssl, "starttls": false if ssl else starttls, "user": u.username, "password": u.password, "timeout": timeout, "verify": not ("verify" in q and q["verify"][0] == "false")}
        return "smtp"

    # Ce qui sera fait d'un message (journal de démarrage, diagnostics).
    func describe():
        if self.kind == "smtp":
            s := self.smtp
            return ("smtps://" if s["ssl"] else "smtp://") + s["host"] + ":" + str(s["port"])
        if self.kind == "file":
            return "file:" + self.dir
        return self.kind

    # network.email.EmailMessage prêt à partir (expéditeur par défaut, options).
    func message(to, subject, text=null, html=null, options=null):
        o := options if options != null else {}
        sender := o["from"] if "from" in o else self.sender
        if sender == null:
            sender = "alweb <noreply@alweb.invalid>" if self.kind != "smtp" else null
        if sender == null:
            _err.alweb_error("mail", "expéditeur manquant : clé mail.from (« Site <noreply@exemple.org> »)")
        m := _email.EmailMessage(sender, to, subject, text, _opt(o, "cc"), _opt(o, "bcc"))
        # adresses vérifiées (une adresse saisie par un visiteur ne glisse ni destinataire ni en-tête)
        for lst in [m.to, m.cc, m.bcc, [m.sender]]:
            for a in lst:
                if not _email.is_valid_email(a.email):
                    _err.alweb_error("mail", "adresse invalide : " + str(a.email))
        if len(m.to) + len(m.cc) + len(m.bcc) == 0:
            _err.alweb_error("mail", "aucun destinataire")
        if _s.contains(subject, "\n") or _s.contains(subject, "\r"):
            _err.alweb_error("mail", "objet sur plusieurs lignes refusé")
        if html != null:
            m.set_html(html)
        rt := o["reply_to"] if "reply_to" in o else self.reply_to
        if rt != null:
            m.reply_to = _email.parse_address_list(rt)
        if "locale" in o and o["locale"] != null and _hv_token(o["locale"]):
            m.add_header("Content-Language", o["locale"])
        if "headers" in o:
            for k in keys(o["headers"]):
                m.add_header(k, o["headers"][k])
        if "attachments" in o:
            for a in o["attachments"]:
                if type(a) == "list":
                    m.attach(a[0], a[1], a[2] if len(a) > 2 else null)
                else:
                    m.attach(a)
        return m

    # Envoie et rend le Message-ID (tâche à attendre). Tous les destinataires refusés : SmtpError ; certains
    # seulement : journalisé.
    async func send(to, subject, text=null, html=null, options=null):
        m := null
        try:
            m = self.message(to, subject, text, html, options)
        catch e:
            self.failed += 1
            raise(e.type, e.message)
        return await self.deliver(m)

    # Comme send, corps rendus par les gabarits emails/<name>.txt et emails/<name>.html (l'un des deux au moins).
    # options["locale"] : langue du courriel (alweb.i18n) : _(), dates, nombres et gabarit emails/<name>.<langue>.txt
    # s'il existe.
    async func send_template(to, subject, name, context=null, options=null):
        r := self.render(name, context, _opt(options if options != null else {}, "locale"))
        return await self.send(to, subject, r[0], r[1], options)

    # Sans attendre : la tâche est rendue, une erreur est journalisée (et comptée dans failed) au lieu d'être levée.
    # Avec une file de tâches (alweb.jobs, app.jobs) : mis en file (tâche « alweb.mail »), réessayé en cas d'échec,
    # sauf mail.queue = false. La tâche rendue donne l'identifiant de la tâche (ou le Message-ID sans file).
    func send_later(to, subject, text=null, html=null, options=null):
        if self._queued():
            return self.app.jobs.track(self._later(self._enqueue(to, subject, text, html, options), subject))
        return self._later(self.send(to, subject, text, html, options), subject)

    func send_template_later(to, subject, name, context=null, options=null):
        if self._queued():
            r := self.render(name, context, _opt(options if options != null else {}, "locale"))   # erreur de gabarit visible ici
            return self.app.jobs.track(self._later(self._enqueue(to, subject, r[0], r[1], options), subject))
        return self._later(self.send_template(to, subject, name, context, options), subject)

    func _queued():
        return self.queue and self.app != null and self.app.jobs != null

    async func _enqueue(to, subject, text, html, options):
        self.message(to, subject, text, html, options)       # adresses vérifiées avant la mise en file
        return await self.app.jobs.enqueue("alweb.mail", _jobs_payload(to, subject, text, html, options))

    async func _later(task, subject):
        try:
            return await task
        catch e:
            print("alweb mail : échec de l'envoi de « " + subject + " » : " + str(e.type) + " : " + str(e.message))
            _io.flush()
            return null

    # [texte, html] rendus (null pour un gabarit absent) ; contexte : app_name, url_for, site_url en plus. locale
    # (avec alweb.i18n) : _(), _n(), filtres de dates et nombres dans cette langue ; emails/<name>.<langue>.txt
    # (puis .<langue de base>.txt) passe avant emails/<name>.txt, de même pour .html.
    func render(name, context=null, locale=null):
        env := self._env()
        if env == null:
            _err.alweb_error("mail", "gabarits de courriel : appeler app.use_templates(dossier) (emails/" + name + ".txt / .html)")
        ctx := {"app_name": self.app.name if self.app != null else "alweb", "site_url": self._site_url()}
        names := [name]
        if self.app != null and self.app.i18n != null:
            tr := self.app.i18n.translator(locale)
            extra := self.app.i18n.context(tr)
            for k in keys(extra):
                ctx[k] = extra[k]
            b := _base_lang(tr.locale)
            names = [name + "." + tr.locale] + ([name + "." + b] if b != tr.locale else []) + [name]
        if context != null:
            for k in keys(context):
                ctx[k] = context[k]
        txt := null
        htm := null
        for nm in names:
            if txt == null and _exists(env, "emails/" + nm + ".txt"):
                txt = self._text_env(env).render("emails/" + nm + ".txt", ctx)
            if htm == null and _exists(env, "emails/" + nm + ".html"):
                htm = env.render("emails/" + nm + ".html", ctx)
        if txt == null and htm == null:
            _err.alweb_error("mail", "gabarit de courriel introuvable : emails/" + name + ".txt ou .html")
        return [txt, htm]

    func _env():
        return self.app.templates if self.app != null else null

    # Gabarits texte : même dossier, mêmes fonctions, sans échappement HTML.
    func _text_env(env):
        if self.text_env == null:
            t := _tpl.Environment(env.directories, env.auto_reload, false)
            for k in keys(env.globals):
                t.globals[k] = env.globals[k]
            for k in keys(env.filters):
                t.filters[k] = env.filters[k]
            for k in keys(env.sources):
                t.sources[k] = env.sources[k]
            self.text_env = t
        return self.text_env

    func _site_url():
        if self.app != null and self.app.config != null:
            v := self.app.config.get("site_url")
            if v != null and v != "":
                return _strip_slash(v)
        return null

    # Envoie un EmailMessage déjà construit ; rend son Message-ID.
    async func deliver(m):
        raw := m.to_bytes()
        try:
            if self.kind == "memory":
                append(self.outbox, Sent(m, raw))
            elif self.kind == "console":
                print(_console_text(m))
                _io.flush()
            elif self.kind == "file":
                _os.mkdir_all(self.dir)
                n := str(to_int(_time.time() * 1000)) + "-" + str(self.sent + self.failed + 1)
                _io.write_file(_os.join(self.dir, n + ".eml"), raw)
            elif self.kind == "smtp":
                s := self.smtp
                refused := await _offload.run(_smtp_send, [s["host"], s["port"], s["ssl"], s["starttls"], s["user"], s["password"], s["timeout"], s["verify"], self.ca_file, m.sender.email, m.recipients(), raw])
                if len(refused) > 0:
                    print("alweb mail : destinataires refusés : " + _s.join(", ", refused))
                    _io.flush()
            else:
                _err.alweb_error("mail", "aucun envoi configuré : clé mail.url (smtp://…, console, memory, file:dossier)")
        catch e:
            self.failed += 1
            raise(e.type, e.message)
        self.sent += 1
        return m.message_id

# Fil d'envoi : arguments simples seulement (rien de partagé avec la boucle).
func _smtp_send(host, port, ssl, starttls, user, password, timeout, verify, ca_file, sender, recipients, raw):
    c := _smtp.SmtpClient(host, port, ssl, starttls, timeout, null, verify, ca_file)
    try:
        if user != null and user != "":
            c.login(user, password if password != null else "")
        refused := c.send(sender, recipients, raw)
        c.quit()
        out := []
        for a in keys(refused):
            append(out, a + " (" + refused[a].str() + ")")
        return out
    catch e:
        c.close()
        raise(e.type, e.message)

func _console_text(m):
    lines := ["", "──── courriel (alweb mail : console) ────", "De : " + m.sender.str(), "À : " + _s.join(", ", _addresses(m.to))]
    if len(m.cc) > 0:
        append(lines, "Cc : " + _s.join(", ", _addresses(m.cc)))
    if len(m.bcc) > 0:
        append(lines, "Cci : " + _s.join(", ", _addresses(m.bcc)))
    append(lines, "Objet : " + m.subject)
    append(lines, "")
    append(lines, m.body_text())
    if m.html != null and m.text != null:
        append(lines, "[+ version HTML, " + str(len(m.html)) + " caractères]")
    if len(m.attachments) > 0:
        append(lines, "[+ " + str(len(m.attachments)) + " pièce(s) jointe(s)]")
    append(lines, "─────────────────────────────────────────")
    return _s.join("\n", lines)

func _exists(env, name):
    return env.exists(name)

func _opt(o, k):
    return o[k] if k in o else null

func _strip_slash(v):
    out := v
    while _s.ends_with(out, "/"):
        out = _s.slice(out, 0, len(out) - 1)
    return out

# Lien absolu vers path pour un courriel : site_url de la configuration ; à défaut, en mode debug seulement,
# schéma et hôte de la requête (en production, Host vient du client : refusé).
func absolute_url(req, path):
    app := req.state["app"] if req != null and "app" in req.state else null
    if app != null and app.config != null:
        v := app.config.get("site_url")
        if v != null and v != "":
            return _strip_slash(v) + path
    if app != null and app.debug and req != null:
        h := req.header("host")
        if h != null and h != "":
            scheme := req.state["scheme"] if "scheme" in req.state else ("https" if req.secure else "http")
            return scheme + "://" + h + path
    _err.alweb_error("mail.absolute_url", "clé site_url requise pour les liens des courriels (« https://exemple.org »)")

# Vrai si text est une adresse acceptable (forme RFC 5321, 254 caractères au plus, sans saut de ligne) : pour
# valider un champ « courriel » avant de s'en servir.
func valid_address(text):
    return type(text) == "str" and _email.is_valid_email(_s.trim(text))

# Charge JSON d'un courriel mis en file (pièces jointes en base64).
func _jobs_payload(to, subject, text, html, options):
    o := {}
    if options != null:
        for k in keys(options):
            if k == "attachments":
                atts := []
                for a in options[k]:
                    if type(a) == "list":
                        append(atts, [a[0], _enc.base64_encode(a[1]), a[2] if len(a) > 2 else null])
                    else:
                        append(atts, a)
                o["attachments64"] = atts
            else:
                o[k] = options[k]
    return {"to": to, "subject": subject, "text": text, "html": html, "options": o}

# Lien absolu hors requête (tâche de fond, script) : site_url de la configuration de l'application, requis.
func site_link(app, path):
    v := app.config.get("site_url") if app != null and app.config != null else null
    if v == null or v == "":
        _err.alweb_error("mail.site_link", "clé site_url requise pour les liens des courriels (« https://exemple.org »)")
    return _strip_slash(v) + path

func _base_lang(code):
    k := _s.find(code, "-")
    return code if k < 0 else code[0:k]

# Code de langue sûr pour un en-tête (lettres, chiffres, tirets).
func _hv_token(code):
    if type(code) != "str" or code == "" or len(code) > 20:
        return false
    for ch in code:
        c := str(ch)
        if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-"):
            return false
    return true
