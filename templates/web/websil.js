/**
 * @file WebSIL: browse a SIL library in a web browser, and queue tag
 * changes as a SIL manifest.
 *
 * The page runs from file:// with nothing outside the library. Data comes
 * from two script files, as browsers refuse fetch() of file:// URLs:
 *   web/imageData.js - window.SIL_DATA, written by `sil BUILDWEB`
 *   web/silStamp.js  - window.SIL_STAMP, rewritten by every sil run
 * A page can't write to the library, so changes become a manifest the user
 * downloads or copies, and runs with sil.
 */
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);

  /** Tiles added to the grid at a time, as the user scrolls. */
  const BATCH = 150;
  /** Characters SIL allows in a tag level (TAG-03): ASCII and Latin-1 letters. */
  const TAG_LEVEL_RE = /^[A-Za-z0-9 _\-À-ÖØ-öø-ÿ]+$/;
  const VIDEO_EXT = new Set(['mp4', 'webm', 'mov']);
  /** Upper edges of the size histogram's bins, in bytes; the last is open. */
  const HIST_EDGES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
    .map((kb) => kb * 1024).concat([Infinity]);

  const data = window.SIL_DATA;
  /** The library's folder: from the page's own location, which is right on any machine. */
  const libraryPath = location.protocol === 'file:'
    ? decodeURIComponent(location.pathname).replace(/\/[^/]*$/, '')
    : (data && data.library) || '';
  const storeKey = 'websil:' + libraryPath;

  /**
   * One stored image.
   * @typedef {Object} Img
   * @property {string} hash  - SHA1 of the stored file, its SIL name
   * @property {string} ext   - Stored suffix, eg jpg
   * @property {number} bytes - File size
   * @property {?string} date - Day added, YYYY-MM-DD, from the date tag
   * @property {string[]} tags - Tag paths, eg Animal/Dog
   * @property {Set<string>} anc - Lowercased tags and all their ancestors, for filtering
   * @property {string} src   - Path from the page to the file
   * @property {boolean} video
   * @property {number} rand  - Position in the random order; see shuffle
   */
  /** @type {Img[]} */
  let images = [];
  /** @type {Img[]} Images passing the filters, in sort order. */
  let view = [];
  let rendered = 0;
  /** Vocabulary for autocomplete: tags, aliases and their image counts. */
  let vocab = [];
  /** Lowercased tag path -> images having it or a tag below it. */
  const tagCount = new Map();
  /** Lowercased tag path -> the path as the library spells it. */
  const tagSpelling = new Map();

  const state = {
    include: [], exclude: [], dateFrom: '', dateTo: '',
    sizeMin: null, sizeMax: null, type: '', sort: 'date-desc', onlySelected: false,
  };
  /** Where per-browser display settings are kept, for every library. */
  const PREFS_KEY = 'websil:prefs';
  /** @type {Set<string>} Selected image hashes. */
  const selected = new Set();
  let selecting = false;
  let lastClicked = -1;
  /** Tags typed in the selection bar, waiting for Add or Remove. */
  let editTags = [];
  /**
   * Queued changes, in order.
   * @type {{op: ('TAG'|'UNTAG'), tags: string[], hashes: string[]}[]}
   */
  let pending = [];
  let pendingHashes = new Set();
  let lbIndex = -1;

  // ---------------------------------------------------------------- data

  /**
   * Expand SIL_DATA into Img records and count tags.
   * @returns {void}
   */
  function loadData() {
    const names = data.tags;
    data.tags.forEach((t) => tagSpelling.set(t.toLowerCase(), t));
    images = data.images.map(([hash, ext, bytes, date, tagNums]) => {
      const tags = tagNums.map((n) => names[n]);
      const anc = new Set();
      for (const t of tags) {
        const parts = t.toLowerCase().split('/');
        for (let i = 1; i <= parts.length; i++) anc.add(parts.slice(0, i).join('/'));
      }
      anc.forEach((a) => tagCount.set(a, (tagCount.get(a) || 0) + 1));
      return {
        hash, ext, bytes, date, tags, anc,
        src: `images/${hash.slice(0, 2)}/${hash.slice(2, 4)}/${hash}.${ext}`,
        video: VIDEO_EXT.has(ext),
        rand: 0,
      };
    });
    shuffle();
    vocab = names.map((t) => ({ label: t, target: t, count: tagCount.get(t.toLowerCase()) || 0 }));
    for (const [alias, target] of data.aliases) {
      vocab.push({ label: alias, target, alias: true, count: tagCount.get(target.toLowerCase()) || 0 });
    }
  }

  /**
   * Parse a size the way SIL does: 1024-based, a bare number is kilobytes.
   * @param {string} text - eg "500", "500kb", "1.5mb"
   * @returns {?number} Bytes, or null if blank or unreadable
   */
  function parseSize(text) {
    const m = /^\s*([\d.]+)\s*([kmg]?)b?\s*$/i.exec(text || '');
    if (!m || isNaN(parseFloat(m[1]))) return null;
    const unit = { '': 1024, k: 1024, m: 1024 ** 2, g: 1024 ** 3 }[m[2].toLowerCase()];
    return Math.round(parseFloat(m[1]) * unit);
  }

  /**
   * Human readable size, 1024-based.
   * @param {number} bytes
   * @returns {string} eg "1.5 MB"
   */
  function humanSize(bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let n = bytes, u = 0;
    while (n >= 1024 && u < units.length - 1) { n /= 1024; u++; }
    return (u === 0 || n >= 100 ? Math.round(n) : Number(n.toFixed(1))) + ' ' + units[u];
  }

  /**
   * Clean a typed tag to what SIL would accept: levels split on / or :,
   * unsupported characters dropped, and an existing tag's spelling reused.
   * @param {string} text
   * @returns {string} The tag path, or '' if nothing usable remains
   */
  function cleanTag(text) {
    const levels = text.split(/[/:]/)
      .map((l) => [...l].filter((c) => TAG_LEVEL_RE.test(c)).join('').trim())
      .filter(Boolean);
    const path = levels.join('/');
    return tagSpelling.get(path.toLowerCase()) || path;
  }

  /**
   * Quote text for a POSIX shell, for commands shown to the user.
   * @param {string} s
   * @returns {string}
   */
  function shellQuote(s) {
    return /^[\w./~-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
  }

  /**
   * Deal every image a new place in the random order. The order is kept
   * while filters change, so narrowing a filter doesn't reshuffle.
   * @returns {void}
   */
  function shuffle() {
    for (const im of images) im.rand = Math.random();
  }

  // ------------------------------------------------------------ filtering

  /**
   * Rebuild the view from the filters and sort, and restart the grid.
   * @returns {void}
   */
  function applyFilters() {
    const s = state;
    view = images.filter((im) =>
      s.include.every((t) => im.anc.has(t)) &&
      !s.exclude.some((t) => im.anc.has(t)) &&
      (!s.dateFrom || (im.date && im.date >= s.dateFrom)) &&
      (!s.dateTo || (im.date && im.date <= s.dateTo)) &&
      (s.sizeMin === null || im.bytes >= s.sizeMin) &&
      (s.sizeMax === null || im.bytes <= s.sizeMax) &&
      (!s.type || im.ext === s.type) &&
      (!s.onlySelected || selected.has(im.hash)));
    const byHash = (a, b) => (a.hash < b.hash ? -1 : 1);
    const byDate = (a, b) => (a.date || '').localeCompare(b.date || '') || byHash(a, b);
    switch (s.sort) {
      case 'date-asc': view.sort(byDate); break;
      case 'date-desc': view.sort((a, b) => byDate(b, a)); break;
      case 'size-asc': view.sort((a, b) => a.bytes - b.bytes || byHash(a, b)); break;
      case 'size-desc': view.sort((a, b) => b.bytes - a.bytes || byHash(a, b)); break;
      default: view.sort((a, b) => a.rand - b.rand);
    }
    $('count').textContent = view.length === images.length
      ? `${images.length.toLocaleString()} images`
      : `${view.length.toLocaleString()} of ${images.length.toLocaleString()} images`;
    $('shuffleBtn').hidden = s.sort !== 'random';
    renderChips();
    renderTreeMarks();
    resetGrid();
  }

  /**
   * Add a tag filter, or swap it between required and excluded.
   * @param {string} tag - Tag path, any case
   * @param {boolean} negate - true to exclude images with it
   * @returns {void}
   */
  function addFilter(tag, negate) {
    const t = tag.toLowerCase();
    state.include = state.include.filter((x) => x !== t);
    state.exclude = state.exclude.filter((x) => x !== t);
    (negate ? state.exclude : state.include).push(t);
    applyFilters();
  }

  /**
   * Tag tree click: remove a tag already in the filter, or add it. A
   * Shift+click on a required tag switches it to excluded.
   * @param {string} tag - Tag path, any case
   * @param {boolean} negate - Shift was held
   * @returns {void}
   */
  function toggleFilter(tag, negate) {
    const t = tag.toLowerCase();
    const isIn = state.include.includes(t), isOut = state.exclude.includes(t);
    if (isOut || (isIn && !negate)) {
      state.include = state.include.filter((x) => x !== t);
      state.exclude = state.exclude.filter((x) => x !== t);
      applyFilters();
    } else addFilter(t, negate);
  }

  /**
   * Show the filter chips.
   * @returns {void}
   */
  function renderChips() {
    const box = $('filterChips');
    box.replaceChildren(
      ...state.include.map((t) => chip(tagSpelling.get(t) || t, '', () => {
        state.include = state.include.filter((x) => x !== t); applyFilters();
      })),
      ...state.exclude.map((t) => chip('!' + (tagSpelling.get(t) || t), 'not', () => {
        state.exclude = state.exclude.filter((x) => x !== t); applyFilters();
      })));
  }

  /**
   * Make a removable chip.
   * @param {string} text
   * @param {string} cls - Extra class: '', 'not' or 'new'
   * @param {function(): void} onRemove
   * @returns {HTMLElement}
   */
  function chip(text, cls, onRemove) {
    const el = document.createElement('span');
    el.className = 'chip ' + cls;
    el.textContent = text;
    const x = document.createElement('button');
    x.type = 'button';
    x.textContent = '×';
    x.title = 'Remove';
    x.addEventListener('click', onRemove);
    el.append(x);
    return el;
  }

  // --------------------------------------------------------- autocomplete

  /**
   * Give an input a tag autocomplete list.
   * @param {HTMLInputElement} input
   * @param {Object} opts
   * @param {function(string, boolean): void} opts.onPick - Called with the
   *     chosen tag path, and whether it was given with a leading '!'
   * @param {boolean} opts.allowNew - Offer the typed text as a new tag
   * @param {function(): void} opts.onBackspace - Empty input and Backspace
   * @returns {void}
   */
  function attachComplete(input, opts) {
    const list = $('complete');
    let items = [], active = 0;

    function close() { list.hidden = true; items = []; }

    function open() {
      const raw = input.value;
      const negate = raw.startsWith('!');
      const q = raw.replace(/^!/, '').trim().toLowerCase();
      if (!q) { close(); return; }
      const scored = [];
      for (const v of vocab) {
        const l = v.label.toLowerCase();
        let score = l === q ? 0 : l.startsWith(q) ? 1 : l.includes('/' + q) ? 2 : l.includes(q) ? 3 : -1;
        if (score >= 0) scored.push([score, v]);
      }
      scored.sort((a, b) => a[0] - b[0] || b[1].count - a[1].count || a[1].label.localeCompare(b[1].label));
      items = scored.slice(0, 12).map(([, v]) => ({ ...v, negate }));
      const typed = cleanTag(raw.replace(/^!/, ''));
      if (opts.allowNew && typed && !vocab.some((v) => v.label.toLowerCase() === typed.toLowerCase())) {
        items.push({ label: typed, target: typed, isNew: true, count: 0 });
      }
      if (!items.length) { close(); return; }
      active = 0;
      list.replaceChildren(...items.map((it, i) => {
        const row = document.createElement('div');
        row.setAttribute('role', 'option');
        const name = document.createElement('span');
        name.textContent = (it.negate ? '!' : '') + it.label;
        const note = document.createElement('span');
        if (it.isNew) { note.textContent = 'new tag'; note.className = 'alias'; }
        else if (it.alias) { note.textContent = '→ ' + it.target; note.className = 'alias'; }
        else { note.textContent = it.count.toLocaleString(); note.className = 'n'; }
        row.append(name, note);
        row.addEventListener('mousedown', (e) => { e.preventDefault(); pick(i); });
        return row;
      }));
      const r = input.getBoundingClientRect();
      list.style.left = r.left + 'px';
      list.style.top = r.bottom + 4 + 'px';
      list.hidden = false;
      mark();
    }

    function mark() {
      [...list.children].forEach((row, i) => row.setAttribute('aria-selected', i === active));
      list.children[active]?.scrollIntoView({ block: 'nearest' });
    }

    function pick(i) {
      const it = items[i];
      if (!it) return;
      input.value = '';
      close();
      opts.onPick(it.target, !!it.negate);
    }

    input.addEventListener('input', open);
    input.addEventListener('blur', close);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' && items.length) { active = (active + 1) % items.length; mark(); e.preventDefault(); }
      else if (e.key === 'ArrowUp' && items.length) { active = (active + items.length - 1) % items.length; mark(); e.preventDefault(); }
      else if ((e.key === 'Enter' || e.key === 'Tab') && items.length && !list.hidden) { pick(active); e.preventDefault(); }
      else if (e.key === 'Escape') { close(); input.blur(); }
      else if (e.key === 'Backspace' && !input.value) opts.onBackspace();
    });
  }

  // ------------------------------------------------------------------ grid

  /**
   * Empty the grid and show the first batch of the view.
   * @returns {void}
   */
  function resetGrid() {
    $('grid').replaceChildren();
    rendered = 0;
    const empty = $('empty');
    empty.hidden = view.length > 0;
    if (!view.length) empty.textContent = 'No images match these filters.';
    renderMore();
  }

  /**
   * Add the next batch of tiles, and keep going while the end of the grid
   * is near the screen.
   * @returns {void}
   */
  function renderMore() {
    if (rendered >= view.length) return;
    const frag = document.createDocumentFragment();
    const end = Math.min(rendered + BATCH, view.length);
    for (let i = rendered; i < end; i++) frag.append(makeTile(view[i], i));
    rendered = end;
    $('grid').append(frag);
    const scroller = document.querySelector('main');
    if ($('sentinel').getBoundingClientRect().top < scroller.getBoundingClientRect().bottom + 1500) {
      requestAnimationFrame(renderMore);
    }
  }

  /**
   * Make one grid tile.
   * @param {Img} im
   * @param {number} i - Position in the view
   * @returns {HTMLElement}
   */
  function makeTile(im, i) {
    const tile = document.createElement('div');
    tile.className = 'tile';
    tile.dataset.i = i;
    tile.classList.toggle('sel', selected.has(im.hash));
    tile.classList.toggle('pend', pendingHashes.has(im.hash));
    let media;
    if (im.video) {
      media = document.createElement('video');
      media.src = im.src + '#t=0.1';
      media.preload = 'metadata';
      media.muted = true;
    } else {
      media = document.createElement('img');
      media.src = im.src;
      media.loading = 'lazy';
      media.decoding = 'async';
      media.alt = '';
    }
    const check = document.createElement('span');
    check.className = 'check';
    tile.append(media, check);
    if (im.video || im.ext === 'gif') {
      const kind = document.createElement('span');
      kind.className = 'kind';
      kind.textContent = im.video ? '▶ ' + im.ext : im.ext;
      tile.append(kind);
    }
    tile.title = describe(im);
    return tile;
  }

  /**
   * One line describing an image, for tooltips.
   * @param {Img} im
   * @returns {string}
   */
  function describe(im) {
    return `${im.date || 'no date'} · ${humanSize(im.bytes)} · ${im.ext}\n` +
      (im.tags.length ? im.tags.join(', ') : 'no tags');
  }

  /**
   * Refresh the selected and pending marks on tiles already shown.
   * @returns {void}
   */
  function refreshTiles() {
    for (const tile of $('grid').children) {
      const im = view[tile.dataset.i];
      tile.classList.toggle('sel', selected.has(im.hash));
      tile.classList.toggle('pend', pendingHashes.has(im.hash));
    }
    updateSelBar();
  }

  /**
   * Select or unselect one image, or with a range, every image between it
   * and the last one clicked.
   * @param {number} i - Position in the view
   * @param {boolean} range
   * @returns {void}
   */
  function toggleSelect(i, range) {
    const on = !selected.has(view[i].hash);
    const [a, b] = range && lastClicked >= 0 ? [Math.min(i, lastClicked), Math.max(i, lastClicked)] : [i, i];
    for (let k = a; k <= b; k++) {
      if (on) selected.add(view[k].hash); else selected.delete(view[k].hash);
    }
    lastClicked = i;
    refreshTiles();
  }

  /**
   * Show or hide the selection bar, with its count.
   * @returns {void}
   */
  function updateSelBar() {
    $('selBar').hidden = !selecting && selected.size === 0;
    $('selCount').textContent = `${selected.size.toLocaleString()} selected`;
    $('selAllBtn').textContent = `Select all shown (${view.length.toLocaleString()})`;
    $('onlySelBtn').setAttribute('aria-pressed', state.onlySelected);
    document.body.classList.toggle('selecting', selecting);
    $('selectBtn').setAttribute('aria-pressed', selecting);
  }

  /**
   * Show only the selected images, or go back to the filters alone.
   * Unselecting an image while on leaves it shown until the view refreshes.
   * @param {boolean} on
   * @returns {void}
   */
  function showOnlySelected(on) {
    if (state.onlySelected === on) return;
    state.onlySelected = on;
    applyFilters();
    updateSelBar();
  }

  // -------------------------------------------------------------- lightbox

  /**
   * Show an image filling the window.
   * @param {number} i - Position in the view
   * @returns {void}
   */
  function openLightbox(i) {
    lbIndex = i;
    $('lightbox').hidden = false;
    showLightbox();
  }

  /**
   * Show the lightbox's current image, and preload the next.
   * @returns {void}
   */
  function showLightbox() {
    const im = view[lbIndex];
    let media;
    if (im.video) {
      media = document.createElement('video');
      Object.assign(media, { src: im.src, controls: true, autoplay: true, loop: true, muted: true });
    } else {
      media = document.createElement('img');
      media.src = im.src;
      media.alt = im.tags.join(', ');
    }
    $('lbMedia').replaceChildren(media);
    const cap = $('lbCaption');
    cap.replaceChildren();
    const add = (text, cls) => {
      const s = document.createElement('span');
      s.textContent = text;
      if (cls) s.className = cls;
      cap.append(s);
    };
    add(`${lbIndex + 1} / ${view.length} · ${im.date || 'no date'} · ${humanSize(im.bytes)} · ${im.ext}`);
    if (selected.has(im.hash)) add(' · selected', 'sel');
    add(` · ${im.hash}  —  ← → move · Space next · X select · I hide this · Esc close`, 'muted');
    const tags = document.createElement('div');
    tags.className = 'lbtags';
    if (!im.tags.length) {
      tags.textContent = 'no tags';
      tags.classList.add('muted');
    }
    for (const t of im.tags) tags.append(lightboxTag(im, t));
    cap.append(tags);
    const next = view[lbIndex + 1];
    if (next && !next.video) new Image().src = next.src;
  }

  /**
   * One of the lightbox image's tags, with a button to queue its removal,
   * or to undo that.
   * @param {Img} im
   * @param {string} tag
   * @returns {HTMLElement}
   */
  function lightboxTag(im, tag) {
    const queued = untagEntry(im.hash, tag);
    const el = document.createElement('span');
    el.className = 'lbtag' + (queued ? ' gone' : '');
    el.textContent = tag;
    // Removals queued with other tags, from the selection bar, can't be
    // undone one tag at a time
    if (queued && queued.tags.length > 1) return el;
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = queued ? '↺' : '×';
    b.title = queued ? 'Keep this tag' : 'Remove this tag';
    // Keep focus off the button, so Space still moves to the next image
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', () => {
      if (queued) {
        queued.hashes = queued.hashes.filter((h) => h !== im.hash);
        pending = pending.filter((p) => p.hashes.length);
      } else queueUntag(im.hash, tag);
      savePending();
      refreshTiles();
      showLightbox();
    });
    el.append(b);
    return el;
  }

  /**
   * Find a queued removal of a tag from an image.
   * @param {string} hash
   * @param {string} tag
   * @returns {?{op: string, tags: string[], hashes: string[]}} The queue entry
   */
  function untagEntry(hash, tag) {
    const t = tag.toLowerCase();
    return pending.find((p) => p.op === 'UNTAG' && p.hashes.includes(hash) &&
      p.tags.some((x) => x.toLowerCase() === t)) || null;
  }

  /**
   * Queue the removal of one tag from one image. Joins the last queue
   * entry if it removes just that tag, so stepping through images removing
   * the same tag makes one manifest block.
   * @param {string} hash
   * @param {string} tag
   * @returns {void}
   */
  function queueUntag(hash, tag) {
    const last = pending[pending.length - 1];
    if (last && last.op === 'UNTAG' && last.tags.length === 1 && last.tags[0] === tag) {
      last.hashes.push(hash);
    } else pending.push({ op: 'UNTAG', tags: [tag], hashes: [hash] });
  }

  /**
   * Leave the lightbox, scrolling the grid to the image last shown.
   * @returns {void}
   */
  function closeLightbox() {
    $('lightbox').hidden = true;
    $('lbMedia').replaceChildren();
    while (rendered <= lbIndex && rendered < view.length) renderMore();
    $('grid').children[lbIndex]?.scrollIntoView({ block: 'center' });
    lbIndex = -1;
  }

  /**
   * Move through the lightbox, staying within the view.
   * @param {number} step - +1 forward, -1 back
   * @returns {void}
   */
  function lightboxStep(step) {
    const i = Math.max(0, Math.min(view.length - 1, lbIndex + step));
    if (i !== lbIndex) { lbIndex = i; showLightbox(); }
  }

  // -------------------------------------------------------------- tag tree

  /**
   * Build the tag tree panel from the tags and aliases.
   * @returns {void}
   */
  function buildTree() {
    const root = { kids: new Map() };
    const place = (path, alias) => {
      let node = root, sofar = [];
      for (const part of path.split('/')) {
        sofar.push(part);
        if (!node.kids.has(part)) node.kids.set(part, { name: part, path: sofar.join('/'), kids: new Map() });
        node = node.kids.get(part);
      }
      if (alias) node.alias = alias;
    };
    data.tags.forEach((t) => place(t));
    data.aliases.forEach(([a, target]) => place(a, target));

    const list = (node, depth) => {
      const ul = document.createElement('ul');
      const kids = [...node.kids.values()].sort((a, b) => a.name.localeCompare(b.name));
      for (const k of kids) {
        const li = document.createElement('li');
        const row = document.createElement('div');
        const tw = document.createElement('button');
        tw.type = 'button';
        tw.className = 'tw';
        tw.textContent = k.kids.size ? (depth < 1 ? '▾' : '▸') : '';
        const name = document.createElement('button');
        name.type = 'button';
        name.className = 'tn';
        name.dataset.tag = (k.alias || k.path).toLowerCase();
        name.textContent = k.name;
        const n = document.createElement('span');
        if (k.alias) { n.className = 'alias'; n.textContent = '→ ' + k.alias; }
        else { n.className = 'n'; n.textContent = (tagCount.get(k.path.toLowerCase()) || 0).toLocaleString(); }
        row.append(tw, name, n);
        li.append(row);
        if (k.kids.size) {
          const sub = list(k, depth + 1);
          sub.hidden = depth >= 1;
          li.append(sub);
          tw.addEventListener('click', () => {
            sub.hidden = !sub.hidden;
            tw.textContent = sub.hidden ? '▸' : '▾';
          });
        }
        name.addEventListener('click', (e) => toggleFilter(name.dataset.tag, e.shiftKey));
        ul.append(li);
      }
      return ul;
    };
    $('treeBody').replaceChildren(list(root, 0));
  }

  /**
   * Open or close every branch of the tag tree. Closed leaves only the top
   * level showing.
   * @param {boolean} open
   * @returns {void}
   */
  function setTreeOpen(open) {
    for (const li of document.querySelectorAll('#treeBody li')) {
      const sub = li.querySelector(':scope > ul');
      if (!sub) continue;
      sub.hidden = !open;
      li.querySelector('.tw').textContent = open ? '▾' : '▸';
    }
  }

  /**
   * Highlight tree entries that are active filters.
   * @returns {void}
   */
  function renderTreeMarks() {
    for (const b of document.querySelectorAll('#tree .tn')) {
      b.classList.toggle('in', state.include.includes(b.dataset.tag));
      b.classList.toggle('out', state.exclude.includes(b.dataset.tag));
    }
  }

  // ------------------------------------------------------- queued changes

  /**
   * Save queued changes in the browser, so a reload doesn't lose them.
   * @returns {void}
   */
  function savePending() {
    pendingHashes = new Set(pending.flatMap((p) => p.hashes));
    const n = pending.reduce((sum, p) => sum + p.hashes.length, 0);
    $('pendingCount').textContent = n.toLocaleString();
    $('pendingCount').classList.toggle('on', n > 0);
    try { localStorage.setItem(storeKey, JSON.stringify({ pending })); } catch (e) { /* private mode */ }
  }

  /**
   * Restore queued changes saved by savePending, dropping any the library
   * data already shows as done (the manifest was run and BUILDWEB since).
   * @returns {void}
   */
  function loadPending() {
    try { pending = JSON.parse(localStorage.getItem(storeKey) || '{}').pending || []; } catch (e) { pending = []; }
    const byHash = new Map(images.map((im) => [im.hash, im]));
    const has = (im, t) => im.tags.some((x) => x.toLowerCase() === t.toLowerCase());
    pending = pending.map((p) => ({
      ...p,
      hashes: p.hashes.filter((h) => {
        const im = byHash.get(h);
        if (!im) return false;
        return p.op === 'TAG' ? !p.tags.every((t) => has(im, t)) : p.tags.some((t) => has(im, t));
      }),
    })).filter((p) => p.hashes.length);
    savePending();
  }

  /**
   * Queue the selection bar's tags to be added to, or removed from, the
   * selected images.
   * @param {('TAG'|'UNTAG')} op
   * @returns {void}
   */
  function queueChange(op) {
    const typed = cleanTag($('tagInput').value);
    if (typed && !editTags.includes(typed)) editTags.push(typed);
    $('tagInput').value = '';
    if (!editTags.length) { toast('Type a tag first'); $('tagInput').focus(); return; }
    if (!selected.size) { toast('Select some images first'); return; }
    pending.push({ op, tags: [...editTags], hashes: [...selected] });
    toast(`Queued: ${op === 'TAG' ? 'add' : 'remove'} ${editTags.join(', ')} for ${selected.size} image(s)`);
    editTags = [];
    selected.clear();
    renderEditChips();
    savePending();
    showOnlySelected(false);
    refreshTiles();
  }

  /**
   * Show the tags typed in the selection bar.
   * @returns {void}
   */
  function renderEditChips() {
    $('tagChips').replaceChildren(...editTags.map((t) => chip(t,
      tagSpelling.has(t.toLowerCase()) ? '' : 'new',
      () => { editTags = editTags.filter((x) => x !== t); renderEditChips(); })));
  }

  /**
   * The queued changes as a SIL manifest. LIBRARY is given, so it works
   * from any folder, eg Downloads.
   * @returns {string}
   */
  function manifestText() {
    const lines = [
      `# WebSIL changes, ${new Date().toLocaleString()}`,
      '# Images are named by hash. Run with:',
      `#   sil LIBRARY=${shellQuote(libraryPath)} BUILDWEB <this file>`,
      `LIBRARY=${libraryPath}`,
    ];
    let tag = '', untag = '';
    for (const p of pending) {
      lines.push('');
      const value = p.tags.join(',');
      if (p.op === 'TAG') {
        if (untag) { lines.push('UNTAG='); untag = ''; }
        lines.push('TAG=' + value); tag = value;
      } else {
        if (tag) { lines.push('TAG='); tag = ''; }
        lines.push('UNTAG=' + value); untag = value;
      }
      lines.push(...p.hashes);
    }
    return lines.join('\n') + '\n';
  }

  /**
   * File name for a downloaded manifest, eg WebSIL_Manifest_2026-11-21_1042.txt.
   * @returns {string}
   */
  function manifestName() {
    const d = new Date(), z = (n) => String(n).padStart(2, '0');
    return `WebSIL_Manifest_${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}_${z(d.getHours())}${z(d.getMinutes())}.txt`;
  }

  /**
   * Show the queued changes dialog.
   * @returns {void}
   */
  function showPending() {
    const body = $('pendingBody');
    body.replaceChildren();
    if (!pending.length) {
      body.innerHTML = '<p class="muted">Nothing queued. Select images, type tags in the bar that appears, and use Add tags or Remove tags.</p>';
      $('pendingDlg').showModal();
      return;
    }
    const name = manifestName();
    const cmd = `sil LIBRARY=${shellQuote(libraryPath)} BUILDWEB ~/Downloads/${name}`;
    body.innerHTML = `
      <p>This page can't change the library itself. Save these changes as a manifest and run it
      with sil, which also rebuilds this page's data. Then reload the page.</p>
      <div class="buttons">
        <button type="button" class="primary" id="dlBtn">Download manifest</button>
        <button type="button" id="copyBtn">Copy to clipboard</button>
        <button type="button" id="clearBtn" class="quiet">Discard all changes</button>
      </div>
      <p class="muted">Then run, adjusting the folder if your browser saves elsewhere:<br><code id="cmd"></code></p>
      <p class="muted">If you copied instead: paste into a new text file ending <code>.txt</code>, and run sil on that file in the same way.</p>
      <textarea readonly id="manifestText"></textarea>`;
    $('cmd').textContent = cmd;
    $('manifestText').value = manifestText();
    $('dlBtn').addEventListener('click', () => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([manifestText()], { type: 'text/plain' }));
      a.download = name;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    });
    $('copyBtn').addEventListener('click', () => copyText(manifestText()));
    $('clearBtn').addEventListener('click', () => {
      if (!confirm('Discard every queued change?')) return;
      pending = [];
      savePending();
      refreshTiles();
      $('pendingDlg').close();
    });
    $('pendingDlg').showModal();
  }

  /**
   * Copy text to the clipboard, falling back to the older API for
   * browsers that don't allow the newer one on file:// pages.
   * @param {string} text
   * @returns {void}
   */
  function copyText(text) {
    const fallback = () => {
      const ta = $('manifestText');
      ta.select();
      toast(document.execCommand('copy') ? 'Copied' : 'Copy failed: select the text and copy it');
    };
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(() => toast('Copied'), fallback);
    } else fallback();
  }

  // ------------------------------------------------------- library summary

  /**
   * Show the library summary dialog: totals, a breakdown by type, and a
   * histogram of image sizes.
   * @returns {void}
   */
  function showInfo() {
    const body = $('infoBody');
    const total = images.reduce((s, im) => s + im.bytes, 0);
    const shown = view.reduce((s, im) => s + im.bytes, 0);
    const stat = (n, label) => `<div class="stat"><b>${n}</b><span>${label}</span></div>`;
    const byType = new Map();
    for (const im of images) {
      const t = byType.get(im.ext) || { n: 0, bytes: 0 };
      t.n++; t.bytes += im.bytes;
      byType.set(im.ext, t);
    }
    const dates = images.map((im) => im.date).filter(Boolean).sort();
    body.innerHTML = `
      <div class="stats">
        ${stat(images.length.toLocaleString(), 'images')}
        ${stat(humanSize(total), 'total size')}
        ${stat(images.length ? humanSize(total / images.length) : '-', 'average size')}
        ${stat(data.tags.length.toLocaleString(), 'tags')}
        ${stat(dates.length ? `${dates[0]} – ${dates[dates.length - 1]}` : '-', 'added')}
      </div>
      <p class="muted">Shown with current filters: ${view.length.toLocaleString()} images, ${humanSize(shown)}.
      Data built ${data.builtText}.</p>
      <h3>By type</h3>
      <table><thead><tr><th>Type</th><th>Images</th><th>Share</th><th>Size</th><th>Average</th></tr></thead><tbody>
      ${[...byType].sort((a, b) => b[1].n - a[1].n).map(([ext, t]) =>
        `<tr><td>${ext}</td><td>${t.n.toLocaleString()}</td><td>${(100 * t.n / images.length).toFixed(1)}%</td>` +
        `<td>${humanSize(t.bytes)}</td><td>${humanSize(t.bytes / t.n)}</td></tr>`).join('')}
      </tbody></table>
      <h3>Image sizes</h3>
      <p class="muted">Click a bar to show only images of that size.</p>`;
    body.append(histogram());
    $('infoDlg').showModal();
  }

  /**
   * An SVG histogram of image sizes, in doubling bins. Hovering a bar shows
   * its count; clicking one sets the size filter to its range.
   * @returns {SVGSVGElement}
   */
  function histogram() {
    const counts = HIST_EDGES.map(() => 0);
    for (const im of images) counts[HIST_EDGES.findIndex((e) => im.bytes < e)]++;
    let lo = counts.findIndex((c) => c > 0), hi = counts.length - 1 - [...counts].reverse().findIndex((c) => c > 0);
    if (lo < 0) { lo = 0; hi = 0; }
    const bins = [];
    for (let i = lo; i <= hi; i++) {
      const from = i ? HIST_EDGES[i - 1] : 0, to = HIST_EDGES[i];
      const label = i === 0 ? `< ${humanSize(to)}` : to === Infinity ? `≥ ${humanSize(from)}` : `${humanSize(from)}–${humanSize(to)}`;
      bins.push({ from, to, n: counts[i], label, tick: i === 0 ? '<' + humanSize(to) : humanSize(from) });
    }
    const W = 700, H = 220, padL = 8, padB = 34, padT = 18;
    const max = Math.max(1, ...bins.map((b) => b.n));
    const slot = (W - padL * 2) / bins.length, barW = Math.max(4, slot - 2);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.setAttribute('class', 'hist');
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', 'Number of images by file size: ' + bins.map((b) => `${b.label}: ${b.n}`).join('; '));
    const el = (name, attrs) => {
      const e = document.createElementNS(ns, name);
      for (const k in attrs) e.setAttribute(k, attrs[k]);
      svg.append(e);
      return e;
    };
    const base = H - padB;
    el('line', { x1: padL, x2: W - padL, y1: base + 0.5, y2: base + 0.5, class: 'axis' });
    const tip = $('tooltip');
    bins.forEach((b, i) => {
      const x = padL + i * slot + 1, h = b.n ? Math.max(2, (base - padT) * b.n / max) : 0, y = base - h;
      const r = Math.min(4, h, barW / 2);
      if (h) {
        el('path', {
          class: 'b',
          d: `M${x},${base} V${y + r} Q${x},${y} ${x + r},${y} H${x + barW - r} Q${x + barW},${y} ${x + barW},${y + r} V${base} Z`,
        });
      }
      if (bins.length <= 12 || i % 2 === 0) {
        el('text', { x: x + barW / 2, y: base + 14, 'text-anchor': 'middle' }).textContent = b.tick;
      }
      if (b.n === max) el('text', { x: x + barW / 2, y: y - 4, 'text-anchor': 'middle' }).textContent = b.n.toLocaleString();
      const hit = el('rect', { class: 'hit', x: x - 1, y: padT - 10, width: slot, height: base - padT + 10 });
      hit.addEventListener('mousemove', (e) => {
        tip.textContent = `${b.label}: ${b.n.toLocaleString()} images (${(100 * b.n / Math.max(1, images.length)).toFixed(1)}%)`;
        tip.style.left = e.clientX + 12 + 'px';
        tip.style.top = e.clientY + 12 + 'px';
        tip.hidden = false;
      });
      hit.addEventListener('mouseleave', () => { tip.hidden = true; });
      hit.addEventListener('click', () => {
        tip.hidden = true;
        $('sizeMin').value = b.from ? humanSize(b.from).replace(' ', '').toLowerCase() : '';
        $('sizeMax').value = b.to === Infinity ? '' : humanSize(b.to - 1024).replace(' ', '').toLowerCase();
        readFilterInputs();
        $('infoDlg').close();
      });
    });
    return svg;
  }

  // ----------------------------------------------------------- staleness

  /**
   * Compare the data's build time with the stamp each sil run leaves, and
   * say if the page is out of date.
   * @returns {void}
   */
  function checkStale() {
    const s = window.SIL_STAMP, note = $('notice');
    if (!s || !data) return;
    const cmd = `sil LIBRARY=${shellQuote(libraryPath)} BUILDWEB`;
    if (s.built > data.built) {
      note.innerHTML = 'This page\'s data has been rebuilt. <button type="button" id="reloadBtn">Reload</button>';
      $('reloadBtn').addEventListener('click', () => location.reload());
    } else if (s.changed > data.built) {
      note.innerHTML = 'The library has changed since this page\'s data was built ' +
        `(${data.builtText}; last change ${s.changedText}). To update it, run <code></code> and reload.`;
      note.querySelector('code').textContent = cmd;
      note.title = 'Last run: ' + s.command;
    } else { note.hidden = true; return; }
    note.hidden = false;
  }

  /**
   * Reread web/silStamp.js, eg when the user returns from a terminal.
   * @returns {void}
   */
  function refreshStamp() {
    const sc = document.createElement('script');
    sc.src = 'web/silStamp.js?' + Date.now();
    sc.onload = () => { sc.remove(); checkStale(); };
    sc.onerror = () => sc.remove();
    document.head.append(sc);
  }

  // ---------------------------------------------------------------- wiring

  /**
   * Read the date, size, type and sort controls into the state, and refilter.
   * @returns {void}
   */
  function readFilterInputs() {
    state.dateFrom = $('dateFrom').value;
    state.dateTo = $('dateTo').value;
    state.sizeMin = parseSize($('sizeMin').value);
    state.sizeMax = parseSize($('sizeMax').value);
    state.type = $('typeSel').value;
    state.sort = $('sortSel').value;
    for (const id of ['sizeMin', 'sizeMax']) {
      $(id).style.borderColor = $(id).value && parseSize($(id).value) === null ? 'var(--exclude)' : '';
    }
    applyFilters();
  }

  /**
   * Show a short message at the bottom of the window.
   * @param {string} text
   * @returns {void}
   */
  function toast(text) {
    const t = $('toast');
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { t.hidden = true; }, 2600);
  }

  /**
   * Connect the controls, and handle the keyboard.
   * @returns {void}
   */
  function wire() {
    attachComplete($('filterInput'), {
      onPick: addFilter,
      allowNew: false,
      onBackspace: () => {
        if (state.exclude.length) state.exclude.pop(); else state.include.pop();
        applyFilters();
      },
    });
    attachComplete($('tagInput'), {
      onPick: (tag) => { if (!editTags.includes(tag)) editTags.push(tag); renderEditChips(); },
      allowNew: true,
      onBackspace: () => { editTags.pop(); renderEditChips(); },
    });
    $('filterBox').addEventListener('click', () => $('filterInput').focus());
    $('tagBox').addEventListener('click', () => $('tagInput').focus());

    for (const id of ['dateFrom', 'dateTo', 'typeSel', 'sizeMin', 'sizeMax']) $(id).addEventListener('change', readFilterInputs);
    // A select sends no event when its current choice is picked again, so
    // Shuffle is there for a new order while Random stays chosen
    $('sortSel').addEventListener('change', () => {
      if ($('sortSel').value === 'random') shuffle();
      readFilterInputs();
    });
    $('shuffleBtn').addEventListener('click', () => { shuffle(); applyFilters(); });

    let prefs = {};
    try { prefs = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}'); } catch (e) { /* private mode */ }
    const setFit = (fit) => {
      $('fitSel').value = fit === 'fill' ? 'fill' : 'fit';
      document.body.classList.toggle('fill', fit === 'fill');
    };
    setFit(prefs.fit);
    $('fitSel').addEventListener('change', () => {
      setFit($('fitSel').value);
      prefs.fit = $('fitSel').value;
      try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch (e) { /* private mode */ }
    });
    $('resetBtn').addEventListener('click', () => {
      for (const id of ['dateFrom', 'dateTo', 'sizeMin', 'sizeMax', 'typeSel']) $(id).value = '';
      state.include = []; state.exclude = [];
      readFilterInputs();
    });
    for (const ext of [...new Set(images.map((im) => im.ext))].sort()) {
      $('typeSel').append(new Option(ext, ext));
    }

    $('treeBtn').addEventListener('click', () => {
      const tree = $('tree');
      tree.hidden = !tree.hidden;
      $('treeBtn').setAttribute('aria-expanded', !tree.hidden);
    });
    $('selectBtn').addEventListener('click', () => { selecting = !selecting; updateSelBar(); });
    $('selAllBtn').addEventListener('click', () => { view.forEach((im) => selected.add(im.hash)); refreshTiles(); });
    $('selNoneBtn').addEventListener('click', () => {
      selected.clear();
      selecting = false;
      showOnlySelected(false);
      refreshTiles();
    });
    $('onlySelBtn').addEventListener('click', () => showOnlySelected(!state.onlySelected));
    $('expandBtn').addEventListener('click', () => setTreeOpen(true));
    $('collapseBtn').addEventListener('click', () => setTreeOpen(false));
    $('addTagsBtn').addEventListener('click', () => queueChange('TAG'));
    $('untagBtn').addEventListener('click', () => queueChange('UNTAG'));
    $('pendingBtn').addEventListener('click', showPending);
    $('infoBtn').addEventListener('click', showInfo);

    $('grid').addEventListener('click', (e) => {
      const tile = e.target.closest('.tile');
      if (!tile) return;
      const i = Number(tile.dataset.i);
      if (selecting || e.target.classList.contains('check') || e.ctrlKey || e.metaKey || e.shiftKey) {
        toggleSelect(i, e.shiftKey);
      } else openLightbox(i);
    });

    new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting) renderMore();
    }, { root: document.querySelector('main'), rootMargin: '1500px' }).observe($('sentinel'));

    $('lbClose').addEventListener('click', closeLightbox);
    $('lbMedia').addEventListener('click', (e) => {
      if (e.target.tagName === 'VIDEO') return;
      lightboxStep(e.clientX < window.innerWidth / 3 ? -1 : 1);
    });

    document.addEventListener('keydown', (e) => {
      if (!$('lightbox').hidden) {
        if (e.ctrlKey || e.metaKey || e.altKey) return;
        // Claim every character key, or Firefox's find as you type takes
        // the ones the lightbox doesn't use, and X and I with them
        if (e.key.length === 1) e.preventDefault();
        const keys = {
          ArrowRight: 1, ArrowDown: 1, PageDown: 1, ' ': 1,
          ArrowLeft: -1, ArrowUp: -1, PageUp: -1,
        };
        if (e.key in keys) { lightboxStep(keys[e.key]); e.preventDefault(); }
        else if (e.key === 'Home') { lbIndex = 0; showLightbox(); e.preventDefault(); }
        else if (e.key === 'End') { lbIndex = view.length - 1; showLightbox(); e.preventDefault(); }
        else if (e.key === 'Escape') closeLightbox();
        else if (e.key.toLowerCase() === 'x') { toggleSelect(lbIndex, false); showLightbox(); }
        else if (e.key.toLowerCase() === 'i') $('lbCaption').hidden = !$('lbCaption').hidden;
        return;
      }
      if (e.target.matches('input, select, textarea') || document.querySelector('dialog[open]')) return;
      if (e.key === '/') { $('filterInput').focus(); e.preventDefault(); }
      else if (e.key === 'Escape' && selected.size) { selected.clear(); refreshTiles(); }
    });

    window.addEventListener('focus', refreshStamp);
  }

  /**
   * Replace the grid with a message, and disable the controls.
   * @param {string} html - Message, with an optional empty <code> for the command
   * @param {string} [code] - Text for the <code>
   * @returns {void}
   */
  function halt(html, code) {
    const empty = $('empty');
    empty.hidden = false;
    empty.innerHTML = html;
    if (code !== undefined) empty.querySelector('code:not([class])').textContent = code;
    document.querySelectorAll('#bar button, #bar input, #bar select').forEach((el) => { el.disabled = true; });
  }

  /**
   * Start the page, or explain what stops it: data not built, or an error.
   * @returns {void}
   */
  function start() {
    const errors = window.SIL_ERRORS || [];
    const rebuild = `sil LIBRARY=${shellQuote(libraryPath)} BUILDWEB`;
    if (!data) {
      if (errors.length) {
        // Browsers hide the details of errors in local files, as "Script error."
        halt('This library\'s web page data, <code class="f"></code>, could not be read. The browser says:' +
          '<br><br><code></code><br><br>Please report this. Rebuilding with <code class="rb"></code> may help.',
          errors.join('\n'));
        document.querySelector('#empty .f').textContent = 'web/imageData.js';
        document.querySelector('#empty .rb').textContent = rebuild;
      } else {
        halt('This library\'s web page data has not been built yet. Run:<br><br><code></code><br><br>then reload this page.', rebuild);
      }
      return;
    }
    try {
      run();
    } catch (e) {
      halt('The page failed to start:<br><br><code></code><br><br>Please report this message.',
        `${e.message}\n${e.stack || ''}`);
      throw e;
    }
  }

  /**
   * Load the data and connect the page.
   * @returns {void}
   */
  function run() {
    $('brand').textContent = 'WebSIL · ' + (libraryPath.split('/').pop() || 'library');
    document.title = $('brand').textContent;
    loadData();
    buildTree();
    wire();
    loadPending();
    updateSelBar();
    applyFilters();
    checkStale();
  }

  start();
}());
