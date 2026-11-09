# alweb.errors — erreurs du framework et interruption d'un gestionnaire.
#
#   use alweb
#   @app.get("/notes/{id:int}")
#   async func voir(req):
#       note := await trouver(req.params["id"])
#       if note == null:
#           alweb.abort(404, "note introuvable")
#       return note
#
# abort(statut, message) lève l'erreur HttpAbort de web.server : le routeur la transforme en réponse d'erreur
# négociée (JSON pour une API, HTML pour un navigateur), y compris dans une `async func`.
#
#   AlwebError        usage invalide du framework (route mal déclarée, application déjà démarrée)
#   ValidationError   données d'entrée refusées par un schéma (devient une réponse 422)

use web.server.server_errors as _se

const ALWEB := "AlwebError"
const VALIDATION := "ValidationError"

func abort(status, message=null):
    _se.abort(status, message)

func alweb_error(where, message):
    raise(ALWEB, where + " : " + message)
