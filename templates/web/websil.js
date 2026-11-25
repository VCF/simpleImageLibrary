/**
 * @file WebSIL: browse a SIL library in a web browser, and queue tag
 * changes as a SIL manifest.
 *
 * The page runs from file:// with nothing outside the library. Data comes
 * from two script files, as browsers refuse fetch() of file:// URLs:
 *   web/imageData.js - window.SIL_DATA, written by `sil BUILDWEB`
 *   web/silStamp.js  - window.SIL_STAMP, rewritten by sil runs that change the library
 * A page can't write to the library, so changes become a manifest the user
 * downloads or copies, and runs with sil.
 *
 * Copied into a library's web/ folder by `sil BUILDWEB`, which replaces it
 * on each build: do not edit a library's copy. The source is SIL's
 * templates/web/websil.js.
 */
(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);

  /** Tiles added to the grid at a time, as the user scrolls. */
  const BATCH = 150;
  /** Characters SIL allows in a tag level (TAG-03): ASCII and Latin-1 letters. */
  const TAG_LEVEL_RE = /^[A-Za-z0-9 _\-À-ÖØ-öø-ÿ]+$/;
  const VIDEO_EXT = new Set(['mp4', 'webm', 'mov']);
  /**
   * Reserved tags that queue a SIL operation on the images, rather than a
   * tag: a COPY or MOVE block (REQ-14), REMOVE, or REFETCH. Each has what
   * the autocomplete says of it, and what a toast says was queued.
   */
  const OP_TAGS = {
    SILCOPY: { op: 'COPY', note: 'SIL: copy to another library', verb: 'copy {n} to another library' },
    SILMOVE: { op: 'MOVE', note: 'SIL: move to another library', verb: 'move {n} to another library' },
    SILREMOVE: { op: 'REMOVE', note: 'SIL: remove from the library', verb: 'remove {n} from the library' },
    SILREFETCH: { op: 'REFETCH', note: 'SIL: download again from source', verb: 'download {n} again from source' },
  };
  /** Queue operations that are COPY or MOVE blocks, which need a target library. */
  const SEND_OPS = new Set(['COPY', 'MOVE']);
  /** Order of operation blocks in a manifest, after every tag change. */
  const OP_ORDER = ['COPY', 'MOVE', 'REFETCH', 'REMOVE'];
  /** Target written in COPY and MOVE blocks, for the user to replace. SIL refuses it. */
  const SEND_PLACEHOLDER = 'update/this/path/to/your/desired/destination/library';
  /** Upper edges of the size histogram's bins, in bytes; the last is open. */
  const HIST_EDGES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
    .map((kb) => kb * 1024).concat([Infinity]);

  const data = window.SIL_DATA;
  /** The library's folder: from the page's own location, which is right on any machine. */
  const libraryPath = location.protocol === 'file:'
    ? decodeURIComponent(location.pathname).replace(/\/[^/]*$/, '')
    : (data && data.library) || '';
  const storeKey = 'websil:' + libraryPath;
  /** Where the tags recently added are kept, for the right-click menu. */
  const recentKey = 'websil:recent:' + libraryPath;
  /** Recent tags the right-click menu lists. */
  const RECENT_MAX = 10;

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
  /** @type {Map<string, Img>} Images by hash. */
  const imageByHash = new Map();
  /** @type {Img[]} Images passing the filters, in sort order. */
  let view = [];
  let rendered = 0;
  /** The library's tags and aliases, with their image counts. */
  let libraryVocab = [];
  /** Vocabulary for autocomplete: libraryVocab, then new tags in queued changes. */
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
  /** Per-browser display settings: fit (tiles) and theme. */
  let prefs = {};
  /** Themes the theme button steps through, with its icon and name for each. */
  const THEMES = {
    auto: { icon: 'i-auto', name: 'System' },
    dark: { icon: 'i-moon', name: 'Dark' },
    light: { icon: 'i-sun', name: 'Light' },
  };
  /**
   * WEBACCENT colors by name: the shade for the dark theme, then the light.
   * Keep the names in step with _silAccentNames in src/params.sh.
   */
  const ACCENTS = {
    blue: ['#6ea8fe', '#2563eb'],
    teal: ['#2dd4bf', '#0f8a7c'],
    green: ['#6dd38a', '#1f8a43'],
    amber: ['#f5b544', '#b25f00'],
    violet: ['#a78bfa', '#6d4fd6'],
    rose: ['#fb7185', '#c0264a'],
  };
  /** @type {Set<string>} Selected image hashes. */
  const selected = new Set();
  let selecting = false;
  /** Whether anything was selected at the last updateSelBar, to open the bar on a first selection. */
  let hadSelection = false;
  let lastClicked = -1;
  /** Tags typed in the selection bar, waiting for Add or Remove. */
  let editTags = [];
  /**
   * Queued changes, in order. Operations (OP_TAGS) have no tags, and note
   * when they were queued (epoch seconds), to compare with the data's
   * build. REFETCH may give a SHRINK for its images, in KB ('' for the
   * library's own).
   * @type {{op: ('TAG'|'UNTAG'|'COPY'|'MOVE'|'REMOVE'|'REFETCH'), tags: string[],
   *     hashes: string[], at: ?number, shrink: ?string}[]}
   */
  let pending = [];
  let pendingHashes = new Set();
  let lbIndex = -1;
  /** Slideshow delays offered, in seconds; Up and Down move along these. */
  const SLIDE_DELAYS = [1, 3, 5, 10, 15, 30, 60];
  const SLIDE_DEFAULT = SLIDE_DELAYS.indexOf(5);
  let slideDelay = SLIDE_DEFAULT;
  /** Timer for the next slide, or null when the lightbox is manual. */
  let slideTimer = null;
  /**
   * Lightbox zoom levels, in the order + steps through them, each giving
   * the scale for an image's natural size in a window of the given size.
   * 1:1 is in screen pixels, which a HiDPI display has several of per CSS
   * pixel.
   */
  const ZOOMS = [
    { name: 'Fit all', scale: (w, h, vw, vh) => Math.min(vw / w, vh / h) },
    { name: 'Fit edge', scale: (w, h, vw, vh) => Math.max(vw / w, vh / h) },
    { name: '1:1', scale: () => 1 / (window.devicePixelRatio || 1) },
  ];
  let zoom = 0;
  /** The point of the image at the window's centre, as fractions of its width and height. */
  let panX = 0.5;
  let panY = 0.5;
  /**
   * The lightbox image as last placed: its shown size, and whether it is
   * wider or taller than the window. Null for a video or an image not loaded.
   * @type {?{w: number, h: number, cropX: boolean, cropY: boolean}}
   */
  let lbPlace = null;
  /** Lightbox info line levels, in the order I steps through them. */
  const INFO_MODES = ['minimal', 'extended', 'hidden'];
  let infoMode = 0;
  /** Tags recently added from this browser, most recent first. */
  let recentTags = [];
  /** @type {string[]} Hashes of the images the right-click menu would tag. */
  let menuHashes = [];
  /** A left click closed the tag menu; the click it ends shouldn't act too. */
  let swallowClick = false;
  /** Last pointer position, where / opens the tag menu in the lightbox. Null until it moves. */
  let pointer = null;

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
        src: `images/${hash.slice(0, 2)}/${hash}.${ext}`,
        video: VIDEO_EXT.has(ext),
        rand: 0,
      };
    });
    images.forEach((im) => imageByHash.set(im.hash, im));
    shuffle();
    libraryVocab = names.map((t) => ({ label: t, target: t, count: tagCount.get(t.toLowerCase()) || 0 }));
    for (const [alias, target] of data.aliases) {
      libraryVocab.push({ label: alias, target, alias: true, count: tagCount.get(target.toLowerCase()) || 0 });
    }
  }

  /**
   * Rebuild the autocomplete vocabulary: the library's tags, plus tags
   * that queued changes would add, so a new tag can be picked again.
   * @returns {void}
   */
  function refreshVocab() {
    const known = new Set(libraryVocab.map((v) => v.label.toLowerCase()));
    const queued = [];
    for (const p of pending) {
      if (p.op !== 'TAG') continue;
      for (const t of p.tags) {
        if (known.has(t.toLowerCase())) continue;
        known.add(t.toLowerCase());
        queued.push({ label: t, target: t, note: 'queued', count: 0 });
      }
    }
    vocab = libraryVocab.concat(queued);
  }

  /**
   * An image's name for display: enough of its hash to tell it apart from
   * every other image in the library (BUILDWEB's prefix), plus two
   * characters. Everything else, eg manifests, uses the full hash.
   * @param {string} hash
   * @returns {string} eg "0060d...", or the full hash if it is no shorter
   */
  function shortHash(hash) {
    const n = (data.prefix || hash.length) + 2;
    return n < hash.length ? hash.slice(0, n) + '...' : hash;
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
    const op = text.trim().toUpperCase();
    if (OP_TAGS[op]) return op;
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
      ? images.length.toLocaleString()
      : `${view.length.toLocaleString()} / ${images.length.toLocaleString()}`;
    $('count').title = `${view.length.toLocaleString()} of ${images.length.toLocaleString()} images shown`;
    $('shuffleBtn').hidden = s.sort !== 'random';
    // The filter button shows a dot while any filter under it is set
    const set = [s.dateFrom || s.dateTo, s.sizeMin !== null || s.sizeMax !== null, s.type].filter(Boolean).length;
    $('filterDot').hidden = !set;
    $('filterSummary').textContent = set ? `${set} filter${set > 1 ? 's' : ''} set` : 'No filters set';
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
   * @param {Object[]} [opts.extra] - Entries offered besides the library's
   *     tags, eg SILCOPY, each with a 'note' to show in place of a count,
   *     and 'op' set to mark it as a SIL operation
   * @returns {void}
   */
  function attachComplete(input, opts) {
    const list = $('complete');
    let items = [], active = 0;
    const choices = () => (opts.extra ? vocab.concat(opts.extra) : vocab);

    function close() { list.hidden = true; items = []; }

    function open() {
      const raw = input.value;
      const negate = raw.startsWith('!');
      const q = raw.replace(/^!/, '').trim().toLowerCase();
      if (!q) { close(); return; }
      const scored = [];
      for (const v of choices()) {
        const l = v.label.toLowerCase();
        let score = l === q ? 0 : l.startsWith(q) ? 1 : l.includes('/' + q) ? 2 : l.includes(q) ? 3 : -1;
        if (score >= 0) scored.push([score, v]);
      }
      scored.sort((a, b) => a[0] - b[0] || b[1].count - a[1].count || a[1].label.localeCompare(b[1].label));
      items = scored.slice(0, 12).map(([, v]) => ({ ...v, negate }));
      const typed = cleanTag(raw.replace(/^!/, ''));
      if (opts.allowNew && typed && !choices().some((v) => v.label.toLowerCase() === typed.toLowerCase())) {
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
        else if (it.note) { note.textContent = it.note; note.className = it.op ? 'alias op' : 'alias'; }
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
   * Show or hide the selection bar, with its count. It shows while
   * selecting, which a first selection turns on.
   * @returns {void}
   */
  function updateSelBar() {
    // A first selection, eg by Ctrl+click, opens the bar; the Select button
    // can then close it again, keeping the selection
    if (selected.size && !hadSelection) selecting = true;
    hadSelection = selected.size > 0;
    $('selBar').hidden = !selecting;
    $('selCount').textContent = `${selected.size.toLocaleString()} selected`;
    $('selAllBtn').dataset.tip = `Select all shown (${view.length.toLocaleString()})`;
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
   * Show the lightbox's current image, centred, and preload the next. The
   * media is only replaced when the image changes, so redrawing the info
   * line keeps the pan, and a video playing.
   * @returns {void}
   */
  function showLightbox() {
    const im = view[lbIndex];
    const box = $('lbMedia');
    if (box.dataset.hash !== im.hash) {
      let media;
      if (im.video) {
        media = document.createElement('video');
        Object.assign(media, { src: im.src, controls: true, autoplay: true, loop: true, muted: true });
      } else {
        media = document.createElement('img');
        media.src = im.src;
        media.alt = im.tags.join(', ');
        media.draggable = false;
        media.addEventListener('load', placeImage);
      }
      box.replaceChildren(media);
      box.dataset.hash = im.hash;
      box.classList.remove('pan');
      panX = 0.5;
      panY = 0.5;
      lbPlace = null;
      const next = view[lbIndex + 1];
      if (next && !next.video) new Image().src = next.src;
    }
    renderCaption();
  }

  /**
   * Fill the lightbox's info line for its current image, at the level I
   * chose: minimal, extended, or hidden.
   * @returns {void}
   */
  function renderCaption() {
    const im = view[lbIndex];
    const cap = $('lbCaption');
    const extended = INFO_MODES[infoMode] === 'extended';
    cap.hidden = INFO_MODES[infoMode] === 'hidden';
    cap.replaceChildren();
    const add = (text, cls) => {
      const s = document.createElement('span');
      s.textContent = text;
      if (cls) s.className = cls;
      cap.append(s);
    };
    if (extended) add(`${lbIndex + 1} / ${view.length}`);
    add(im.date || 'no date');
    add(humanSize(im.bytes));
    if (extended) add(im.ext);
    const tags = document.createElement('span');
    tags.className = 'lbtags';
    if (!im.tags.length) {
      tags.textContent = 'no tags';
      tags.classList.add('muted');
    }
    for (const t of im.tags) tags.append(lightboxTag(im, t));
    cap.append(tags);
    if (extended) add(shortHash(im.hash), 'muted');
    if (selected.has(im.hash)) add('selected', 'sel');
    if (slideTimer) add(`▶ every ${SLIDE_DELAYS[slideDelay]}s`, 'sel');
    add('h - key help', 'muted help');
  }

  /**
   * Size and position the lightbox image for the zoom and pan, keeping the
   * pan within the image: a dimension smaller than the window is centred,
   * and a larger one never shows a gap at its edges. Does nothing for a
   * video, or an image still loading, which CSS fits to the window.
   * @returns {void}
   */
  function placeImage() {
    const box = $('lbMedia');
    const img = box.querySelector('img');
    lbPlace = null;
    if (!img || !img.naturalWidth) return;
    const vw = box.clientWidth;
    const vh = box.clientHeight;
    const s = ZOOMS[zoom].scale(img.naturalWidth, img.naturalHeight, vw, vh);
    const w = Math.round(img.naturalWidth * s);
    const h = Math.round(img.naturalHeight * s);
    const offset = (pan, size, room) => (size <= room ? (room - size) / 2
      : Math.min(0, Math.max(room - size, room / 2 - pan * size)));
    const x = Math.round(offset(panX, w, vw));
    const y = Math.round(offset(panY, h, vh));
    // Store the pan as clamped, so panning back from past an edge moves at once
    panX = (vw / 2 - x) / w;
    panY = (vh / 2 - y) / h;
    Object.assign(img.style, { left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' });
    img.classList.add('placed');
    lbPlace = { w, h, cropX: w > vw, cropY: h > vh };
    box.classList.toggle('pan', lbPlace.cropX || lbPlace.cropY);
  }

  /**
   * Move the view over a zoomed lightbox image, as scrolling would.
   * @param {number} dx - CSS pixels; positive shows more of the right
   * @param {number} dy - CSS pixels; positive shows more of the bottom
   * @returns {void}
   */
  function panBy(dx, dy) {
    if (!lbPlace) return;
    panX += dx / lbPlace.w;
    panY += dy / lbPlace.h;
    placeImage();
  }

  /**
   * Step through the zoom levels, wrapping at either end, and say which
   * is now in use.
   * @param {number} step - +1 closer, -1 back
   * @returns {void}
   */
  function zoomStep(step) {
    zoom = (zoom + step + ZOOMS.length) % ZOOMS.length;
    placeImage();
    const im = view[lbIndex];
    toast(`Zoom: ${ZOOMS[zoom].name}` + (im.video ? ' (images only)' : ''), 1000);
  }

  /**
   * Step to the next info line level, and say which is now in use.
   * @returns {void}
   */
  function infoStep() {
    infoMode = (infoMode + 1) % INFO_MODES.length;
    renderCaption();
    toast(`Info: ${INFO_MODES[infoMode]}`, 1000);
  }

  /**
   * Return the lightbox's zoom, pan, info line, help and slideshow to how
   * they are when it first opens.
   * @returns {void}
   */
  function resetLightbox() {
    stopSlideshow();
    slideDelay = SLIDE_DEFAULT;
    zoom = 0;
    panX = 0.5;
    panY = 0.5;
    infoMode = 0;
    $('lbHelp').hidden = true;
    placeImage();
    renderCaption();
    toast('View reset', 1000);
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
    // Keep focus off the button, so Space still starts or pauses the slideshow
    b.addEventListener('mousedown', (e) => e.preventDefault());
    b.addEventListener('click', () => {
      if (queued) {
        queued.hashes = queued.hashes.filter((h) => h !== im.hash);
        pending = pending.filter((p) => p.hashes.length);
      } else queueTag('UNTAG', [im.hash], tag);
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
   * Queue adding or removing one tag on some images. Joins the last queue
   * entry if it does the same with just that tag, so stepping through
   * images with the same change makes one manifest block. The caller saves.
   * @param {('TAG'|'UNTAG')} op
   * @param {string[]} hashes
   * @param {string} tag
   * @returns {void}
   */
  function queueTag(op, hashes, tag) {
    const last = pending[pending.length - 1];
    if (last && last.op === op && last.tags.length === 1 && last.tags[0] === tag) {
      for (const h of hashes) if (!last.hashes.includes(h)) last.hashes.push(h);
    } else pending.push({ op, tags: [tag], hashes: [...hashes] });
  }

  /**
   * Leave the lightbox, scrolling the grid to the image last shown.
   * @returns {void}
   */
  function closeLightbox() {
    stopSlideshow();
    slideDelay = SLIDE_DEFAULT;
    zoom = 0;
    $('lbHelp').hidden = true;
    $('lightbox').hidden = true;
    $('lbMedia').replaceChildren();
    delete $('lbMedia').dataset.hash;
    lbPlace = null;
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

  /**
   * Start the slideshow, or pause it if running. It pauses itself on
   * reaching the last image.
   * @returns {void}
   */
  function toggleSlideshow() {
    if (slideTimer) {
      stopSlideshow();
      toast('Slideshow paused');
    } else {
      scheduleSlide();
      toast(`Slideshow: every ${SLIDE_DELAYS[slideDelay]}s`);
    }
    showLightbox();
  }

  /**
   * Time the next slide from now, replacing any pending one.
   * @returns {void}
   */
  function scheduleSlide() {
    clearTimeout(slideTimer);
    slideTimer = setTimeout(() => {
      if (lbIndex >= view.length - 1) {
        stopSlideshow();
        showLightbox();
        toast('Slideshow ended: last image');
        return;
      }
      scheduleSlide();
      lightboxStep(1);
    }, SLIDE_DELAYS[slideDelay] * 1000);
  }

  /**
   * Return the lightbox to manual mode.
   * @returns {void}
   */
  function stopSlideshow() {
    clearTimeout(slideTimer);
    slideTimer = null;
  }

  /**
   * Move the running slideshow to the next delay up or down, stopping at
   * either end, and time the next slide with it.
   * @param {number} step - +1 slower, -1 faster
   * @returns {void}
   */
  function slideDelayStep(step) {
    slideDelay = Math.max(0, Math.min(SLIDE_DELAYS.length - 1, slideDelay + step));
    scheduleSlide();
    toast(`Slideshow: every ${SLIDE_DELAYS[slideDelay]}s`);
    showLightbox();
  }

  // ------------------------------------------------------ right-click menu

  /**
   * Restore the recent tags saved by noteRecent.
   * @returns {void}
   */
  function loadRecent() {
    try { recentTags = JSON.parse(localStorage.getItem(recentKey) || '[]'); } catch (e) { recentTags = []; }
    if (!Array.isArray(recentTags)) recentTags = [];
  }

  /**
   * Move tags just added to the top of the recent list, and save it.
   * @param {string[]} tags - In the order added; the last ends up first
   * @returns {void}
   */
  function noteRecent(tags) {
    for (const t of tags) {
      recentTags = [t].concat(recentTags.filter((x) => x.toLowerCase() !== t.toLowerCase()));
    }
    recentTags = recentTags.slice(0, RECENT_MAX);
    try { localStorage.setItem(recentKey, JSON.stringify(recentTags)); } catch (e) { /* private mode */ }
  }

  /**
   * Whether every image the menu would tag has a tag already, or has it
   * queued to be added.
   * @param {string} tag
   * @returns {boolean}
   */
  function menuHasTag(tag) {
    const t = tag.toLowerCase();
    const queued = pending.filter((p) => p.op === 'TAG' && p.tags.some((x) => x.toLowerCase() === t));
    return menuHashes.every((h) => {
      const im = imageByHash.get(h);
      return (im && im.tags.some((x) => x.toLowerCase() === t)) || queued.some((p) => p.hashes.includes(h));
    });
  }

  /**
   * Open the tag menu for some images: a box to type a tag, over the recent
   * tags, placed so the most recent is under the pointer, and the box just
   * above it.
   * @param {string[]} hashes - Images a tag picked will be added to
   * @param {number} x - Pointer position, in CSS pixels from the window's left
   * @param {number} y - Pointer position, from the window's top
   * @returns {void}
   */
  function openTagMenu(hashes, x, y) {
    menuHashes = hashes;
    const menu = $('tagMenu');
    $('tmHead').textContent = hashes.length > 1
      ? `Add a tag to ${hashes.length.toLocaleString()} selected images` : 'Add a tag to this image';
    $('tmRecent').replaceChildren(...recentTags.map((t) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = t;
      if (menuHasTag(t)) { b.disabled = true; b.title = 'Already has this tag'; }
      b.addEventListener('click', () => menuPick(t));
      return b;
    }));
    $('tmInput').value = '';
    menu.hidden = false;
    const first = $('tmRecent').firstElementChild || $('tmInput');
    const r = menu.getBoundingClientRect();
    const f = first.getBoundingClientRect();
    const fit = (pos, size, room) => Math.max(4, Math.min(room - size - 4, pos));
    menu.style.left = fit(x - r.width / 2, r.width, window.innerWidth) + 'px';
    menu.style.top = fit(y - (f.top - r.top + f.height / 2), r.height, window.innerHeight) + 'px';
    $('tmInput').focus();
  }

  /**
   * Close the tag menu, if open.
   * @returns {void}
   */
  function closeTagMenu() {
    if ($('tagMenu').hidden) return;
    $('tagMenu').hidden = true;
    $('tmInput').blur();
    menuHashes = [];
  }

  /**
   * Queue the tag picked in the menu to be added to its images, and close
   * it. An operation tag (OP_TAGS) queues its operation instead, as in the
   * selection bar; SILREFETCH first asks for a SHRINK.
   * @param {string} tag - Tag path, as cleanTag gives it
   * @returns {void}
   */
  function menuPick(tag) {
    const hashes = menuHashes;
    const n = hashes.length === 1 ? 'this image' : `${hashes.length.toLocaleString()} images`;
    closeTagMenu();
    if (!tag || !hashes.length) return;
    const done = () => {
      savePending();
      refreshTiles();
      if (!$('lightbox').hidden) showLightbox();
    };
    if (OP_TAGS[tag]) {
      askShrink(OP_TAGS[tag].op, hashes.length, (shrink) => {
        queueOp(OP_TAGS[tag].op, hashes, shrink);
        toast('Queued: ' + OP_TAGS[tag].verb.replace('{n}', n));
        done();
      });
    } else {
      queueTag('TAG', hashes, tag);
      noteRecent([tag]);
      toast(`Queued: add ${tag} to ${n}`);
      done();
    }
  }

  /**
   * Queue a SIL operation (OP_TAGS) on some images. Joins the last queue
   * entry if it is the same operation (and SHRINK), so stepping through
   * images makes one manifest block. The caller saves.
   * @param {('COPY'|'MOVE'|'REMOVE'|'REFETCH')} op
   * @param {string[]} hashes
   * @param {string} [shrink=''] - REFETCH only: SHRINK in KB, '' for the library's
   * @returns {void}
   */
  function queueOp(op, hashes, shrink = '') {
    const last = pending[pending.length - 1];
    const at = Date.now() / 1000;
    if (last && last.op === op && (last.shrink || '') === shrink) {
      for (const h of hashes) if (!last.hashes.includes(h)) last.hashes.push(h);
      last.at = at;
    } else pending.push({ op, tags: [], hashes: [...hashes], at, shrink });
  }

  /**
   * Before queueing REFETCH, offer to change SHRINK for the images
   * refetched. Other operations go straight on.
   * @param {string} op - The operation about to be queued
   * @param {number} count - Images it is for
   * @param {function(string): void} onOk - Called with the SHRINK in KB,
   *     or '' to keep the library's; not called if the user cancels
   * @returns {void}
   */
  function askShrink(op, count, onOk) {
    if (op !== 'REFETCH') { onOk(''); return; }
    const dlg = $('refetchDlg'), input = $('rfShrink');
    $('rfHead').textContent = `Refetching ${count === 1 ? 'this image' : count.toLocaleString() + ' images'}`;
    input.value = '';
    $('rfError').hidden = true;
    dlg.onclose = null;
    $('rfForm').onsubmit = (e) => {
      if (e.submitter && e.submitter.value === 'cancel') return;
      const v = input.value.trim();
      if (v && !/^\d+(\.\d+)?$/.test(v)) {
        e.preventDefault();
        $('rfError').hidden = false;
        input.focus();
        return;
      }
      dlg.onclose = () => { dlg.onclose = null; onOk(v); };
    };
    dlg.showModal();
    input.focus();
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
   * Save queued changes in the browser, so a reload doesn't lose them,
   * and offer the tags they add in autocomplete.
   * @returns {void}
   */
  function savePending() {
    pendingHashes = new Set(pending.flatMap((p) => p.hashes));
    const n = pending.reduce((sum, p) => sum + p.hashes.length, 0);
    $('pendingCount').textContent = n.toLocaleString();
    $('pendingCount').classList.toggle('on', n > 0);
    $('pendingBtn').dataset.tip = n ? `Queued changes (${n.toLocaleString()})` : 'Queued changes';
    refreshVocab();
    try { localStorage.setItem(storeKey, JSON.stringify({ pending })); } catch (e) { /* private mode */ }
  }

  /**
   * Restore queued changes saved by savePending, dropping any the library
   * data already shows as done (the manifest was run and BUILDWEB since).
   * @returns {void}
   */
  function loadPending() {
    try { pending = JSON.parse(localStorage.getItem(storeKey) || '{}').pending || []; } catch (e) { pending = []; }
    const has = (im, t) => im.tags.some((x) => x.toLowerCase() === t.toLowerCase());
    // A copy leaves no mark in the data, so is taken as done once the data
    // is rebuilt after it was queued, as running the manifest does. So is a
    // refetch: one that replaced its image has no hash left in the data,
    // but one that didn't (eg no web source) leaves no mark
    pending = pending.filter((p) => (p.op !== 'COPY' && p.op !== 'REFETCH') || !(data.built > p.at));
    pending = pending.map((p) => ({
      ...p,
      hashes: p.hashes.filter((h) => {
        const im = imageByHash.get(h);
        if (!im) return false;
        if (OP_ORDER.includes(p.op)) return true;
        return p.op === 'TAG' ? !p.tags.every((t) => has(im, t)) : p.tags.some((t) => has(im, t));
      }),
    })).filter((p) => p.hashes.length);
    savePending();
  }

  /**
   * Queue the selection bar's tags to be added to, or removed from, the
   * selected images. Adding an operation tag (OP_TAGS) queues that SIL
   * operation on them instead, after any tags added with it; SILREFETCH
   * first asks for a SHRINK, and nothing is queued if that is cancelled.
   * @param {('TAG'|'UNTAG')} op
   * @returns {void}
   */
  function queueChange(op) {
    const typed = cleanTag($('tagInput').value);
    if (typed && !editTags.includes(typed)) editTags.push(typed);
    $('tagInput').value = '';
    if (!editTags.length) { toast('Type a tag first'); $('tagInput').focus(); return; }
    if (!selected.size) { toast('Select some images first'); return; }
    const ops = editTags.filter((t) => OP_TAGS[t]);
    const tags = editTags.filter((t) => !OP_TAGS[t]);
    if (ops.length && op === 'UNTAG') { toast(`${ops.join(' and ')} can only be added, to queue a SIL operation`); return; }
    if (ops.length > 1) { toast(`Choose one of ${ops.join(', ')}`); return; }
    const hashes = [...selected];
    askShrink(ops.length ? OP_TAGS[ops[0]].op : '', hashes.length, (shrink) => {
      const done = [];
      if (tags.length) {
        pending.push({ op, tags, hashes });
        if (op === 'TAG') noteRecent(tags);
        done.push(`${op === 'TAG' ? 'add' : 'remove'} ${tags.join(', ')}`);
      }
      if (ops.length) {
        queueOp(OP_TAGS[ops[0]].op, hashes, shrink);
        done.push(OP_TAGS[ops[0]].verb.replace('{n} ', ''));
      }
      toast(`Queued: ${done.join(', then ')} for ${hashes.length} image(s)`);
      editTags = [];
      selected.clear();
      renderEditChips();
      savePending();
      showOnlySelected(false);
      refreshTiles();
    });
  }

  /**
   * Show the tags typed in the selection bar.
   * @returns {void}
   */
  function renderEditChips() {
    $('tagChips').replaceChildren(...editTags.map((t) => chip(t,
      OP_TAGS[t] ? 'op' : tagSpelling.has(t.toLowerCase()) ? '' : 'new',
      () => { editTags = editTags.filter((x) => x !== t); renderEditChips(); })));
  }

  /**
   * A queued copy or move as a manifest block, with comments explaining it
   * and asking for the target library (REQ-14).
   * @param {{op: ('COPY'|'MOVE'), hashes: string[]}} p
   * @returns {string[]} The block's lines
   */
  function sendBlock(p) {
    const n = p.hashes.length;
    const lines = [
      `# ${p.op === 'COPY' ? 'Copy' : 'Move'} ${n} image(s) from this library to another one.`,
      '# Before running this file, replace the path after "->" below with the',
      '# folder of the library to send them to. It must already be a SIL library;',
      '# SIL refuses the placeholder. The images keep their tags and sources there.',
    ];
    if (p.op === 'MOVE') {
      lines.push(
        '#',
        '# !!! MOVE DELETES THESE IMAGES FROM THIS LIBRARY once each is copied.',
        '# !!! To keep them here as well, change MOVE to COPY and STOPMOVE to STOPCOPY.',
      );
    }
    lines.push(`${p.op} ${libraryPath} -> ${SEND_PLACEHOLDER}`, ...p.hashes, `STOP${p.op}`);
    return lines;
  }

  /**
   * A queued REMOVE or REFETCH as a manifest block, with comments
   * explaining it. The block turns its flag off, and restores SHRINK if it
   * set one, so nothing after it is affected.
   * @param {{op: ('REMOVE'|'REFETCH'), hashes: string[], shrink: ?string}} p
   * @returns {string[]} The block's lines
   */
  function opBlock(p) {
    const n = p.hashes.length;
    if (p.op === 'REMOVE') {
      return [
        `# Remove ${n} image(s) from this library: each file, its tags, and its`,
        '# records. A library under git keeps them in its history.',
        'REMOVE', ...p.hashes, 'REMOVE=off',
      ];
    }
    const lines = [
      `# Download ${n} image(s) again from the web addresses they came from. Each`,
      '# download replaces its image if it still matches it, keeping its tags and',
      '# date; the old file is kept in replacedWithHigherRes/. Images with no web',
      '# address recorded are left as they are (NOSOURCE).',
    ];
    if (p.shrink) {
      lines.push(
        p.shrink === '0' ? '# Not shrunk, for these images only:' : `# Shrunk to about ${p.shrink} KB, for these images only:`,
        `SHRINK=${p.shrink}kb`,
      );
    }
    lines.push('REFETCH', ...p.hashes, 'REFETCH=off');
    if (p.shrink) lines.push('# Back to the library\'s own SHRINK:', 'SHRINK=');
    return lines;
  }

  /**
   * The queued changes as a SIL manifest. LIBRARY is given, so it works
   * from any folder, eg Downloads. Operations come after every tag change,
   * which then ends, so that images are tagged before they are sent, and
   * nothing is tagged twice: copies and moves, then refetches (which give
   * images new hashes, so must follow anything naming the old ones), then
   * removals.
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
      if (OP_ORDER.includes(p.op)) continue;
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
    if (tag) lines.push('TAG=');
    if (untag) lines.push('UNTAG=');
    for (const op of OP_ORDER) {
      for (const p of pending.filter((x) => x.op === op)) {
        lines.push('', ...(SEND_OPS.has(op) ? sendBlock(p) : opBlock(p)));
      }
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
      body.innerHTML = '<p class="muted">Nothing queued. Select images, type tags in the bar that appears, and use Add tags or Remove tags. ' +
        'To have SIL copy, move, remove or refetch images, add the tag SILCOPY, SILMOVE, SILREMOVE or SILREFETCH.</p>';
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
      <p id="sendNote" hidden><strong>Copies and moves:</strong> edit the manifest first, to replace
      <code>${SEND_PLACEHOLDER}</code> with the folder of the library to send the images to.
      A queued copy is cleared from this list once the page's data is rebuilt.</p>
      <textarea readonly id="manifestText"></textarea>`;
    $('cmd').textContent = cmd;
    $('sendNote').hidden = !pending.some((p) => SEND_OPS.has(p.op));
    $('manifestText').value = manifestText();
    $('dlBtn').addEventListener('click', () => {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([manifestText()], { type: 'text/plain' }));
      a.download = name;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    });
    $('copyBtn').addEventListener('click', (e) => copyText(manifestText(), e.currentTarget));
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
   * browsers that don't allow the newer one on file:// pages, and say
   * how it went in a bubble above the button pressed.
   * @param {string} text
   * @param {HTMLElement} btn - The button pressed
   * @returns {void}
   */
  function copyText(text, btn) {
    const fallback = () => {
      const ta = $('manifestText');
      ta.select();
      if (document.execCommand('copy')) bubble(btn, 'Copied!');
      else bubble(btn, 'Copy failed: select the text and copy it', true);
    };
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(() => bubble(btn, 'Copied!'), fallback);
    } else fallback();
  }

  /**
   * Show a short message in a bubble above an element, which stays for two
   * seconds then fades over two more (the .bubble animation). Unlike
   * toast, it shows inside a modal dialog, which covers everything else.
   * @param {HTMLElement} el - The element to show it above
   * @param {string} text
   * @param {boolean} [failed=false] - Color it as a failure
   * @returns {void}
   */
  function bubble(el, text, failed = false) {
    el.parentElement.querySelector('.bubble')?.remove();
    const b = document.createElement('span');
    b.className = 'bubble' + (failed ? ' failed' : '');
    b.setAttribute('role', 'status');
    b.textContent = text;
    b.style.left = `${el.offsetLeft + el.offsetWidth / 2}px`;
    b.style.top = `${el.offsetTop}px`;
    b.addEventListener('animationend', () => b.remove());
    el.parentElement.append(b);
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
   * Compare the data's build time with the stamp left by the last sil run
   * to change the library, and say if the page is out of date.
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

  // ---------------------------------------------------------- appearance

  /**
   * Keep the display settings (prefs) for every library in this browser.
   * @returns {void}
   */
  function savePrefs() {
    try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch (e) { /* private mode */ }
  }

  /**
   * Apply the theme in prefs: System follows the browser's preference,
   * Dark and Light override it. Updates the theme button to match.
   * @returns {void}
   */
  function applyTheme() {
    const theme = THEMES[prefs.theme] ? prefs.theme : 'auto';
    if (theme === 'auto') delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
    $('themeBtn').dataset.tip = 'Theme: ' + THEMES[theme].name;
    $('themeBtn').querySelector('use').setAttribute('href', '#' + THEMES[theme].icon);
  }

  /**
   * Text color for a background, dark or white, whichever reads better.
   * @param {string} hex - Background, as #rrggbb
   * @returns {string} A #rrggbb color
   */
  function inkFor(hex) {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? '#0b1220' : '#ffffff';
  }

  /**
   * Color the page and its browser tab icon with the library's WEBACCENT.
   * A named color has its own shade for each theme; a hex color is used as
   * given in the dark theme, and darkened for the light one.
   * @param {string} [accent] - A name from ACCENTS, or #rrggbb; blue if unknown
   * @returns {void}
   */
  function applyAccent(accent) {
    let shades = ACCENTS[accent] || ACCENTS.blue;
    if (/^#[0-9a-f]{6}$/.test(accent || '')) {
      const dark = [1, 3, 5].map((i) => Math.round(parseInt(accent.slice(i, i + 2), 16) * 0.72)
        .toString(16).padStart(2, '0'));
      shades = [accent, '#' + dark.join('')];
    }
    const root = document.documentElement.style;
    root.setProperty('--accD', shades[0]);
    root.setProperty('--accL', shades[1]);
    root.setProperty('--accInkD', inkFor(shades[0]));
    root.setProperty('--accInkL', inkFor(shades[1]));
    // The toolbar's logo, drawn on the accent
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">' +
      `<rect width="24" height="24" rx="6" fill="${shades[0]}"/>` +
      `<g transform="translate(3 3) scale(.75)" fill="none" stroke="${inkFor(shades[0])}" ` +
      'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
      $('i-logo').innerHTML + '</g></svg>';
    $('favicon').href = 'data:image/svg+xml,' + encodeURIComponent(svg);
  }

  /**
   * Show a short message at the bottom center of the window. Over the full
   * window view it sits just above the info line, which can wrap.
   * @param {string} text
   * @param {number} [ms=2600] - How long to show it
   * @returns {void}
   */
  function toast(text, ms = 2600) {
    const t = $('toast');
    const cap = $('lbCaption');
    const above = !$('lightbox').hidden && cap.offsetHeight ? cap.offsetHeight + 12 : 0;
    t.style.bottom = above ? above + 'px' : '';
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { t.hidden = true; }, ms);
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
      extra: Object.entries(OP_TAGS).map(([t, v]) => ({ label: t, target: t, note: v.note, op: true, count: 0 })),
      onBackspace: () => { editTags.pop(); renderEditChips(); },
    });
    attachComplete($('tmInput'), {
      onPick: menuPick,
      allowNew: true,
      extra: Object.entries(OP_TAGS).map(([t, v]) => ({ label: t, target: t, note: v.note, op: true, count: 0 })),
      onBackspace: () => {},
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

    const setFit = (fit) => {
      for (const b of $('fitSeg').children) b.setAttribute('aria-pressed', b.dataset.fit === (fit === 'fill' ? 'fill' : 'fit'));
      document.body.classList.toggle('fill', fit === 'fill');
    };
    setFit(prefs.fit);
    $('fitSeg').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      setFit(b.dataset.fit);
      prefs.fit = b.dataset.fit;
      savePrefs();
    });
    $('themeBtn').addEventListener('click', () => {
      const names = Object.keys(THEMES);
      prefs.theme = names[(names.indexOf(prefs.theme || 'auto') + 1) % names.length];
      applyTheme();
      savePrefs();
    });
    // The filter popover closes on Escape, or a click outside it
    const setPop = (open) => {
      $('filterPop').hidden = !open;
      $('filterBtn').setAttribute('aria-expanded', open);
      // Under its button, as far as the toolbar's edge allows
      const bar = $('bar').getBoundingClientRect();
      $('filterPop').style.right = Math.max(8, bar.right - $('filterBtn').getBoundingClientRect().right - 40) + 'px';
    };
    $('filterBtn').addEventListener('click', () => setPop($('filterPop').hidden));
    document.addEventListener('pointerdown', (e) => {
      if (!$('filterPop').hidden && !$('filterPop').contains(e.target) && !$('filterBtn').contains(e.target)) setPop(false);
    });
    $('filterPop').addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { setPop(false); $('filterBtn').focus(); }
    });
    // What scrolls under the toolbar starts below it, however tall it grows
    new ResizeObserver(() => {
      document.documentElement.style.setProperty('--barH', $('bar').offsetHeight + 'px');
    }).observe($('bar'));
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
      hadSelection = false;
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

    // Right-click: the tag menu, for the image, or every selected image if
    // it is one of them. Shift+right-click leaves the browser's own menu
    $('grid').addEventListener('contextmenu', (e) => {
      const tile = e.target.closest('.tile');
      if (!tile || e.shiftKey) return;
      e.preventDefault();
      const im = view[Number(tile.dataset.i)];
      openTagMenu(selected.has(im.hash) ? [...selected] : [im.hash], e.clientX, e.clientY);
    });
    // A click outside the menu closes it, without also acting on what it hit
    document.addEventListener('pointerdown', (e) => {
      if ($('tagMenu').hidden || $('tagMenu').contains(e.target) || $('complete').contains(e.target)) return;
      closeTagMenu();
      swallowClick = e.button === 0;
    }, true);
    document.addEventListener('click', (e) => {
      if (!swallowClick) return;
      swallowClick = false;
      e.stopPropagation();
      e.preventDefault();
    }, true);
    document.querySelector('main').addEventListener('scroll', closeTagMenu);
    window.addEventListener('resize', closeTagMenu);

    new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting) renderMore();
    }, { root: document.querySelector('main'), rootMargin: '1500px' }).observe($('sentinel'));

    $('lbClose').addEventListener('click', closeLightbox);
    // A click on either side moves through the images; a drag pans a zoomed
    // one, and the click that ends it is ignored
    const lbMedia = $('lbMedia');
    let drag = null;
    let dragged = false;
    lbMedia.addEventListener('pointerdown', (e) => {
      dragged = false;
      if (e.button !== 0 || !lbPlace || !(lbPlace.cropX || lbPlace.cropY)) return;
      drag = { x: e.clientX, y: e.clientY };
      lbMedia.setPointerCapture(e.pointerId);
    });
    lbMedia.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const dx = e.clientX - drag.x;
      const dy = e.clientY - drag.y;
      // Small movements are a shaky click, not a drag
      if (!dragged && Math.hypot(dx, dy) < 5) return;
      dragged = true;
      lbMedia.classList.add('dragging');
      panBy(-dx, -dy);
      drag = { x: e.clientX, y: e.clientY };
    });
    const endDrag = () => { drag = null; lbMedia.classList.remove('dragging'); };
    lbMedia.addEventListener('pointerup', endDrag);
    lbMedia.addEventListener('pointercancel', endDrag);
    // With one dimension cropped, the wheel pans along it, Shift or not.
    // With both, it pans up and down, and Shift+wheel sideways
    lbMedia.addEventListener('wheel', (e) => {
      if (!lbPlace || !(lbPlace.cropX || lbPlace.cropY)) return;
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? lbMedia.clientHeight : 1;
      let dx = e.deltaX * unit;
      let dy = e.deltaY * unit;
      // Some browsers turn Shift+wheel into sideways scrolling themselves
      if (e.shiftKey && !dx) { dx = dy; dy = 0; }
      if (!lbPlace.cropY) { dx += dy; dy = 0; } else if (!lbPlace.cropX) { dy += dx; dx = 0; }
      panBy(dx, dy);
    }, { passive: false });
    window.addEventListener('resize', () => { if (!$('lightbox').hidden) placeImage(); });
    // The lightbox's tag menu, from a right-click or /, pausing the slideshow
    const lightboxMenu = (x, y) => {
      if (lbIndex < 0) return;
      if (slideTimer) { stopSlideshow(); showLightbox(); }
      openTagMenu([view[lbIndex].hash], x, y);
    };
    lbMedia.addEventListener('contextmenu', (e) => {
      if (e.shiftKey) return;
      e.preventDefault();
      lightboxMenu(e.clientX, e.clientY);
    });
    document.addEventListener('pointermove', (e) => { pointer = { x: e.clientX, y: e.clientY }; }, { passive: true });
    lbMedia.addEventListener('click', (e) => {
      if (e.target.tagName === 'VIDEO' || dragged) return;
      const wasRunning = slideTimer;
      stopSlideshow();
      lightboxStep(e.clientX < window.innerWidth / 3 ? -1 : 1);
      if (wasRunning) showLightbox();
    });

    document.addEventListener('keydown', (e) => {
      // A dialog, eg the refetch SHRINK, takes the keys while open
      if (document.querySelector('dialog[open]')) return;
      // The menu takes the keys while open; its input closes the
      // autocomplete on Escape, which reaches here to close the menu
      if (!$('tagMenu').hidden) {
        if (e.key === 'Escape') { closeTagMenu(); e.preventDefault(); }
        return;
      }
      if (!$('lightbox').hidden) {
        if (e.ctrlKey || e.metaKey || e.altKey) return;
        // Claim every character key, or Firefox's find as you type takes
        // the ones the lightbox doesn't use, and X and I with them
        if (e.key.length === 1) e.preventDefault();
        const keys = {
          ArrowRight: 1, ArrowDown: 1, PageDown: 1,
          ArrowLeft: -1, ArrowUp: -1, PageUp: -1,
        };
        // While the slideshow runs, Up and Down change its delay; the other
        // movement keys return to manual mode before moving
        const delayKeys = { ArrowUp: 1, ArrowDown: -1 };
        if (e.key === ' ') { toggleSlideshow(); e.preventDefault(); }
        else if (slideTimer && e.key in delayKeys) { slideDelayStep(delayKeys[e.key]); e.preventDefault(); }
        else if (e.key in keys) {
          const wasRunning = slideTimer;
          stopSlideshow();
          lightboxStep(keys[e.key]);
          // lightboxStep doesn't redraw at either end; the caption still must
          if (wasRunning) showLightbox();
          e.preventDefault();
        }
        else if (e.key === 'Home') { lbIndex = 0; showLightbox(); e.preventDefault(); }
        else if (e.key === 'End') { lbIndex = view.length - 1; showLightbox(); e.preventDefault(); }
        else if (e.key === 'Escape') {
          if ($('lbHelp').hidden) closeLightbox(); else $('lbHelp').hidden = true;
        } else {
          // Shifted or not, so + and = zoom in, - and _ back
          const k = e.key.toLowerCase();
          if (k === 'x') { toggleSelect(lbIndex, false); showLightbox(); }
          else if (k === 'i') infoStep();
          else if (k === 'h' || k === '?') $('lbHelp').hidden = !$('lbHelp').hidden;
          // At the pointer, as a right-click would be; the window's centre
          // if it hasn't moved since the page loaded
          else if (k === '/') lightboxMenu(pointer ? pointer.x : window.innerWidth / 2, pointer ? pointer.y : window.innerHeight / 2);
          else if (k === '+' || k === '=') zoomStep(1);
          else if (k === '-' || k === '_') zoomStep(-1);
          else if (k === 'r') resetLightbox();
        }
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
    try { prefs = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}') || {}; } catch (e) { /* private mode */ }
    applyTheme();
    applyAccent(data && data.accent);
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
    document.title = 'WebSIL · ' + (libraryPath.split('/').pop() || 'library');
    $('brand').dataset.tip = document.title;
    loadData();
    buildTree();
    wire();
    loadPending();
    loadRecent();
    updateSelBar();
    applyFilters();
    checkStale();
  }

  start();
}());
