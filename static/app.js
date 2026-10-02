// YT-NEXUS — interface. Aucun framework : rendu par gabarits échappés + mises à jour ciblées.

// ── utilitaires ──────────────────────────────────────────────────────
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
// Gabarit qui échappe tout sauf les fragments déjà sûrs (brut()).
class Brut { constructor(s) { this.s = s; } toString() { return this.s; } }
const brut = (s) => new Brut(s);
const rendu = (v) => (v instanceof Brut ? v.s : Array.isArray(v) ? v.map(rendu).join("") : v === false || v == null ? "" : esc(v));
const h = (parts, ...vals) => brut(parts.reduce((acc, p, i) => acc + rendu(vals[i - 1]) + p));
const html = (v) => rendu(v);

async function api(chemin, { methode = "GET", corps, form } = {}) {
  const opts = { method: methode, headers: {} };
  if (form) opts.body = form;
  else if (corps !== undefined) { opts.body = JSON.stringify(corps); opts.headers["Content-Type"] = "application/json"; }
  let r;
  try { r = await fetch("/api" + chemin, opts); }
  catch { throw new Error("Serveur injoignable. YT-NEXUS est-il lancé ?"); }
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.erreur || `Erreur ${r.status}`);
  return d;
}

function toast(msg, type = "") {
  const t = document.createElement("div");
  const duree = type === "err" ? 6 : 3.2;
  t.className = `toast ${type}`;
  t.style.setProperty("--duree", `${duree}s`);
  t.innerHTML = html(h`<span class="ic">${brut(type === "err" ? I.alerte : type === "ok" ? I.ok : I.info)}</span><span>${msg}</span>`);
  $("#toasts").append(t);
  setTimeout(() => { t.classList.add("sort"); setTimeout(() => t.remove(), 350); }, duree * 1000);
}

const taille = (o) => {
  if (!o) return "—";
  const u = ["o", "Ko", "Mo", "Go", "To"]; let i = 0; let n = o;
  while (n >= 1000 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 1 ? 1 : 0)} ${u[i]}`;
};
const duree = (s) => {
  if (s == null) return "";
  s = Math.round(s); const hh = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = s % 60;
  return (hh ? `${hh}:${String(m).padStart(2, "0")}` : `${m}`) + `:${String(ss).padStart(2, "0")}`;
};
const restant = (s) => (s == null ? "" : s < 60 ? `${s} s` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)}`);
const vues = (n) => (n == null ? "" : n >= 1e9 ? `${(n / 1e9).toFixed(1).replace(".", ",")} Md vues` : n >= 1e6 ? `${(n / 1e6).toFixed(1).replace(".", ",")} M vues` : n >= 1e3 ? `${Math.round(n / 1e3)} k vues` : `${n} vues`);
const dateYT = (d) => (d && d.length === 8 ? new Date(`${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6)}`).toLocaleDateString("fr-FR", { day: "numeric", month: "short", year: "numeric" }) : "");
const quand = (t) => (t ? new Date(t * 1000).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "");
const estUrl = (s) => /^(https?:\/\/|www\.|youtu\.?be|m\.youtube)/i.test(s.trim()) || /^[\w-]+\.[a-z]{2,}\/\S+/i.test(s.trim());
const base = (c) => (c || "").toLowerCase().split("-")[0];
let noms;
try { noms = new Intl.DisplayNames(["fr"], { type: "language" }); } catch { noms = null; }
const nomPiste = (p) => {
  if (p.nom && p.nom.toLowerCase() !== p.code.toLowerCase()) return p.nom;
  try { const n = noms?.of(p.code === "iw" ? "he" : p.code); return n ? n[0].toUpperCase() + n.slice(1) : p.code; } catch { return p.code; }
};

