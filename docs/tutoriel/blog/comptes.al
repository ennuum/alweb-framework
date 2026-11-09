# Comptes : inscription, connexion, déconnexion (étape 4 du tutoriel), puis courriels (étape 9) : confirmation de
# l'adresse, mot de passe oublié. Mots de passe hachés par PBKDF2 hors de la boucle d'événements ; le premier
# compte créé est administrateur.
use string as s
use alweb
use alweb.auth as auth
use alweb.forms as forms
use alweb.mail as mail
use alweb.ratelimit as rl
use modeles as m

func formulaire_vide(values=null):
    return forms.FormResult(true, values if values != null else {}, null, {})

func erreur_formulaire(values, message, champ=""):
    return forms.FormResult(false, values, null, {champ: message})

func page_compte(titre, bouton, form, nxt, inscription=false):
    return {"titre": titre, "bouton": bouton, "form": form, "next": nxt, "inscription": inscription}

func installer(app, cfg):
    iterations := cfg.get("auth.iterations", 600000)
    secret := cfg.require("secret_key")
    if not app.debug:
        # liens des courriels et envoi : à régler avant de servir (ALWEB_SITE_URL, ALWEB_MAIL__URL en production)
        cfg.require("site_url")
        cfg.require("mail.url")
    site := app.group("", null, ["db", "user"])

    # Lien de confirmation envoyé à l'adresse du compte, par la file de tâches (send_template_later) : un serveur
    # SMTP en panne ne bloque pas l'inscription, et le courriel est réessayé plus tard.
    func envoyer_confirmation(req, u):
        lien := mail.absolute_url(req, "/confirmation/" + auth.confirm_token(secret, u["id"], u["courriel"]))
        alweb.mailer(req).send_template_later(u["courriel"], "Confirmez votre adresse", "confirmation", {"nom": u["nom"], "lien": lien})

    # Rappel un jour après l'inscription si l'adresse n'est toujours pas confirmée (tâche différée : gardée en base,
    # elle part même si le serveur a redémarré entre-temps).
    @app.jobs.task("rappel_confirmation")
    async func rappel_confirmation(p, job):
        u := await m.UTILISATEURS.get(job.app.value("db"), p["id"])
        if u == null or u["confirme"] or u["courriel"] == null:
            return null
        lien := mail.site_link(job.app, "/confirmation/" + auth.confirm_token(secret, u["id"], u["courriel"]))
        await job.app.mail().send_template(u["courriel"], "Rappel : confirmez votre adresse", "confirmation", {"nom": u["nom"], "lien": lien})

    @site.get("/inscription", {"name": "inscription"})
    func inscription_page(req):
        return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", formulaire_vide(), "/", true))

    @site.post("/inscription")
    async func inscription(req):
        db := req.deps["db"]
        f := alweb.validate_form(req, m.COMPTE)
        if f.valid and not mail.valid_address(f.data["courriel"]):
            f = erreur_formulaire(f.values, "adresse de courriel invalide", "courriel")
        if not f.valid:
            return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", f, "/", true), 422)
        courriel := s.lower(s.trim(f.data["courriel"]))
        if await m.UTILISATEURS.where("nom", f.data["nom"]).exists(db):
            f = erreur_formulaire(f.values, "ce nom est déjà pris", "nom")
            return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", f, "/", true), 422)
        if await m.UTILISATEURS.where("courriel", courriel).exists(db):
            f = erreur_formulaire(f.values, "un compte utilise déjà cette adresse", "courriel")
            return alweb.render(req, "compte.html", page_compte("Créer un compte", "S'inscrire", f, "/", true), 422)
        premier := (await m.UTILISATEURS.query().count(db)) == 0
        roles := ["admin", "auteur"] if premier else ["auteur"]
        mdp := await auth.hash_password(f.data["mdp"], iterations)
        id := await m.UTILISATEURS.insert(db, {"nom": f.data["nom"], "courriel": courriel, "mdp": mdp, "roles": roles})
        auth.login(req, id, roles)
        envoyer_confirmation(req, {"id": id, "nom": f.data["nom"], "courriel": courriel})
        await app.jobs.enqueue("rappel_confirmation", {"id": id}, {"delay": 86400, "key": "rappel-" + str(id)})
        alweb.session(req).flash("Bienvenue, " + f.data["nom"] + " ! Un lien de confirmation vous a été envoyé.", "succes")
        return alweb.redirect("/", 303)

    @site.get("/connexion", {"name": "connexion"})
    func connexion_page(req):
        return alweb.render(req, "compte.html", page_compte("Connexion", "Se connecter", formulaire_vide(), auth.next_url(req, "/")))

    @site.post("/connexion")
    async func connexion(req):
        f := alweb.validate_form(req, m.IDENTIFIANTS)
        nxt := auth.next_url(req, "/")
        if f.valid:
            u := await m.UTILISATEURS.where("nom", f.data["nom"]).first(req.deps["db"])
            if u != null and await auth.verify_password(f.data["mdp"], u["mdp"]):
                auth.login(req, u["id"], u["roles"])
                alweb.session(req).flash("Vous êtes connecté.", "succes")
                return alweb.redirect(nxt, 303)
        f = erreur_formulaire(f.values, "nom ou mot de passe incorrect")
        return alweb.render(req, "compte.html", page_compte("Connexion", "Se connecter", f, nxt), 401)

    @site.post("/deconnexion", {"name": "deconnexion"})
    func deconnexion(req):
        auth.logout(req)
        alweb.session(req).flash("À bientôt !", "info")
        return alweb.redirect("/", 303)

    # ---------------------------------------------------------------- confirmation de l'adresse

    @site.get("/confirmation/{jeton}", {"name": "confirmation"})
    async func confirmation(req):
        db := req.deps["db"]
        c := auth.read_confirm_token(secret, req.params["jeton"])
        u := null
        if c != null:
            u = await m.UTILISATEURS.get(db, c["id"])
        if u == null or u["courriel"] != c["email"]:
            alweb.session(req).flash("Ce lien de confirmation n'est pas valable (ou a expiré).", "erreur")
            return alweb.redirect("/", 303)
        if not u["confirme"]:
            await m.UTILISATEURS.where("id", u["id"]).update(db, {"confirme": true})
        alweb.session(req).flash("Adresse confirmée, merci !", "succes")
        return alweb.redirect("/", 303)

    @site.post("/confirmation", {"name": "renvoyer_confirmation", "middleware": [auth.login_required(), rl.limit(3, 3600, null, null, "renvoi")]})
    func renvoyer(req):
        u := req.deps["user"]
        if u["confirme"] or u["courriel"] == null:
            alweb.session(req).flash("Votre adresse est déjà confirmée.", "info")
        else:
            envoyer_confirmation(req, u)
            alweb.session(req).flash("Nouveau lien envoyé à " + u["courriel"] + ".", "info")
        return alweb.redirect("/", 303)

    # ---------------------------------------------------------------- mot de passe oublié

    @site.get("/mot-de-passe-oublie", {"name": "oubli"})
    func oubli_page(req):
        return alweb.render(req, "oubli.html", {"form": formulaire_vide(), "envoye": false})

    # Même réponse que l'adresse soit connue ou non (on ne révèle pas qui a un compte) ; 5 demandes par quart
    # d'heure et par adresse IP.
    @site.post("/mot-de-passe-oublie", {"middleware": [rl.limit(5, 900, null, null, "oubli")]})
    async func oubli(req):
        f := alweb.validate_form(req, m.OUBLI)
        if not f.valid:
            return alweb.render(req, "oubli.html", {"form": f, "envoye": false}, 422)
        u := await m.UTILISATEURS.where("courriel", s.lower(s.trim(f.data["courriel"]))).first(req.deps["db"])
        if u != null:
            lien := mail.absolute_url(req, "/reinitialisation/" + auth.reset_token(secret, u["id"], u["mdp"]))
            alweb.mailer(req).send_template_later(u["courriel"], "Réinitialiser votre mot de passe", "reinitialisation", {"nom": u["nom"], "lien": lien})
        return alweb.render(req, "oubli.html", {"form": formulaire_vide(), "envoye": true})

    # Le jeton porte l'empreinte du mot de passe du moment : il ne sert qu'une fois, et pendant une heure.
    async func compte_du_jeton(req):
        id := auth.reset_token_user(secret, req.params["jeton"])
        u := null
        if id != null:
            u = await m.UTILISATEURS.get(req.deps["db"], id)
        if u == null or not auth.check_reset_token(secret, req.params["jeton"], u["mdp"]):
            return null
        return u

    func lien_perime(req):
        alweb.session(req).flash("Ce lien n'est plus valable : demandez-en un nouveau.", "erreur")
        return alweb.redirect("/mot-de-passe-oublie", 303)

    @site.get("/reinitialisation/{jeton}", {"name": "reinitialisation"})
    async func reinitialisation_page(req):
        u := await compte_du_jeton(req)
        if u == null:
            return lien_perime(req)
        return alweb.render(req, "reinitialisation.html", {"form": formulaire_vide()})

    @site.post("/reinitialisation/{jeton}")
    async func reinitialisation(req):
        u := await compte_du_jeton(req)
        if u == null:
            return lien_perime(req)
        f := alweb.validate_form(req, m.NOUVEAU_MDP)
        if not f.valid:
            return alweb.render(req, "reinitialisation.html", {"form": f}, 422)
        mdp := await auth.hash_password(f.data["mdp"], iterations)
        # le lien reçu par courriel prouve aussi l'adresse
        await m.UTILISATEURS.where("id", u["id"]).update(req.deps["db"], {"mdp": mdp, "confirme": true})
        auth.logout(req)
        alweb.session(req).flash("Mot de passe changé : vous pouvez vous connecter.", "succes")
        return alweb.redirect("/connexion", 303)
