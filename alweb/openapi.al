# alweb.openapi — description OpenAPI 3.1 générée depuis les routes et leurs schémas, et page de documentation.
#
#   use alweb.openapi as oa
#   oa.setup(app, title="Messagerie", version="1.0.0")          # GET /openapi.json et GET /docs
#   oa.setup(app, title="API v2", version="2", prefix="/api/v2", path="/api/v2/openapi.json", docs="/api/v2/docs")
#
# Ce qui est décrit, pour chaque route : méthodes, paramètres de chemin typés ({id:int} -> integer), paramètres de
# requête (option query), corps JSON (option body), réponse (options response / status / responses), réponse 422
# des routes validées, 429 si une limite de débit s'applique (à déclarer dans responses), sécurité (security),
# tags, summary et description (à défaut : le premier paragraphe du commentaire n'est pas lisible à l'exécution,
# la description reste vide). Les routes WebSocket, statiques et hidden ne sont pas décrites.
#
# Schémas serialization.schema traduits en JSON Schema 2020-12 : string (minLength, maxLength, pattern), integer et
# number (minimum, maximum), boolean, null, enum, list (items, minItems, maxItems), dict (additionalProperties),
# object (properties, required, additionalProperties), one_of (oneOf), optional (type null admis), default,
# description. Un schéma enregistré avec component(nom, schéma) est décrit une fois dans components et référencé.

from core use len, type, to_int
from collections use append, keys
use string as _s
use json as _json
use web.http.response as _response
use web.server.request_dispatch as _rd
use serialization.schema as _sch

const METHOD_ORDER := ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

# Schémas d'authentification reconnus par security : ["bearer"], ["cookie"], ["basic"], ["api_key"].
const SECURITY_SCHEMES := {"bearer": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}, "basic": {"type": "http", "scheme": "basic"}, "cookie": {"type": "apiKey", "in": "cookie", "name": "session"}, "api_key": {"type": "apiKey", "in": "header", "name": "X-API-Key"}}

_components := []                         # [schéma, nom] (component)
_component_schemas := {}                  # nom -> schéma
_used := [{}]                             # noms référencés pendant spec()

# Donne un nom à un schéma : il sera décrit dans components.schemas et référencé par $ref. Rend le schéma.
func component(name, schema):
    append(_components, [schema, name])
    _component_schemas[name] = schema
    return schema

func _component_name(schema):
    for c in _components:
        if c[0] == schema:
            return c[1]
    return null

# ---------------------------------------------------------------- schémas

# JSON Schema d'un schéma serialization.schema.
func json_schema(schema, use_refs=true):
    if schema == null:
        return {}
    ref := _component_name(schema) if use_refs else null
    if ref != null:
        _used[0][ref] = true
        return {"$ref": "#/components/schemas/" + ref}
    k := schema.kind
    out := {}
    if k == "string":
        out["type"] = "string"
        if schema.min != null:
            out["minLength"] = schema.min
        if schema.max != null:
            out["maxLength"] = schema.max
        if schema.regex != null:
            out["pattern"] = schema.regex
    elif k == "integer" or k == "number":
        out["type"] = k
        if schema.min != null:
            out["minimum"] = schema.min
        if schema.max != null:
            out["maximum"] = schema.max
    elif k == "boolean" or k == "null":
        out["type"] = k
    elif k == "enum":
        out["enum"] = schema.values
    elif k == "list":
        out["type"] = "array"
        out["items"] = json_schema(schema.items)
        if schema.min != null:
            out["minItems"] = schema.min
        if schema.max != null:
            out["maxItems"] = schema.max
    elif k == "dict":
        out["type"] = "object"
        out["additionalProperties"] = json_schema(schema.items)
    elif k == "object":
        out["type"] = "object"
        props := {}
        for f in keys(schema.fields):
            props[f] = json_schema(schema.fields[f])
        out["properties"] = props
        if len(schema.required) > 0:
            out["required"] = schema.required
        if not schema.additional:
            out["additionalProperties"] = false
    elif k == "one_of":
        alts := []
        for c in schema.choices:
            append(alts, json_schema(c))
        out["oneOf"] = alts
    if schema.nullable and ("type" in out):
        out["type"] = [out["type"], "null"]
    elif schema.nullable and not ("$ref" in out):
        out = {"anyOf": [out, {"type": "null"}]} if len(keys(out)) > 0 else out
    if schema.has_default:
        out["default"] = schema.default_value
    if schema.description != "":
        out["description"] = schema.description
    return out

# ---------------------------------------------------------------- description