// ── icônes ───────────────────────────────────────────────────────────
const svg = (d, extra = "") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" ${extra}>${d}</svg>`;
const I = {
  dl: svg('<path d="M12 3v12m0 0-5-5m5 5 5-5M4 19h16"/>'),
  coller: svg('<rect x="8" y="3" width="8" height="4" rx="1"/><path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2"/>'),
  lien: svg('<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>'),
  chercher: svg('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
  video: svg('<rect x="2" y="5" width="15" height="14" rx="3"/><path d="m17 10 5-3v10l-5-3"/>'),
  audio: svg('<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>'),
  pause: svg('<rect x="6" y="5" width="4" height="14" rx="1.5"/><rect x="14" y="5" width="4" height="14" rx="1.5"/>'),
  lecture: svg('<path d="M7 4.5v15a1 1 0 0 0 1.5.9l12-7.5a1 1 0 0 0 0-1.8l-12-7.5A1 1 0 0 0 7 4.5z"/>'),
  stop: svg('<rect x="6" y="6" width="12" height="12" rx="3"/>'),
  relancer: svg('<path d="M3 12a9 9 0 0 1 15.5-6.2L21 8M21 3v5h-5M21 12a9 9 0 0 1-15.5 6.2L3 16m0 5v-5h5"/>'),
  poubelle: svg('<path d="M3 6h18M8 6V4h8v2m1 0-1 14H8L7 6M10 11v5M14 11v5"/>'),
  dossier: svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
  ouvrir: svg('<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>'),
  enregistrer: svg('<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>'),
  alerte: svg('<path d="M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>'),
  ok: svg('<path d="M20 6 9 17l-5-5"/>'),
  info: svg('<circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v5h1"/>'),
  fleche: svg('<path d="M5 12h14m-6-6 6 6-6 6"/>'),
  chev: svg('<path d="m6 9 6 6 6-6"/>'),
  langue: svg('<path d="M5 8h10M9 4v4m-3 0c0 4 3 7 7 8M14 8c-1 4-4 7-9 8m8 4 4-9 4 9m-7-3h6"/>'),
  liste: svg('<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>'),
  qualite: svg('<rect x="2" y="4" width="20" height="16" rx="3"/><path d="M7 15V9l3 3 3-3v6M16 9v6"/>'),
  format: svg('<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>'),
  type: svg('<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>'),
  reglage: svg('<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>'),
  st: svg('<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M6 12h4M14 12h4M6 15h8"/>'),
  ciseaux: svg('<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12"/>'),
  horloge: svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  bouclier: svg('<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/>'),
  chapitres: svg('<path d="M4 6h16M4 12h16M4 18h10"/>'),
  disque: svg('<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>'),
  reseau: svg('<path d="M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M2 9a15 15 0 0 1 20 0M12 19.5h.01"/>'),
  compte: svg('<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'),
  systeme: svg('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>'),
  vide: svg('<path d="M12 3v12m0 0-5-5m5 5 5-5"/><path d="M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>'),
  biblio: svg('<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m10 9 5 3-5 3z"/>'),
  eclair: svg('<path d="M13 2 3 14h9l-1 8 10-12h-9z"/>'),
  micro: svg('<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/>'),
  vues: svg('<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/>'),
  calendrier: svg('<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M16 3v4M8 3v4M3 11h18"/>'),
  etoile: svg('<path d="m12 3 2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.4 6.8 19.1l1-5.8L3.5 9.2l5.9-.9z"/>'),
  lune: svg('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>'),
  soleil: svg('<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M2 12h2m16 0h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>'),
  croix: svg('<path d="M6 6l12 12M18 6 6 18"/>'),
};

// ── état ─────────────────────────────────────────────────────────────
const E = {
  vue: "telecharger",
  etat: null,
  taches: new Map(),
  rev: 0,
  saisie: "",
  chargement: null,
  erreur: null,
  resultat: null,
  choix: {},
  selection: new Set(),
  toutesLangues: false,
  filtreLangue: "",
  filtre: "tout",
  recherche_biblio: "",
  envoi: false,
};
const R = () => E.etat?.reglages || {};

const LANGUES = [
  ["fr", "🇫🇷 Français"], ["en", "🇬🇧 Anglais"], ["es", "🇪🇸 Espagnol"], ["de", "🇩🇪 Allemand"],
  ["it", "🇮🇹 Italien"], ["pt", "🇵🇹 Portugais"], ["ar", "🇸🇦 Arabe"], ["ru", "🇷🇺 Russe"],
  ["ja", "🇯🇵 Japonais"], ["ko", "🇰🇷 Coréen"], ["hi", "🇮🇳 Hindi"], ["tr", "🇹🇷 Turc"],
  ["pl", "🇵🇱 Polonais"], ["id", "🇮🇩 Indonésien"], ["zh", "🇨🇳 Chinois"], ["original", "🎙️ Version originale"],
];
const nomLangue = (c) => (LANGUES.find(([k]) => k === c)?.[1] || c).replace(/^\S+\s/, "");
const drapeauLangue = (c) => (LANGUES.find(([k]) => k === c)?.[1] || "🌐").split(" ")[0];
const QUALITES = [["best", "Meilleure"], ["2160", "4K"], ["1440", "2K"], ["1080", "1080p"], ["720", "720p"], ["480", "480p"], ["360", "360p"]];
const POPULAIRES = ["fr", "en", "es", "de", "it", "pt", "ar", "ja", "ko", "hi"];

function choixParDefaut() {
  const r = R();
  return {
    type: r.type || "video", qualite: r.qualite || "best", conteneur: r.conteneur || "mp4",
    format_audio: r.format_audio || "mp3", qualite_audio: r.qualite_audio || "0",
    langue_audio: null, garder_vo: r.garder_vo ?? true, sous_titres: [], sous_titres_auto: false,
    sous_titres_fichier: false, sponsorblock: r.sponsorblock || false, debut: "", fin: "",
    chapitres_separes: false, programme: "",
  };
}

// ── navigation ───────────────────────────────────────────────────────
const VUES = ["telecharger", "file", "bibliotheque", "reglages"];
function aller(vue, { histo = true } = {}) {
  if (!VUES.includes(vue)) vue = "telecharger";
  E.vue = vue;
  if (histo && location.hash.slice(1) !== vue) history.pushState(null, "", vue === "telecharger" ? "/" : `#${vue}`);
  $$("#nav button").forEach((b) => (b.dataset.vue === vue ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current")));
  placerIndicateur();
  rendre();
  window.scrollTo({ top: 0, behavior: "instant" });
  if (vue === "reglages" || vue === "bibliotheque") chargerEtat().then(() => E.vue === vue && vue === "bibliotheque" && rendre());
}
function placerIndicateur() {
  const b = $(`#nav button[data-vue="${E.vue}"]`), ind = $("#nav .indic");
  if (!b || !ind) return;
  ind.style.width = `${b.offsetWidth}px`;
  ind.style.transform = `translateX(${b.offsetLeft}px)`;
}
window.addEventListener("resize", placerIndicateur);
window.addEventListener("popstate", () => aller(location.hash.slice(1) || "telecharger", { histo: false }));
$("#nav").addEventListener("click", (e) => { const b = e.target.closest("button[data-vue]"); if (b) aller(b.dataset.vue); });

function rendre() {
  const vues = { telecharger: vueTelecharger, file: vueFile, bibliotheque: vueBibliotheque, reglages: vueReglages };
  $("#contenu").innerHTML = `<section class="vue">${html(vues[E.vue]())}</section>`;
  if (E.vue === "telecharger") apresTelecharger();
}

// ── thème ────────────────────────────────────────────────────────────
function majBoutonTheme() {
  $("#btn-theme").innerHTML = document.documentElement.dataset.theme === "clair" ? I.lune : I.soleil;
}
$("#btn-theme").addEventListener("click", () => {
  const t = document.documentElement.dataset.theme === "clair" ? "sombre" : "clair";
  const changer = () => { document.documentElement.dataset.theme = t; majBoutonTheme(); };
  document.startViewTransition ? document.startViewTransition(changer) : changer();
  try { localStorage.setItem("theme", t); } catch {}
});

// ── vue Télécharger ──────────────────────────────────────────────────
function vueTelecharger() {
  const compact = !!(E.resultat || E.chargement || E.erreur);
  return h`
  <div class="heros ${compact ? "compact" : ""}">
    ${compact ? "" : h`
      <div class="surtitre anim"><span>NOUVEAU</span>Doublages YouTube en français, automatiquement</div>
      <h1 class="anim" style="--i:1">Tes vidéos YouTube,<br><em>en français.</em></h1>
      <p class="chapo anim" style="--i:2">Colle un lien : YT-NEXUS récupère la piste audio doublée que YouTube propose, garde la VO en bonus, et s'occupe du reste.</p>`}
    <div class="saisie-cadre ${compact ? "" : "anim"}" style="--i:3">
      <form class="saisie" id="form-saisie">
        ${brut(I.lien)}
        <textarea id="saisie" rows="1" placeholder="Lien YouTube, playlist, chaîne… ou une recherche" autocomplete="off" spellcheck="false">${E.saisie}</textarea>
        <button type="button" class="btn fantome" id="btn-coller" title="Coller le presse-papiers">${brut(I.coller)}<span>Coller</span></button>
        <button type="submit" class="btn principal" id="btn-go"><span>Analyser</span>${brut(I.fleche)}</button>
      </form>
    </div>
    ${compact ? "" : h`
      <div class="caracteristiques">
        ${[[I.micro, "Doublage FR auto"], [I.qualite, "Jusqu'à 8K HDR"], [I.liste, "Playlists & chaînes"], [I.eclair, "Pause & reprise"], [I.st, "Sous-titres FR"]].map(([ic, t], i) => h`<span class="anim" style="--i:${i + 4}">${brut(ic)}${t}</span>`)}
      </div>
      <div class="astuces anim" style="--i:9"><span><kbd>Ctrl</kbd> <kbd>V</kbd> n'importe où pour coller</span><span><kbd>/</kbd> pour chercher</span><span>Glisse-dépose un lien</span></div>`}
  </div>
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}

function zoneResultat() {
  if (E.chargement) return squelette();
  if (E.erreur) return h`<div class="alerte err anim">${brut(I.alerte)}<span>${E.erreur}</span></div>`;
  const r = E.resultat;
  if (!r) return "";
  if (r.type === "video") return carteVideo(r);
  if (r.type === "playlist" || r.type === "lot") return cartePlaylist(r);
  if (r.type === "recherche") return grilleRecherche(r);
  return "";
}

function squelette() {
  if (E.chargement.startsWith("Recherche")) {
    return h`<div class="chargement-texte" style="margin-bottom:18px"><span class="rond"></span>${E.chargement}</div>
    <div class="grille-videos">${[...Array(8)].map((_, i) => h`<div class="verre carte-video anim" style="--i:${i}"><div class="squelette" style="aspect-ratio:16/9;border-radius:0"></div><div class="corps" style="flex-direction:column;gap:8px"><div class="squelette" style="height:14px;width:90%"></div><div class="squelette" style="height:12px;width:50%"></div></div></div>`)}</div>`;
  }
  return h`<div class="video">
    <div class="apercu"><div class="squelette" style="aspect-ratio:16/9;border-radius:20px"></div>
      <div class="apercu-infos" style="display:grid;gap:10px"><div class="squelette" style="height:22px;width:95%"></div><div class="squelette" style="height:22px;width:60%"></div><div class="squelette" style="height:34px;width:45%;border-radius:99px;margin-top:6px"></div></div></div>
    <div class="verre panneau" style="padding:26px;display:grid;gap:18px">
      <div class="chargement-texte"><span class="rond"></span>${E.chargement}</div>
      <div class="squelette" style="height:44px;width:260px;border-radius:15px"></div>
      <div class="langues">${[...Array(6)].map(() => h`<div class="squelette" style="height:64px;border-radius:16px"></div>`)}</div>
      <div class="qualites">${[...Array(6)].map(() => h`<div class="squelette" style="height:70px;border-radius:16px"></div>`)}</div>
    </div></div>`;
}

function pisteChoisie(v) {
  // null = langue préférée des réglages (avec repli VO + sous-titres côté serveur)
  return E.choix.langue_audio ?? (v.piste_voulue || v.originale);
}
const estChoisie = (p, choisie) => p.code === choisie || (p.originale && choisie === "original");

function carteLangue(p, choisie, i) {
  const genre = p.originale ? "Originale" : p.genre === "doublage IA" ? "Doublage IA" : "Doublage";
  return h`<button class="langue anim" style="--i:${i}" data-piste="${p.originale ? "original" : p.code}" aria-pressed="${estChoisie(p, choisie)}">
    <span class="drapeau">${p.drapeau}</span>
    <span><span class="nom">${nomPiste(p)}</span><span class="genre">${p.originale ? h`<span class="tag vo">VO</span>` : ""}${genre}</span></span>
    <span class="coche">${brut(I.ok)}</span>
  </button>`;
}

function blocLangues(v, choisie) {
  const pref = R().langue_audio || "fr";
  const vedettes = [];
  const ajouter = (p) => p && !vedettes.includes(p) && vedettes.push(p);
  ajouter(v.pistes.find((p) => base(p.code) === base(pref)));
  ajouter(v.pistes.find((p) => p.originale));
  for (const c of POPULAIRES) ajouter(v.pistes.find((p) => base(p.code) === c));
  const montrees = vedettes.slice(0, 6);
  const sel = v.pistes.find((p) => estChoisie(p, choisie));
  if (sel && !montrees.includes(sel)) montrees.push(sel);
  const autres = v.pistes.filter((p) => !montrees.includes(p));
  const f = E.filtreLangue.toLowerCase();
  const filtrees = autres.filter((p) => !f || nomPiste(p).toLowerCase().includes(f) || p.code.toLowerCase().includes(f));
  return h`
    <div class="langues">${montrees.map((p, i) => carteLangue(p, choisie, i))}</div>
    ${autres.length ? h`
      <div class="plus-langues"><button class="btn petit fantome" data-action="toutes-langues">${brut(I.langue)} ${E.toutesLangues ? "Masquer" : "Voir"} les ${autres.length} autres langues ${brut(I.chev)}</button></div>
      ${E.toutesLangues ? h`<div class="toutes-langues">
        <div class="avec-icone">${brut(I.chercher)}<input class="entree" id="filtre-langue" placeholder="Chercher une langue…" value="${E.filtreLangue}" /></div>
        <div class="puces">${filtrees.map((p) => h`<button class="puce" data-piste="${p.code}" aria-pressed="${estChoisie(p, choisie)}">${p.drapeau} ${nomPiste(p)}${p.genre === "doublage IA" ? h` <span class="tag ia">IA</span>` : ""}</button>`)}</div>
      </div>` : ""}` : ""}`;
}

function carteVideo(v) {
  const c = E.choix;
  const choisie = pisteChoisie(v);
  const estOriginale = choisie === v.originale || choisie === "original";
  const pref = R().langue_audio || "fr";
  const manque = pref !== "original" && v.pistes.length > 0 && !v.piste_voulue;
  const q = v.qualites.find((x) => String(x.hauteur) === String(c.qualite)) || v.qualites[0];
  const tailleAudio = v.taille_audio || 0;
  const vo = !estOriginale && c.garder_vo && c.type === "video";
  let est = c.type === "audio" ? tailleAudio : (q?.taille || 0) + (vo ? tailleAudio : 0);
  if (c.debut || c.fin) est = 0;
  const actif = (x) => String(c.qualite) === String(x.hauteur) || (c.qualite === "best" && x === v.qualites[0]) || (!v.qualites.some((y) => String(y.hauteur) === String(c.qualite)) && x === v.qualites[0]);
  const pisteSel = v.pistes.find((p) => estChoisie(p, choisie));
  const nbLangues = v.pistes.length;
  const avance = c.sous_titres.length || c.sponsorblock || c.debut || c.fin || c.programme || c.chapitres_separes;
  const tete = (icone, titre, aide = "") => h`<div class="etape-tete"><span class="num">${brut(icone)}</span><h3>${titre}</h3>${aide ? h`<span class="aide">${aide}</span>` : ""}</div>`;

  return h`
  <div class="video">
    <aside class="apercu anim">
      <div class="ambiance">
        ${v.miniature ? h`<img class="flou" src="${v.miniature}" alt="" referrerpolicy="no-referrer" />` : ""}
        <div class="vignette">${v.miniature ? h`<img src="${v.miniature}" alt="" referrerpolicy="no-referrer" />` : ""}${v.duree ? h`<span class="duree">${duree(v.duree)}</span>` : ""}</div>
      </div>
      <div class="apercu-infos">
        <h2>${v.titre}</h2>
        ${v.chaine ? h`<div class="chaine"><span class="avatar">${(v.chaine || "?").trim()[0].toUpperCase()}</span>${v.chaine}</div>` : ""}
        <div class="puces-meta">
          ${v.vues ? h`<span class="puce-meta">${brut(I.vues)}${vues(v.vues)}</span>` : ""}
          ${v.date ? h`<span class="puce-meta">${brut(I.calendrier)}${dateYT(v.date)}</span>` : ""}
          ${nbLangues > 1 ? h`<span class="puce-meta">${brut(I.langue)}${nbLangues} langues</span>` : ""}
          ${v.plateforme && v.plateforme !== "Youtube" ? h`<span class="puce-meta">${v.plateforme}</span>` : ""}
        </div>
        ${v.playlist ? h`<button class="btn petit" style="margin-top:16px" data-action="ouvrir-playlist">${brut(I.liste)} Toute la playlist</button>` : ""}
      </div>
      ${fichierFinal(v, { q, pisteSel, vo, manque })}
    </aside>

    <div class="verre panneau anim" style="--i:2">
      ${v.direct ? h`<div class="etape"><div class="alerte">${brut(I.alerte)}<span>C'est un <b>direct en cours</b> : attends la fin du live pour le télécharger.</span></div></div>` : ""}
      <div class="etape">
        ${tete(I.type, "Que veux-tu télécharger ?")}
        <div class="segment">
          <button data-type="video" aria-pressed="${c.type === "video"}">${brut(I.video)} Vidéo</button>
          <button data-type="audio" aria-pressed="${c.type === "audio"}">${brut(I.audio)} Audio seul</button>
        </div>
      </div>

      ${nbLangues > 1 || manque ? h`
      <div class="etape">
        ${tete(I.langue, "Langue audio", nbLangues > 1 ? `${nbLangues} pistes sur YouTube` : "")}
        ${manque && E.choix.langue_audio == null ? h`<div class="alerte info" style="margin-bottom:14px">${brut(I.info)}<span>Pas de doublage <b>${nomLangue(pref).toLowerCase()}</b> sur YouTube pour cette vidéo.${R().sous_titres_secours && c.type === "video" ? (v.sous_titres.auto || v.sous_titres.manuels.length ? " Elle sera téléchargée en VO avec les sous-titres intégrés." : " Pas de sous-titres non plus.") : ""}</span></div>` : ""}
        ${nbLangues > 1 ? blocLangues(v, choisie) : ""}
        ${!estOriginale && c.type === "video" ? h`
        <label class="option" style="margin-top:14px">
          <span class="ic">${brut(I.micro)}</span>
          <span class="texte"><b>Garder aussi la VO</b><span>${v.originale_nom || "Version originale"} en 2ᵉ piste — à choisir dans VLC, mpv ou ta TV</span></span>
          <input type="checkbox" class="interrupteur" data-opt="garder_vo" ${c.garder_vo ? "checked" : ""} />
        </label>` : ""}
      </div>` : ""}

      ${c.type === "video" && v.qualites.length ? h`
      <div class="etape">
        ${tete(I.qualite, "Qualité", "taille estimée")}
        <div class="qualites">${v.qualites.map((x, i) => h`
          <button class="qualite anim" style="--i:${i}" data-qualite="${x.hauteur}" aria-pressed="${actif(x)}">
            <b>${x.libelle}</b>
            <span class="ligne-q"><span class="taille">${x.taille ? taille(x.taille + (vo ? tailleAudio : 0)) : "—"}</span>${x.hdr ? h`<span class="tag ia">HDR</span>` : x.badge ? h`<span class="tag hd">${x.badge}</span>` : ""}</span>
          </button>`)}
        </div>
      </div>` : ""}

      <div class="etape">${tete(I.format, "Format")}${selecteurFormat()}</div>

      <details class="avance"${avance ? " open" : ""}>
        <summary>${brut(I.reglage)} Options avancées<span class="discret petit" style="font-weight:500">sous-titres, extrait, SponsorBlock, programmation</span>${brut(I.chev.replace("<svg", '<svg class="chev"'))}</summary>
        <div class="contenu-avance">
          ${c.type === "video" && (v.sous_titres.manuels.length || v.sous_titres.auto_fr) ? h`
          <div><div class="sous-titre-bloc">Sous-titres</div>
            <div class="puces">
              ${v.sous_titres.auto_fr ? h`<button class="puce" data-st="fr" aria-pressed="${c.sous_titres.includes("fr")}">🇫🇷 Français <span class="tag ia">auto</span></button>` : ""}
              ${v.sous_titres.manuels.slice(0, 30).map((s) => h`<button class="puce" data-st="${s.code}" aria-pressed="${c.sous_titres.includes(s.code)}">${s.drapeau} ${nomPiste(s)}</button>`)}
            </div>
            ${c.sous_titres.length ? h`<label class="option" style="margin-top:10px"><span class="texte"><b>Fichiers .srt séparés</b><span>Sinon intégrés directement dans la vidéo</span></span><input type="checkbox" class="interrupteur" data-opt="sous_titres_fichier" ${c.sous_titres_fichier ? "checked" : ""} /></label>` : ""}
          </div>` : ""}
          ${optionsAvancees(v.chapitres)}
        </div>
      </details>

      <div class="barre-action">
        <div class="recap">
          ${c.type === "audio" ? h`<span>${brut(I.audio.replace("<svg", '<svg style="width:16px;height:16px;vertical-align:-3px"'))} Audio ${(c.format_audio || "mp3").toUpperCase()}</span>` : h`<span>${q?.libelle || "Meilleure"}</span><span class="sep"></span><span>${(c.conteneur || "mp4").toUpperCase()}</span>`}
          ${pisteSel ? h`<span class="sep"></span><span>${pisteSel.drapeau} ${nomPiste(pisteSel)}${vo ? " + VO" : ""}</span>` : ""}
          ${est ? h`<span class="sep"></span><span class="poids">≈ ${taille(est)}</span>` : ""}
        </div>
        <button class="btn principal grand" data-action="telecharger" ${E.envoi || v.direct ? "disabled" : ""}>${brut(c.programme ? I.horloge : I.dl)} ${c.programme ? "Programmer" : "Télécharger"}</button>
      </div>
    </div>
  </div>`;
}

function fichierFinal(v, { q, pisteSel, vo, manque }) {
  const c = E.choix;
  const lignes = [];
  if (c.type === "video") lignes.push([I.video, `Vidéo ${q?.libelle || ""}`.trim(), (c.conteneur || "mp4").toUpperCase(), ""]);
  if (pisteSel) lignes.push([I.audio, `${pisteSel.drapeau} ${nomPiste(pisteSel)}`, c.type === "audio" ? (c.format_audio || "mp3").toUpperCase() : "Piste 1 · par défaut", "fr"]);
  if (vo) { const o = v.pistes.find((p) => p.originale); lignes.push([I.audio, `${o?.drapeau || "🎙️"} ${o ? nomPiste(o) : "VO"}`, "Piste 2 · VO", ""]); }
  const st = [...c.sous_titres];
  if (manque && E.choix.langue_audio == null && c.type === "video" && R().sous_titres_secours && (v.sous_titres.auto || v.sous_titres.manuels.length)) st.unshift(R().langue_audio || "fr");
  if (st.length && c.type === "video") lignes.push([I.st, `Sous-titres ${[...new Set(st)].map((x) => x.toUpperCase()).join(", ")}`, c.sous_titres_fichier ? "fichiers .srt" : "intégrés", ""]);
  if (c.sponsorblock) lignes.push([I.bouclier, "Sans sponsors", "SponsorBlock", ""]);
  if (c.debut || c.fin) lignes.push([I.ciseaux, `Extrait ${c.debut || "0:00"} → ${c.fin || "fin"}`, "", ""]);
  return h`<div class="verre fichier-final">
    <div class="sous-titre-bloc">Ton fichier</div>
    ${lignes.map(([ic, t, d, cls]) => h`<div class="piste-ff ${cls}"><span class="ic">${brut(ic)}</span><span class="t">${t}</span><span class="d">${d}</span></div>`)}
  </div>`;
}

function selecteurFormat() {
  const c = E.choix;
  if (c.type === "audio") {
    return h`<div class="segment">
      ${[["mp3", "MP3"], ["m4a", "M4A"], ["opus", "Opus"], ["flac", "FLAC"], ["wav", "WAV"], ["original", "Original"]].map(([k, l]) => h`<button data-format-audio="${k}" aria-pressed="${c.format_audio === k}">${l}</button>`)}
    </div>
    ${c.format_audio !== "original" && !["flac", "wav"].includes(c.format_audio) ? h`
    <div style="margin-top:12px;max-width:260px"><select class="entree" data-opt="qualite_audio">
      ${[["0", "Meilleure qualité"], ["320K", "320 kbit/s"], ["256K", "256 kbit/s"], ["192K", "192 kbit/s"], ["128K", "128 kbit/s"]].map(([k, l]) => h`<option value="${k}" ${c.qualite_audio === k ? "selected" : ""}>${l}</option>`)}
    </select></div>` : ""}`;
  }
  return h`<div class="segment">
    ${[["mp4", "MP4", "partout"], ["mkv", "MKV", "flexible"], ["webm", "WebM", "web"]].map(([k, l, d]) => h`<button data-conteneur="${k}" aria-pressed="${c.conteneur === k}">${l} <small>${d}</small></button>`)}
  </div>`;
}

function optionsAvancees(chapitres) {
  const c = E.choix;
  return h`
  <div><div class="sous-titre-bloc">Extrait et programmation</div>
    <div class="grille">
      <div class="champ"><label>Début</label><div class="avec-icone">${brut(I.ciseaux)}<input class="entree" data-opt="debut" placeholder="ex. 1:30" value="${c.debut}" /></div></div>
      <div class="champ"><label>Fin</label><div class="avec-icone">${brut(I.ciseaux)}<input class="entree" data-opt="fin" placeholder="ex. 5:00" value="${c.fin}" /></div></div>
      <div class="champ"><label>Programmer pour</label><input class="entree" type="datetime-local" data-opt="programme" value="${c.programme}" /></div>
    </div>
  </div>
  <div class="options">
    <label class="option"><span class="ic">${brut(I.bouclier)}</span><span class="texte"><b>Retirer les sponsors</b><span>Coupe les passages sponsorisés et autopromos (SponsorBlock)</span></span><input type="checkbox" class="interrupteur" data-opt="sponsorblock" ${c.sponsorblock ? "checked" : ""} /></label>
    ${chapitres && c.type === "video" ? h`<label class="option"><span class="ic">${brut(I.chapitres)}</span><span class="texte"><b>Un fichier par chapitre</b><span>${chapitres} chapitres en plus de la vidéo complète</span></span><input type="checkbox" class="interrupteur" data-opt="chapitres_separes" ${c.chapitres_separes ? "checked" : ""} /></label>` : ""}
  </div>`;
}

function cartePlaylist(p) {
  const c = E.choix;
  const n = E.selection.size;
  const langue = c.langue_audio ?? R().langue_audio ?? "fr";
  const dureeTotale = [...E.selection].reduce((s, i) => s + (p.entrees[i]?.duree || 0), 0);
  return h`
  <div class="verre panneau anim">
    <div class="tete-playlist">
      ${p.miniature ? h`<div class="ambiance" style="flex:none"><img class="flou" src="${p.miniature}" alt="" referrerpolicy="no-referrer" /><div class="vignette" style="width:220px"><img src="${p.miniature}" alt="" referrerpolicy="no-referrer" /></div></div>` : ""}
      <div style="min-width:0">
        <span class="etiquette-type">${brut(I.liste.replace("<svg", '<svg style="width:13px;height:13px"'))} ${p.type === "lot" ? "Plusieurs liens" : "Playlist"}</span>
        <h2 style="margin-top:10px">${p.titre}</h2>
        <div class="puces-meta">${p.chaine ? h`<span class="puce-meta">${p.chaine}</span>` : ""}<span class="puce-meta">${p.nombre} vidéo${p.nombre > 1 ? "s" : ""}</span>${dureeTotale ? h`<span class="puce-meta">${brut(I.horloge)}${duree(dureeTotale)}</span>` : ""}</div>
      </div>
    </div>
    <div class="etape">
      <div class="grille" style="align-items:end">
        <div class="champ"><span>Type</span>
          <div class="segment">
            <button data-type="video" aria-pressed="${c.type === "video"}">${brut(I.video)} Vidéo</button>
            <button data-type="audio" aria-pressed="${c.type === "audio"}">${brut(I.audio)} Audio</button>
          </div>
        </div>
        <div class="champ"><label>Langue audio, si YouTube la propose</label>
          <select class="entree" data-opt="langue_audio">${LANGUES.map(([k, l]) => h`<option value="${k}" ${langue === k ? "selected" : ""}>${l}</option>`)}</select>
        </div>
        ${c.type === "video" ? h`<div class="champ"><label>Qualité maximale</label>
          <select class="entree" data-opt="qualite">${QUALITES.map(([k, l]) => h`<option value="${k}" ${String(c.qualite) === k ? "selected" : ""}>${l}</option>`)}</select></div>` : ""}
      </div>
      <div style="margin-top:16px">${selecteurFormat()}</div>
      ${c.type === "video" && langue !== "original" ? h`<label class="option" style="margin-top:14px"><span class="ic">${brut(I.micro)}</span><span class="texte"><b>Garder aussi la VO</b><span>En 2ᵉ piste, quand un doublage existe</span></span><input type="checkbox" class="interrupteur" data-opt="garder_vo" ${c.garder_vo ? "checked" : ""} /></label>` : ""}
    </div>
    <details class="avance" style="border-top:1px solid var(--trait)"><summary>${brut(I.reglage)} Options avancées${brut(I.chev.replace("<svg", '<svg class="chev"'))}</summary><div class="contenu-avance">${optionsAvancees()}</div></details>
    <div class="selection-barre" style="border-top:1px solid var(--trait)">
      <input type="checkbox" class="case" id="tout-cocher" ${n === p.entrees.length ? "checked" : ""} />
      <label for="tout-cocher" style="font-weight:700;font-size:.9rem;cursor:pointer">Tout sélectionner</label>
      <span style="margin-left:auto" class="muet petit mono">${n} / ${p.entrees.length}</span>
    </div>
    <div class="liste-entrees" id="liste-entrees">
      ${p.entrees.map((e, i) => h`
      <label class="entree-pl">
        <input type="checkbox" class="case" data-sel="${i}" ${E.selection.has(i) ? "checked" : ""} />
        <span class="n">${i + 1}</span>
        ${e.miniature ? h`<img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : h`<span class="squelette"></span>`}
        <span class="t">${e.titre}</span>
        <span class="d">${duree(e.duree)}</span>
      </label>`)}
    </div>
    <div class="barre-action">
      <div class="recap"><span>${n} vidéo${n > 1 ? "s" : ""}</span><span class="sep"></span><span>${drapeauLangue(langue)} ${nomLangue(langue)}</span><span class="sep"></span><span>${c.type === "audio" ? (c.format_audio || "mp3").toUpperCase() : `${QUALITES.find(([k]) => k === String(c.qualite))?.[1] || c.qualite} · ${(c.conteneur || "mp4").toUpperCase()}`}</span></div>
      <button class="btn principal grand" data-action="telecharger-selection" ${!n || E.envoi ? "disabled" : ""}>${brut(c.programme ? I.horloge : I.dl)} ${c.programme ? "Programmer" : "Tout télécharger"}</button>
    </div>
  </div>`;
}

function grilleRecherche(r) {
  if (!r.resultats.length) return h`<div class="vide"><div class="halo">${brut(I.chercher)}</div><h3>Aucun résultat</h3><p>Essaie d'autres mots-clés.</p></div>`;
  return h`<div class="titre-section"><h2>Résultats</h2><span class="muet">pour « ${r.requete} »</span></div>
  <div class="grille-videos">${r.resultats.map((e, i) => h`
    <article class="verre carte-video anim" style="--i:${Math.min(i, 12)}" data-res="${i}" tabindex="0">
      <div class="vignette"><img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />
        <span class="survol"><span class="rond-lecture">${brut(I.chercher)}</span></span>
        ${e.duree ? h`<span class="duree">${duree(e.duree)}</span>` : e.direct ? h`<span class="duree" style="background:var(--rouge)">DIRECT</span>` : ""}</div>
      <div class="corps">
        <div style="flex:1;min-width:0"><div class="t">${e.titre}</div><div class="s">${e.chaine || ""}${e.vues ? " · " + vues(e.vues) : ""}</div></div>
        <button class="icone-btn accent" data-rapide="${i}" title="Télécharger directement avec les réglages par défaut">${brut(I.dl)}</button>
      </div>
    </article>`)}
  </div>`;
}

function rafraichirResultat() {
  const z = $("#resultat");
  if (!z) return rendre();
  const heros = $(".heros");
  const compact = !!(E.resultat || E.chargement || E.erreur);
  if (heros && heros.classList.contains("compact") !== compact) return rendre();
  const ouvert = $("details.avance", z)?.open;
  const defil = $("#liste-entrees", z)?.scrollTop;
  const focus = document.activeElement?.id;
  z.innerHTML = html(zoneResultat());
  // pas de ré-animation à chaque clic : seulement au premier affichage
  $$(".anim", z).forEach((el) => el.classList.remove("anim"));
  if (ouvert) $("details.avance", z)?.setAttribute("open", "");
  if (defil) $("#liste-entrees", z).scrollTop = defil;
  if (focus === "filtre-langue") { const f = $("#filtre-langue"); f?.focus(); f?.setSelectionRange(f.value.length, f.value.length); }
}
function afficherResultat() {
  const z = $("#resultat");
  if (!z || $(".heros")?.classList.contains("compact") !== !!(E.resultat || E.chargement || E.erreur)) return rendre();
  z.innerHTML = html(zoneResultat());
}

function apresTelecharger() {
  const ta = $("#saisie");
  const ajuster = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 180) + "px"; };
  ajuster();
  ta.addEventListener("input", () => { E.saisie = ta.value; ajuster(); $("#btn-go span").textContent = libelleGo(); });
  ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); lancerSaisie(); } });
  $("#btn-go span").textContent = libelleGo();
  $("#form-saisie").addEventListener("submit", (e) => { e.preventDefault(); lancerSaisie(); });
  $("#btn-coller").addEventListener("click", async () => {
    try {
      const t = (await navigator.clipboard.readText()).trim();
      if (!t) return toast("Le presse-papiers est vide.");
      E.saisie = t; ta.value = t; ajuster(); lancerSaisie();
    } catch { ta.focus(); toast("Fais Ctrl+V dans le champ (accès au presse-papiers refusé)."); }
  });
  if (!E.resultat && !E.chargement) ta.focus({ preventScroll: true });
}

