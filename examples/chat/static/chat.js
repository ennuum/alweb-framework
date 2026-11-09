// Client de la messagerie : API REST /api/v1 pour les comptes, les salons et l'historique ; WebSocket pour le direct.
"use strict";
const $ = (s) => document.querySelector(s);
const etat = { jeton: null, pseudo: null, salon: null, ws: null, suivant: null, ecrit: {}, essais: 0 };

function memo(cle, valeur) {           // sessionStorage peut être indisponible (navigation privée, iframe)
  try { if (valeur === undefined) return sessionStorage.getItem(cle); if (valeur === null) sessionStorage.removeItem(cle); else sessionStorage.setItem(cle, valeur); } catch (e) { return null; }
}

async function api(methode, chemin, corps) {
  const init = { method: methode, headers: { "Accept": "application/json" } };
  if (corps !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(corps); }
  if (etat.jeton) init.headers["Authorization"] = "Bearer " + etat.jeton;
  const r = await fetch("/api/v1" + chemin, init);
  const d = r.status === 204 ? null : await r.json().catch(() => null);
  if (!r.ok) {
    if (r.status === 401 && etat.jeton) sortir();
    const detail = d && d.details && d.details.length ? " (" + d.details.map((x) => x.message || x).join(", ") + ")" : "";
    throw new Error((d && d.message) || r.statusText + detail);
  }
  return d;
}

// ---------------------------------------------------------------- identification

$("#identification").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const f = new FormData(ev.target);
  const action = ev.submitter ? ev.submitter.value : "connexion";
  const ident = { pseudo: f.get("pseudo"), mot_de_passe: f.get("mot_de_passe") };
  $("#erreur").textContent = "";
  try {
    if (action === "inscription") await api("POST", "/comptes", ident);
    const j = await api("POST", "/jeton", ident);
    entrer(j.jeton, ident.pseudo);
  } catch (e) { $("#erreur").textContent = e.message; }
});

function entrer(jeton, pseudo) {
  etat.jeton = jeton; etat.pseudo = pseudo;
  memo("jeton", jeton); memo("pseudo", pseudo);
  $("#accueil").hidden = true; $("#appli").hidden = false;
  $("#moi").textContent = pseudo;
  chargerSalons().then(() => ouvrir(memo("salon") || "general"));
  suivreSalons();
}

function sortir() {
  memo("jeton", null);
  if (etat.ws) etat.ws.close();
  location.reload();
}
$("#sortir").addEventListener("click", sortir);

// ---------------------------------------------------------------- salons

async function chargerSalons() {
  const liste = await api("GET", "/salons");
  const ul = $("#salons"); ul.innerHTML = "";
  for (const s of liste) {
    const li = document.createElement("li");
    li.dataset.nom = s.nom;
    li.title = s.sujet || "";
    li.innerHTML = "<b></b><span></span>";
    li.querySelector("b").textContent = "# " + s.nom;
    li.querySelector("span").textContent = s.presents || "";
    li.classList.toggle("actif", s.nom === etat.salon);
    li.addEventListener("click", () => ouvrir(s.nom));
    ul.appendChild(li);
  }
}

function suivreSalons() {                 // création de salons : flux SSE (reconnexion automatique du navigateur)
  const src = new EventSource("/salons/evenements");
  src.addEventListener("salon", () => chargerSalons());
}

$("#nouveau-salon").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const nom = ev.target.nom.value;
  try { await api("POST", "/salons", { nom }); ev.target.reset(); await chargerSalons(); ouvrir(nom); }
  catch (e) { alerte(e.message); }
});

async function ouvrir(nom) {
  if (etat.ws) { etat.ws.onclose = null; etat.ws.close(); etat.ws = null; }
  $("#etat").textContent = "connexion…";
  etat.salon = nom; memo("salon", nom); etat.ecrit = {};
  $("#titre").textContent = "# " + nom;
  $("#messages").innerHTML = ""; $("#presents").innerHTML = ""; $("#ecrit").textContent = "";
  for (const li of document.querySelectorAll("#salons li")) li.classList.toggle("actif", li.dataset.nom === nom);
  const page = await api("GET", "/salons/" + encodeURIComponent(nom) + "/messages");
  for (const m of page.items.reverse()) afficher(m, false);
  etat.suivant = page.next; $("#plus").hidden = !page.next;
  descendre();
  connecter();
}