# Description OpenAPI (dict) des routes de l'application ; prefix : seulement les routes sous ce préfixe (une
# description par version d'API). servers : liste d'URL.
func spec(app, title=null, version="1.0.0", description=null, prefix=null, servers=null):
    _used[0] = {}
    paths := {}
    used_security := {}
    ops_ids := {}
    for m in app.meta:
        if ("hidden" in m and m["hidden"]) or (prefix != null and not _s.starts_with(m["pattern"], prefix)):
            continue
        p := _openapi_path(m["pattern"])
        if not (p in paths):
            paths[p] = {}
        for meth in _methods(m["methods"]):
            op := _operation(m, meth, ops_ids)
            if "security" in m and m["security"] != null:
                sec := []
                for name in m["security"]:
                    used_security[name] = true
                    item := {}
                    item[name] = []
                    append(sec, item)
                op["security"] = sec
            paths[p][_s.lower(meth)] = op
    info := {"title": title if title != null else app.name, "version": str(version)}
    if description != null:
        info["description"] = description
    out := {"openapi": "3.1.0", "info": info, "paths": paths}
    if servers != null:
        sv := []
        for u in servers:
            append(sv, {"url": u})
        out["servers"] = sv
    comps := {}
    schemas := {}
    pending := keys(_used[0])
    while len(pending) > 0:
        for name in pending:
            schemas[name] = json_schema(_component_schemas[name], false)
        pending = []
        for name in keys(_used[0]):
            if not (name in schemas):
                append(pending, name)
    if len(keys(schemas)) > 0:
        comps["schemas"] = schemas
    if len(keys(used_security)) > 0:
        ss := {}
        for name in keys(used_security):
            ss[name] = SECURITY_SCHEMES[name] if name in SECURITY_SCHEMES else {"type": "http", "scheme": name}
        comps["securitySchemes"] = ss
    comps["schemas"] = (comps["schemas"] if "schemas" in comps else {})
    comps["schemas"]["Erreur"] = {"type": "object", "properties": {"error": {"type": "string"}, "status": {"type": "integer"}, "message": {"type": ["string", "null"]}, "details": {"type": "array"}}, "required": ["error", "status"]}
    out["components"] = comps
    return out

func _methods(ms):
    out := []
    for x in METHOD_ORDER:
        if x in ms and x != "HEAD" and x != "OPTIONS":
            append(out, x)
    if "*" in ms:
        return ["GET", "POST", "PUT", "PATCH", "DELETE"]
    return out

func _operation(m, meth, ops_ids):
    op := {}
    if "summary" in m and m["summary"] != null:
        op["summary"] = m["summary"]
    if "description" in m and m["description"] != null:
        op["description"] = m["description"]
    if "tags" in m and m["tags"] != null:
        op["tags"] = m["tags"]
    oid := m["operation_id"] if "operation_id" in m and m["operation_id"] != null else (m["name"] if "name" in m and m["name"] != null else _auto_id(meth, m["pattern"]))
    if oid in ops_ids:
        oid = oid + "_" + _s.lower(meth)
    ops_ids[oid] = true
    op["operationId"] = oid
    params := []
    for part in _rd.compile_pattern(m["pattern"]):
        if part[0] == "param":
            append(params, {"name": part[1], "in": "path", "required": true, "schema": _param_schema(part[2])})
    if "query" in m and m["query"] != null:
        q := m["query"]
        if q.kind == "object":
            for f in keys(q.fields):
                fs := q.fields[f]
                pr := {"name": f, "in": "query", "required": f in q.required, "schema": json_schema(fs)}
                if fs.description != "":
                    pr["description"] = fs.description
                append(params, pr)
    if len(params) > 0:
        op["parameters"] = params
    if "body" in m and m["body"] != null:
        op["requestBody"] = {"required": true, "content": {"application/json": {"schema": json_schema(m["body"])}}}
    status := str(m["status"]) if "status" in m and m["status"] != null else ("201" if meth == "POST" else "200")
    ok := {"description": "Succès"}
    if "response" in m and m["response"] != null:
        ok["content"] = {"application/json": {"schema": json_schema(m["response"])}}
    responses := {}
    responses[status] = ok
    if ("body" in m and m["body"] != null) or ("query" in m and m["query"] != null):
        responses["422"] = _error_response("Données invalides")
    if "security" in m and m["security"] != null:
        responses["401"] = _error_response("Authentification requise")
    if "responses" in m and m["responses"] != null:
        for code in keys(m["responses"]):
            v := m["responses"][code]
            if type(v) == "str":
                responses[str(code)] = _error_response(v) if to_int(code) >= 400 else {"description": v}
            else:
                r := {"description": v["description"] if "description" in v else ""}
                if "schema" in v:
                    r["content"] = {"application/json": {"schema": json_schema(v["schema"])}}
                responses[str(code)] = r
    op["responses"] = responses
    if "deprecated" in m and m["deprecated"] != null and m["deprecated"] != false:
        op["deprecated"] = true
    return op