const libelleGo = () => {
  const lignes = E.saisie.split(/\s*\n\s*/).filter(Boolean);
  if (!lignes.length) return "Analyser";
  if (lignes.length > 1 && lignes.every(estUrl)) return `${lignes.length} liens`;
  return estUrl(lignes[0]) ? "Analyser" : "Rechercher";
};

async function lancerSaisie(texte = E.saisie) {
  const liens = texte.split(/\s+/).map((s) => s.trim()).filter(estUrl);
  if (!texte.trim()) return $("#saisie")?.focus();
  E.erreur = null; E.resultat = null; E.toutesLangues = false; E.filtreLangue = "";
  if (liens.length > 1) {
    E.choix = choixParDefaut();
    const entrees = [...new Set(liens)].map((u) => ({ url: u, titre: u }));
    E.resultat = { type: "lot", titre: `${entrees.length} liens`, nombre: entrees.length, entrees };
    E.selection = new Set(entrees.map((_, i) => i));
    return afficherResultat();
  }
  if (liens.length === 1) return analyser(liens[0]);
  return rechercher(texte.trim());
}

async function analyser(url) {
  E.chargement = "Analyse : pistes audio, qualités, sous-titres…"; E.erreur = null; E.resultat = null;
  if (E.vue !== "telecharger") aller("telecharger"); else afficherResultat();
  try {
    const r = await api("/analyse", { methode: "POST", corps: { url } });
    E.choix = choixParDefaut();
    E.resultat = r;
    if (r.type === "playlist") E.selection = new Set(r.entrees.map((_, i) => i));
  } catch (e) { E.erreur = e.message; }
  E.chargement = null;
  afficherResultat();
}

