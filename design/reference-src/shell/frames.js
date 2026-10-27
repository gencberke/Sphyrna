/* ---------- the frames: every document is stored once, compressed, and shown in frames of its own ----------
   The page passes its state (appearance, tone, art, pins, size) to every frame with the sections that frame shows.
   A frame reports its height, its errors and any choice made inside it, which becomes the page's. */
let REF = null;
async function unpack() {
  const bytes = Uint8Array.from(atob($('#ref-docs').textContent.trim()), c => c.charCodeAt(0));
  const text = await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).text();
  REF = JSON.parse(text);
}
const docHtml = name => REF.docs[name].map(k => REF.blocks[k]).join('');
const STATE = { theme: 'dark', cast: 'neutral', pins: false, zoom: false };
const frames = [];
// A frame shows the listed sections of one document: nums renumbers them, and bare shows each one's window alone.
function addFrame(parent, doc, only, opts = {}) {
  const el = document.createElement('iframe');
  el.className = 'frame wait'; el.title = opts.title || only.join(', ');
  el.style.height = (opts.height || 900 * only.length) + 'px';
  parent.appendChild(el);
  frames.push({ el, doc, only, nums: opts.nums, bare: opts.bare });
}
function post(f) { if (f.el.contentWindow) f.el.contentWindow.postMessage({ ref: 'state', ...STATE, only: f.only, nums: f.nums, bare: f.bare }, '*'); }
const postAll = () => frames.forEach(post);
// The frames load one after another, so the page answers at once and the reading position settles quickly.
let next = 0;
function loadNext() {
  if (next >= frames.length) return;
  const f = frames[next++];
  f.el.srcdoc = docHtml(f.doc);
  f.timer = setTimeout(loadNext, 4000);
}
addEventListener('message', e => {
  const f = frames.find(x => x.el.contentWindow === e.source), m = e.data;
  if (!f || !m || !m.ref) return;
  if (m.ref === 'ready') { post(f); clearTimeout(f.timer); setTimeout(loadNext, 30); }
  if (m.ref === 'h') { f.el.style.height = m.h + 'px'; f.el.classList.remove('wait'); if (m.errs.length) console.warn(`[${f.doc}]`, m.errs.join(' | ')); }
  if (m.ref === 'local') {
    // A choice made inside a frame, such as Settings' tone, becomes the page's.
    let changed = false;
    ['theme', 'cast'].forEach(key => { if (m[key] && m[key] !== STATE[key]) { STATE[key] = m[key]; changed = true; } });
    if (changed) { paintTools(); postAll(); }
  }
});
// The page's own switches: base.js already toggles them; these pass the state to every frame.
function paintTools() {
  $$('#themeSeg button').forEach(b => b.classList.toggle('on', b.dataset.themeSet === STATE.theme));
  if (document.documentElement.dataset.theme !== STATE.theme) { document.documentElement.dataset.theme = STATE.theme; }
  $$('#toneSeg button').forEach(b => b.classList.toggle('on', b.dataset.tone === STATE.cast));
}
$$('#themeSeg button').forEach(b => b.addEventListener('click', () => { STATE.theme = b.dataset.themeSet; postAll(); }));
$$('#toneSeg button').forEach(b => b.addEventListener('click', () => { STATE.cast = b.dataset.tone; paintTools(); postAll(); }));
[['#swPins', 'pins'], ['#swZoom', 'zoom']].forEach(([id, key]) =>
  $(id).parentElement.addEventListener('click', () => { STATE[key] = $(id).classList.contains('on'); postAll(); }));
