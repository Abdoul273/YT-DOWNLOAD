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
const relatif = new Intl.RelativeTimeFormat("fr", { numeric: "auto" });
// « il y a 3 jours », « il y a 2 ans »…
const ilYa = (ts) => {
  if (!ts) return "";
  const s = Date.now() / 1000 - ts;
  for (const [u, n] of [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]]) {
    if (Math.abs(s) >= n) return relatif.format(-Math.floor(s / n), u);
  }
  return "à l'instant";
};
const dateLongue = (ts) => (ts ? new Date(ts * 1000).toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" }) : "");
const tsYT = (d) => (d && d.length === 8 ? new Date(`${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6)}T12:00`).getTime() / 1000 : null);
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
  filtre: svg('<path d="M3 5h18l-7 8v6l-4 2v-8z"/>'),
  tri: svg('<path d="M7 4v16m0 0-3-3m3 3 3-3M17 20V4m0 0-3 3m3-3 3 3"/>'),
  lot: svg('<rect x="3" y="7" width="18" height="14" rx="2"/><path d="M7 3h10M5 5h14"/>'),
  playlist: svg('<path d="M3 6h13M3 11h13M3 16h8M17 13v8l5-4z"/>'),
  exporter: svg('<path d="M12 15V3m0 0L8 7m4-4 4 4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>'),
  pouls: svg('<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>'),
  fichier: svg('<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6"/>'),
  cookie: svg('<path d="M12 2a10 10 0 1 0 10 10 4 4 0 0 1-5-5 4 4 0 0 1-5-5"/><path d="M8.5 8.5v.01M16 15.5v.01M12 12v.01M11 17v.01M7 14v.01"/>'),
};