async function rechercher(q) {
  E.chargement = `Recherche « ${q} »…`; afficherResultat();
  try {
    const r = await api("/recherche", { methode: "POST", corps: { q } });
    E.resultat = { type: "recherche", requete: q, resultats: r.resultats };
  } catch (e) { E.erreur = e.message; }
  E.chargement = null; afficherResultat();
}

function optionsEnvoi() {
  const c = { ...E.choix };
  if (c.programme) c.programme = Math.floor(new Date(c.programme).getTime() / 1000);
  else delete c.programme;
  if (c.langue_audio == null) delete c.langue_audio;
  if (c.sous_titres.includes("fr")) c.sous_titres_auto = true;
  return c;
}

async function envoyer(elements, bouton) {
  E.envoi = true;
  if (bouton) { bouton.disabled = true; bouton.innerHTML = '<span class="rond mini"></span> Envoi…'; }
  try {
    const r = await api("/telechargements", { methode: "POST", corps: { elements, options: optionsEnvoi() } });
    r.taches.forEach(fusionner);
    const n = r.taches.length;
    toast(n > 1 ? `${n} téléchargements ajoutés à la file` : E.choix.programme ? "Téléchargement programmé" : "C'est parti ! Suis-le dans la file.", "ok");
    majPastille();
    if (bouton) { bouton.innerHTML = `${I.ok} Ajouté`; setTimeout(() => { E.envoi = false; rafraichirResultat(); }, 1400); return; }
  } catch (e) { toast(e.message, "err"); }
  E.envoi = false; rafraichirResultat();
}