func _error_response(text):
    return {"description": text, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Erreur"}}}}

func _param_schema(kind):
    if kind == "int":
        return {"type": "integer"}
    if kind == "float":
        return {"type": "number"}
    if kind == "uuid":
        return {"type": "string", "format": "uuid"}
    if kind == "slug":
        return {"type": "string", "pattern": "^[a-z0-9]+(?:-[a-z0-9]+)*$"}
    return {"type": "string"}

# /articles/{id:int} -> /articles/{id}
func _openapi_path(pattern):
    out := ""
    for part in _rd.compile_pattern(pattern):
        if part[0] == "param":
            out = out + "/{" + part[1] + "}"
        else:
            out = out + "/" + part[1]
    if out == "":
        return "/"
    if _s.ends_with(pattern, "/") and pattern != "/":
        out = out + "/"
    return out

func _auto_id(meth, pattern):
    out := _s.lower(meth)
    for part in _rd.compile_pattern(pattern):
        clean := part[1]
        for bad in ["-", ".", "*", "~", "@", ":"]:
            clean = _s.replace(clean, bad, "_")
        out = out + "_" + clean
    return out

# ---------------------------------------------------------------- routes

# Ajoute GET path (description JSON) et GET docs (page HTML autonome, sans ressource externe) ; docs=false : pas
# de page. Rend la description, calculée à la première demande puis gardée.
func setup(app, title=null, version="1.0.0", description=null, prefix=null, servers=null, path="/openapi.json", docs="/docs"):
    cache := [null]
    getter := () => _cached(cache, app, title, version, description, prefix, servers)
    app.get(path, (req) => _response.json(getter()), {"hidden": true, "name": "openapi" + (prefix if prefix != null else "")})
    if docs != null and docs != false:
        app.get(docs, (req) => _docs_page(path, title if title != null else app.name), {"hidden": true})
    return app

func _cached(cache, app, title, version, description, prefix, servers):
    if cache[0] == null:
        cache[0] = spec(app, title, version, description, prefix, servers)
    return cache[0]

func _docs_page(spec_url, title):
    r := _response.html(_s.replace(_s.replace(DOCS_HTML, "%%SPEC%%", _json.stringify(spec_url)), "%%TITLE%%", _html_escape(title)))
    r.headers.set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'")
    return r

func _html_escape(t):
    return _s.replace(_s.replace(_s.replace(t, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

const DOCS_HTML := """<!DOCTYPE html>
<html lang=\"fr\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>%%TITLE%% — API</title>
<style>
:root{--fg:#1d1d1f;--mut:#6b6b70;--bd:#e3e3e6;--bg:#fff;--soft:#f6f6f7;--get:#1f6feb;--post:#1a7f37;--put:#9a6700;--patch:#8250df;--delete:#cf222e}
@media (prefers-color-scheme:dark){:root{--fg:#eaeaea;--mut:#9a9aa0;--bd:#33343a;--bg:#16171a;--soft:#1f2024}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,sans-serif;color:var(--fg);background:var(--bg)}
main{max-width:960px;margin:0 auto;padding:24px}h1{margin:0 0 4px;font-size:26px}.mut{color:var(--mut)}
h2{font-size:17px;margin:28px 0 8px;border-bottom:1px solid var(--bd);padding-bottom:4px}
details{border:1px solid var(--bd);border-radius:8px;margin:8px 0;background:var(--bg)}
summary{cursor:pointer;padding:10px 12px;display:flex;gap:10px;align-items:center;list-style:none}
summary::-webkit-details-marker{display:none}
.m{font:600 12px ui-monospace,monospace;color:#fff;border-radius:4px;padding:2px 8px;min-width:62px;text-align:center}
.GET{background:var(--get)}.POST{background:var(--post)}.PUT{background:var(--put)}.PATCH{background:var(--patch)}.DELETE{background:var(--delete)}
code,pre,textarea,input{font:13px ui-monospace,monospace}.p{font-family:ui-monospace,monospace}.dep{text-decoration:line-through}
.body{padding:0 12px 12px}pre{background:var(--soft);padding:10px;border-radius:6px;overflow:auto;margin:6px 0}
table{border-collapse:collapse;width:100%}td,th{text-align:left;border-bottom:1px solid var(--bd);padding:4px 6px;vertical-align:top}
input,textarea{width:100%;padding:6px;border:1px solid var(--bd);border-radius:6px;background:var(--bg);color:var(--fg)}
button{margin-top:8px;padding:6px 14px;border:0;border-radius:6px;background:var(--get);color:#fff;cursor:pointer}
.tag{font-size:12px;border:1px solid var(--bd);border-radius:10px;padding:0 8px;color:var(--mut)}
</style></head><body><main><h1 id=\"t\">%%TITLE%%</h1><div class=\"mut\" id=\"v\"></div><div id=\"ops\">Chargement…</div></main>
<script>
const SPEC=%%SPEC%%;
const esc=s=>String(s).replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));
const resolve=(spec,s)=>s&&s.$ref?spec.components.schemas[s.$ref.split('/').pop()]:s;
function example(spec,s,d){s=resolve(spec,s)||{};d=d||0;if(d>5)return null;if('default' in s)return s.default;if(s.enum)return s.enum[0];
 const t=Array.isArray(s.type)?s.type[0]:s.type;if(s.oneOf)return example(spec,s.oneOf[0],d+1);
 if(t==='object'){const o={};for(const k in (s.properties||{}))o[k]=example(spec,s.properties[k],d+1);return o}
 if(t==='array')return [example(spec,s.items,d+1)];if(t==='integer'||t==='number')return s.minimum||0;if(t==='boolean')return false;if(t==='string')return 'texte';return null}
function op(spec,path,meth,o){const el=document.createElement('details');const ps=o.parameters||[];
 const body=o.requestBody?o.requestBody.content['application/json'].schema:null;
 let h='<summary><span class=\"m '+meth.toUpperCase()+'\">'+meth.toUpperCase()+'</span><span class=\"p'+(o.deprecated?' dep':'')+'\">'+esc(path)+'</span><span class=\"mut\">'+esc(o.summary||'')+'</span></summary><div class=\"body\">';
 if(o.description)h+='<p>'+esc(o.description)+'</p>';
 if(ps.length){h+='<table><tr><th>Paramètre</th><th>Où</th><th>Valeur</th></tr>';for(const p of ps)h+='<tr><td><code>'+esc(p.name)+'</code>'+(p.required?' *':'')+'</td><td>'+p.in+'</td><td><input data-in=\"'+p.in+'\" data-name=\"'+esc(p.name)+'\" placeholder=\"'+esc(JSON.stringify(p.schema))+'\"></td></tr>';h+='</table>'}
 if(body)h+='<div class=\"mut\">Corps JSON</div><textarea rows=\"6\">'+esc(JSON.stringify(example(spec,body),null,2))+'</textarea>';
 h+='<div class=\"mut\">Réponses</div><pre>'+esc(Object.entries(o.responses).map(([c,r])=>c+'  '+r.description+(r.content?'\\n'+JSON.stringify(resolve(spec,r.content['application/json'].schema),null,1):'')).join('\\n'))+'</pre>';
 h+='<button>Essayer</button><pre class=\"out\" hidden></pre></div>';el.innerHTML=h;
 el.querySelector('button').onclick=async()=>{let url=path;const q=new URLSearchParams();
  for(const i of el.querySelectorAll('input')){if(!i.value)continue;if(i.dataset.in==='path')url=url.replace('{'+i.dataset.name+'}',encodeURIComponent(i.value));else q.set(i.dataset.name,i.value)}
  const init={method:meth.toUpperCase(),headers:{'Accept':'application/json'}};const ta=el.querySelector('textarea');
  if(ta){init.headers['Content-Type']='application/json';init.body=ta.value}
  let tok=null;try{tok=localStorage.getItem('alweb-docs-token')}catch(e){}if(tok)init.headers['Authorization']='Bearer '+tok;
  const out=el.querySelector('.out');out.hidden=false;
  try{const r=await fetch(url+(q.toString()?'?'+q:''),init);const t=await r.text();let b=t;try{b=JSON.stringify(JSON.parse(t),null,2)}catch(e){}
   out.textContent=r.status+' '+r.statusText+'\\n\\n'+b}catch(e){out.textContent=String(e)}};
 return el}
fetch(SPEC).then(r=>r.json()).then(spec=>{document.getElementById('t').textContent=spec.info.title;
 document.getElementById('v').innerHTML='OpenAPI '+esc(spec.openapi)+' · version '+esc(spec.info.version)+' · <a href=\"'+esc(SPEC)+'\">'+esc(SPEC)+'</a>'+(spec.components.securitySchemes?' · jeton : <input id=\"tok\" style=\"width:220px\" placeholder=\"Bearer …\">':'');
 const tk=document.getElementById('tok');if(tk){try{tk.value=localStorage.getItem('alweb-docs-token')||''}catch(e){}tk.onchange=()=>{try{localStorage.setItem('alweb-docs-token',tk.value)}catch(e){}}}
 const groups={};for(const [path,item] of Object.entries(spec.paths))for(const [meth,o] of Object.entries(item)){const g=(o.tags&&o.tags[0])||'Général';(groups[g]=groups[g]||[]).push([path,meth,o])}
 const root=document.getElementById('ops');root.innerHTML='';
 for(const g of Object.keys(groups)){const h=document.createElement('h2');h.textContent=g;root.appendChild(h);for(const [p,m,o] of groups[g])root.appendChild(op(spec,p,m,o))}
}).catch(e=>{document.getElementById('ops').textContent='Description introuvable : '+e});
</script></body></html>
"""