$("#plus").addEventListener("click", async () => {
  const page = await api("GET", "/salons/" + encodeURIComponent(etat.salon) + "/messages?cursor=" + encodeURIComponent(etat.suivant));
  const ol = $("#messages"), haut = ol.scrollHeight;
  for (const m of page.items) afficher(m, true);
  ol.scrollTop = ol.scrollHeight - haut;
  etat.suivant = page.next; $("#plus").hidden = !page.next;
});

// ---------------------------------------------------------------- direct

function connecter() {
  const proto = location.protocol === "https:" ? "wss://" : "ws://";
  const ws = new WebSocket(proto + location.host + "/ws/" + encodeURIComponent(etat.salon) + "?jeton=" + encodeURIComponent(etat.jeton));
  etat.ws = ws;
  $("#etat").textContent = "connexion…";
  ws.onopen = () => { etat.essais = 0; $("#etat").textContent = "en direct"; };
  ws.onclose = (ev) => {
    $("#etat").textContent = "déconnecté";
    if (ev.code === 4401) return sortir();
    const delai = Math.min(10000, 500 * 2 ** etat.essais++);
    setTimeout(() => { if (etat.ws === ws) ouvrir(etat.salon); }, delai);
  };
  ws.onmessage = (ev) => {
    const e = JSON.parse(ev.data);
    if (e.type === "bienvenue") return presents(e.membres);
    if (e.type === "message") { afficher(e.data, false); descendre(); delete etat.ecrit[e.member.pseudo]; montrerEcrit(); }
    else if (e.type === "join" || e.type === "leave") { info(e.member.pseudo + (e.type === "join" ? " arrive" : " part")); presence(); }
    else if (e.type === "ecrit" && e.member.pseudo !== etat.pseudo) { etat.ecrit[e.member.pseudo] = Date.now(); montrerEcrit(); }
  };
}

let dernierEcrit = 0;
$("#envoi input").addEventListener("input", () => {
  if (Date.now() - dernierEcrit > 2000 && etat.ws && etat.ws.readyState === 1) { dernierEcrit = Date.now(); etat.ws.send(JSON.stringify({ type: "ecrit" })); }
});
$("#envoi").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const texte = ev.target.texte.value.trim();
  if (!texte || !etat.ws || etat.ws.readyState !== 1) return;
  etat.ws.send(JSON.stringify({ texte }));
  ev.target.reset();
});

function montrerEcrit() {
  const qui = Object.keys(etat.ecrit).filter((p) => Date.now() - etat.ecrit[p] < 4000);
  $("#ecrit").textContent = qui.length ? qui.join(", ") + (qui.length > 1 ? " écrivent…" : " écrit…") : "";
}
setInterval(montrerEcrit, 1000);

async function presence() {
  presents(await api("GET", "/salons/" + encodeURIComponent(etat.salon) + "/presence"));
  chargerSalons();
}

function presents(membres) {
  const ul = $("#presents"); ul.innerHTML = "";
  for (const m of membres) { const li = document.createElement("li"); li.textContent = m.pseudo; ul.appendChild(li); }
}

// ---------------------------------------------------------------- affichage

function afficher(m, enHaut) {
  const li = document.createElement("li");
  li.className = m.auteur === etat.pseudo ? "mien" : "";
  const b = document.createElement("b"); b.textContent = m.auteur;
  const t = document.createElement("time"); t.textContent = new Date(m.cree_le * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  li.append(b, document.createTextNode(m.texte), t);
  const ol = $("#messages");
  if (enHaut) ol.prepend(li); else ol.appendChild(li);
}

function info(texte) { const li = document.createElement("li"); li.className = "info"; li.textContent = texte; $("#messages").appendChild(li); descendre(); }
function alerte(texte) { info("⚠ " + texte); }
function descendre() { const ol = $("#messages"); ol.scrollTop = ol.scrollHeight; }

// reprise d'une session ouverte dans cet onglet
if (memo("jeton")) entrer(memo("jeton"), memo("pseudo"));