// Interactions de la vue Télécharger (délégation)
$("#contenu").addEventListener("click", (e) => {
  if (E.vue !== "telecharger") return;
  const el = e.target.closest("[data-type],[data-piste],[data-qualite],[data-st],[data-action],[data-res],[data-rapide],[data-conteneur],[data-format-audio]");
  if (!el) return;
  const r = E.resultat;
  if (el.dataset.type) { E.choix.type = el.dataset.type; return rafraichirResultat(); }
  if (el.dataset.piste) { E.choix.langue_audio = el.dataset.piste; return rafraichirResultat(); }
  if (el.dataset.qualite) { E.choix.qualite = el.dataset.qualite; return rafraichirResultat(); }
  if (el.dataset.conteneur) { E.choix.conteneur = el.dataset.conteneur; return rafraichirResultat(); }
  if (el.dataset.formatAudio) { E.choix.format_audio = el.dataset.formatAudio; return rafraichirResultat(); }
  if (el.dataset.st) {
    const s = new Set(E.choix.sous_titres);
    s.has(el.dataset.st) ? s.delete(el.dataset.st) : s.add(el.dataset.st);
    E.choix.sous_titres = [...s]; return rafraichirResultat();
  }
  if (el.dataset.rapide) {
    e.stopPropagation();
    const x = r.resultats[+el.dataset.rapide];
    E.choix = choixParDefaut();
    el.classList.remove("accent");
    return envoyer([{ url: x.url, titre: x.titre, miniature: x.miniature, chaine: x.chaine, duree: x.duree }]);
  }
  if (el.dataset.res) { const x = r.resultats[+el.dataset.res]; E.saisie = x.url; return analyser(x.url).then(() => window.scrollTo({ top: 0, behavior: "smooth" })); }
  const a = el.dataset.action;
  if (a === "toutes-langues") { E.toutesLangues = !E.toutesLangues; return rafraichirResultat(); }
  if (a === "ouvrir-playlist") { E.saisie = r.playlist; return analyser(r.playlist); }
  if (a === "telecharger") return envoyer([{ url: r.url, titre: r.titre, miniature: r.miniature, chaine: r.chaine, duree: r.duree }], el);
  if (a === "telecharger-selection") {
    const groupe = r.type === "playlist" ? r.titre : null;
    return envoyer([...E.selection].sort((x, y) => x - y).map((i) => ({ ...r.entrees[i], groupe })), el);
  }
});
$("#contenu").addEventListener("keydown", (e) => {
  if (E.vue === "telecharger" && e.key === "Enter" && e.target.dataset?.res) e.target.click();
});
$("#contenu").addEventListener("change", (e) => {
  const el = e.target;
  if (E.vue === "telecharger") {
    if (el.id === "tout-cocher") { E.selection = el.checked ? new Set(E.resultat.entrees.map((_, i) => i)) : new Set(); return rafraichirResultat(); }
    if (el.dataset.sel) { el.checked ? E.selection.add(+el.dataset.sel) : E.selection.delete(+el.dataset.sel); return rafraichirResultat(); }
    if (el.dataset.opt) {
      E.choix[el.dataset.opt] = el.type === "checkbox" ? el.checked : el.value;
      if (el.type === "checkbox" || el.tagName === "SELECT" || el.dataset.opt === "programme") rafraichirResultat();
    }
  } else if (E.vue === "reglages") changerReglage(el);
});
$("#contenu").addEventListener("input", (e) => {
  const el = e.target;
  if (E.vue === "telecharger" && el.id === "filtre-langue") { E.filtreLangue = el.value; return rafraichirResultat(); }
  if (E.vue === "telecharger" && el.dataset.opt && el.tagName === "INPUT" && el.type !== "checkbox") E.choix[el.dataset.opt] = el.value;
  if (E.vue === "bibliotheque" && el.id === "recherche-biblio") { E.recherche_biblio = el.value; rendreListeBiblio(); }
});

// ── vue File ─────────────────────────────────────────────────────────
const LIBELLES = {
  en_attente: "En attente", programme: "Programmé", analyse: "Analyse", telechargement: "Téléchargement",
  traitement: "Finalisation", attente_relance: "Nouvelle tentative", pause: "En pause", termine: "Terminé",
  erreur: "Erreur", annule: "Annulé",
};
const ACTIFS = new Set(["analyse", "telechargement", "traitement", "attente_relance"]);
const FILTRES = {
  tout: [() => true, "Tout"],
  cours: [(t) => ACTIFS.has(t.statut), "En cours"],
  attente: [(t) => ["en_attente", "programme"].includes(t.statut), "En attente"],
  pause: [(t) => t.statut === "pause", "En pause"],
  echecs: [(t) => ["erreur", "annule"].includes(t.statut), "Échecs"],
};
const tachesFile = () => [...E.taches.values()].filter((t) => t.statut !== "termine").sort((a, b) => a.cree - b.cree);

