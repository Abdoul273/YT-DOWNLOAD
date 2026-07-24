/* YT-NEXUS AETHER v7 — Premium frontend layer */
(() => {
  'use strict';

  const P = {
    clipWatch: localStorage.getItem('ytnexus_clip_watch') === '1',
    lastClip: '',
    libFilter: 'all',
    libData: null,
    profiles: [],
    fabOpen: false,
    notifGranted: false,
  };

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

  function toast(msg, type = 'info', ms = 3500) {
    if (typeof window.toast === 'function') window.toast(msg, type, ms);
    else console.log('[v7]', msg);
  }

  function esc(s) {
    return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  // ── Branding ──────────────────────────────────────────────
  function brandV7() {
    document.title = 'YT-NEXUS • AETHER v7.0 — Ultra Premium';
    const v = $('.logo-v');
    if (v) v.textContent = 'AETHER v7.0';
    const theme = document.querySelector('meta[name="theme-color"]');
    if (theme) theme.setAttribute('content', '#00e5a0');
  }

  // ── Inject nav tabs + panels ──────────────────────────────
  function injectUI() {
    const nav = $('#mainNav');
    if (!nav || $('#tab-queue')) return;

    const tabs = [
      { id: 'queue', label: 'File', icon: '<line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/>' },
      { id: 'later', label: 'À plus tard', icon: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>' },
    ];

    // Insert before history tab
    const histBtn = nav.querySelector('[data-tab="history"]');
    tabs.forEach(t => {
      const btn = document.createElement('button');
      btn.className = 'tab';
      btn.dataset.tab = t.id;
      btn.id = 'tab-' + t.id;
      btn.onclick = () => switchTab(t.id);
      btn.innerHTML = `<span class="tab-ico"><svg viewBox="0 0 24 24">${t.icon}</svg></span>${t.label}`;
      if (t.id === 'queue') {
        btn.innerHTML += `<span class="tab-badge" id="queueBadge" style="display:none"></span>`;
      }
      if (t.id === 'later') {
        btn.innerHTML += `<span class="tab-badge" id="laterBadge" style="display:none"></span>`;
      }
      if (histBtn) nav.insertBefore(btn, histBtn);
      else nav.appendChild(btn);
    });

    // Header actions: disk + clipboard watch
    const actions = $('.header-actions');
    if (actions && !$('#diskChip')) {
      const disk = document.createElement('div');
      disk.className = 'disk-chip';
      disk.id = 'diskChip';
      disk.title = 'Espace disque';
      disk.innerHTML = `<div class="disk-bar"><i id="diskBarFill" style="width:0%"></i></div><span id="diskLabel">…</span>`;
      actions.insertBefore(disk, actions.firstChild);

      const clip = document.createElement('button');
      clip.className = 'clip-watch' + (P.clipWatch ? ' on' : '');
      clip.id = 'clipWatchBtn';
      clip.title = 'Surveillance presse-papier (auto-détection URL)';
      clip.innerHTML = `<svg viewBox="0 0 24 24"><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/><path d="M9 14l2 2 4-4"/></svg>`;
      clip.onclick = toggleClipWatch;
      actions.insertBefore(clip, disk.nextSibling);
    }

    const main = $('main');
    if (!main || $('#panel-queue')) return;

    main.insertAdjacentHTML('beforeend', `
      <div class="panel" id="panel-queue">
        <div class="toolbar">
          <span class="toolbar-title">📋 File d'attente</span>
          <button class="btn btn-ghost btn-sm" onclick="V7.loadQueue()">↻</button>
          <button class="btn btn-danger btn-sm" onclick="V7.clearQueue()">Vider</button>
        </div>
        <div class="scroll" style="padding:14px 18px">
          <div id="queueList"><div class="v7-empty"><div class="big">📋</div>File vide</div></div>
          <div class="section-hdr" style="margin-top:18px">⏱ Téléchargements planifiés</div>
          <div class="sch-form">
            <div>
              <label>URL</label>
              <input type="text" id="schUrl" placeholder="https://…">
            </div>
            <div>
              <label>Dans (minutes)</label>
              <input type="number" id="schDelay" value="30" min="1">
            </div>
            <button class="btn btn-primary btn-sm" onclick="V7.scheduleNow()">Planifier</button>
          </div>
          <div id="scheduleList"></div>
        </div>
      </div>

      <div class="panel" id="panel-later">
        <div class="toolbar">
          <span class="toolbar-title">⏳ À regarder plus tard</span>
          <button class="btn btn-ghost btn-sm" onclick="V7.loadWatchLater()">↻</button>
          <button class="btn btn-danger btn-sm" onclick="V7.clearWatchLater()">Vider</button>
        </div>
        <div class="scroll" style="padding:14px 18px">
          <div id="laterList"><div class="v7-empty"><div class="big">⏳</div>Liste vide — ajoutez depuis une analyse vidéo</div></div>
        </div>
      </div>
    `);

    // Smart FAB
    if (!$('.smart-fab')) {
      document.body.insertAdjacentHTML('beforeend', `
        <div class="smart-fab-menu" id="smartFabMenu">
          <button onclick="V7.fab('paste')">📋 Coller URL</button>
          <button onclick="V7.fab('queue')">📋 File</button>
          <button onclick="V7.fab('later')">⏳ À plus tard</button>
          <button onclick="V7.fab('disk')">💾 Espace disque</button>
          <button onclick="V7.fab('palette')">⌘ Palette</button>
        </div>
        <button class="smart-fab" id="smartFab" title="Actions rapides">✦</button>
      `);
      $('#smartFab').onclick = () => {
        P.fabOpen = !P.fabOpen;
        $('#smartFabMenu').classList.toggle('open', P.fabOpen);
      };
    }
  }

  // ── Patch switchTab ───────────────────────────────────────
  function patchSwitchTab() {
    const orig = window.switchTab;
    if (typeof orig !== 'function') return;
    window.switchTab = function (name) {
      orig(name);
      if (name === 'queue') { V7.loadQueue(); V7.loadSchedule(); }
      if (name === 'later') V7.loadWatchLater();
      if (name === 'dashboard') V7.enrichDashboard();
      if (name === 'single') V7.injectPremiumOpts();
    };
  }

  // ── Disk ──────────────────────────────────────────────────
  async function refreshDisk() {
    try {
      const r = await fetch('/api/v7/disk');
      const d = await r.json();
      if (d.error) return;
      const chip = $('#diskChip');
      const fill = $('#diskBarFill');
      const lbl = $('#diskLabel');
      if (!chip) return;
      const pct = d.percent_used || 0;
      if (fill) fill.style.width = pct + '%';
      if (lbl) lbl.textContent = d.free_h + ' free';
      chip.classList.toggle('warn', pct >= 80);
      chip.classList.toggle('crit', pct >= 92);
      chip.title = `Dossier: ${d.folder_h}\nDisque: ${d.used_h} / ${d.total_h} (${pct}%)\n${d.path}`;
    } catch (_) {}
  }

  function dlFromUrl(url, title) {
    // Put in single tab and start with default opts
    switchTab('single');
    const inp = $('#urlInput');
    if (inp) { inp.value = url; if (typeof onUrlInput === 'function') onUrlInput(url); }
    setTimeout(() => { if (typeof fetchInfo === 'function') fetchInfo(); }, 100);
    toast(`Chargé: ${title || url}`, 'info');
  }

  // ── Queue ─────────────────────────────────────────────────
  async function loadQueue() {
    const list = $('#queueList');
    try {
      const r = await fetch('/api/queue');
      const d = await r.json();
      const q = d.queue || [];
      const badge = $('#queueBadge');
      if (badge) {
        if (q.length) { badge.style.display = ''; badge.textContent = q.length; }
        else badge.style.display = 'none';
      }
      if (!list) return;
      if (!q.length) {
        list.innerHTML = '<div class="v7-empty"><div class="big">📋</div>File d\'attente vide</div>';
        return;
      }
      list.innerHTML = q.map((item, i) => `
        <div class="queue-item">
          <div class="queue-pos">${i + 1}</div>
          <div style="flex:1;min-width:0">
            <div style="font-weight:650;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(item.title || item.url)}</div>
            <div style="font-size:10px;color:var(--t3);font-family:'Space Mono',monospace">${esc(item.url)}</div>
          </div>
        </div>`).join('');
    } catch (e) {
      if (list) list.innerHTML = `<div class="v7-empty">${esc(e.message)}</div>`;
    }
  }

  async function clearQueue() {
    if (!confirm('Vider la file ?')) return;
    await fetch('/api/queue/clear', { method: 'POST' });
    toast('File vidée', 'success');
    loadQueue();
  }

  // ── Schedule ──────────────────────────────────────────────
  async function loadSchedule() {
    const list = $('#scheduleList');
    if (!list) return;
    try {
      const r = await fetch('/api/v7/schedule');
      const d = await r.json();
      const jobs = (d.jobs || []).filter(j => j.status === 'scheduled' || j.status === 'queued');
      if (!jobs.length) {
        list.innerHTML = '<div style="font-size:12px;color:var(--t3)">Aucun job planifié</div>';
        return;
      }
      list.innerHTML = jobs.map(j => `
        <div class="queue-item">
          <div class="queue-pos">⏱</div>
          <div style="flex:1;min-width:0">
            <div style="font-weight:650;font-size:12.5px">${esc(j.title)}</div>
            <div style="font-size:10px;color:var(--t3);font-family:'Space Mono',monospace">${esc(j.run_at_h)} · ${esc(j.status)}</div>
          </div>
          <button class="btn btn-danger btn-sm" onclick="V7.delSchedule('${j.id}')">✕</button>
        </div>`).join('');
    } catch (_) {}
  }

  async function scheduleNow() {
    const url = ($('#schUrl')?.value || '').trim();
    const delay = parseFloat($('#schDelay')?.value || '30');
    if (!url) return toast('URL requise', 'warn');
    try {
      const r = await fetch('/api/v7/schedule', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url, delay_min: delay, title: url.slice(0, 60),
          opts: collectPremiumOpts({ type: 'video', quality: '1080', format: 'mp4', turbo: true }),
        }),
      });
      const d = await r.json();
      if (d.error) toast(d.error, 'error');
      else { toast(`Planifié pour ${d.job?.run_at_h}`, 'success'); loadSchedule(); }
    } catch (e) { toast(e.message, 'error'); }
  }

  async function delSchedule(id) {
    await fetch(`/api/v7/schedule/${id}`, { method: 'DELETE' });
    loadSchedule();
  }

  // ── Watch later ───────────────────────────────────────────
  async function loadWatchLater() {
    const list = $('#laterList');
    try {
      const r = await fetch('/api/v7/watchlater');
      const d = await r.json();
      const items = d.items || [];
      const badge = $('#laterBadge');
      if (badge) {
        if (items.length) { badge.style.display = ''; badge.textContent = items.length; }
        else badge.style.display = 'none';
      }
      if (!list) return;
      if (!items.length) {
        list.innerHTML = '<div class="v7-empty"><div class="big">⏳</div>Liste vide</div>';
        return;
      }
      list.innerHTML = items.map(it => `
        <div class="wl-item">
          ${it.thumbnail ? `<img src="${esc(it.thumbnail)}" alt="">` : '<div style="width:96px;height:54px;border-radius:8px;background:var(--deep);display:flex;align-items:center;justify-content:center">🎬</div>'}
          <div class="wl-body">
            <div class="wl-title">${esc(it.title)}</div>
            <div class="wl-meta">${esc(it.added_h)} · ${esc((it.platform && it.platform.name) || '')}</div>
          </div>
          <button class="btn btn-primary btn-sm" onclick="V7.dlFromUrl('${esc(it.url)}','${esc(it.title).replace(/'/g,"\\'")}')">Ouvrir</button>
          <button class="btn btn-ghost btn-sm" onclick="V7.delWatchLater('${it.id}')">✕</button>
        </div>`).join('');
    } catch (e) {
      if (list) list.innerHTML = `<div class="v7-empty">${esc(e.message)}</div>`;
    }
  }

  async function addWatchLater(info) {
    const payload = {
      url: info?.url || $('#urlInput')?.value,
      title: info?.title || '',
      thumbnail: info?.thumbnail || '',
    };
    if (!payload.url) return toast('Pas d\'URL', 'warn');
    try {
      const r = await fetch('/api/v7/watchlater', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const d = await r.json();
      if (d.error) toast(d.error, 'error');
      else toast(d.already ? 'Déjà dans la liste' : 'Ajouté à « À plus tard »', 'success');
      loadWatchLater();
    } catch (e) { toast(e.message, 'error'); }
  }

  async function delWatchLater(id) {
    await fetch(`/api/v7/watchlater/${id}`, { method: 'DELETE' });
    loadWatchLater();
  }

  async function clearWatchLater() {
    if (!confirm('Vider la liste ?')) return;
    await fetch('/api/v7/watchlater/clear', { method: 'POST' });
    loadWatchLater();
  }

  // ── Premium opts on single download ───────────────────────
  // NOTE: le panneau "✦ Options premium v7" (profils HD/MP3/4K/FR/M4A +
  // toggles SponsorBlock/thumbnail/etc.) a été retiré à la demande. On
  // garde uniquement les actions "À plus tard" / "Planifier", toujours
  // utiles, rattachées directement à la zone d'options.
  function injectPremiumOpts() {
    if ($('#premiumOptsBox')) return;
    const opts = $('#optionsWrap');
    if (!opts || !opts.innerHTML.trim()) return;

    const box = document.createElement('div');
    box.id = 'premiumOptsBox';
    box.innerHTML = `
      <div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap">
        <button class="btn btn-watch btn-sm" type="button" onclick="V7.addWatchLater(window.S && S.currentInfo)">⏳ À plus tard</button>
        <button class="btn btn-ghost btn-sm" type="button" onclick="V7.scheduleFromCurrent()">⏱ Planifier</button>
      </div>`;
    opts.appendChild(box);
  }

  function collectPremiumOpts(base = {}) {
    // Les toggles premium (SponsorBlock, embed thumbnail, etc.) ont été
    // retirés de l'UI : on ne force plus embed_metadata à false — le
    // backend garde son comportement par défaut (métadonnées activées).
    const o = { ...base };
    if ($('#optSponsorblock')?.checked) o.sponsorblock = true;
    if ($('#optEmbedThumb')?.checked) o.embed_thumbnail = true;
    if ($('#optEmbedMeta')) o.embed_metadata = !!$('#optEmbedMeta').checked;
    if ($('#optEmbedSubs')?.checked) o.embed_subs = true;
    if ($('#optWriteThumb')?.checked) o.write_thumbnail = true;
    if ($('#optSplitChapters')?.checked) o.split_chapters = true;
    return o;
  }

  function patchStartDownload() {
    const orig = window.startSingleDownload;
    if (typeof orig !== 'function') return;
    window.startSingleDownload = async function () {
      // Monkey-patch fetch temporarily for /api/download body
      const _fetch = window.fetch;
      window.fetch = async function (url, opts) {
        if (String(url).includes('/api/download') && opts && opts.body) {
          try {
            const body = JSON.parse(opts.body);
            if (body.opts) body.opts = collectPremiumOpts(body.opts);
            else body.opts = collectPremiumOpts({});
            opts = { ...opts, body: JSON.stringify(body) };
          } catch (_) {}
        }
        return _fetch.call(this, url, opts);
      };
      try {
        await orig.apply(this, arguments);
      } finally {
        window.fetch = _fetch;
      }
    };
  }

  async function loadProfilesIntoBar() {
    const bar = $('#profileBar');
    if (!bar) return;
    try {
      const r = await fetch('/api/profiles');
      P.profiles = await r.json();
      bar.innerHTML = `<span style="font-size:10px;color:var(--t3);align-self:center;margin-right:4px">PROFILS</span>` +
        (P.profiles || []).map(p =>
          `<button type="button" class="profile-chip" data-id="${esc(p.id)}" onclick="V7.applyProfile('${esc(p.id)}')">${esc(p.name)}</button>`
        ).join('');
    } catch (_) {}
  }

  function applyProfile(id) {
    const p = (P.profiles || []).find(x => x.id === id);
    if (!p || !p.opts) return;
    const o = p.opts;
    // Map to existing UI controls if present
    const typeSel = $('#dlType');
    const qSel = $('#dlQuality');
    const fSel = $('#dlFormat');
    if (typeSel && o.type) {
      typeSel.value = o.type;
      if (typeof updateFormatOptions === 'function') updateFormatOptions();
    }
    if (qSel && o.quality) qSel.value = o.quality;
    if (fSel && o.format) fSel.value = o.format;
    if (o.sponsorblock && $('#optSponsorblock')) $('#optSponsorblock').checked = true;
    if (o.dl_subs && $('#dlSubs')) $('#dlSubs').checked = true;
    $$('.profile-chip').forEach(c => c.classList.toggle('active', c.dataset.id === id));
    toast(`Profil: ${p.name}`, 'success');
    if (typeof updateSizePreview === 'function') updateSizePreview();
  }

  function scheduleFromCurrent() {
    const url = (window.S && S.currentInfo && S.currentInfo.url) || $('#urlInput')?.value;
    if (!url) return toast('Analysez d\'abord une vidéo', 'warn');
    const delay = prompt('Télécharger dans combien de minutes ?', '60');
    if (delay === null) return;
    fetch('/api/v7/schedule', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        url,
        title: (S.currentInfo && S.currentInfo.title) || url,
        delay_min: parseFloat(delay) || 60,
        opts: collectPremiumOpts({
          type: $('#dlType')?.value || 'video',
          quality: $('#dlQuality')?.value || '1080',
          format: $('#dlFormat')?.value || 'mp4',
          turbo: true,
        }),
      }),
    }).then(r => r.json()).then(d => {
      if (d.error) toast(d.error, 'error');
      else toast(`Planifié: ${d.job?.run_at_h}`, 'success');
    });
  }

  // ── Patch fetchInfo to inject premium opts after render ───
  function patchFetchInfo() {
    const orig = window.fetchInfo;
    if (typeof orig !== 'function') return;
    window.fetchInfo = async function () {
      await orig.apply(this, arguments);
      setTimeout(() => {
        injectPremiumOpts();
        // Add later button already in inject
      }, 80);
    };
  }

  // ── Clipboard watch ───────────────────────────────────────
  function toggleClipWatch() {
    P.clipWatch = !P.clipWatch;
    localStorage.setItem('ytnexus_clip_watch', P.clipWatch ? '1' : '0');
    $('#clipWatchBtn')?.classList.toggle('on', P.clipWatch);
    toast(P.clipWatch ? 'Surveillance presse-papier ON' : 'Surveillance OFF', 'info');
    if (P.clipWatch) requestNotifPermission();
  }

  async function pollClipboard() {
    if (!P.clipWatch) return;
    try {
      if (!navigator.clipboard?.readText) return;
      const text = (await navigator.clipboard.readText() || '').trim();
      if (!text || text === P.lastClip) return;
      if (!/^https?:\/\//i.test(text)) return;
      if (!/(youtube|youtu\.be|tiktok|instagram|twitter|x\.com|vimeo|facebook|soundcloud|twitch)/i.test(text)) return;
      P.lastClip = text;
      toast('URL détectée dans le presse-papier', 'success', 2500);
      notify('YT-NEXUS', 'URL média détectée — prêt à analyser');
      switchTab('single');
      const inp = $('#urlInput');
      if (inp) {
        inp.value = text;
        if (typeof onUrlInput === 'function') onUrlInput(text);
      }
    } catch (_) { /* permission denied */ }
  }

  function requestNotifPermission() {
    if (!('Notification' in window)) return;
    if (Notification.permission === 'granted') { P.notifGranted = true; return; }
    if (Notification.permission !== 'denied') {
      Notification.requestPermission().then(p => { P.notifGranted = p === 'granted'; });
    }
  }

  function notify(title, body) {
    if (!P.notifGranted && Notification.permission !== 'granted') return;
    try {
      new Notification(title, { body, icon: '/static/manifest.json' });
    } catch (_) {}
  }

  // ── Notifications on download complete ────────────────────
  function patchProgressToasts() {
    // Hook into trackProgress if available
    const orig = window.trackProgress;
    if (typeof orig !== 'function') return;
    window.trackProgress = function (dlId, type) {
      // wrap EventSource path by monitoring S.activeDownloads
      orig(dlId, type);
      // poll status for this id
      const iv = setInterval(() => {
        const d = window.S?.activeDownloads?.[dlId];
        if (!d) return;
        if (d.status === 'done') {
          clearInterval(iv);
          notify('Téléchargement terminé', d.title || d.filename || 'Fichier prêt');
          refreshDisk();
        }
        if (['failed', 'error', 'stopped'].includes(d.status)) {
          clearInterval(iv);
          if (d.status !== 'stopped') notify('Échec téléchargement', d.error || d.title || '');
        }
      }, 2000);
      setTimeout(() => clearInterval(iv), 4 * 60 * 60 * 1000);
    };
  }

  // ── Dashboard enrich ──────────────────────────────────────
  async function enrichDashboard() {
    try {
      const r = await fetch('/api/v7/stats');
      const s = await r.json();
      const box = $('#dashboardStats');
      if (!box || box.dataset.v7) return;
      // append extra cards
      const extra = document.createElement('div');
      extra.style.cssText = 'display:contents';
      extra.innerHTML = `
        <div class="lib-stat"><b>${s.queue}</b><span>File</span></div>
        <div class="lib-stat"><b>${s.watchlater}</b><span>À plus tard</span></div>
        <div class="lib-stat"><b>${s.scheduled}</b><span>Planifiés</span></div>`;
      // dashboard may use different structure — inject below if possible
      const host = $('#dashboardStats');
      if (host) {
        host.insertAdjacentHTML('beforeend', extra.innerHTML);
        host.dataset.v7 = '1';
      }
    } catch (_) {}
    refreshDisk();
  }

  // ── Command palette extensions ────────────────────────────
  function extendCmdPalette() {
    if (!window.CMD_ACTIONS) return;
    const extra = [
      { id: 'go-queue', label: '📋 File d\'attente', action: () => switchTab('queue') },
      { id: 'go-later', label: '⏳ À regarder plus tard', action: () => switchTab('later') },
      { id: 'clip-toggle', label: '📋 Toggle surveillance presse-papier', action: () => toggleClipWatch() },
      { id: 'disk', label: '💾 Espace disque', action: () => { refreshDisk(); toast($('#diskChip')?.title || 'Disque', 'info', 5000); } },
    ];
    extra.forEach(a => {
      if (!CMD_ACTIONS.find(x => x.id === a.id)) CMD_ACTIONS.push(a);
    });
  }

  function fab(action) {
    P.fabOpen = false;
    $('#smartFabMenu')?.classList.remove('open');
    if (action === 'paste' && typeof pasteFromClipboard === 'function') pasteFromClipboard();
    if (action === 'queue') switchTab('queue');
    if (action === 'later') switchTab('later');
    if (action === 'disk') { refreshDisk(); toast($('#diskChip')?.title || '', 'info', 5000); }
    if (action === 'palette' && typeof openCmdPalette === 'function') openCmdPalette();
  }

  // ── Init ──────────────────────────────────────────────────
  function init() {
    brandV7();
    injectUI();
    patchSwitchTab();
    patchFetchInfo();
    patchStartDownload();
    patchProgressToasts();
    extendCmdPalette();
    refreshDisk();
    loadWatchLater();
    loadQueue();
    setInterval(pollClipboard, 2500);
    setInterval(refreshDisk, 60000);
    setInterval(() => {
      if ($('#panel-queue')?.classList.contains('active')) { loadQueue(); loadSchedule(); }
    }, 12000);
    // tip
    setTimeout(() => {
      if (!localStorage.getItem('ytnexus_v7_tipped')) {
        toast('✦ AETHER v7 — File, À plus tard, SponsorBlock', 'info', 6000);
        localStorage.setItem('ytnexus_v7_tipped', '1');
      }
    }, 1800);
    console.log('%c[YT-NEXUS] AETHER v7.0 premium layer ready ✦', 'color:#00e5a0;font-weight:bold');
  }

  window.V7 = {
    dlFromUrl,
    loadQueue, clearQueue, loadSchedule, scheduleNow, delSchedule, scheduleFromCurrent,
    loadWatchLater, addWatchLater, delWatchLater, clearWatchLater,
    injectPremiumOpts, applyProfile, collectPremiumOpts, refreshDisk,
    toggleClipWatch, fab, enrichDashboard,
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => setTimeout(init, 120));
  } else {
    setTimeout(init, 120);
  }
})();
