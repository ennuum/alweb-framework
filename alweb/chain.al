# alweb.chain — exécution d'une chaîne d'intergiciels (application, groupe, route).

from core use len
use asyncio as _aio
use web.server.request_dispatch as _rd

#
# Un intergiciel est soit une fonction (req, nxt) -> réponse (souvent async : chaque niveau est alors une tâche,
# attendue par celui du dessus), soit un Hook : avant(req) et après(req, réponse), appelés directement. Une
# chaîne faite de hooks autour d'une route synchrone reste entièrement synchrone : aucune tâche n'est créée.

# Intergiciel synchrone : before(req) -> null pour continuer, ou une réponse (la suite n'est pas appelée) ;
# after(req, réponse) -> la réponse (modifiée ou remplacée ; null : la même). Une exception donne la page d'erreur.
class Hook:
    func init(before=null, after=null):
        self.before = before
        self.after = after

func run(mws, i, req, final, on_error):
    if i >= len(mws):
        return final(req)
    m := mws[i]
    if not isinstance(m, Hook):
        return _run_async(mws, i, req, final, on_error)
    try:
        if m.before != null:
            early := m.before(req)
            if early != null:
                return _rd.to_response(early, req)
        r := run(mws, i + 1, req, final, on_error)
        if _aio.is_future(r):
            return _hook_later(m, req, r, on_error)
        return _hook_after(m, req, r)
    catch e:
        return on_error(req, e)

func _hook_after(m, req, r):
    resp := _rd.to_response(r, req)
    if m.after == null:
        return resp
    out := m.after(req, resp)
    return resp if out == null else _rd.to_response(out, req)

async func _hook_later(m, req, fut, on_error):
    try:
        return _hook_after(m, req, await fut)
    catch e:
        return on_error(req, e)

async func _run_async(mws, i, req, final, on_error):
    try:
        out := mws[i](req, (q) => _as_task(run(mws, i + 1, q, final, on_error)))
        if _aio.is_future(out):
            out = await out
        return _rd.to_response(out, req)
    catch e:
        return on_error(req, e)

# nxt(req) d'un intergiciel async rend toujours une tâche (il fait « await nxt(req) »).
func _as_task(v):
    return v if _aio.is_future(v) else _ready(v)

async func _ready(v):
    return v