function vueFile() {
  const toutes = tachesFile();
  const liste = toutes.filter(FILTRES[E.filtre][0]);
  return h`
  <div class="tete-page anim">
    <h2>File de téléchargement</h2><span class="compte">${toutes.length}</span>
    <div class="actions">
      <button class="btn petit fantome" data-global="pause_tout">${brut(I.pause)} Tout en pause</button>
      <button class="btn petit fantome" data-global="reprendre_tout">${brut(I.lecture)} Tout reprendre</button>
      <button class="btn petit fantome" data-global="relancer_erreurs">${brut(I.relancer)} Relancer les échecs</button>
      <button class="btn petit fantome danger" data-global="vider_echecs">${brut(I.poubelle)} Vider les échecs</button>
    </div>
  </div>
  <div class="onglets anim" style="--i:1">${Object.entries(FILTRES).map(([k, [f, l]]) => h`<button data-filtre="${k}" aria-pressed="${E.filtre === k}">${l}<span class="n">${toutes.filter(f).length}</span></button>`)}</div>
  <div class="taches" id="liste-taches">
    ${liste.length ? liste.map((t, i) => carteTache(t, i)) : h`<div class="vide anim"><div class="halo">${brut(I.vide)}</div><h3>Rien en cours</h3><p>Colle un lien pour lancer un téléchargement. Les vidéos terminées t'attendent dans la Bibliothèque.</p><button class="btn principal" data-aller="telecharger">${brut(I.dl)} Télécharger une vidéo</button></div>`}
  </div>`;
}

function chiffresTache(t) {
  if (t.statut === "telechargement") {
    return h`${t.total ? h`<span><b>${taille(t.telecharge)}</b> / ${taille(t.total)}</span>` : ""}${t.vitesse ? h`<span>${taille(t.vitesse)}/s</span>` : ""}${t.eta != null ? h`<span>reste ${restant(t.eta)}</span>` : ""}`;
  }
  if (t.statut === "termine") return h`<span>${taille(t.taille_fichier)}</span><span>${quand(t.fin)}</span>`;
  if (t.statut === "programme") return h`<span>Prévu le ${quand(t.programme)}</span>`;
  if (["pause", "erreur"].includes(t.statut) && t.total) return h`<span>${taille(t.telecharge)} / ${taille(t.total)}</span>`;
  return "";
}
const pourcent = (t) => (["telechargement", "pause", "traitement", "attente_relance"].includes(t.statut) || (t.statut === "erreur" && t.progression) ? h`${Math.floor(t.progression)}<small>%</small>` : "");

function boutonsTache(t) {
  const b = (action, icone, titre, cls = "") => h`<button class="icone-btn ${cls}" data-t="${t.id}" data-act="${action}" title="${titre}" aria-label="${titre}">${brut(icone)}</button>`;
  const r = [];
  if (ACTIFS.has(t.statut) || ["en_attente", "programme"].includes(t.statut)) r.push(b("pause", I.pause, "Mettre en pause"));
  if (t.statut === "pause") r.push(b("reprendre", I.lecture, "Reprendre", "accent"));
  if (["erreur", "annule"].includes(t.statut)) r.push(b("relancer", I.relancer, "Réessayer", "accent"));
  if (!["termine", "annule", "erreur"].includes(t.statut)) r.push(b("annuler", I.stop, "Annuler", "danger"));
  r.push(b("supprimer", I.poubelle, "Retirer de la liste", "danger"));
  return r;
}

function carteTache(t, i = 0) {
  const msg = t.erreur ? h`<div class="msg err">${brut(I.alerte)}${t.erreur}</div>` : t.message ? h`<div class="msg">${brut(I.info)}${t.message}</div>` : "";
  const largeur = t.statut === "analyse" || t.statut === "traitement" ? 100 : t.progression;
  return h`
  <article class="verre tache ${t.statut} anim" style="--i:${Math.min(i, 10)}" id="t-${t.id}">
    <div class="vignette">${t.miniature ? h`<img src="${t.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : ""}${t.duree ? h`<span class="duree">${duree(t.duree)}</span>` : ""}</div>
    <div style="min-width:0">
      <h4 title="${t.titre}">${t.titre}</h4>
      <div class="sous-ligne">
        <span class="statut ${t.statut}"><span class="point"></span>${LIBELLES[t.statut] || t.statut}</span>
        ${t.options?.type === "audio" ? h`<span class="info-chip">${(t.options.format_audio || "mp3").toUpperCase()}</span>` : ""}
        ${t.pistes ? h`<span class="info-chip">${t.pistes}</span>` : ""}
        ${t.groupe ? h`<span class="info-chip">${brut(I.liste.replace("<svg", '<svg style="width:12px;height:12px"'))}${t.groupe}</span>` : ""}
        <span data-champ="phase" class="discret">${t.phase || ""}</span>
      </div>
      <div class="progres"><i data-champ="barre" style="width:${largeur}%"></i></div>
      <div class="chiffres" data-champ="chiffres">${chiffresTache(t)}</div>
      ${msg}
    </div>
    <div class="cote">
      <div class="pourcent" data-champ="pourcent">${pourcent(t)}</div>
      <div class="boutons-tache">${boutonsTache(t)}</div>
    </div>
  </article>`;
}

// Mise à jour ciblée d'une carte (évite de tout redessiner 4 fois par seconde)
function majCarte(t, ancien) {
  const el = document.getElementById(`t-${t.id}`);
  if (!el) return false;
  if (!ancien || ancien.statut !== t.statut || ancien.message !== t.message || ancien.erreur !== t.erreur || ancien.pistes !== t.pistes || ancien.titre !== t.titre || ancien.miniature !== t.miniature) {
    const tmp = document.createElement("div");
    tmp.innerHTML = html(carteTache(t));
    tmp.firstElementChild.classList.remove("anim");
    el.replaceWith(tmp.firstElementChild);
    return true;
  }
  const barre = $('[data-champ="barre"]', el);
  if (barre && t.statut === "telechargement") barre.style.width = `${t.progression}%`;
  $('[data-champ="phase"]', el).textContent = t.phase || "";
  $('[data-champ="chiffres"]', el).innerHTML = html(chiffresTache(t));
  $('[data-champ="pourcent"]', el).innerHTML = html(pourcent(t));
  return true;
}

$("#contenu").addEventListener("click", async (e) => {
  const versVue = e.target.closest("[data-aller]");
  if (versVue) { e.preventDefault(); return aller(versVue.dataset.aller); }
  const f = e.target.closest("[data-filtre]");
  if (f) { E.filtre = f.dataset.filtre; return rendre(); }
  const g = e.target.closest("[data-global]");
  if (g) {
    try { await api(`/telechargements/tout/${g.dataset.global}`, { methode: "POST" }); } catch (err) { toast(err.message, "err"); }
    return;
  }
  if (e.target.closest("[data-ouvrir-dossier]")) return api("/ouvrir-dossier", { methode: "POST" }).catch((err) => toast(err.message, "err"));
  const b = e.target.closest("[data-act]");
  if (!b) return;
  e.stopPropagation();
  const t = E.taches.get(b.dataset.t);
  if (!t) return;
  const act = b.dataset.act;
  try {
    if (["pause", "reprendre", "annuler", "relancer"].includes(act)) await api(`/telechargements/${t.id}/${act}`, { methode: "POST" });
    else if (act === "lire") lire(t);
    else if (act === "ouvrir" || act === "dossier") await api(`/ouvrir/${t.id}`, { methode: "POST", corps: { dossier: act === "dossier" } });
    else if (act === "enregistrer") { const a = document.createElement("a"); a.href = `/api/fichier/${t.id}?enregistrer=1`; a.click(); }
    else if (act === "supprimer") {
      let fichier = false;
      if (t.statut === "termine" && t.fichier) {
        const rep = await choisir(`Retirer « ${t.titre} » ?`, "Le fichier peut rester sur ton disque.", [["liste", "Retirer de la liste"], ["fichier", "Supprimer le fichier"]]);
        if (!rep) return;
        fichier = rep === "fichier";
      }
      await api(`/telechargements/${t.id}${fichier ? "?fichier=1" : ""}`, { methode: "DELETE" });
      if (fichier) toast("Fichier supprimé", "ok");
    }
  } catch (err) { toast(err.message, "err"); }
});

function choisir(question, detail, options) {
  return new Promise((ok) => {
    const d = document.createElement("dialog");
    d.style.width = "min(460px, calc(100vw - 32px))";
    d.innerHTML = html(h`<div style="padding:26px"><h3 style="font-size:1.1rem;font-weight:800;margin-bottom:6px">${question}</h3><p class="muet petit" style="margin-bottom:22px">${detail}</p>
      <div style="display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap"><button class="btn petit fantome" value="">Annuler</button>
      ${options.map(([v, l], i) => h`<button class="btn petit ${i === options.length - 1 ? "danger" : ""}" value="${v}">${l}</button>`)}</div></div>`);
    d.addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) d.close(b.value); else if (e.target === d) d.close(""); });
    d.addEventListener("close", () => { ok(d.returnValue); d.remove(); });
    document.body.append(d); d.showModal();
  });
}

function lire(t) {
  const d = $("#lecteur"), v = $("#lecteur-video");
  $("#lecteur-titre").textContent = t.titre;
  v.src = `/api/fichier/${t.id}`;
  d.showModal(); v.play().catch(() => {});
}
$("#lecteur").addEventListener("close", () => { const v = $("#lecteur-video"); v.pause(); v.removeAttribute("src"); v.load(); });
$("#lecteur").addEventListener("click", (e) => { if (e.target.closest("[data-fermer]") || e.target === e.currentTarget) $("#lecteur").close(); });

