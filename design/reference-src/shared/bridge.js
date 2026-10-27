/* ---------- the bridge to the reference and the landing page ----------
   In those pages this document sits in a frame: the page sets its appearance, tone and switches, chooses which
   sections it shows (bare: each one's window alone), and learns its height. Opened on its own, the document is as it was. */
(() => {
  if (window.parent === window) return;
  const css = document.createElement('style');
  css.textContent = 'header.top,section.intro{display:none!important}';
  document.head.appendChild(css);
  const q = s => document.querySelector(s);
  const toggle = (id, want) => { const el = q(id); if (el && el.classList.contains('on') !== want) el.parentElement.click(); };
  let last = -1;
  function report() {
    // the content's own height: the frame is as tall as it, so the page never scrolls inside it
    const kids = [...document.body.children].filter(el => el.offsetParent !== null || getComputedStyle(el).position === 'fixed');
    const bottom = Math.max(0, ...kids.map(el => el.getBoundingClientRect().bottom + scrollY + parseFloat(getComputedStyle(el).marginBottom || 0)));
    const h = Math.ceil(bottom);
    if (h !== last) { last = h; parent.postMessage({ ref: 'h', h, errs: window.__errs || [] }, '*'); }
  }
  function apply(m) {
    applying = true;
    if (m.theme) { const b = q(`#themeSeg [data-theme-set="${m.theme}"]`); if (b && !b.classList.contains('on')) b.click(); }
    // v3 or the v4 tokens, and the v4 chapter's open choices Q1–Q6 (B0)
    if (m.ink) { const b = q(`#inkSeg [data-ink-set="${m.ink}"]`); if (b) { if (!b.classList.contains('on')) b.click(); } else document.documentElement.dataset.ink = m.ink; }
    if (m.q) Object.entries(m.q).forEach(([k, v]) => { document.documentElement.dataset[k] = v; });
    if (m.cast) {
      const tile = q(`[data-set="cast"] [data-v="${m.cast}"]`);
      if (tile) { if (!tile.classList.contains('on')) tile.click(); } else document.body.dataset.cast = m.cast;
    }
    if ('sharks' in m) toggle('#swAmbient', m.sharks);
    if ('pins' in m) toggle('#swPins', m.pins);
    if ('zoom' in m) toggle('#swZoom', m.zoom);
    if (m.only) document.querySelectorAll('section.sec').forEach(s => { s.style.display = m.only.includes(s.id) ? '' : 'none'; });
    if (m.nums) Object.entries(m.nums).forEach(([id, n]) => { const el = q(`#${id} .sechead .num`); if (el) el.textContent = n; });
    if (m.bare) bare();
    requestAnimationFrame(report);
    document.dispatchEvent(new CustomEvent('ref:state'));
    setTimeout(() => { applying = false; });
  }
  // The landing page shows each section's window alone: its first stage, without the heading, notes or parts, on a clear ground.
  let bared = false;
  function bare() {
    if (bared) return;
    bared = true;
    const css = document.createElement('style');
    css.textContent = 'html,body{background:transparent!important}section.sec{padding:24px 0 64px!important}body>footer,.wrap>footer{display:none!important}';
    document.head.appendChild(css);
    document.querySelectorAll('section.sec').forEach(s => {
      if (s.style.display === 'none') return;
      const st = s.querySelector('.stage');
      if (st) s.querySelectorAll('*').forEach(el => { if (!el.contains(st) && !st.contains(el)) el.style.display = 'none'; });
    });
  }
  // A choice made here, such as Settings' appearance, tone or Animated art, goes back to the page, which passes it to every frame.
  let applying = false;
  const art = q('#swAmbient');
  const local = () => {
    if (applying) return;
    const root = document.documentElement, qs = {};
    ['q1', 'q2', 'q3', 'q4', 'q5', 'q6'].forEach(k => { if (root.dataset[k]) qs[k] = root.dataset[k]; });
    parent.postMessage({ ref: 'local', theme: root.dataset.theme, ink: root.dataset.ink, q: qs, cast: document.body.dataset.cast, sharks: art ? art.classList.contains('on') : undefined }, '*');
  };
  new MutationObserver(local).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-ink', 'data-q1', 'data-q2', 'data-q3', 'data-q4', 'data-q5', 'data-q6'] });
  new MutationObserver(local).observe(document.body, { attributes: true, attributeFilter: ['data-cast'] });
  if (art) new MutationObserver(local).observe(art, { attributes: true, attributeFilter: ['class'] });
  addEventListener('message', e => { if (e.source === parent && e.data && e.data.ref === 'state') apply(e.data); });
  new ResizeObserver(() => requestAnimationFrame(report)).observe(document.body);
  addEventListener('load', report);
  parent.postMessage({ ref: 'ready' }, '*');
})();
