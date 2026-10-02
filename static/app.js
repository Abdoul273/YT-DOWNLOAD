// YT-NEXUS — interface. Aucun framework : rendu par chaînes échappées + mises à jour ciblées.

// ── utilitaires ──────────────────────────────────────────────────────
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
// Gabarit qui échappe tout sauf les fragments marqués sûrs (brut()).
class Brut { constructor(s) { this.s = s; } toString() { return this.s; } }
const brut = (s) => new Brut(s);
const h = (parts, ...vals) => brut(parts.reduce((acc, p, i) => {
  const v = vals[i - 1];
  const s = v instanceof Brut ? v.s : Array.isArray(v) ? v.map((x) => (x instanceof Brut ? x.s : esc(x))).join("") : v === false || v == null ? "" : esc(v);
  return acc + s + p;
}));

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
  t.className = `toast ${type}`;
  t.innerHTML = h`${brut(type === "err" ? I.alerte : type === "ok" ? I.ok : I.info)}<span>${msg}</span>`.s;
  $("#toasts").append(t);
  setTimeout(() => { t.style.opacity = "0"; t.style.transition = "opacity .3s"; setTimeout(() => t.remove(), 300); }, type === "err" ? 6000 : 3200);
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
const restant = (s) => (s == null ? "" : s < 60 ? `${s} s` : s < 3600 ? `${Math.round(s / 60)} min` : `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`);
const vues = (n) => (n == null ? "" : n >= 1e9 ? `${(n / 1e9).toFixed(1)} Md vues` : n >= 1e6 ? `${(n / 1e6).toFixed(1)} M vues` : n >= 1e3 ? `${Math.round(n / 1e3)} k vues` : `${n} vues`);
const dateYT = (d) => (d && d.length === 8 ? new Date(`${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6)}`).toLocaleDateString("fr-FR", { day: "numeric", month: "short", year: "numeric" }) : "");
const quand = (t) => (t ? new Date(t * 1000).toLocaleString("fr-FR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "");
const estUrl = (s) => /^(https?:\/\/|www\.|youtu\.?be|m\.youtube)/i.test(s.trim()) || /^[\w-]+\.[a-z]{2,}\/\S+/i.test(s.trim());

// ── icônes ───────────────────────────────────────────────────────────
const svg = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
const I = {
  dl: svg('<path d="M12 3v12m0 0-5-5m5 5 5-5M4 19h16"/>'),
  coller: svg('<rect x="8" y="3" width="8" height="4" rx="1"/><path d="M16 5h2a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2"/>'),
  chercher: svg('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
  video: svg('<rect x="2" y="5" width="15" height="14" rx="2"/><path d="m17 10 5-3v10l-5-3"/>'),
  audio: svg('<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>'),
  pause: svg('<rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/>'),
  lecture: svg('<path d="m7 4 13 8-13 8z"/>'),
  stop: svg('<rect x="6" y="6" width="12" height="12" rx="2"/>'),
  relancer: svg('<path d="M3 12a9 9 0 0 1 15.5-6.2L21 8M21 3v5h-5M21 12a9 9 0 0 1-15.5 6.2L3 16m0 5v-5h5"/>'),
  poubelle: svg('<path d="M3 6h18M8 6V4h8v2m1 0-1 14H8L7 6"/>'),
  dossier: svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
  ouvrir: svg('<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>'),
  enregistrer: svg('<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>'),
  alerte: svg('<path d="M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>'),
  ok: svg('<path d="M20 6 9 17l-5-5"/>'),
  info: svg('<circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v5h1"/>'),
  fleche: svg('<path d="m9 6 6 6-6 6"/>'),
  langue: svg('<path d="M5 8h10M9 4v4m-3 0c0 4 3 7 7 8M14 8c-1 4-4 7-9 8m8 4 4-9 4 9m-7-3h6"/>'),
  liste: svg('<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>'),
  disque: svg('<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>'),
  reseau: svg('<path d="M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M2 9a15 15 0 0 1 20 0M12 19.5h.01"/>'),
  compte: svg('<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'),
  systeme: svg('<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>'),
  vide: svg('<path d="M12 3v12m0 0-5-5m5 5 5-5"/><path d="M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>'),
  lune: svg('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>'),
};

// ── état ─────────────────────────────────────────────────────────────
const E = {
  vue: "telecharger",
  etat: null,               // /api/etat
  taches: new Map(),
  rev: 0,
  saisie: "",
  chargement: null,         // texte de chargement
  erreur: null,
  resultat: null,           // vidéo | playlist | lot | recherche
  choix: {},                // options de téléchargement en cours
  selection: new Set(),
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
const QUALITES = [["best", "Meilleure"], ["2160", "4K"], ["1440", "2K"], ["1080", "1080p"], ["720", "720p"], ["480", "480p"], ["360", "360p"]];

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
function aller(vue) {
  E.vue = vue;
  $$("#nav button").forEach((b) => (b.dataset.vue === vue ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current")));
  rendre();
  window.scrollTo({ top: 0, behavior: "instant" });
  if (vue === "reglages" || vue === "bibliotheque") chargerEtat().then(() => E.vue === vue && rendre());
}
$("#nav").addEventListener("click", (e) => { const b = e.target.closest("button[data-vue]"); if (b) aller(b.dataset.vue); });

function rendre() {
  const vues = { telecharger: vueTelecharger, file: vueFile, bibliotheque: vueBibliotheque, reglages: vueReglages };
  $("#contenu").innerHTML = `<section class="vue">${vues[E.vue]().s}</section>`;
  if (E.vue === "telecharger") apresTelecharger();
}

// ── vue Télécharger ──────────────────────────────────────────────────
function vueTelecharger() {
  return h`
  <div class="heros">
    <h1>Tes vidéos YouTube, <em>en français</em>.</h1>
    <p>Récupère la piste audio doublée que YouTube propose, garde la VO en bonus. Vidéos, playlists, chaînes, recherche.</p>
    <form class="saisie" id="form-saisie">
      <textarea id="saisie" rows="1" placeholder="Colle un lien YouTube, une playlist, une chaîne… ou tape une recherche" autocomplete="off" spellcheck="false">${E.saisie}</textarea>
      <button type="button" class="btn" id="btn-coller" title="Coller le presse-papiers">${brut(I.coller)}<span>Coller</span></button>
      <button type="submit" class="btn principal" id="btn-go">${brut(I.fleche)}<span>Analyser</span></button>
    </form>
    <div class="astuces"><span><kbd>Ctrl</kbd>+<kbd>V</kbd> n'importe où pour coller un lien</span><span>Plusieurs liens : un par ligne</span><span>Glisse-dépose un lien</span></div>
  </div>
  <div class="resultat" id="resultat">${zoneResultat()}</div>`;
}

function zoneResultat() {
  if (E.chargement) return h`<div class="carte chargement"><div class="rond"></div><span>${E.chargement}</span></div>`;
  if (E.erreur) return h`<div class="alerte err">${brut(I.alerte)}<span>${E.erreur}</span></div>`;
  const r = E.resultat;
  if (!r) return "";
  if (r.type === "video") return carteVideo(r);
  if (r.type === "playlist" || r.type === "lot") return cartePlaylist(r);
  if (r.type === "recherche") return grilleRecherche(r);
  return "";
}

function pisteChoisie(v) {
  // null = langue préférée des réglages (avec repli VO + sous-titres)
  return E.choix.langue_audio ?? (v.piste_voulue || v.originale);
}

function carteVideo(v) {
  const c = E.choix;
  const choisie = pisteChoisie(v);
  const estOriginale = choisie === v.originale || choisie === "original";
  const pref = R().langue_audio || "fr";
  const manque = pref !== "original" && v.pistes.length > 0 && !v.piste_voulue;
  const q = v.qualites.find((x) => String(x.hauteur) === String(c.qualite)) || v.qualites[0];
  const tailleAudio = v.taille_audio || 0;
  let est = c.type === "audio" ? tailleAudio : (q?.taille || 0) + (!estOriginale && c.garder_vo ? tailleAudio : 0);
  if (c.debut || c.fin) est = 0;
  const qualiteActive = (x) => String(c.qualite) === String(x.hauteur) || (c.qualite === "best" && x === v.qualites[0]);
  return h`
  <article class="carte video">
    <div>
      <div class="vignette">${v.miniature ? h`<img src="${v.miniature}" alt="" referrerpolicy="no-referrer" />` : ""}${v.duree ? h`<span class="duree">${duree(v.duree)}</span>` : ""}</div>
      <h2 style="margin-top:14px">${v.titre}</h2>
      <div class="meta">
        ${v.chaine ? h`<span>${v.chaine}</span>` : ""}${v.vues ? h`<span>${vues(v.vues)}</span>` : ""}${v.date ? h`<span>${dateYT(v.date)}</span>` : ""}
        ${v.plateforme && v.plateforme !== "Youtube" ? h`<span class="etiquette">${v.plateforme}</span>` : ""}
      </div>
      ${v.playlist ? h`<button class="btn petit" style="margin-top:14px" data-action="ouvrir-playlist">${brut(I.liste)} Voir toute la playlist</button>` : ""}
    </div>
    <div>
      ${v.direct ? h`<div class="alerte">${brut(I.alerte)}<span>C'est un direct en cours : attends la fin du live pour le télécharger.</span></div>` : ""}
      <div class="bloc"><h3>Type</h3>
        <div class="segment">
          <button data-type="video" aria-pressed="${c.type === "video"}">${brut(I.video)} Vidéo</button>
          <button data-type="audio" aria-pressed="${c.type === "audio"}">${brut(I.audio)} Audio seul</button>
        </div>
      </div>

      ${v.pistes.length > 1 || manque ? h`
      <div class="bloc"><h3>${brut(I.langue)} Langue audio · ${v.pistes.length} piste${v.pistes.length > 1 ? "s" : ""}</h3>
        <div class="puces">${v.pistes.map((p) => h`
          <button class="puce" data-piste="${p.originale ? "original" : p.code}" aria-pressed="${p.code === choisie || (p.originale && choisie === "original")}">
            <span>${p.drapeau}</span>${p.nom}
            ${p.originale ? h`<span class="tag vo">VO</span>` : p.genre === "doublage IA" ? h`<span class="tag ia">IA</span>` : ""}
          </button>`)}
        </div>
        ${manque && E.choix.langue_audio == null ? h`<div class="alerte" style="margin-top:12px">${brut(I.info)}<span>YouTube ne propose pas de doublage ${nomLangue(pref).toLowerCase()} pour cette vidéo.
          ${R().sous_titres_secours && c.type === "video" ? (v.sous_titres.auto || v.sous_titres.manuels.length ? " Elle sera téléchargée en VO avec des sous-titres intégrés (traduits automatiquement si besoin)." : " Pas de sous-titres disponibles non plus.") : ""}</span></div>` : ""}
        ${!estOriginale && c.type === "video" ? h`<label class="interrupteur" style="margin-top:12px"><input type="checkbox" data-opt="garder_vo" ${c.garder_vo ? "checked" : ""} /> Garder la VO (${v.originale_nom || "originale"}) en 2<sup>e</sup> piste</label>` : ""}
      </div>` : ""}

      ${c.type === "video" ? h`
      <div class="bloc"><h3>Qualité</h3>
        <div class="puces">${v.qualites.map((x) => h`
          <button class="puce" data-qualite="${x.hauteur}" aria-pressed="${qualiteActive(x)}">
            ${x.libelle}${x.badge ? h` <span class="tag badge">${x.badge}</span>` : ""}${x.hdr ? h` <span class="tag ia">HDR</span>` : ""}
            ${x.taille ? h`<span class="sous">${taille(x.taille + (!estOriginale && c.garder_vo ? tailleAudio : 0))}</span>` : ""}
          </button>`)}
        </div>
      </div>` : ""}

      <div class="bloc"><h3>Format</h3>${selecteurFormat()}</div>

      <details class="avance"${c.sous_titres.length || c.sponsorblock || c.debut || c.fin || c.programme ? " open" : ""}>
        <summary>${brut(I.fleche)} Options avancées</summary>
        ${c.type === "video" && (v.sous_titres.manuels.length || v.sous_titres.auto) ? h`
        <div class="bloc"><h3>Sous-titres</h3>
          <div class="puces">
            ${v.sous_titres.auto_fr ? h`<button class="puce" data-st="fr" data-auto="1" aria-pressed="${c.sous_titres.includes("fr")}">🇫🇷 Français <span class="tag ia">auto</span></button>` : ""}
            ${v.sous_titres.manuels.slice(0, 30).map((s) => h`<button class="puce" data-st="${s.code}" aria-pressed="${c.sous_titres.includes(s.code)}">${s.drapeau} ${s.nom}</button>`)}
          </div>
          <label class="interrupteur" style="margin-top:12px"><input type="checkbox" data-opt="sous_titres_fichier" ${c.sous_titres_fichier ? "checked" : ""} /> En fichiers .srt séparés (sinon intégrés à la vidéo)</label>
        </div>` : ""}
        ${optionsAvancees(v.chapitres)}
      </details>

      <div class="actions-bas">
        <button class="btn principal grand" data-action="telecharger" ${E.envoi || v.direct ? "disabled" : ""}>${brut(I.dl)} ${c.programme ? "Programmer" : "Télécharger"}</button>
        ${est ? h`<span class="estimation">≈ <b>${taille(est)}</b></span>` : ""}
      </div>
    </div>
  </article>`;
}

function selecteurFormat() {
  const c = E.choix;
  if (c.type === "audio") {
    return h`<div class="ligne">
      <select class="entree" data-opt="format_audio">
        ${[["mp3", "MP3"], ["m4a", "M4A (AAC)"], ["opus", "Opus"], ["flac", "FLAC"], ["wav", "WAV"], ["original", "Original, sans conversion"]].map(([k, l]) => h`<option value="${k}" ${c.format_audio === k ? "selected" : ""}>${l}</option>`)}
      </select>
      ${c.format_audio !== "original" && !["flac", "wav"].includes(c.format_audio) ? h`
      <select class="entree" data-opt="qualite_audio">
        ${[["0", "Meilleure qualité"], ["320K", "320 kbit/s"], ["256K", "256 kbit/s"], ["192K", "192 kbit/s"], ["128K", "128 kbit/s"]].map(([k, l]) => h`<option value="${k}" ${c.qualite_audio === k ? "selected" : ""}>${l}</option>`)}
      </select>` : ""}
    </div>`;
  }
  return h`<div class="ligne">
    <select class="entree" data-opt="conteneur">
      <option value="mp4" ${c.conteneur === "mp4" ? "selected" : ""}>MP4 — lisible partout</option>
      <option value="mkv" ${c.conteneur === "mkv" ? "selected" : ""}>MKV — le plus flexible</option>
      <option value="webm" ${c.conteneur === "webm" ? "selected" : ""}>WebM</option>
    </select>
  </div>`;
}

function optionsAvancees(chapitres) {
  const c = E.choix;
  return h`<div class="grille2">
    <div class="champ"><label>Début de l'extrait</label><input class="entree" data-opt="debut" placeholder="ex. 1:30" value="${c.debut}" /></div>
    <div class="champ"><label>Fin de l'extrait</label><input class="entree" data-opt="fin" placeholder="ex. 5:00" value="${c.fin}" /></div>
    <div class="champ"><label>Programmer pour</label><input class="entree" type="datetime-local" data-opt="programme" value="${c.programme}" /></div>
  </div>
  <div class="options-bool">
    <label class="interrupteur"><input type="checkbox" data-opt="sponsorblock" ${c.sponsorblock ? "checked" : ""} /> Retirer les passages sponsorisés (SponsorBlock)</label>
    ${chapitres !== 0 && c.type === "video" ? h`<label class="interrupteur"><input type="checkbox" data-opt="chapitres_separes" ${c.chapitres_separes ? "checked" : ""} /> Créer aussi un fichier par chapitre</label>` : ""}
  </div>`;
}

function cartePlaylist(p) {
  const c = E.choix;
  const n = E.selection.size;
  const langue = c.langue_audio ?? R().langue_audio ?? "fr";
  return h`
  <article class="carte playlist">
    <div class="tete-playlist">
      ${p.miniature ? h`<img src="${p.miniature}" alt="" referrerpolicy="no-referrer" />` : ""}
      <div>
        <div class="etiquette">${p.type === "lot" ? "Plusieurs liens" : "Playlist"}</div>
        <h2 style="margin-top:6px;font-size:1.25rem">${p.titre}</h2>
        <div class="meta">${p.chaine ? h`<span>${p.chaine}</span>` : ""}<span>${p.nombre} élément${p.nombre > 1 ? "s" : ""}</span></div>
      </div>
    </div>
    <div class="grille2" style="margin-top:18px">
      <div class="champ"><span>Type</span>
        <div class="segment">
          <button data-type="video" aria-pressed="${c.type === "video"}">${brut(I.video)} Vidéo</button>
          <button data-type="audio" aria-pressed="${c.type === "audio"}">${brut(I.audio)} Audio</button>
        </div>
      </div>
      <div class="champ"><label>Langue audio (si YouTube la propose)</label>
        <select class="entree" data-opt="langue_audio">${LANGUES.map(([k, l]) => h`<option value="${k}" ${langue === k ? "selected" : ""}>${l}</option>`)}</select>
      </div>
      ${c.type === "video" ? h`<div class="champ"><label>Qualité max</label>
        <select class="entree" data-opt="qualite">${QUALITES.map(([k, l]) => h`<option value="${k}" ${String(c.qualite) === k ? "selected" : ""}>${l}</option>`)}</select></div>` : ""}
      <div class="champ"><span>Format</span>${selecteurFormat()}</div>
    </div>
    ${c.type === "video" && langue !== "original" ? h`<label class="interrupteur" style="margin-top:14px"><input type="checkbox" data-opt="garder_vo" ${c.garder_vo ? "checked" : ""} /> Garder la VO en 2<sup>e</sup> piste quand un doublage existe</label>` : ""}
    <details class="avance"><summary>${brut(I.fleche)} Options avancées</summary>${optionsAvancees()}</details>

    <div class="ligne" style="margin-top:18px">
      <label class="interrupteur"><input type="checkbox" id="tout-cocher" ${n === p.entrees.length ? "checked" : ""} /> Tout sélectionner</label>
      <span class="espace"></span><span class="muet petit">${n} / ${p.entrees.length} sélectionné${n > 1 ? "s" : ""}</span>
    </div>
    <div class="liste-entrees" id="liste-entrees">
      ${p.entrees.map((e, i) => h`
      <label class="entree-pl">
        <input type="checkbox" data-sel="${i}" ${E.selection.has(i) ? "checked" : ""} />
        ${e.miniature ? h`<img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : h`<span class="squelette" style="width:96px;aspect-ratio:16/9"></span>`}
        <span class="t">${e.titre}</span>
        <span class="d muet mono petit">${duree(e.duree)}</span>
      </label>`)}
    </div>
    <div class="actions-bas">
      <button class="btn principal grand" data-action="telecharger-selection" ${!n || E.envoi ? "disabled" : ""}>${brut(I.dl)} ${c.programme ? "Programmer" : "Télécharger"} ${n} élément${n > 1 ? "s" : ""}</button>
    </div>
  </article>`;
}

function grilleRecherche(r) {
  if (!r.resultats.length) return h`<div class="vide"><h3>Aucun résultat</h3><p>Essaie d'autres mots-clés.</p></div>`;
  return h`<div class="ligne"><h3 class="titre-bloc" style="margin:0">Résultats pour « ${r.requete} »</h3></div>
  <div class="grille-recherche">${r.resultats.map((e, i) => h`
    <article class="carte res" data-res="${i}" tabindex="0">
      <div class="vignette"><img src="${e.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />${e.duree ? h`<span class="duree">${duree(e.duree)}</span>` : e.direct ? h`<span class="duree" style="background:var(--rouge)">DIRECT</span>` : ""}</div>
      <div class="corps">
        <div style="flex:1;min-width:0"><div class="t">${e.titre}</div><div class="muet petit" style="margin-top:4px">${e.chaine || ""}${e.vues ? " · " + vues(e.vues) : ""}</div></div>
        <button class="icone-btn" data-rapide="${i}" title="Télécharger directement (réglages par défaut)">${brut(I.dl)}</button>
      </div>
    </article>`)}
  </div>`;
}

function rafraichirResultat() {
  const z = $("#resultat");
  if (!z) return;
  const ouvert = $("details.avance", z)?.open;
  const defil = $("#liste-entrees", z)?.scrollTop;
  const contenu = zoneResultat();
  z.innerHTML = contenu.s ?? contenu;
  if (ouvert) $("details.avance", z)?.setAttribute("open", "");
  if (defil) $("#liste-entrees", z).scrollTop = defil;
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
  if (!E.resultat && !E.chargement) ta.focus();
}

const libelleGo = () => {
  const lignes = E.saisie.split(/\s*\n\s*/).filter(Boolean);
  if (!lignes.length) return "Analyser";
  if (lignes.length > 1 && lignes.every(estUrl)) return `Analyser ${lignes.length} liens`;
  return estUrl(lignes[0]) ? "Analyser" : "Rechercher";
};

async function lancerSaisie(texte = E.saisie) {
  const lignes = texte.split(/\s+/).map((s) => s.trim()).filter(Boolean);
  const liens = lignes.filter(estUrl);
  if (!texte.trim()) return $("#saisie")?.focus();
  E.erreur = null; E.resultat = null;
  if (liens.length > 1) {
    E.choix = choixParDefaut();
    E.resultat = { type: "lot", titre: `${liens.length} liens`, nombre: liens.length, entrees: [...new Set(liens)].map((u) => ({ url: u, titre: u })) };
    E.resultat.nombre = E.resultat.entrees.length;
    E.selection = new Set(E.resultat.entrees.map((_, i) => i));
    return rafraichirResultat();
  }
  if (liens.length === 1) return analyser(liens[0]);
  return rechercher(texte.trim());
}

async function analyser(url) {
  E.chargement = "Analyse de la vidéo… (pistes audio, qualités, sous-titres)"; E.erreur = null; E.resultat = null;
  if (E.vue !== "telecharger") aller("telecharger"); else rafraichirResultat();
  try {
    const r = await api("/analyse", { methode: "POST", corps: { url } });
    E.choix = choixParDefaut();
    E.resultat = r;
    if (r.type === "playlist") E.selection = new Set(r.entrees.map((_, i) => i));
  } catch (e) { E.erreur = e.message; }
  E.chargement = null;
  rafraichirResultat();
}

async function rechercher(q) {
  E.chargement = `Recherche « ${q} »…`; rafraichirResultat();
  try {
    const r = await api("/recherche", { methode: "POST", corps: { q } });
    E.resultat = { type: "recherche", requete: q, resultats: r.resultats };
  } catch (e) { E.erreur = e.message; }
  E.chargement = null; rafraichirResultat();
}

function optionsEnvoi() {
  const c = { ...E.choix };
  if (c.programme) c.programme = Math.floor(new Date(c.programme).getTime() / 1000);
  else delete c.programme;
  if (c.langue_audio == null) delete c.langue_audio;
  if (c.sous_titres.includes("fr")) c.sous_titres_auto = true;
  return c;
}

async function envoyer(elements) {
  E.envoi = true; rafraichirResultat();
  try {
    const r = await api("/telechargements", { methode: "POST", corps: { elements, options: optionsEnvoi() } });
    r.taches.forEach(fusionner);
    const n = r.taches.length;
    toast(n > 1 ? `${n} téléchargements ajoutés à la file` : E.choix.programme ? "Téléchargement programmé" : "Téléchargement lancé", "ok");
    majPastille();
  } catch (e) { toast(e.message, "err"); }
  E.envoi = false; rafraichirResultat();
}

// Interactions de la vue Télécharger (délégation)
$("#contenu").addEventListener("click", (e) => {
  if (E.vue !== "telecharger") return;
  const el = e.target.closest("[data-type],[data-piste],[data-qualite],[data-st],[data-action],[data-res],[data-rapide]");
  if (!el) return;
  const r = E.resultat;
  if (el.dataset.type) { E.choix.type = el.dataset.type; return rafraichirResultat(); }
  if (el.dataset.piste) { E.choix.langue_audio = el.dataset.piste; return rafraichirResultat(); }
  if (el.dataset.qualite) { E.choix.qualite = el.dataset.qualite; return rafraichirResultat(); }
  if (el.dataset.st) {
    const s = new Set(E.choix.sous_titres);
    s.has(el.dataset.st) ? s.delete(el.dataset.st) : s.add(el.dataset.st);
    E.choix.sous_titres = [...s]; return rafraichirResultat();
  }
  if (el.dataset.rapide) {
    e.stopPropagation();
    const x = r.resultats[+el.dataset.rapide];
    E.choix = choixParDefaut();
    return envoyer([{ url: x.url, titre: x.titre, miniature: x.miniature, chaine: x.chaine, duree: x.duree }]);
  }
  if (el.dataset.res) { const x = r.resultats[+el.dataset.res]; E.saisie = x.url; $("#saisie").value = x.url; return analyser(x.url); }
  const a = el.dataset.action;
  if (a === "ouvrir-playlist") { E.saisie = r.playlist; $("#saisie").value = r.playlist; return analyser(r.playlist); }
  if (a === "telecharger") return envoyer([{ url: r.url, titre: r.titre, miniature: r.miniature, chaine: r.chaine, duree: r.duree }]);
  if (a === "telecharger-selection") {
    const groupe = r.type === "playlist" ? r.titre : null;
    return envoyer([...E.selection].sort((x, y) => x - y).map((i) => ({ ...r.entrees[i], groupe })));
  }
});
$("#contenu").addEventListener("keydown", (e) => {
  if (E.vue === "telecharger" && e.key === "Enter" && e.target.dataset.res) e.target.click();
});
$("#contenu").addEventListener("change", (e) => {
  const el = e.target;
  if (E.vue === "telecharger") {
    if (el.id === "tout-cocher") { E.selection = el.checked ? new Set(E.resultat.entrees.map((_, i) => i)) : new Set(); return rafraichirResultat(); }
    if (el.dataset.sel) { el.checked ? E.selection.add(+el.dataset.sel) : E.selection.delete(+el.dataset.sel); return rafraichirResultat(); }
    if (el.dataset.opt) {
      E.choix[el.dataset.opt] = el.type === "checkbox" ? el.checked : el.value;
      if (["conteneur", "format_audio", "langue_audio", "garder_vo", "programme", "qualite"].includes(el.dataset.opt)) rafraichirResultat();
    }
  } else if (E.vue === "reglages") changerReglage(el);
});
$("#contenu").addEventListener("input", (e) => {
  const el = e.target;
  if (E.vue === "telecharger" && el.dataset.opt && el.tagName === "INPUT" && el.type !== "checkbox") E.choix[el.dataset.opt] = el.value;
  if (E.vue === "bibliotheque" && el.id === "recherche-biblio") { E.recherche_biblio = el.value; rendreListeBiblio(); }
});

// ── vue File ─────────────────────────────────────────────────────────
const LIBELLES = {
  en_attente: "En attente", programme: "Programmé", analyse: "Analyse", telechargement: "Téléchargement",
  traitement: "Traitement", attente_relance: "Nouvelle tentative", pause: "En pause", termine: "Terminé",
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
  <div class="barre-outils">
    <h2>File de téléchargement</h2>
    <button class="btn petit" data-global="pause_tout">${brut(I.pause)} Tout en pause</button>
    <button class="btn petit" data-global="reprendre_tout">${brut(I.lecture)} Tout reprendre</button>
    <button class="btn petit" data-global="relancer_erreurs">${brut(I.relancer)} Relancer les échecs</button>
    <button class="btn petit danger" data-global="vider_echecs">${brut(I.poubelle)} Vider les échecs</button>
  </div>
  <div class="filtres">${Object.entries(FILTRES).map(([k, [f, l]]) => {
    const n = toutes.filter(f).length;
    return h`<button class="puce" data-filtre="${k}" aria-pressed="${E.filtre === k}">${l}<span class="sous">${n}</span></button>`;
  })}</div>
  <div class="taches" id="liste-taches">
    ${liste.length ? liste.map(carteTache) : h`<div class="vide">${brut(I.vide)}<h3>Rien en cours</h3><p>Les vidéos terminées sont dans la <a href="#" data-aller="bibliotheque">Bibliothèque</a>.</p></div>`}
  </div>`;
}

function chiffresTache(t) {
  if (t.statut === "telechargement") {
    return h`<b>${t.progression.toFixed(1)} %</b>${t.total ? h`<span>${taille(t.telecharge)} / ${taille(t.total)}</span>` : ""}${t.vitesse ? h`<span>${taille(t.vitesse)}/s</span>` : ""}${t.eta != null ? h`<span>reste ${restant(t.eta)}</span>` : ""}`;
  }
  if (t.statut === "termine") return h`<span>${taille(t.taille_fichier)}</span><span>${quand(t.fin)}</span>`;
  if (t.statut === "programme") return h`<span>Prévu le ${quand(t.programme)}</span>`;
  if (["pause", "erreur"].includes(t.statut) && t.progression) return h`<span>${t.progression.toFixed(1)} %</span>${t.total ? h`<span>${taille(t.total)}</span>` : ""}`;
  return "";
}

function boutonsTache(t) {
  const b = (action, icone, titre, cls = "") => h`<button class="icone-btn ${cls}" data-t="${t.id}" data-act="${action}" title="${titre}" aria-label="${titre}">${brut(icone)}</button>`;
  const r = [];
  if (ACTIFS.has(t.statut) || ["en_attente", "programme"].includes(t.statut)) r.push(b("pause", I.pause, "Mettre en pause"));
  if (t.statut === "pause") r.push(b("reprendre", I.lecture, "Reprendre"));
  if (["erreur", "annule"].includes(t.statut)) r.push(b("relancer", I.relancer, "Réessayer"));
  if (t.statut === "termine" && t.fichier) {
    r.push(b("lire", I.lecture, "Lire"));
    if (E.etat?.local !== false) r.push(b("ouvrir", I.ouvrir, "Ouvrir avec le lecteur"), b("dossier", I.dossier, "Afficher dans le dossier"));
    r.push(b("enregistrer", I.enregistrer, "Enregistrer sur cet appareil"));
  }
  if (!["termine", "annule", "erreur"].includes(t.statut)) r.push(b("annuler", I.stop, "Annuler", "danger"));
  r.push(b("supprimer", I.poubelle, t.statut === "termine" ? "Retirer de la liste (ou supprimer le fichier)" : "Retirer", "danger"));
  return r;
}

function carteTache(t) {
  const msg = t.erreur ? h`<div class="msg err">${t.erreur}</div>` : t.message ? h`<div class="msg">${t.message}</div>` : "";
  return h`
  <article class="carte tache ${t.statut}" id="t-${t.id}">
    <div class="vignette">${t.miniature ? h`<img src="${t.miniature}" alt="" loading="lazy" referrerpolicy="no-referrer" />` : ""}${t.duree ? h`<span class="duree">${duree(t.duree)}</span>` : ""}</div>
    <div style="min-width:0">
      <h4 title="${t.titre}">${t.titre}</h4>
      <div class="sous-ligne">
        <span class="etiquette ${t.statut}" data-champ="statut">${LIBELLES[t.statut] || t.statut}</span>
        ${t.options?.type === "audio" ? h`<span class="etiquette">${(t.options.format_audio || "mp3").toUpperCase()}</span>` : ""}
        ${t.pistes ? h`<span>${t.pistes}</span>` : ""}
        ${t.groupe ? h`<span>· ${t.groupe}</span>` : ""}
        <span data-champ="phase">${t.phase || ""}</span>
      </div>
      ${t.statut !== "termine" ? h`<div class="progres"><i data-champ="barre" style="width:${t.statut === "analyse" || t.statut === "traitement" ? 100 : t.progression}%"></i></div>` : ""}
      <div class="chiffres" data-champ="chiffres">${chiffresTache(t)}</div>
      ${msg}
    </div>
    <div class="boutons-tache">${boutonsTache(t)}</div>
  </article>`;
}

// Mise à jour ciblée d'une carte (évite de tout redessiner 4 fois par seconde)
function majCarte(t, ancien) {
  const el = document.getElementById(`t-${t.id}`);
  if (!el) return false;
  if (!ancien || ancien.statut !== t.statut || ancien.message !== t.message || ancien.erreur !== t.erreur || ancien.pistes !== t.pistes || ancien.titre !== t.titre || ancien.miniature !== t.miniature) {
    el.outerHTML = carteTache(t).s;
    return true;
  }
  const barre = $('[data-champ="barre"]', el);
  if (barre && t.statut === "telechargement") barre.style.width = `${t.progression}%`;
  $('[data-champ="phase"]', el).textContent = t.phase || "";
  $('[data-champ="chiffres"]', el).innerHTML = chiffresTache(t).s ?? "";
  return true;
}

$("#contenu").addEventListener("click", async (e) => {
  const aller_ = e.target.closest("[data-aller]");
  if (aller_) { e.preventDefault(); return aller(aller_.dataset.aller); }
  const f = e.target.closest("[data-filtre]");
  if (f) { E.filtre = f.dataset.filtre; return rendre(); }
  const g = e.target.closest("[data-global]");
  if (g) {
    try { await api(`/telechargements/tout/${g.dataset.global}`, { methode: "POST" }); } catch (err) { toast(err.message, "err"); }
    return;
  }
  const b = e.target.closest("[data-act]");
  if (!b) return;
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
        const rep = await choisir(`Retirer « ${t.titre} » de la bibliothèque ?`, [["liste", "Retirer de la liste"], ["fichier", "Supprimer aussi le fichier"]]);
        if (!rep) return;
        fichier = rep === "fichier";
      }
      await api(`/telechargements/${t.id}${fichier ? "?fichier=1" : ""}`, { methode: "DELETE" });
      if (fichier) toast("Fichier supprimé", "ok");
    }
  } catch (err) { toast(err.message, "err"); }
});

function choisir(question, options) {
  return new Promise((ok) => {
    const d = document.createElement("dialog");
    d.style.width = "min(440px, calc(100vw - 32px))";
    d.innerHTML = h`<div style="padding:22px"><p style="font-weight:700;margin-bottom:18px">${question}</p>
      <div class="ligne" style="justify-content:flex-end"><button class="btn petit" value="">Annuler</button>
      ${options.map(([v, l], i) => h`<button class="btn petit ${i === options.length - 1 ? "danger" : ""}" value="${v}">${l}</button>`)}</div></div>`.s;
    d.addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) { d.close(b.value); } else if (e.target === d) d.close(""); });
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
  <div class="barre-outils">
    <h2>Bibliothèque</h2>
    ${E.etat?.local !== false ? h`<button class="btn petit" data-ouvrir-dossier>${brut(I.dossier)} Ouvrir le dossier</button>` : ""}
    <button class="btn petit danger" data-global="vider_termines">${brut(I.poubelle)} Vider la liste</button>
  </div>
  <div class="stats">
    <div class="carte stat"><div class="v">${termines.length}</div><div class="l">fichiers téléchargés</div></div>
    <div class="carte stat"><div class="v">${taille(total)}</div><div class="l">au total</div></div>
    ${d ? h`<div class="carte stat"><div class="v">${taille(d.libre)}</div><div class="l">libres sur le disque</div><div class="jauge"><i style="width:${((1 - d.libre / d.total) * 100).toFixed(1)}%"></i></div></div>` : ""}
  </div>
  <input class="entree" id="recherche-biblio" placeholder="Rechercher dans la bibliothèque…" value="${E.recherche_biblio}" style="width:100%;margin-bottom:14px" />
  <div class="taches" id="liste-biblio">${listeBiblio()}</div>`;
}
function listeBiblio() {
  const q = E.recherche_biblio.toLowerCase();
  const l = [...E.taches.values()].filter((t) => t.statut === "termine" && (!q || `${t.titre} ${t.chaine} ${t.groupe}`.toLowerCase().includes(q))).sort((a, b) => (b.fin || 0) - (a.fin || 0));
  if (!l.length) return h`<div class="vide">${brut(I.vide)}<h3>${q ? "Aucun résultat" : "Encore rien ici"}</h3><p>${q ? "" : "Tes téléchargements terminés apparaîtront ici."}</p></div>`;
  return h`${l.map(carteTache)}`;
}
function rendreListeBiblio() { const z = $("#liste-biblio"); if (z) z.innerHTML = listeBiblio().s; }
$("#contenu").addEventListener("click", (e) => {
  if (e.target.closest("[data-ouvrir-dossier]")) api("/ouvrir-dossier", { methode: "POST" }).catch((err) => toast(err.message, "err"));
});

// ── vue Réglages ─────────────────────────────────────────────────────
function vueReglages() {
  const r = R(), e = E.etat || {};
  const bool = (k, l, aide = "") => h`<label class="interrupteur"><input type="checkbox" data-reglage="${k}" ${r[k] ? "checked" : ""} /> <span>${l}${aide ? h`<br><span class="muet petit">${aide}</span>` : ""}</span></label>`;
  const sel = (k, l, opts) => h`<div class="champ"><label>${l}</label><select class="entree" data-reglage="${k}">${opts.map(([v, t]) => h`<option value="${v}" ${String(r[k]) === String(v) ? "selected" : ""}>${t}</option>`)}</select></div>`;
  const txt = (k, l, ph = "", type = "text") => h`<div class="champ"><label>${l}</label><input class="entree" type="${type}" data-reglage="${k}" value="${r[k] ?? ""}" placeholder="${ph}" /></div>`;
  const theme = document.documentElement.dataset.theme;
  return h`
  <div class="barre-outils"><h2>Réglages</h2>
    <button class="btn petit" id="btn-theme">${brut(I.lune)} Thème ${theme === "clair" ? "sombre" : "clair"}</button></div>
  <div class="reglages">
    <section class="carte section"><h3>${brut(I.langue)} Langue et pistes audio</h3>
      <p>La piste doublée est choisie automatiquement quand YouTube la propose (doublage humain ou IA).</p>
      <div class="grille2">${sel("langue_audio", "Langue audio préférée", LANGUES)}</div>
      <div class="options-bool">
        ${bool("garder_vo", "Garder la VO en 2e piste", "Tu peux changer de piste dans VLC, mpv, la TV…")}
        ${bool("sous_titres_secours", "Sans doublage : intégrer les sous-titres dans ma langue", "Traduits automatiquement par YouTube si besoin")}
      </div>
    </section>
    <section class="carte section"><h3>${brut(I.dl)} Téléchargement</h3>
      <div class="grille2">
        ${txt("dossier", "Dossier de destination")}
        ${sel("simultanes", "Téléchargements simultanés", [1, 2, 3, 4, 5, 6, 8].map((n) => [n, n]))}
        ${sel("type", "Type par défaut", [["video", "Vidéo"], ["audio", "Audio seul"]])}
        ${sel("qualite", "Qualité par défaut", QUALITES)}
        ${sel("conteneur", "Format vidéo", [["mp4", "MP4"], ["mkv", "MKV"], ["webm", "WebM"]])}
        ${sel("format_audio", "Format audio", [["mp3", "MP3"], ["m4a", "M4A"], ["opus", "Opus"], ["flac", "FLAC"], ["wav", "WAV"], ["original", "Original"]])}
        ${txt("modele_nom", "Modèle de nom de fichier", "%(title)s [%(id)s].%(ext)s")}
      </div>
      <div class="options-bool">
        ${bool("sous_dossier_playlist", "Ranger chaque playlist dans son propre dossier")}
        ${bool("miniature", "Intégrer la miniature")}
        ${bool("metadonnees", "Intégrer les métadonnées et chapitres")}
        ${bool("sponsorblock", "Retirer les sponsors par défaut (SponsorBlock)")}
        ${bool("notifications", "Notification quand un téléchargement se termine")}
      </div>
    </section>
    <section class="carte section"><h3>${brut(I.reseau)} Réseau</h3>
      <div class="grille2">
        ${sel("fragments", "Connexions par fichier", [1, 2, 4, 8, 16].map((n) => [n, n]))}
        ${txt("limite_vitesse", "Limite de vitesse", "illimitée — ex. 2M, 500K")}
        ${sel("relances", "Nouvelles tentatives auto", [0, 2, 4, 6, 10].map((n) => [n, n]))}
      </div>
    </section>
    <section class="carte section"><h3>${brut(I.compte)} Compte YouTube</h3>
      <p>Nécessaire seulement si YouTube bloque (« prouve que tu n'es pas un robot », vidéos 18+, réservées aux membres). Les cookies restent sur ta machine.</p>
      <div class="grille2">${sel("cookies_navigateur", "Utiliser les cookies de", [["", "Aucun navigateur"], ["firefox", "Firefox"], ["chrome", "Chrome"], ["chromium", "Chromium"], ["brave", "Brave"], ["edge", "Edge"], ["opera", "Opera"], ["vivaldi", "Vivaldi"]])}</div>
      <div class="ligne" style="margin-top:14px">
        <label class="btn petit">${brut(I.enregistrer)} Importer un cookies.txt<input type="file" accept=".txt" id="fichier-cookies" hidden /></label>
        ${e.cookies_fichier ? h`<span class="etiquette termine">cookies.txt importé</span><button class="btn petit danger" id="suppr-cookies">Supprimer</button>` : ""}
      </div>
    </section>
    <section class="carte section"><h3>${brut(I.systeme)} Système</h3>
      <div class="diag">
        <div>YT-NEXUS<b>${e.version || "?"}</b></div>
        <div>yt-dlp<b>${e.ytdlp || "absent"}</b></div>
        <div>Solveur YouTube<b class="${e.ejs && e.deno ? "ok-c" : "ko-c"}">${e.ejs && e.deno ? "OK" : "manquant"}</b></div>
        <div>ffmpeg<b class="${e.ffmpeg ? "ok-c" : "ko-c"}">${e.ffmpeg ? "OK" : "absent"}</b></div>
        ${e.disque ? h`<div>Espace libre<b>${taille(e.disque.libre)}</b></div>` : ""}
      </div>
      ${!e.ffmpeg ? h`<div class="alerte err" style="margin-top:12px">${brut(I.alerte)}<span>ffmpeg est indispensable pour fusionner vidéo et pistes audio : <code>sudo pacman -S ffmpeg</code></span></div>` : ""}
      <div class="ligne" style="margin-top:14px"><button class="btn petit" id="maj-ytdlp">${brut(I.relancer)} Mettre à jour yt-dlp</button><span class="muet petit" id="maj-etat">À faire si YouTube se met à refuser les téléchargements.</span></div>
    </section>
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
  }, el.tagName === "INPUT" && el.type === "text" ? 500 : 0);
}
$("#contenu").addEventListener("input", (e) => { if (E.vue === "reglages" && e.target.type === "text") changerReglage(e.target); });
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
  if (e.target.closest("#btn-theme")) {
    const t = document.documentElement.dataset.theme === "clair" ? "sombre" : "clair";
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem("theme", t); } catch {}
    return rendre();
  }
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
  $("#debit").textContent = vitesse ? `↓ ${taille(vitesse)}/s` : "";
  const enCours = actifs.filter((t) => t.statut === "telechargement");
  const moy = enCours.length ? enCours.reduce((s, t) => s + t.progression, 0) / enCours.length : null;
  document.title = moy != null ? `(${Math.round(moy)} %) YT-NEXUS` : "YT-NEXUS";
}

function appliquer(maj) {
  let structure = false;
  for (const t of maj.taches || []) {
    const ancien = fusionner(t);
    if (E.vue === "file") {
      const visible = t.statut !== "termine" && FILTRES[E.filtre][0](t);
      if (!visible || !majCarte(t, ancien)) structure = true;
    } else if (E.vue === "bibliotheque" && (t.statut === "termine" || ancien?.statut === "termine")) structure = true;
  }
  for (const id of maj.supprimees || []) {
    if (E.taches.delete(id)) structure = true;
  }
  if (structure && (E.vue === "file" || E.vue === "bibliotheque")) {
    const defil = window.scrollY;
    if (E.vue === "bibliotheque") rendreListeBiblio(); else rendre();
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

// ── coller / glisser-déposer / partage ───────────────────────────────
document.addEventListener("paste", (e) => {
  const cible = e.target;
  if (cible.closest?.("input, textarea, [contenteditable]")) return;
  const t = e.clipboardData.getData("text").trim();
  if (!t) return;
  e.preventDefault();
  E.saisie = t;
  if (E.vue !== "telecharger") aller("telecharger");
  $("#saisie").value = t;
  lancerSaisie(t);
});
let profondeur = 0;
document.addEventListener("dragenter", (e) => { if ([...e.dataTransfer.types].some((x) => x.startsWith("text/"))) { profondeur++; $("#deposer").hidden = false; } });
document.addEventListener("dragleave", () => { if (--profondeur <= 0) { profondeur = 0; $("#deposer").hidden = true; } });
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", (e) => {
  e.preventDefault(); profondeur = 0; $("#deposer").hidden = true;
  const t = (e.dataTransfer.getData("text/uri-list") || e.dataTransfer.getData("text/plain")).trim();
  if (!t) return;
  E.saisie = t;
  if (E.vue !== "telecharger") aller("telecharger");
  $("#saisie").value = t; lancerSaisie(t);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "/" && !e.target.closest("input, textarea, select")) { e.preventDefault(); if (E.vue !== "telecharger") aller("telecharger"); $("#saisie").focus(); }
});

// ── démarrage ────────────────────────────────────────────────────────
(async () => {
  await chargerEtat();
  E.choix = choixParDefaut();
  const p = new URLSearchParams(location.search);
  const partage = [p.get("url"), p.get("texte"), p.get("titre")].filter(Boolean).join(" ");
  const lien = partage.match(/https?:\/\/\S+/)?.[0];
  rendre();
  await chargerTaches().catch((e) => toast(e.message, "err"));
  ecouter();
  if (lien) { history.replaceState(null, "", "/"); E.saisie = lien; $("#saisie").value = lien; analyser(lien); }
})();