// ── vue Bibliothèque ─────────────────────────────────────────────────
function vueBibliotheque() {
  const termines = [...E.taches.values()].filter((t) => t.statut === "termine");
  const total = termines.reduce((s, t) => s + (t.taille_fichier || 0), 0);
  const d = E.etat?.disque;
  return h`
  <div class="tete-page anim">
    <h2>Bibliothèque</h2><span class="compte">${termines.length}</span>
    <div class="actions">
      ${E.etat?.local !== false ? h`<button class="btn petit" data-ouvrir-dossier>${brut(I.dossier)} Ouvrir le dossier</button>` : ""}
      <button class="btn petit fantome danger" data-global="vider_termines">${brut(I.poubelle)} Vider la liste</button>
    </div>
  </div>
  <div class="stats">
    <div class="verre stat anim" style="--i:1"><span class="ic g1">${brut(I.biblio)}</span><div><div class="v">${termines.length}</div><div class="l">fichiers téléchargés</div></div></div>
    <div class="verre stat anim" style="--i:2"><span class="ic g2">${brut(I.disque)}</span><div><div class="v">${taille(total)}</div><div class="l">au total</div></div></div>
    ${d ? h`<div class="verre stat anim" style="--i:3"><span class="ic g3">${brut(I.dossier)}</span><div style="flex:1"><div class="v">${taille(d.libre)}</div><div class="l">libres sur le disque</div><div class="jauge"><i style="width:${((1 - d.libre / d.total) * 100).toFixed(1)}%"></i></div></div></div>` : ""}
  </div>
  <div class="avec-icone anim" style="--i:4;margin-bottom:20px">${brut(I.chercher)}<input class="entree" id="recherche-biblio" placeholder="Rechercher dans la bibliothèque…" value="${E.recherche_biblio}" style="height:50px;border-radius:16px" /></div>
  <div class="biblio" id="liste-biblio">${listeBiblio()}</div>`;
}
function carteBiblio(t, i) {
  const b = (action, icone, titre, cls = "") => h`<button class="icone-btn ${cls}" data-t="${t.id}" data-act="${action}" title="${titre}" aria-label="${titre}">${brut(icone)}</button>`;
  const local = E.etat?.local !== false;
  return h`<article class="verre carte-video anim" style="--i:${Math.min(i, 12)}" data-t="${t.id}" data-act="lire">
    <div class="vignette">${t.miniature ? h`<img src="${t.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : ""}
      <span class="survol"><span class="rond-lecture">${brut(I.lecture)}</span></span>
      ${t.options?.type === "audio" ? h`<span class="badge-audio">${(t.options.format_audio || "mp3").toUpperCase()}</span>` : ""}
      ${t.duree ? h`<span class="duree">${duree(t.duree)}</span>` : ""}</div>
    <div class="corps">
      <div class="t" title="${t.titre}">${t.titre}</div>
      <div class="s">${taille(t.taille_fichier)} · ${quand(t.fin)}</div>
      ${t.pistes ? h`<div class="infos-carte"><span class="info-chip">${t.pistes}</span></div>` : ""}
      ${t.message ? h`<div class="msg">${brut(I.info)}${t.message}</div>` : ""}
      <div class="actions-carte">
        ${local ? h`${b("ouvrir", I.ouvrir, "Ouvrir avec le lecteur")}${b("dossier", I.dossier, "Afficher dans le dossier")}` : ""}
        ${b("enregistrer", I.enregistrer, "Enregistrer sur cet appareil")}
        <span class="espace"></span>
        ${b("supprimer", I.poubelle, "Retirer ou supprimer", "danger")}
      </div>
    </div>
  </article>`;
}
function listeBiblio() {
  const q = E.recherche_biblio.toLowerCase();
  const l = [...E.taches.values()].filter((t) => t.statut === "termine" && (!q || `${t.titre} ${t.chaine} ${t.groupe}`.toLowerCase().includes(q))).sort((a, b) => (b.fin || 0) - (a.fin || 0));
  if (!l.length) return h`<div class="vide anim"><div class="halo">${brut(I.biblio)}</div><h3>${q ? "Aucun résultat" : "Ta bibliothèque est vide"}</h3><p>${q ? "Essaie un autre mot." : "Tes vidéos terminées apparaîtront ici, prêtes à être regardées."}</p>${q ? "" : h`<button class="btn principal" data-aller="telecharger">${brut(I.dl)} Télécharger une vidéo</button>`}</div>`;
  return h`<div class="grille-videos">${l.map((t, i) => carteBiblio(t, i))}</div>`;
}
function rendreListeBiblio() { const z = $("#liste-biblio"); if (z) z.innerHTML = html(listeBiblio()); }

// ── vue Réglages ─────────────────────────────────────────────────────
function vueReglages() {
  const r = R(), e = E.etat || {};
  const rangee = (titre, aide, controle) => h`<div class="rangee"><div class="texte"><b>${titre}</b>${aide ? h`<span>${aide}</span>` : ""}</div><div class="controle">${controle}</div></div>`;
  const bool = (k, titre, aide = "") => rangee(titre, aide, h`<input type="checkbox" class="interrupteur" data-reglage="${k}" ${r[k] ? "checked" : ""} />`);
  const sel = (k, titre, aide, opts) => rangee(titre, aide, h`<select class="entree" data-reglage="${k}">${opts.map(([v, t]) => h`<option value="${v}" ${String(r[k]) === String(v) ? "selected" : ""}>${t}</option>`)}</select>`);
  const txt = (k, titre, aide, ph = "") => rangee(titre, aide, h`<input class="entree" data-reglage="${k}" value="${r[k] ?? ""}" placeholder="${ph}" />`);
  const section = (id, icone, g, titre, desc, contenu, i) => h`<section class="verre section anim" style="--i:${i}" id="${id}"><div class="section-tete"><span class="ic ${g}">${brut(icone)}</span><div><h3>${titre}</h3><p>${desc}</p></div></div>${contenu}</section>`;
  const menu = [["s-langue", I.langue, "Langue"], ["s-dl", I.dl, "Téléchargement"], ["s-reseau", I.reseau, "Réseau"], ["s-compte", I.compte, "Compte YouTube"], ["s-systeme", I.systeme, "Système"]];
  return h`
  <div class="tete-page anim"><h2>Réglages</h2><span class="compte">enregistrés automatiquement</span></div>
  <div class="reglages">
    <nav class="verre menu-reglages anim" style="--i:1">${menu.map(([id, ic, l]) => h`<a href="#${id}" data-ancre="${id}">${brut(ic)}${l}</a>`)}</nav>
    <div class="sections">
      ${section("s-langue", I.langue, "g1", "Langue et pistes audio", "La piste doublée est choisie automatiquement quand YouTube la propose.", h`
        ${sel("langue_audio", "Langue audio préférée", "Doublage humain ou IA", LANGUES)}
        ${bool("garder_vo", "Garder la VO en 2ᵉ piste", "Change de piste dans VLC, mpv, ta TV…")}
        ${bool("sous_titres_secours", "Sans doublage : sous-titres intégrés", "Dans ta langue, traduits automatiquement par YouTube si besoin")}`, 2)}
      ${section("s-dl", I.dl, "g2", "Téléchargement", "Où et comment enregistrer tes fichiers.", h`
        ${txt("dossier", "Dossier de destination", "Créé automatiquement s'il n'existe pas")}
        ${sel("simultanes", "Téléchargements simultanés", "Plus = plus rapide si ta connexion suit", [1, 2, 3, 4, 5, 6, 8].map((n) => [n, n]))}
        ${sel("type", "Type par défaut", "", [["video", "Vidéo"], ["audio", "Audio seul"]])}
        ${sel("qualite", "Qualité par défaut", "", QUALITES)}
        ${sel("conteneur", "Format vidéo", "MP4 se lit partout", [["mp4", "MP4"], ["mkv", "MKV"], ["webm", "WebM"]])}
        ${sel("format_audio", "Format audio", "Pour le mode « audio seul »", [["mp3", "MP3"], ["m4a", "M4A"], ["opus", "Opus"], ["flac", "FLAC"], ["wav", "WAV"], ["original", "Original"]])}
        ${txt("modele_nom", "Nom des fichiers", "Modèle yt-dlp", "%(title)s [%(id)s].%(ext)s")}
        ${bool("sous_dossier_playlist", "Un dossier par playlist")}
        ${bool("miniature", "Intégrer la miniature")}
        ${bool("metadonnees", "Intégrer métadonnées et chapitres")}
        ${bool("sponsorblock", "Retirer les sponsors par défaut", "SponsorBlock")}
        ${bool("notifications", "Notifier à la fin d'un téléchargement")}`, 3)}
      ${section("s-reseau", I.reseau, "g3", "Réseau", "Vitesse et robustesse.", h`
        ${sel("fragments", "Connexions par fichier", "Accélère les vidéos découpées en fragments", [1, 2, 4, 8, 16].map((n) => [n, n]))}
        ${txt("limite_vitesse", "Limite de vitesse", "Vide = illimitée. Ex. 2M, 500K", "illimitée")}
        ${sel("relances", "Nouvelles tentatives automatiques", "En cas de coupure réseau ou de blocage temporaire", [0, 2, 4, 6, 10].map((n) => [n, n]))}`, 4)}
      ${section("s-compte", I.compte, "g4", "Compte YouTube", "Seulement si YouTube bloque : « prouve que tu n'es pas un robot », vidéos 18+, réservées aux membres. Tout reste sur ta machine.", h`
        ${sel("cookies_navigateur", "Cookies du navigateur", "Le navigateur où tu es connecté à YouTube", [["", "Aucun"], ["firefox", "Firefox"], ["chrome", "Chrome"], ["chromium", "Chromium"], ["brave", "Brave"], ["edge", "Edge"], ["opera", "Opera"], ["vivaldi", "Vivaldi"]])}
        ${rangee("Fichier cookies.txt", e.cookies_fichier ? "Importé ✓" : "Alternative au navigateur", h`
          <label class="btn petit">${brut(I.enregistrer)} Importer<input type="file" accept=".txt" id="fichier-cookies" hidden /></label>
          ${e.cookies_fichier ? h`<button class="btn petit fantome danger" id="suppr-cookies">Supprimer</button>` : ""}`)}`, 5)}
      ${section("s-systeme", I.systeme, "g5", "Système", "État des outils utilisés par YT-NEXUS.", h`
        <div class="diag">
          <div>YT-NEXUS<b>${e.version || "?"}</b></div>
          <div>yt-dlp<b>${e.ytdlp || "absent"}</b></div>
          <div>Solveur YouTube<b class="${e.ejs && e.deno ? "ok-c" : "ko-c"}">${e.ejs && e.deno ? "● OK" : "● manquant"}</b></div>
          <div>ffmpeg<b class="${e.ffmpeg ? "ok-c" : "ko-c"}">${e.ffmpeg ? "● OK" : "● absent"}</b></div>
          ${e.disque ? h`<div>Espace libre<b>${taille(e.disque.libre)}</b></div>` : ""}
        </div>
        ${!e.ffmpeg ? h`<div style="padding:0 24px 16px"><div class="alerte err">${brut(I.alerte)}<span>ffmpeg est indispensable pour assembler vidéo et pistes audio : <code>sudo pacman -S ffmpeg</code></span></div></div>` : ""}
        ${rangee("Mettre à jour yt-dlp", h`<span id="maj-etat">À faire si YouTube se met à refuser les téléchargements.</span>`, h`<button class="btn petit" id="maj-ytdlp">${brut(I.relancer)} Mettre à jour</button>`)}`, 6)}
    </div>
  </div>`;
}

let minuteurReglage;
function changerReglage(el) {
  const k = el.dataset.reglage;
  if (!k) return;
  const v = el.type === "checkbox" ? el.checked : el.value;
  clearTimeout(minuteurReglage);
  minuteurReglage = setTimeout(async () => {
    try {
      E.etat.reglages = await api("/reglages", { methode: "POST", corps: { [k]: v } });
      toast("Réglage enregistré", "ok");
      if (k === "notifications" && v && "Notification" in window) Notification.requestPermission();
    } catch (err) { toast(err.message, "err"); rendre(); }
  }, el.tagName === "INPUT" && el.type !== "checkbox" ? 600 : 0);
}
$("#contenu").addEventListener("input", (e) => { if (E.vue === "reglages" && e.target.tagName === "INPUT" && e.target.type !== "checkbox" && e.target.type !== "file") changerReglage(e.target); });
$("#contenu").addEventListener("change", async (e) => {
  if (e.target.id !== "fichier-cookies") return;
  const f = e.target.files[0];
  if (!f) return;
  const form = new FormData(); form.append("fichier", f);
  try { await api("/cookies", { methode: "POST", form }); toast("Cookies importés", "ok"); await chargerEtat(); rendre(); }
  catch (err) { toast(err.message, "err"); }
});
$("#contenu").addEventListener("click", async (e) => {
  if (E.vue !== "reglages") return;
  const ancre = e.target.closest("[data-ancre]");
  if (ancre) { e.preventDefault(); return document.getElementById(ancre.dataset.ancre)?.scrollIntoView({ behavior: "smooth" }); }
  if (e.target.closest("#suppr-cookies")) { await api("/cookies", { methode: "DELETE" }); await chargerEtat(); return rendre(); }
  if (e.target.closest("#maj-ytdlp")) {
    const b = e.target.closest("#maj-ytdlp"); b.disabled = true;
    $("#maj-etat").innerHTML = '<span class="rond mini" style="display:inline-block;vertical-align:middle"></span> Mise à jour…';
    try {
      await api("/maj-ytdlp", { methode: "POST" });
      let r;
      do { await new Promise((ok) => setTimeout(ok, 1500)); r = await api("/maj-ytdlp"); } while (r.en_cours);
      $("#maj-etat").textContent = r.code === 0 ? `À jour : ${r.version}. Relance YT-NEXUS pour l'analyse.` : `Échec : ${r.sortie}`;
      toast(r.code === 0 ? `yt-dlp ${r.version}` : "Échec de la mise à jour", r.code === 0 ? "ok" : "err");
    } catch (err) { $("#maj-etat").textContent = err.message; }
    b.disabled = false;
  }
});

