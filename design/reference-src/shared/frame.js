/* ---------- the session frame's behaviour ---------- */
const winA = $('#winA');
function showTab(insp, key) {
  const t = $(`.itab[data-tab="${key}"]`, insp);
  $$('.itab', insp).forEach(x => x.classList.toggle('on', x === t));
  $$('.ipanel', insp).forEach(p => p.hidden = p.dataset.tab !== key);
  insp.style.setProperty('--iw', t.dataset.w + 'px');
}
$$('.insp').forEach(insp => {
  $$('.itab', insp).forEach(t => t.addEventListener('click', () => showTab(insp, t.dataset.tab)));
  $$('[data-goto]', insp).forEach(b => b.addEventListener('click', () => showTab(insp, b.dataset.goto)));
});
$$('.srow', winA).forEach(r => r.addEventListener('click', () => { if (r.classList.contains('draft')) return; $$('.srow', winA).forEach(x => x.classList.toggle('sel', x === r)); }));
$$('.tab', winA).forEach(t => t.addEventListener('click', e => { if (e.target.closest('.x')) return; $$('.tab', winA).forEach(x => x.classList.toggle('on', x === t)); }));
$$('.frow', winA).forEach(r => r.addEventListener('click', () => $$('.frow', winA).forEach(x => x.classList.toggle('on', x === r))));
$$('.agent', winA).forEach(r => r.addEventListener('click', () => $$('.agent', winA).forEach(x => x.classList.toggle('on', x === r))));

function closeAll() { $$('.pop.open, .palette.open, .scrim.open').forEach(e => e.classList.remove('open')); }
document.addEventListener('click', e => {
  const opener = e.target.closest('[data-open]');
  if (opener) {
    const win = opener.closest('.win'), id = opener.dataset.open, el = win && $(`[data-pop="${id}"]`, win);
    if (!el) return;
    const was = el.classList.contains('open');
    closeAll();
    if (!was) {
      el.classList.add('open');
      if (id === 'palette') { $('.scrim', win).classList.add('open'); const inp = $('input', el); inp.value = ''; filter(el, ''); setTimeout(() => inp.focus({ preventScroll: true }), 20); }
    }
    e.stopPropagation(); return;
  }
  if (!e.target.closest('.pop:not(.static), .palette:not(.static)')) closeAll();
});
function rows(pal) { return $$('.prow', pal).filter(r => !r.hidden); }
function filter(pal, q) {
  q = q.trim().toLowerCase();
  $$('.prow', pal).forEach(r => r.hidden = q && !r.textContent.toLowerCase().includes(q));
  $$('.pal-h', pal).forEach(h => { let n = h.nextElementSibling, any = false; while (n && !n.classList.contains('pal-h')) { if (!n.hidden) any = true; n = n.nextElementSibling; } h.hidden = !any; });
  $$('.prow', pal).forEach(r => r.classList.remove('cur'));
  const first = rows(pal)[0]; if (first) first.classList.add('cur');
}
const palA = $('.palette[data-pop="palette"]', winA);
$('input', palA).addEventListener('input', e => filter(palA, e.target.value));
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { closeAll(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); $('.search', winA).click(); return; }
  if (palA.classList.contains('open') && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
    e.preventDefault();
    const list = rows(palA), i = list.findIndex(r => r.classList.contains('cur'));
    const next = list[(i + (e.key === 'ArrowDown' ? 1 : -1) + list.length) % list.length];
    list.forEach(r => r.classList.toggle('cur', r === next));
  }
  if (palA.classList.contains('open') && e.key === 'Enter') closeAll();
});
$$('.prow', palA).forEach(r => r.addEventListener('mousemove', () => $$('.prow', palA).forEach(x => x.classList.toggle('cur', x === r))));