// ── état ─────────────────────────────────────────────────────────────
const nouvellePage = () => ({ saisie: "", chargement: null, erreur: null, resultat: null, choix: {}, selection: new Set(), toutesLangues: false, filtreLangue: "" });
const SOURCES = ["video", "recherche", "lot", "playlist"];
const E = {
  vue: "video",
  etat: null,
  taches: new Map(),
  rev: 0,
  p: { video: nouvellePage(), recherche: { ...nouvellePage(), filtres: {}, panneau: false }, lot: nouvellePage(), playlist: nouvellePage() },
  filtre: "tout",
  fichiers: null,
  ff: { q: "", type: "tout", tri: "date", dossier: "" },
  hq: { q: "", filtre: "tout" },
  diag: null,
  test: null,
  envoi: false,
};
// État de la page source affichée (ou de celle demandée)
const P = (v = E.vue) => E.p[SOURCES.includes(v) ? v : "video"];
const C = () => P().choix;
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
const VUES = ["video", "recherche", "lot", "playlist", "en-cours", "fichiers", "historique", "diagnostics", "parametres"];
const ALIAS = { telecharger: "video", file: "en-cours", bibliotheque: "fichiers", reglages: "parametres" };
function aller(vue, { histo = true } = {}) {
  vue = ALIAS[vue] || vue;
  if (!VUES.includes(vue)) vue = "video";
  const meme = E.vue === vue;
  E.vue = vue;
  if (histo && location.hash.slice(1) !== vue) history.pushState(null, "", vue === "video" ? "/" : `#${vue}`);
  $$("#nav button").forEach((b) => (b.dataset.vue === vue ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current")));
  rendre();
  requestAnimationFrame(placerIndicateur);
  if (!meme) window.scrollTo({ top: 0, behavior: "instant" });
  if (vue === "parametres") chargerEtat();
  if (vue === "fichiers") chargerFichiers();
  if (vue === "diagnostics") chargerDiagnostics();
}
function placerIndicateur() {
  const b = $(`#nav button[data-vue="${E.vue}"]`), ind = $("#nav .indic");
  if (!b || !ind) return;
  ind.style.width = `${b.offsetWidth}px`;
  ind.style.transform = `translateX(${b.offsetLeft}px)`;
  if (window.innerWidth <= 760) b.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
}
window.addEventListener("resize", placerIndicateur);
window.addEventListener("popstate", () => aller(location.hash.slice(1) || "video", { histo: false }));
$("#nav").addEventListener("click", (e) => { const b = e.target.closest("button[data-vue]"); if (b) aller(b.dataset.vue); });

function rendre() {
  const vues = {
    video: vueVideo, recherche: vueRecherche, lot: vueLot, playlist: vuePlaylist, "en-cours": vueFile,
    fichiers: vueFichiers, historique: vueHistorique, diagnostics: vueDiagnostics, parametres: vueReglages,
  };
  $("#contenu").innerHTML = `<section class="vue">${html(vues[E.vue]())}</section>`;
  if (SOURCES.includes(E.vue)) apresSource();
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

// ── pages sources : Vidéo, Recherche, Lot, Playlist ──────────────────
function formSaisie(placeholder, bouton = "Analyser") {
  return h`<div class="saisie-cadre">
      <form class="saisie" id="form-saisie">
        ${brut(E.vue === "recherche" ? I.chercher : I.lien)}
        <textarea id="saisie" rows="1" placeholder="${placeholder}" autocomplete="off" spellcheck="false">${P().saisie}</textarea>
        <button type="button" class="btn fantome" id="btn-coller" title="Coller le presse-papiers">${brut(I.coller)}<span>Coller</span></button>
        <button type="submit" class="btn principal" id="btn-go"><span>${bouton}</span>${brut(I.fleche)}</button>
      </form>
    </div>`;
}
const occupe = () => !!(P().resultat || P().chargement || P().erreur);

function teteSource(ic, g, titre, texte) {
  return h`<div class="tete-source ${occupe() ? "compact" : ""}">
    <div class="badge-page ${g} anim">${brut(ic)}</div>
    <h1 class="anim" style="--i:1">${brut(titre)}</h1>
    <p class="anim" style="--i:2">${texte}</p>
  </div>`;
}

function vueVideo() {
  const compact = occupe();
  return h`
  <div class="heros ${compact ? "compact" : ""}">
    ${compact ? "" : h`
      <div class="surtitre anim"><span>NOUVEAU</span>Doublages YouTube en français, automatiquement</div>
      <h1 class="anim" style="--i:1">Tes vidéos YouTube,<br><em>en français.</em></h1>
      <p class="chapo anim" style="--i:2">Colle un lien : YT-NEXUS récupère la piste audio doublée que YouTube propose, garde la VO en bonus, et s'occupe du reste.</p>`}
    <div class="${compact ? "" : "anim"}" style="--i:3">${formSaisie("Colle un lien YouTube (ou tape une recherche)")}</div>
    ${compact ? "" : h`
      <div class="caracteristiques">
        ${[[I.micro, "Doublage FR auto"], [I.qualite, "Jusqu'à 8K HDR"], [I.liste, "Playlists & chaînes"], [I.eclair, "Pause & reprise"], [I.st, "Sous-titres FR"]].map(([ic, t], i) => h`<span class="anim" style="--i:${i + 4}">${brut(ic)}${t}</span>`)}
      </div>
      <div class="astuces anim" style="--i:9"><span><kbd>Ctrl</kbd> <kbd>V</kbd> n'importe où pour coller</span><span><kbd>/</kbd> pour taper un lien</span><span>Glisse-dépose un lien</span></div>`}
  </div>
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}

function vueRecherche() {
  return h`
  ${teteSource(I.chercher, "g2", "Cherche sur <em>YouTube</em>", "Trouve une vidéo, clique pour choisir la langue et la qualité, ou télécharge-la directement.")}
  <div class="${occupe() ? "" : "anim"}" style="--i:3;${occupe() ? "" : "max-width:860px;margin:30px auto 0"}">${formSaisie("Que veux-tu regarder ?", "Rechercher")}</div>
  ${barreFiltres()}
  ${occupe() ? "" : h`<div class="exemples anim" style="--i:4">${["documentaire espace", "MrBeast", "recette facile", "musique lofi", "tuto Linux"].map((x) => h`<button data-exemple="${x}">${x}</button>`)}</div>`}
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}

// ── filtres de recherche (appliqués par YouTube) ─────────────────────
const GROUPES_FILTRES = {
  tri: ["Trier par", [["pertinence", "Pertinence"], ["date", "Plus récentes"], ["vues", "Plus vues"], ["note", "Mieux notées"]]],
  date: ["Mise en ligne", [["", "N'importe quand"], ["heure", "Dernière heure"], ["jour", "Aujourd'hui"], ["semaine", "Cette semaine"], ["mois", "Ce mois-ci"], ["annee", "Cette année"]]],
  duree: ["Durée", [["", "Toutes"], ["courte", "Moins de 4 min"], ["moyenne", "4 à 20 min"], ["longue", "Plus de 20 min"]]],
};
const OPTIONS_FILTRES = [["hd", "HD"], ["k4", "4K"], ["sous_titres", "Sous-titres"]];
const filtresActifs = (f) => [
  ...["date", "duree"].filter((k) => f[k]).map((k) => [k, GROUPES_FILTRES[k][1].find(([v]) => v === f[k])?.[1]]),
  ...OPTIONS_FILTRES.filter(([k]) => f[k]),
];
function barreFiltres() {
  const pg = E.p.recherche, f = pg.filtres;
  const actifs = filtresActifs(f);
  const tri = f.tri || "pertinence";
  return h`<div class="barre-filtres ${occupe() ? "" : "anim"}" style="--i:4">
    <div class="segment tris">${brut(I.tri.replace("<svg", '<svg class="ic-tri"'))}${GROUPES_FILTRES.tri[1].map(([v, l]) => h`<button data-rf="tri" data-rv="${v}" aria-pressed="${tri === v}">${l}</button>`)}</div>
    <button class="btn petit ${pg.panneau || actifs.length ? "actif-filtre" : ""}" data-panneau-filtres>${brut(I.filtre)} Filtres${actifs.length ? h`<span class="pastille">${actifs.length}</span>` : ""}</button>
    ${actifs.map(([k, l]) => h`<button class="puce filtre-actif" data-retirer-filtre="${k}">${l} ${brut(I.croix)}</button>`)}
    ${actifs.length ? h`<button class="btn petit fantome" data-retirer-filtre="tout">Tout effacer</button>` : ""}
  </div>
  ${pg.panneau ? h`<div class="verre panneau-filtres">
    ${["date", "duree"].map((g) => h`<div><div class="sous-titre-bloc">${GROUPES_FILTRES[g][0]}</div>
      <div class="puces">${GROUPES_FILTRES[g][1].map(([v, l]) => h`<button class="puce" data-rf="${g}" data-rv="${v}" aria-pressed="${(f[g] || "") === v}">${l}</button>`)}</div></div>`)}
    <div><div class="sous-titre-bloc">Qualité et options</div>
      <div class="puces">${OPTIONS_FILTRES.map(([k, l]) => h`<button class="puce" data-rf="${k}" data-rv="bascule" aria-pressed="${!!f[k]}">${l}</button>`)}</div></div>
  </div>` : ""}`;
}
function changerFiltre(groupe, valeur) {
  const pg = E.p.recherche;
  if (groupe === "tout") pg.filtres = { tri: pg.filtres.tri };
  else if (valeur === "bascule") pg.filtres[groupe] = !pg.filtres[groupe];
  else if (valeur === "" && OPTIONS_FILTRES.some(([k]) => k === groupe)) pg.filtres[groupe] = false;
  else pg.filtres[groupe] = valeur;
  if (pg.saisie.trim() && (pg.resultat || pg.erreur)) rechercher(pg.saisie.trim());
  else rendre();
}

function vueLot() {
  const liens = extraireLiens(P().saisie);
  const uniques = [...new Set(liens)];
  return h`
  ${P().resultat ? "" : teteSource(I.lot, "g4", "Téléchargement <em>par lot</em>", "Colle autant de liens que tu veux, un par ligne. Ils partent tous dans la file avec les mêmes réglages.")}
  <div class="verre zone-lot ${P().resultat ? "" : "anim"}" style="--i:3;${P().resultat ? "max-width:none;margin-top:0" : ""}">
    <textarea id="saisie-lot" placeholder="https://youtu.be/…&#10;https://www.youtube.com/watch?v=…&#10;https://youtube.com/shorts/…" spellcheck="false">${P().saisie}</textarea>
    <div class="bas">
      <div class="compteur-liens" id="compteur-liens">${compteurLiens(liens, uniques)}</div>
      <button class="btn fantome petit" id="btn-coller-lot">${brut(I.coller)} Coller</button>
      ${P().saisie ? h`<button class="btn fantome petit danger" id="btn-vider-lot">${brut(I.croix)} Vider</button>` : ""}
      <button class="btn principal" id="btn-preparer" ${uniques.length ? "" : "disabled"}>${brut(I.liste)} Préparer le lot</button>
    </div>
  </div>
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}
function compteurLiens(liens, uniques) {
  return h`<span class="puce-meta">${brut(I.lien)}${uniques.length} lien${uniques.length > 1 ? "s" : ""}</span>${liens.length > uniques.length ? h`<span class="puce-meta">${liens.length - uniques.length} doublon${liens.length - uniques.length > 1 ? "s" : ""} ignoré${liens.length - uniques.length > 1 ? "s" : ""}</span>` : ""}`;
}

function vuePlaylist() {
  return h`
  ${teteSource(I.playlist, "g3", "Playlists <em>& chaînes</em>", "Colle le lien d'une playlist ou d'une chaîne YouTube : choisis les vidéos, la langue, et tout part dans la file.")}
  <div class="${occupe() ? "" : "anim"}" style="--i:3;${occupe() ? "" : "max-width:860px;margin:30px auto 0"}">${formSaisie("Lien de playlist ou de chaîne (youtube.com/@…, /playlist?list=…)")}</div>
  ${occupe() ? "" : h`<div class="astuces anim" style="--i:4"><span>Chaîne : toutes ses vidéos</span><span>Playlist : chaque vidéo, dans l'ordre</span><span>Un dossier par playlist</span></div>`}
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}

function zoneResultat() {
  if (P().chargement) return squelette();
  if (P().erreur) return h`<div class="alerte err anim">${brut(I.alerte)}<span>${P().erreur}</span></div>`;
  const r = P().resultat;
  if (!r) return "";
  if (r.type === "video") return carteVideo(r);
  if (r.type === "playlist" || r.type === "lot") return cartePlaylist(r);
  if (r.type === "recherche") return grilleRecherche(r);
  return "";
}

function squelette() {
  if (P().chargement.startsWith("Recherche")) {
    return h`<div class="chargement-texte" style="margin-bottom:18px"><span class="rond"></span>${P().chargement}</div>
    <div class="grille-videos">${[...Array(8)].map((_, i) => h`<div class="verre carte-video anim" style="--i:${i}"><div class="squelette" style="aspect-ratio:16/9;border-radius:0"></div><div class="corps" style="flex-direction:column;gap:8px"><div class="squelette" style="height:14px;width:90%"></div><div class="squelette" style="height:12px;width:50%"></div></div></div>`)}</div>`;
  }
  return h`<div class="video">
    <div class="apercu"><div class="squelette" style="aspect-ratio:16/9;border-radius:20px"></div>
      <div class="apercu-infos" style="display:grid;gap:10px"><div class="squelette" style="height:22px;width:95%"></div><div class="squelette" style="height:22px;width:60%"></div><div class="squelette" style="height:34px;width:45%;border-radius:99px;margin-top:6px"></div></div></div>
    <div class="verre panneau" style="padding:26px;display:grid;gap:18px">
      <div class="chargement-texte"><span class="rond"></span>${P().chargement}</div>
      <div class="squelette" style="height:44px;width:260px;border-radius:15px"></div>
      <div class="langues">${[...Array(6)].map(() => h`<div class="squelette" style="height:64px;border-radius:16px"></div>`)}</div>
      <div class="qualites">${[...Array(6)].map(() => h`<div class="squelette" style="height:70px;border-radius:16px"></div>`)}</div>
    </div></div>`;
}

function pisteChoisie(v) {
  // null = langue préférée des réglages (avec repli VO + sous-titres côté serveur)
  return C().langue_audio ?? (v.piste_voulue || v.originale);
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
  const f = P().filtreLangue.toLowerCase();
  const filtrees = autres.filter((p) => !f || nomPiste(p).toLowerCase().includes(f) || p.code.toLowerCase().includes(f));
  return h`
    <div class="langues">${montrees.map((p, i) => carteLangue(p, choisie, i))}</div>
    ${autres.length ? h`
      <div class="plus-langues"><button class="btn petit fantome" data-action="toutes-langues">${brut(I.langue)} ${P().toutesLangues ? "Masquer" : "Voir"} les ${autres.length} autres langues ${brut(I.chev)}</button></div>
      ${P().toutesLangues ? h`<div class="toutes-langues">
        <div class="avec-icone">${brut(I.chercher)}<input class="entree" id="filtre-langue" placeholder="Chercher une langue…" value="${P().filtreLangue}" /></div>
        <div class="puces">${filtrees.map((p) => h`<button class="puce" data-piste="${p.code}" aria-pressed="${estChoisie(p, choisie)}">${p.drapeau} ${nomPiste(p)}${p.genre === "doublage IA" ? h` <span class="tag ia">IA</span>` : ""}</button>`)}</div>
      </div>` : ""}` : ""}`;
}

function carteVideo(v) {
  const c = C();
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
          ${v.date ? h`<span class="puce-meta date-video" title="${dateYT(v.date)}">${brut(I.calendrier)}${dateYT(v.date)} · ${ilYa(tsYT(v.date))}</span>` : ""}
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
        ${manque && C().langue_audio == null ? h`<div class="alerte info" style="margin-bottom:14px">${brut(I.info)}<span>Pas de doublage <b>${nomLangue(pref).toLowerCase()}</b> sur YouTube pour cette vidéo.${R().sous_titres_secours && c.type === "video" ? (v.sous_titres.auto || v.sous_titres.manuels.length ? " Elle sera téléchargée en VO avec les sous-titres intégrés." : " Pas de sous-titres non plus.") : ""}</span></div>` : ""}
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
  const c = C();
  const lignes = [];
  if (c.type === "video") lignes.push([I.video, `Vidéo ${q?.libelle || ""}`.trim(), (c.conteneur || "mp4").toUpperCase(), ""]);
  if (pisteSel) lignes.push([I.audio, `${pisteSel.drapeau} ${nomPiste(pisteSel)}`, c.type === "audio" ? (c.format_audio || "mp3").toUpperCase() : "Piste 1 · par défaut", "fr"]);
  if (vo) { const o = v.pistes.find((p) => p.originale); lignes.push([I.audio, `${o?.drapeau || "🎙️"} ${o ? nomPiste(o) : "VO"}`, "Piste 2 · VO", ""]); }
  const st = [...c.sous_titres];
  if (manque && C().langue_audio == null && c.type === "video" && R().sous_titres_secours && (v.sous_titres.auto || v.sous_titres.manuels.length)) st.unshift(R().langue_audio || "fr");
  if (st.length && c.type === "video") lignes.push([I.st, `Sous-titres ${[...new Set(st)].map((x) => x.toUpperCase()).join(", ")}`, c.sous_titres_fichier ? "fichiers .srt" : "intégrés", ""]);
  if (c.sponsorblock) lignes.push([I.bouclier, "Sans sponsors", "SponsorBlock", ""]);
  if (c.debut || c.fin) lignes.push([I.ciseaux, `Extrait ${c.debut || "0:00"} → ${c.fin || "fin"}`, "", ""]);
  return h`<div class="verre fichier-final">
    <div class="sous-titre-bloc">Ton fichier</div>
    ${lignes.map(([ic, t, d, cls]) => h`<div class="piste-ff ${cls}"><span class="ic">${brut(ic)}</span><span class="t">${t}</span><span class="d">${d}</span></div>`)}
  </div>`;
}

function selecteurFormat() {
  const c = C();
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
  const c = C();
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
  const c = C();
  const n = P().selection.size;
  const langue = c.langue_audio ?? R().langue_audio ?? "fr";
  const dureeTotale = [...P().selection].reduce((s, i) => s + (p.entrees[i]?.duree || 0), 0);
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
        <input type="checkbox" class="case" data-sel="${i}" ${P().selection.has(i) ? "checked" : ""} />
        <span class="n">${i + 1}</span>
        ${e.miniature ? h`<img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : h`<span class="squelette"></span>`}
        <span style="min-width:0"><span class="t">${e.attente ? h`<span class="squelette" style="display:block;height:14px;width:70%"></span>` : e.titre}</span>${e.chaine && p.type === "lot" ? h`<span class="d" style="display:block;margin-top:3px">${e.chaine}</span>` : ""}${e.ko ? h`<span class="ko">Aperçu indisponible, téléchargeable quand même</span>` : ""}</span>
        <span class="d" style="text-align:right">${duree(e.duree)}${e.date ? h`<br><span title="${dateLongue(e.date)}">${ilYa(e.date)}</span>` : ""}</span>
      </label>`)}
    </div>
    <div class="barre-action">
      <div class="recap"><span>${n} vidéo${n > 1 ? "s" : ""}</span><span class="sep"></span><span>${drapeauLangue(langue)} ${nomLangue(langue)}</span><span class="sep"></span><span>${c.type === "audio" ? (c.format_audio || "mp3").toUpperCase() : `${QUALITES.find(([k]) => k === String(c.qualite))?.[1] || c.qualite} · ${(c.conteneur || "mp4").toUpperCase()}`}</span></div>
      <button class="btn principal grand" data-action="telecharger-selection" ${!n || E.envoi ? "disabled" : ""}>${brut(c.programme ? I.horloge : I.dl)} ${c.programme ? "Programmer" : "Tout télécharger"}</button>
    </div>
  </div>`;
}

function grilleRecherche(r) {
  if (!r.resultats.length) return h`<div class="vide"><div class="halo">${brut(I.chercher)}</div><h3>Aucun résultat</h3><p>${filtresActifs(E.p.recherche.filtres).length ? "Essaie d'assouplir les filtres." : "Essaie d'autres mots-clés."}</p></div>`;
  return h`<div class="titre-section"><h2>Résultats</h2><span class="muet">${r.resultats.length} vidéos pour « ${r.requete} »</span></div>
  <div class="grille-videos">${r.resultats.map((e, i) => h`
    <article class="verre carte-video anim" style="--i:${Math.min(i, 12)}" data-res="${i}" tabindex="0">
      <div class="vignette"><img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />
        <span class="survol"><span class="rond-lecture">${brut(I.chercher)}</span></span>
        ${e.duree ? h`<span class="duree">${duree(e.duree)}</span>` : e.direct ? h`<span class="duree" style="background:var(--rouge)">DIRECT</span>` : ""}</div>
      <div class="corps">
        <div style="flex:1;min-width:0"><div class="t">${e.titre}</div><div class="s">${e.chaine || ""}${e.vues ? " · " + vues(e.vues) : ""}</div>${e.date ? h`<div class="date-video" title="Publiée vers le ${dateLongue(e.date)}">${brut(I.calendrier)}${ilYa(e.date)}</div>` : ""}</div>
        <button class="icone-btn accent" data-rapide="${i}" title="Choisir la langue, la qualité et télécharger">${brut(I.dl)}</button>
      </div>
    </article>`)}
  </div>`;
}

function rafraichirResultat() {
  const z = $("#resultat");
  if (!z) return rendre();
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
// Ré-affiche la page `page` si elle est visible (l'en-tête change selon qu'il y a un résultat ou non)
function afficherPage(page) {
  if (E.vue === page) rendre();
}

function apresSource() {
  if (E.vue === "lot") return apresLot();
  const ta = $("#saisie");
  const ajuster = () => { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 180) + "px"; };
  ajuster();
  ta.addEventListener("input", () => { P().saisie = ta.value; ajuster(); $("#btn-go span").textContent = libelleGo(); });
  ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); lancerSaisie(); } });
  $("#btn-go span").textContent = libelleGo();
  $("#form-saisie").addEventListener("submit", (e) => { e.preventDefault(); lancerSaisie(); });
  $("#btn-coller").addEventListener("click", async () => {
    try {
      const t = (await navigator.clipboard.readText()).trim();
      if (!t) return toast("Le presse-papiers est vide.");
      router(t, E.vue);
    } catch { ta.focus(); toast("Fais Ctrl+V dans le champ (accès au presse-papiers refusé)."); }
  });
  if (!occupe()) ta.focus({ preventScroll: true });
}

function apresLot() {
  const ta = $("#saisie-lot");
  ta.addEventListener("input", () => {
    P().saisie = ta.value;
    const liens = extraireLiens(ta.value), uniques = [...new Set(liens)];
    $("#compteur-liens").innerHTML = html(compteurLiens(liens, uniques));
    $("#btn-preparer").disabled = !uniques.length;
  });
  ta.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); preparerLot(); } });
  $("#btn-preparer").addEventListener("click", preparerLot);
  $("#btn-vider-lot")?.addEventListener("click", () => { E.p.lot = nouvellePage(); rendre(); });
  $("#btn-coller-lot").addEventListener("click", async () => {
    try {
      const t = (await navigator.clipboard.readText()).trim();
      if (!t) return toast("Le presse-papiers est vide.");
      P().saisie = (P().saisie ? P().saisie.trimEnd() + "\n" : "") + t;
      rendre();
    } catch { ta.focus(); toast("Fais Ctrl+V dans le champ (accès au presse-papiers refusé)."); }
  });
  if (!P().resultat) ta.focus({ preventScroll: true });
}

const libelleGo = () => {
  if (E.vue === "recherche") return "Rechercher";
  const lignes = P().saisie.split(/\s+/).filter(Boolean);
  if (!lignes.length) return "Analyser";
  if (lignes.filter(estUrl).length > 1) return `${lignes.filter(estUrl).length} liens`;
  return estUrl(lignes[0]) ? "Analyser" : "Rechercher";
};

const extraireLiens = (texte) => (texte || "").split(/\s+/).map((x) => x.trim()).filter(estUrl);
const estPlaylist = (u) => (/[?&]list=/.test(u) && !/[?&]v=/.test(u)) || /\/playlist\b/.test(u) || /youtube\.com\/(@|channel\/|c\/|user\/)/i.test(u);

// Envoie un texte dans le bon onglet : plusieurs liens → Lot, playlist/chaîne → Playlist,
// lien → Vidéo, texte → Recherche.
function router(texte, depuis = E.vue) {
  texte = (texte || "").trim();
  if (!texte) return;
  const liens = extraireLiens(texte);
  if (liens.length > 1 || (depuis === "lot" && liens.length)) {
    E.p.lot.saisie = depuis === "lot" && E.p.lot.saisie ? `${E.p.lot.saisie.trimEnd()}\n${liens.join("\n")}` : liens.join("\n");
    E.p.lot.resultat = null;
    aller("lot");
    return preparerLot();
  }
  if (liens.length === 1) {
    const page = estPlaylist(liens[0]) ? "playlist" : "video";
    E.p[page].saisie = liens[0];
    if (E.vue !== page) aller(page);
    return analyser(liens[0], page);
  }
  E.p.recherche.saisie = texte;
  if (E.vue !== "recherche") aller("recherche");
  return rechercher(texte);
}

async function lancerSaisie() {
  const texte = P().saisie;
  if (!texte.trim()) return $("#saisie")?.focus();
  if (E.vue === "recherche" && !extraireLiens(texte).length) return rechercher(texte.trim());
  return router(texte, E.vue);
}

async function analyser(url, page = "video") {
  const pg = E.p[page];
  Object.assign(pg, { chargement: page === "playlist" ? "Lecture de la playlist…" : "Analyse : pistes audio, qualités, sous-titres…", erreur: null, resultat: null, toutesLangues: false, filtreLangue: "" });
  afficherPage(page);
  let r;
  try { r = await api("/analyse", { methode: "POST", corps: { url } }); }
  catch (e) { pg.erreur = e.message; pg.chargement = null; return afficherPage(page); }
  pg.chargement = null;
  // Le lien n'était pas du type attendu : on bascule vers le bon onglet.
  const cible = r.type === "playlist" ? "playlist" : "video";
  const dest = E.p[cible];
  if (cible !== page) { pg.saisie = ""; dest.saisie = url; }
  Object.assign(dest, { resultat: r, choix: choixParDefaut(), erreur: null, chargement: null, toutesLangues: false, filtreLangue: "",
    selection: new Set(r.type === "playlist" ? r.entrees.map((_, i) => i) : []) });
  if (cible !== page && E.vue === page) aller(cible); else afficherPage(cible);
}

async function rechercher(q) {
  const pg = E.p.recherche;
  Object.assign(pg, { chargement: `Recherche « ${q} »…`, erreur: null, resultat: null });
  afficherPage("recherche");
  try {
    const r = await api("/recherche", { methode: "POST", corps: { q, filtres: pg.filtres } });
    pg.resultat = { type: "recherche", requete: q, resultats: r.resultats };
  } catch (e) { pg.erreur = e.message; }
  pg.chargement = null; afficherPage("recherche");
}

async function preparerLot() {
  const pg = E.p.lot;
  const uniques = [...new Set(extraireLiens(pg.saisie))];
  if (!uniques.length) return toast("Aucun lien valide.", "err");
  const entrees = uniques.map((u) => ({ url: u, titre: u, attente: true }));
  Object.assign(pg, { resultat: { type: "lot", titre: `${entrees.length} lien${entrees.length > 1 ? "s" : ""}`, nombre: entrees.length, entrees },
    choix: choixParDefaut(), selection: new Set(entrees.map((_, i) => i)), erreur: null });
  afficherPage("lot");
  try {
    const { apercus } = await api("/apercus", { methode: "POST", corps: { urls: uniques } });
    if (pg.resultat?.entrees !== entrees) return;
    apercus.forEach((a, i) => Object.assign(entrees[i], a.ok ? { titre: a.titre, chaine: a.chaine, miniature: a.miniature, attente: false } : { attente: false, ko: true }));
    pg.resultat.miniature = entrees.find((e) => e.miniature)?.miniature;
    if (E.vue === "lot") rafraichirResultat();
  } catch { entrees.forEach((e) => (e.attente = false)); }
}

function optionsEnvoi() {
  const c = { ...C() };
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
    toast(n > 1 ? `${n} téléchargements ajoutés à la file` : C().programme ? "Téléchargement programmé" : "C'est parti ! Suis-le dans la file.", "ok");
    majPastille();
    if (bouton) { bouton.innerHTML = `${I.ok} Ajouté`; setTimeout(() => { E.envoi = false; rafraichirResultat(); }, 1400); return; }
  } catch (e) { toast(e.message, "err"); }
  E.envoi = false; rafraichirResultat();
}

// Interactions de la vue Télécharger (délégation)
$("#contenu").addEventListener("click", (e) => {
  if (!SOURCES.includes(E.vue)) return;
  const rf = e.target.closest("[data-rf]");
  if (rf) return changerFiltre(rf.dataset.rf, rf.dataset.rv);
  const rt = e.target.closest("[data-retirer-filtre]");
  if (rt) return changerFiltre(rt.dataset.retirerFiltre, rt.dataset.retirerFiltre === "tout" ? null : "");
  if (e.target.closest("[data-panneau-filtres]")) { E.p.recherche.panneau = !E.p.recherche.panneau; return rendre(); }
  const ex = e.target.closest("[data-exemple]");
  if (ex) { P().saisie = ex.dataset.exemple; return rechercher(ex.dataset.exemple); }
  const el = e.target.closest("[data-type],[data-piste],[data-qualite],[data-st],[data-action],[data-res],[data-rapide],[data-conteneur],[data-format-audio]");
  if (!el) return;
  const r = P().resultat;
  if (el.dataset.type) { C().type = el.dataset.type; return rafraichirResultat(); }
  if (el.dataset.piste) { C().langue_audio = el.dataset.piste; return rafraichirResultat(); }
  if (el.dataset.qualite) { C().qualite = el.dataset.qualite; return rafraichirResultat(); }
  if (el.dataset.conteneur) { C().conteneur = el.dataset.conteneur; return rafraichirResultat(); }
  if (el.dataset.formatAudio) { C().format_audio = el.dataset.formatAudio; return rafraichirResultat(); }
  if (el.dataset.st) {
    const s = new Set(C().sous_titres);
    s.has(el.dataset.st) ? s.delete(el.dataset.st) : s.add(el.dataset.st);
    C().sous_titres = [...s]; return rafraichirResultat();
  }
  if (el.dataset.rapide) {
    // Ouvre la vidéo dans l'onglet Vidéo pour choisir langue, qualité et format
    e.stopPropagation();
    const x = r.resultats[+el.dataset.rapide];
    E.p.video.saisie = x.url; aller("video"); return analyser(x.url, "video");
  }
  if (el.dataset.res) { const x = r.resultats[+el.dataset.res]; E.p.video.saisie = x.url; aller("video"); return analyser(x.url, "video"); }
  const a = el.dataset.action;
  if (a === "toutes-langues") { P().toutesLangues = !P().toutesLangues; return rafraichirResultat(); }
  if (a === "ouvrir-playlist") { E.p.playlist.saisie = r.playlist; aller("playlist"); return analyser(r.playlist, "playlist"); }
  if (a === "telecharger") return envoyer([{ url: r.url, titre: r.titre, miniature: r.miniature, chaine: r.chaine, duree: r.duree }], el);
  if (a === "telecharger-selection") {
    const groupe = r.type === "playlist" ? r.titre : null;
    return envoyer([...P().selection].sort((x, y) => x - y).map((i) => ({ ...r.entrees[i], groupe })), el);
  }
});
$("#contenu").addEventListener("keydown", (e) => {
  if (E.vue === "recherche" && e.key === "Enter" && e.target.dataset?.res) e.target.click();
});
$("#contenu").addEventListener("change", (e) => {
  const el = e.target;
  if (SOURCES.includes(E.vue)) {
    if (el.id === "tout-cocher") { P().selection = el.checked ? new Set(P().resultat.entrees.map((_, i) => i)) : new Set(); return rafraichirResultat(); }
    if (el.dataset.sel) { el.checked ? P().selection.add(+el.dataset.sel) : P().selection.delete(+el.dataset.sel); return rafraichirResultat(); }
    if (el.dataset.opt) {
      C()[el.dataset.opt] = el.type === "checkbox" ? el.checked : el.value;
      if (el.type === "checkbox" || el.tagName === "SELECT" || el.dataset.opt === "programme") rafraichirResultat();
    }
  } else if (E.vue === "parametres") changerReglage(el);
});
$("#contenu").addEventListener("input", (e) => {
  const el = e.target;
  if (SOURCES.includes(E.vue) && el.id === "filtre-langue") { P().filtreLangue = el.value; return rafraichirResultat(); }
  if (SOURCES.includes(E.vue) && el.dataset.opt && el.tagName === "INPUT" && el.type !== "checkbox") C()[el.dataset.opt] = el.value;
  if (E.vue === "fichiers" && el.id === "recherche-fichiers") { E.ff.q = el.value; rendreListeFichiers(); }
  if (E.vue === "historique" && el.id === "recherche-histo") { E.hq.q = el.value; rendreListeHisto(); }
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
    <h2>En cours</h2><span class="compte">${toutes.length}</span>
    <div class="actions">
      <button class="btn petit fantome" data-global="pause_tout">${brut(I.pause)} Tout en pause</button>
      <button class="btn petit fantome" data-global="reprendre_tout">${brut(I.lecture)} Tout reprendre</button>
      <button class="btn petit fantome" data-global="relancer_erreurs">${brut(I.relancer)} Relancer les échecs</button>
      <button class="btn petit fantome danger" data-global="vider_echecs">${brut(I.poubelle)} Vider les échecs</button>
    </div>
  </div>
  <div class="onglets anim" style="--i:1">${Object.entries(FILTRES).map(([k, [f, l]]) => h`<button data-filtre="${k}" aria-pressed="${E.filtre === k}">${l}<span class="n">${toutes.filter(f).length}</span></button>`)}</div>
  <div class="taches" id="liste-taches">
    ${liste.length ? liste.map((t, i) => carteTache(t, i)) : h`<div class="vide anim"><div class="halo">${brut(I.vide)}</div><h3>Rien en cours</h3><p>Colle un lien pour lancer un téléchargement. Les vidéos terminées t'attendent dans Fichiers et l'Historique.</p><button class="btn principal" data-aller="video">${brut(I.dl)} Télécharger une vidéo</button></div>`}
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
  if (t.statut === "termine" && t.fichier) r.push(b("lire", I.lecture, "Lire"), ...(E.etat?.local !== false ? [b("dossier", I.dossier, "Afficher dans le dossier")] : []));
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
    else if (act === "retelecharger") { E.p.video.saisie = t.url; aller("video"); analyser(t.url, "video"); }
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

// ── vue Fichiers (dossier de téléchargement) ─────────────────────────
async function chargerFichiers() {
  try {
    const d = await api("/fichiers");
    E.fichiers = d.fichiers;
    if (E.vue === "fichiers") rendre();
  } catch (e) { toast(e.message, "err"); }
}
const fichiersFiltres = () => {
  const { q, type, tri, dossier } = E.ff;
  const l = (E.fichiers || []).filter((f) => (type === "tout" || f.type === type) && (!dossier || f.dossier === dossier) && (!q || `${f.titre} ${f.nom} ${f.dossier}`.toLowerCase().includes(q.toLowerCase())));
  return l.sort((a, b) => (tri === "taille" ? b.taille - a.taille : tri === "nom" ? a.titre.localeCompare(b.titre, "fr") : b.date - a.date));
};
function vueFichiers() {
  const tous = E.fichiers;
  const total = (tous || []).reduce((s, f) => s + f.taille, 0);
  const d = E.etat?.disque;
  const dossiers = [...new Set((tous || []).map((f) => f.dossier).filter(Boolean))].sort();
  return h`
  <div class="tete-page anim">
    <h2>Fichiers</h2><span class="compte">${tous ? tous.length : ""}</span>
    <div class="actions">
      <button class="btn petit fantome" data-recharger-fichiers>${brut(I.relancer)} Actualiser</button>
      ${E.etat?.local !== false ? h`<button class="btn petit" data-ouvrir-dossier>${brut(I.dossier)} Ouvrir le dossier</button>` : ""}
    </div>
  </div>
  <div class="stats">
    <div class="verre stat anim" style="--i:1"><span class="ic g1">${brut(I.fichier)}</span><div><div class="v">${tous ? tous.length : "…"}</div><div class="l">fichiers · ${(tous || []).filter((f) => f.type === "video").length} vidéos, ${(tous || []).filter((f) => f.type === "audio").length} audios</div></div></div>
    <div class="verre stat anim" style="--i:2"><span class="ic g2">${brut(I.disque)}</span><div><div class="v">${taille(total)}</div><div class="l">dans ${E.etat?.dossier ? E.etat.dossier.split("/").slice(-2).join("/") : "le dossier"}</div></div></div>
    ${d ? h`<div class="verre stat anim" style="--i:3"><span class="ic g3">${brut(I.dossier)}</span><div style="flex:1"><div class="v">${taille(d.libre)}</div><div class="l">libres sur le disque</div><div class="jauge"><i style="width:${((1 - d.libre / d.total) * 100).toFixed(1)}%"></i></div></div></div>` : ""}
  </div>
  <div class="outils-fichiers anim" style="--i:4">
    <div class="avec-icone">${brut(I.chercher)}<input class="entree" id="recherche-fichiers" placeholder="Rechercher un fichier…" value="${E.ff.q}" /></div>
    <div class="segment">${[["tout", "Tout"], ["video", "Vidéos"], ["audio", "Audio"]].map(([k, l]) => h`<button data-ff-type="${k}" aria-pressed="${E.ff.type === k}">${l}</button>`)}</div>
    <select class="entree" id="tri-fichiers">${[["date", "Plus récents"], ["taille", "Plus lourds"], ["nom", "Nom (A → Z)"]].map(([k, l]) => h`<option value="${k}" ${E.ff.tri === k ? "selected" : ""}>${l}</option>`)}</select>
  </div>
  ${dossiers.length ? h`<div class="dossiers anim" style="--i:5"><button class="puce" data-ff-dossier="" aria-pressed="${!E.ff.dossier}">${brut(I.dossier)} Tous</button>${dossiers.map((x) => h`<button class="puce" data-ff-dossier="${x}" aria-pressed="${E.ff.dossier === x}">${brut(I.liste)} ${x}</button>`)}</div>` : ""}
  <div id="liste-fichiers">${listeFichiers()}</div>`;
}
function listeFichiers() {
  if (!E.fichiers) return h`<div class="grille-videos">${[...Array(6)].map((_, i) => h`<div class="verre carte-video anim" style="--i:${i}"><div class="squelette" style="aspect-ratio:16/9;border-radius:0"></div><div class="corps" style="flex-direction:column;gap:8px"><div class="squelette" style="height:14px;width:85%"></div><div class="squelette" style="height:12px;width:45%"></div></div></div>`)}</div>`;
  const l = fichiersFiltres();
  if (!l.length) return h`<div class="vide anim"><div class="halo">${brut(I.dossier)}</div><h3>${E.fichiers.length ? "Aucun fichier ne correspond" : "Le dossier est vide"}</h3><p>${E.fichiers.length ? "Change la recherche ou les filtres." : "Tes vidéos et musiques téléchargées apparaîtront ici."}</p>${E.fichiers.length ? "" : h`<button class="btn principal" data-aller="video">${brut(I.dl)} Télécharger une vidéo</button>`}</div>`;
  const local = E.etat?.local !== false;
  const b = (f, action, icone, titre, cls = "") => h`<button class="icone-btn ${cls}" data-f="${f.chemin}" data-fact="${action}" title="${titre}" aria-label="${titre}">${brut(icone)}</button>`;
  return h`<div class="grille-videos biblio">${l.map((f, i) => h`
    <article class="verre carte-video anim" style="--i:${Math.min(i, 12)}" data-f="${f.chemin}" data-fact="lire">
      <div class="vignette ${f.miniature ? "" : `placeholder ${f.type}`}">
        ${f.miniature ? h`<img src="${f.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : brut(f.type === "audio" ? I.audio : I.video)}
        <span class="survol"><span class="rond-lecture">${brut(I.lecture)}</span></span>
        <span class="ext">${f.ext}</span>
        ${f.duree ? h`<span class="duree">${duree(f.duree)}</span>` : ""}
      </div>
      <div class="corps">
        <div class="t" title="${f.titre}">${f.titre}</div>
        <div class="s">${taille(f.taille)} · ${quand(f.date)}</div>
        ${f.pistes || f.dossier ? h`<div class="infos-carte">${f.pistes ? h`<span class="info-chip">${f.pistes}</span>` : ""}${f.dossier ? h`<span class="info-chip">${brut(I.dossier.replace("<svg", '<svg style="width:12px;height:12px"'))}${f.dossier}</span>` : ""}</div>` : ""}
        <div class="actions-carte">
          ${local ? h`${b(f, "ouvrir", I.ouvrir, "Ouvrir avec le lecteur")}${b(f, "dossier", I.dossier, "Afficher dans le dossier")}` : ""}
          ${b(f, "enregistrer", I.enregistrer, "Enregistrer sur cet appareil")}
          <span class="espace"></span>
          ${b(f, "supprimer", I.poubelle, "Supprimer le fichier", "danger")}
        </div>
      </div>
    </article>`)}</div>`;
}
function rendreListeFichiers() { const z = $("#liste-fichiers"); if (z) z.innerHTML = html(listeFichiers()); }
function lireChemin(chemin, titre) {
  const d = $("#lecteur"), v = $("#lecteur-video");
  $("#lecteur-titre").textContent = titre;
  v.src = `/api/fichiers/lire?chemin=${encodeURIComponent(chemin)}`;
  d.showModal(); v.play().catch(() => {});
}
$("#contenu").addEventListener("click", async (e) => {
  if (E.vue !== "fichiers") return;
  if (e.target.closest("[data-recharger-fichiers]")) { E.fichiers = null; rendreListeFichiers(); return chargerFichiers(); }
  const ty = e.target.closest("[data-ff-type]");
  if (ty) { E.ff.type = ty.dataset.ffType; return rendre(); }
  const dos = e.target.closest("[data-ff-dossier]");
  if (dos) { E.ff.dossier = dos.dataset.ffDossier; return rendre(); }
  const b = e.target.closest("[data-fact]");
  if (!b) return;
  e.stopPropagation();
  const f = (E.fichiers || []).find((x) => x.chemin === b.dataset.f);
  if (!f) return;
  try {
    const act = b.dataset.fact;
    if (act === "lire") lireChemin(f.chemin, f.titre);
    else if (act === "ouvrir" || act === "dossier") await api("/fichiers/ouvrir", { methode: "POST", corps: { chemin: f.chemin, dossier: act === "dossier" } });
    else if (act === "enregistrer") { const a = document.createElement("a"); a.href = `/api/fichiers/lire?chemin=${encodeURIComponent(f.chemin)}&enregistrer=1`; a.click(); }
    else if (act === "supprimer") {
      const rep = await choisir(`Supprimer « ${f.titre} » ?`, `${taille(f.taille)} seront libérés. Cette action est définitive.`, [["oui", "Supprimer le fichier"]]);
      if (rep !== "oui") return;
      await api(`/fichiers?chemin=${encodeURIComponent(f.chemin)}`, { methode: "DELETE" });
      E.fichiers = E.fichiers.filter((x) => x.chemin !== f.chemin);
      toast("Fichier supprimé", "ok"); rendre(); chargerEtat();
    }
  } catch (err) { toast(err.message, "err"); }
});
$("#contenu").addEventListener("change", (e) => {
  if (E.vue === "fichiers" && e.target.id === "tri-fichiers") { E.ff.tri = e.target.value; rendreListeFichiers(); }
});

// ── vue Historique ───────────────────────────────────────────────────
const tachesHisto = () => [...E.taches.values()].filter((t) => ["termine", "erreur", "annule"].includes(t.statut)).sort((a, b) => (b.fin || b.cree) - (a.fin || a.cree));
const FILTRES_HISTO = { tout: [() => true, "Tout"], ok: [(t) => t.statut === "termine", "Réussis"], ko: [(t) => t.statut !== "termine", "Échecs"] };
function vueHistorique() {
  const toutes = tachesHisto();
  return h`
  <div class="tete-page anim">
    <h2>Historique</h2><span class="compte">${toutes.length}</span>
    <div class="actions">
      <button class="btn petit fantome" data-exporter="json">${brut(I.exporter)} JSON</button>
      <button class="btn petit fantome" data-exporter="csv">${brut(I.exporter)} CSV</button>
      <button class="btn petit fantome danger" data-vider-histo>${brut(I.poubelle)} Vider l'historique</button>
    </div>
  </div>
  <div class="outils-fichiers anim" style="--i:1">
    <div class="avec-icone">${brut(I.chercher)}<input class="entree" id="recherche-histo" placeholder="Rechercher dans l'historique…" value="${E.hq.q}" /></div>
    <div class="onglets" style="margin:0">${Object.entries(FILTRES_HISTO).map(([k, [f, l]]) => h`<button data-hfiltre="${k}" aria-pressed="${E.hq.filtre === k}">${l}<span class="n">${toutes.filter(f).length}</span></button>`)}</div>
  </div>
  <div id="liste-histo">${listeHisto()}</div>`;
}
function jourDe(t) {
  const d = new Date((t.fin || t.cree) * 1000), auj = new Date();
  const j = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((j(auj) - j(d)) / 864e5);
  if (diff === 0) return "Aujourd'hui";
  if (diff === 1) return "Hier";
  if (diff < 7) return d.toLocaleDateString("fr-FR", { weekday: "long" });
  return d.toLocaleDateString("fr-FR", { day: "numeric", month: "long", year: "numeric" });
}
function listeHisto() {
  const q = E.hq.q.toLowerCase();
  const l = tachesHisto().filter(FILTRES_HISTO[E.hq.filtre][0]).filter((t) => !q || `${t.titre} ${t.chaine} ${t.groupe} ${t.url}`.toLowerCase().includes(q));
  if (!l.length) return h`<div class="vide anim"><div class="halo">${brut(I.horloge)}</div><h3>${q ? "Aucun résultat" : "Pas encore d'historique"}</h3><p>${q ? "Essaie un autre mot." : "Chaque téléchargement terminé ou échoué sera noté ici, jour par jour."}</p></div>`;
  const jours = new Map();
  for (const t of l) { const k = jourDe(t); if (!jours.has(k)) jours.set(k, []); jours.get(k).push(t); }
  let i = 0;
  return h`${[...jours].map(([jour, ts]) => h`
    <div class="jour"><div class="jour-titre">${jour} · ${ts.length}</div>
      <div class="histo">${ts.map((t) => {
        const b = (action, icone, titre, cls = "") => h`<button class="icone-btn ${cls}" data-t="${t.id}" data-act="${action}" title="${titre}" aria-label="${titre}">${brut(icone)}</button>`;
        const fini = t.statut === "termine" && t.fichier;
        return h`<article class="verre ligne-histo anim" style="--i:${Math.min(i++, 12)}">
          <div class="vignette">${t.miniature ? h`<img src="${t.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : ""}</div>
          <div style="min-width:0">
            <h4 title="${t.titre}">${t.titre}</h4>
            <div class="sous-ligne">
              <span class="statut ${t.statut}"><span class="point"></span>${LIBELLES[t.statut]}</span>
              ${t.pistes ? h`<span class="info-chip">${t.pistes}</span>` : ""}
              ${t.taille_fichier ? h`<span class="discret mono">${taille(t.taille_fichier)}</span>` : ""}
              ${t.erreur ? h`<span style="color:var(--rouge)">${t.erreur}</span>` : ""}
            </div>
          </div>
          <span class="heure">${new Date((t.fin || t.cree) * 1000).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}</span>
          <div class="boutons-tache">
            ${fini ? b("lire", I.lecture, "Lire") : ""}
            ${fini && E.etat?.local !== false ? b("dossier", I.dossier, "Afficher dans le dossier") : ""}
            ${b("retelecharger", I.relancer, "Télécharger à nouveau (choisir langue, qualité…)", fini ? "" : "accent")}
            ${b("supprimer", I.poubelle, "Retirer de l'historique", "danger")}
          </div>
        </article>`;
      })}</div>
    </div>`)}`;
}
function rendreListeHisto() { const z = $("#liste-histo"); if (z) z.innerHTML = html(listeHisto()); }
function exporter(format) {
  const l = tachesHisto().map((t) => ({ titre: t.titre, url: t.url, statut: LIBELLES[t.statut], pistes: t.pistes, taille: t.taille_fichier, fichier: t.fichier, date: new Date((t.fin || t.cree) * 1000).toISOString(), erreur: t.erreur }));
  const contenu = format === "json" ? JSON.stringify(l, null, 2)
    : [Object.keys(l[0] || { titre: "" }).join(";"), ...l.map((x) => Object.values(x).map((v) => `"${String(v ?? "").replace(/"/g, '""')}"`).join(";"))].join("\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([format === "csv" ? "﻿" + contenu : contenu], { type: format === "json" ? "application/json" : "text/csv" }));
  a.download = `yt-nexus-historique.${format}`; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}
$("#contenu").addEventListener("click", async (e) => {
  if (E.vue !== "historique") return;
  const f = e.target.closest("[data-hfiltre]");
  if (f) { E.hq.filtre = f.dataset.hfiltre; return rendre(); }
  const x = e.target.closest("[data-exporter]");
  if (x) return exporter(x.dataset.exporter);
  if (e.target.closest("[data-vider-histo]")) {
    const rep = await choisir("Vider l'historique ?", "Les fichiers téléchargés restent sur ton disque.", [["oui", "Vider"]]);
    if (rep !== "oui") return;
    await api("/telechargements/tout/vider_termines", { methode: "POST" });
    await api("/telechargements/tout/vider_echecs", { methode: "POST" });
    toast("Historique vidé", "ok");
  }
});

// ── vue Diagnostics ──────────────────────────────────────────────────
async function chargerDiagnostics() {
  try {
    const [, d] = await Promise.all([chargerEtat(), api("/diagnostics")]);
    E.diag = d;
    if (E.vue === "diagnostics") rendre();
  } catch (e) { toast(e.message, "err"); }
}
function vueDiagnostics() {
  const e = E.etat || {}, d = E.diag, r = R();
  const carte = (ic, g, l, v, etat, i) => h`<div class="verre carte-diag anim" style="--i:${i}"><span class="ic ${g}">${brut(ic)}</span><div style="min-width:0"><div class="l">${l}</div><div class="v">${v ?? "…"}</div>${etat ? h`<div class="etat ${etat[0] ? "ok-c" : "ko-c"}"><span class="point"></span>${etat[1]}</div>` : ""}</div></div>`;
  const solveur = e.ejs && e.deno;
  const cookies = r.cookies_navigateur ? `Navigateur : ${r.cookies_navigateur}` : e.cookies_fichier ? "Fichier cookies.txt" : "Aucun";
  const t = E.test;
  return h`
  <div class="tete-page anim"><h2>Diagnostics</h2><span class="compte">${solveur && e.ffmpeg ? "tout est prêt" : "à vérifier"}</span>
    <div class="actions"><button class="btn petit fantome" data-recharger-diag>${brut(I.relancer)} Actualiser</button></div></div>
  <div class="verre test-yt anim" style="--i:1">
    <span class="ic g2" style="width:52px;height:52px;border-radius:16px;display:grid;place-items:center;color:#fff">${brut(I.pouls)}</span>
    <div class="texte"><h3>Tester la connexion à YouTube</h3><p>Analyse une vidéo de test pour vérifier que YouTube répond et que rien ne bloque.</p></div>
    <button class="btn principal" data-test-yt ${t === "en_cours" ? "disabled" : ""}>${t === "en_cours" ? brut('<span class="rond mini"></span> Test en cours…') : h`${brut(I.lecture)} Lancer le test`}</button>
    ${t && t !== "en_cours" ? h`<div class="resultat-test"><div class="alerte ${t.ok ? "info" : "err"}">${brut(t.ok ? I.ok : I.alerte)}<span>${t.ok ? h`<b>YouTube répond.</b> ${t.formats} formats trouvés en ${t.duree} s : les téléchargements devraient fonctionner.` : h`<b>Échec en ${t.duree} s :</b> ${t.message}`}</span></div></div>` : ""}
  </div>
  <div class="grille-diag">
    ${carte(I.dl, "g1", "YT-NEXUS", e.version, null, 2)}
    ${carte(I.eclair, "g2", "yt-dlp", e.ytdlp, [!!e.ytdlp, e.ytdlp ? "installé" : "absent"], 3)}
    ${carte(I.bouclier, "g3", "Solveur YouTube (JS)", d?.deno?.split(" (")[0] || (e.deno ? "présent" : "absent"), [solveur, solveur ? `yt-dlp-ejs ${e.ejs}` : "deno ou yt-dlp-ejs manquant"], 4)}
    ${carte(I.video, "g4", "ffmpeg", d?.ffmpeg?.replace(/^ffmpeg version /, "").split(" ")[0] || (e.ffmpeg ? "présent" : "absent"), [e.ffmpeg, e.ffmpeg ? "fusion des pistes OK" : "indispensable"], 5)}
    ${carte(I.systeme, "g5", "Système", d ? `${d.systeme}` : null, d ? [true, `Python ${d.python} · Flask ${d.flask}`] : null, 6)}
    ${carte(I.cookie, "g1", "Compte YouTube", cookies, [true, r.cookies_navigateur || e.cookies_fichier ? "cookies actifs" : "non requis en général"], 7)}
    ${carte(I.dossier, "g2", "Dossier", e.dossier ? `…/${e.dossier.split("/").slice(-2).join("/")}` : null, [true, "créé automatiquement"], 8)}
    ${e.disque ? h`<div class="verre carte-diag anim" style="--i:9"><span class="ic g3">${brut(I.disque)}</span><div style="flex:1"><div class="l">Espace disque</div><div class="v">${taille(e.disque.libre)} libres</div><div class="jauge"><i style="width:${((1 - e.disque.libre / e.disque.total) * 100).toFixed(1)}%"></i></div><div class="discret petit" style="margin-top:6px">sur ${taille(e.disque.total)}</div></div></div>` : ""}
  </div>
  <section class="verre section anim" style="--i:10">
    <div class="section-tete"><span class="ic g4">${brut(I.relancer)}</span><div><h3>Mettre à jour yt-dlp</h3><p>YouTube change souvent : si les téléchargements se mettent à échouer, c'est la première chose à faire.</p></div>
      <button class="btn petit" id="maj-ytdlp" style="margin-left:auto">${brut(I.relancer)} Mettre à jour</button></div>
    <div class="rangee"><div class="texte"><span id="maj-etat">Version actuelle : ${e.ytdlp || "?"}</span></div></div>
  </section>
  ${!e.ffmpeg ? h`<div class="alerte err" style="margin-top:18px">${brut(I.alerte)}<span>ffmpeg est indispensable pour assembler vidéo et pistes audio : <code>sudo pacman -S ffmpeg</code></span></div>` : ""}
  <section class="verre section anim" style="--i:11;margin-top:18px">
    <div class="section-tete"><span class="ic g5">${brut(I.alerte)}</span><div><h3>Dernières erreurs</h3><p>${d?.erreurs?.length ? "Les échecs récents, pour comprendre ce qui coince." : "Aucune erreur récente."}</p></div></div>
    ${d?.erreurs?.length ? h`<div class="liste-erreurs">${d.erreurs.map((x) => h`<div><b>${x.titre}</b><span>${x.erreur}</span><div class="discret petit" style="margin-top:3px">${quand(x.fin)}</div></div>`)}</div>` : ""}
  </section>`;
}
$("#contenu").addEventListener("click", async (e) => {
  if (E.vue !== "diagnostics") return;
  if (e.target.closest("[data-recharger-diag]")) { E.test = null; return chargerDiagnostics(); }
  if (e.target.closest("[data-test-yt]")) {
    E.test = "en_cours"; rendre();
    try { E.test = await api("/test-youtube", { methode: "POST" }); } catch (err) { E.test = { ok: false, message: err.message, duree: "?" }; }
    if (E.vue === "diagnostics") rendre();
  }
});

// ── vue Réglages ─────────────────────────────────────────────────────
function vueReglages() {
  const r = R(), e = E.etat || {};
  const rangee = (titre, aide, controle) => h`<div class="rangee"><div class="texte"><b>${titre}</b>${aide ? h`<span>${aide}</span>` : ""}</div><div class="controle">${controle}</div></div>`;
  const bool = (k, titre, aide = "") => rangee(titre, aide, h`<input type="checkbox" class="interrupteur" data-reglage="${k}" ${r[k] ? "checked" : ""} />`);
  const sel = (k, titre, aide, opts) => rangee(titre, aide, h`<select class="entree" data-reglage="${k}">${opts.map(([v, t]) => h`<option value="${v}" ${String(r[k]) === String(v) ? "selected" : ""}>${t}</option>`)}</select>`);
  const txt = (k, titre, aide, ph = "") => rangee(titre, aide, h`<input class="entree" data-reglage="${k}" value="${r[k] ?? ""}" placeholder="${ph}" />`);
  const section = (id, icone, g, titre, desc, contenu, i) => h`<section class="verre section anim" style="--i:${i}" id="${id}"><div class="section-tete"><span class="ic ${g}">${brut(icone)}</span><div><h3>${titre}</h3><p>${desc}</p></div></div>${contenu}</section>`;
  const menu = [["s-langue", I.langue, "Langue"], ["s-dl", I.dl, "Téléchargement"], ["s-reseau", I.reseau, "Réseau"], ["s-compte", I.compte, "Compte YouTube"]];
  return h`
  <div class="tete-page anim"><h2>Paramètres</h2><span class="compte">enregistrés automatiquement</span></div>
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
$("#contenu").addEventListener("input", (e) => { if (E.vue === "parametres" && e.target.tagName === "INPUT" && e.target.type !== "checkbox" && e.target.type !== "file") changerReglage(e.target); });
$("#contenu").addEventListener("change", async (e) => {
  if (e.target.id !== "fichier-cookies") return;
  const f = e.target.files[0];
  if (!f) return;
  const form = new FormData(); form.append("fichier", f);
  try { await api("/cookies", { methode: "POST", form }); toast("Cookies importés", "ok"); await chargerEtat(); rendre(); }
  catch (err) { toast(err.message, "err"); }
});
$("#contenu").addEventListener("click", async (e) => {
  if (E.vue !== "parametres" && E.vue !== "diagnostics") return;
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
    n.onclick = () => { window.focus(); aller("fichiers"); };
  }
}

function majPastille() {
  const actifs = [...E.taches.values()].filter((t) => ACTIFS.has(t.statut) || ["en_attente", "programme"].includes(t.statut));
  const p = $("#pastille");
  p.hidden = !actifs.length; p.textContent = actifs.length;
  const echecs = [...E.taches.values()].filter((t) => t.statut === "erreur").length;
  const ph = $("#pastille-hist");
  ph.hidden = !echecs; ph.textContent = echecs; ph.title = `${echecs} échec(s)`;
  const vitesse = actifs.reduce((s, t) => s + (t.statut === "telechargement" ? t.vitesse || 0 : 0), 0);
  $("#debit").hidden = !vitesse;
  $("#debit-v").textContent = vitesse ? `${taille(vitesse)}/s` : "";
  const enCours = actifs.filter((t) => t.statut === "telechargement");
  const moy = enCours.length ? enCours.reduce((s, t) => s + t.progression, 0) / enCours.length : null;
  document.title = moy != null ? `${Math.round(moy)} % · YT-NEXUS` : "YT-NEXUS";
  placerIndicateur();
}

function appliquer(maj) {
  let structure = false, nouveauFichier = false;
  for (const t of maj.taches || []) {
    const ancien = fusionner(t);
    if (t.statut === "termine" && ancien && ancien.statut !== "termine") nouveauFichier = true;
    if (E.vue === "en-cours") {
      const visible = t.statut !== "termine" && FILTRES[E.filtre][0](t);
      const avant = ancien && ancien.statut !== "termine" && FILTRES[E.filtre][0](ancien);
      if (visible ? !majCarte(t, ancien) : avant) structure = true;
    } else if (E.vue === "historique" && (["termine", "erreur", "annule"].includes(t.statut) || ["termine", "erreur", "annule"].includes(ancien?.statut))) structure = true;
  }
  for (const id of maj.supprimees || []) if (E.taches.delete(id)) structure = true;
  if (nouveauFichier && E.vue === "fichiers") chargerFichiers();
  if (structure && (E.vue === "en-cours" || E.vue === "historique")) {
    const defil = window.scrollY;
    if (E.vue === "historique") rendreListeHisto(); else rendre();
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
  if (E.vue === "en-cours" || E.vue === "historique") rendre();
}
async function chargerEtat() {
  try { E.etat = await api("/etat"); } catch (e) { toast(e.message, "err"); }
}

// ── coller / glisser-déposer / raccourcis ────────────────────────────
function depuisDehors(t) {
  router(t, SOURCES.includes(E.vue) ? E.vue : "video");
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
    e.preventDefault(); if (!SOURCES.includes(E.vue)) aller("video");
    const champ = $("#saisie") || $("#saisie-lot"); champ?.focus(); champ?.select?.();
  }
});

// ── démarrage ────────────────────────────────────────────────────────
(async () => {
  majBoutonTheme();
  await chargerEtat();
  for (const v of SOURCES) E.p[v].choix = choixParDefaut();
  const p = new URLSearchParams(location.search);
  const partage = [p.get("url"), p.get("texte"), p.get("titre")].filter(Boolean).join(" ");
  const lien = partage.match(/https?:\/\/\S+/)?.[0];
  aller(location.hash.slice(1) || "video", { histo: false });
  await chargerTaches().catch((e) => toast(e.message, "err"));
  ecouter();
  if (document.fonts) document.fonts.ready.then(placerIndicateur);
  if (lien) { history.replaceState(null, "", "/"); router(lien, "video"); }
})();