// ── synchronisation temps réel ───────────────────────────────────────
function fusionner(t) {
  const ancien = E.taches.get(t.id);
  E.taches.set(t.id, t);
  if (ancien && ancien.statut !== "termine" && t.statut === "termine") termine(t);
  if (ancien && ancien.statut !== "erreur" && t.statut === "erreur") toast(`Échec : ${t.titre} — ${t.erreur}`, "err");
  return ancien;
}

function termine(t) {
  toast(`Terminé : ${t.titre}`, "ok");
  if (R().notifications && document.hidden && "Notification" in window && Notification.permission === "granted") {
    const n = new Notification("Téléchargement terminé", { body: t.titre, icon: "/static/icone.svg" });
    n.onclick = () => { window.focus(); aller("bibliotheque"); };
  }
}

function majPastille() {
  const actifs = [...E.taches.values()].filter((t) => ACTIFS.has(t.statut) || ["en_attente", "programme"].includes(t.statut));
  const p = $("#pastille");
  p.hidden = !actifs.length; p.textContent = actifs.length;
  const vitesse = actifs.reduce((s, t) => s + (t.statut === "telechargement" ? t.vitesse || 0 : 0), 0);
  $("#debit").hidden = !vitesse;
  $("#debit-v").textContent = vitesse ? `${taille(vitesse)}/s` : "";
  const enCours = actifs.filter((t) => t.statut === "telechargement");
  const moy = enCours.length ? enCours.reduce((s, t) => s + t.progression, 0) / enCours.length : null;
  document.title = moy != null ? `${Math.round(moy)} % · YT-NEXUS` : "YT-NEXUS";
  placerIndicateur();
}

function appliquer(maj) {
  let structure = false;
  for (const t of maj.taches || []) {
    const ancien = fusionner(t);
    if (E.vue === "file") {
      const visible = t.statut !== "termine" && FILTRES[E.filtre][0](t);
      const avant = ancien && ancien.statut !== "termine" && FILTRES[E.filtre][0](ancien);
      if (visible ? !majCarte(t, ancien) : avant) structure = true;
    } else if (E.vue === "bibliotheque" && (t.statut === "termine" || ancien?.statut === "termine")) structure = true;
  }
  for (const id of maj.supprimees || []) if (E.taches.delete(id)) structure = true;
  if (structure && (E.vue === "file" || E.vue === "bibliotheque")) {
    const defil = window.scrollY;
    if (E.vue === "bibliotheque") rendreListeBiblio(); else rendre();
    $$("#contenu .anim").forEach((el) => el.classList.remove("anim"));
    window.scrollTo(0, defil);
  }
  majPastille();
}

let flux;
function ecouter() {
  flux?.close();
  flux = new EventSource(`/api/evenements?rev=${E.rev}`);
  flux.onmessage = (ev) => {
    const d = JSON.parse(ev.data);
    E.rev = Math.max(E.rev, d.rev);
    appliquer(d);
  };
  flux.onerror = () => {
    flux.close();
    setTimeout(async () => { await chargerTaches().catch(() => {}); ecouter(); }, 2500);
  };
}

async function chargerTaches() {
  const d = await api("/telechargements");
  E.taches = new Map(d.taches.map((t) => [t.id, t]));
  E.rev = d.rev;
  majPastille();
  if (E.vue === "file" || E.vue === "bibliotheque") rendre();
}
async function chargerEtat() {
  try { E.etat = await api("/etat"); } catch (e) { toast(e.message, "err"); }
}

// ── coller / glisser-déposer / raccourcis ────────────────────────────
function depuisDehors(t) {
  E.saisie = t;
  if (E.vue !== "telecharger") aller("telecharger");
  const ta = $("#saisie"); if (ta) ta.value = t;
  lancerSaisie(t);
}
document.addEventListener("paste", (e) => {
  if (e.target.closest?.("input, textarea, [contenteditable]")) return;
  const t = e.clipboardData.getData("text").trim();
  if (!t) return;
  e.preventDefault();
  depuisDehors(t);
});
let profondeur = 0;
document.addEventListener("dragenter", (e) => { if ([...e.dataTransfer.types].some((x) => x.startsWith("text/"))) { profondeur++; $("#deposer").hidden = false; } });
document.addEventListener("dragleave", () => { if (--profondeur <= 0) { profondeur = 0; $("#deposer").hidden = true; } });
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", (e) => {
  e.preventDefault(); profondeur = 0; $("#deposer").hidden = true;
  const t = (e.dataTransfer.getData("text/uri-list") || e.dataTransfer.getData("text/plain")).trim();
  if (t) depuisDehors(t);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "/" && !e.target.closest("input, textarea, select")) {
    e.preventDefault(); if (E.vue !== "telecharger") aller("telecharger");
    $("#saisie").focus(); $("#saisie").select();
  }
});

// ── démarrage ────────────────────────────────────────────────────────
(async () => {
  majBoutonTheme();
  await chargerEtat();
  E.choix = choixParDefaut();
  const p = new URLSearchParams(location.search);
  const partage = [p.get("url"), p.get("texte"), p.get("titre")].filter(Boolean).join(" ");
  const lien = partage.match(/https?:\/\/\S+/)?.[0];
  aller(location.hash.slice(1) || "telecharger", { histo: false });
  await chargerTaches().catch((e) => toast(e.message, "err"));
  ecouter();
  if (document.fonts) document.fonts.ready.then(placerIndicateur);
  if (lien) { history.replaceState(null, "", "/"); E.saisie = lien; analyser(lien); }
})();
