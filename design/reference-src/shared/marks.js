/* ---------- the menu bar mark: one colour, a 20 pt canvas, drawn as paths ----------
   Only M, L, C and Z, the commands the app's own path reader takes. Each string is one shape and its holes (even-odd). */
const circ = (cx, cy, r) => {
  const k = r * .5523;
  return `M${cx + r} ${cy}C${cx + r} ${cy + k} ${cx + k} ${cy + r} ${cx} ${cy + r}C${cx - k} ${cy + r} ${cx - r} ${cy + k} ${cx - r} ${cy}C${cx - r} ${cy - k} ${cx - k} ${cy - r} ${cx} ${cy - r}C${cx + k} ${cy - r} ${cx + r} ${cy - k} ${cx + r} ${cy}Z`;
};
const MARKS = {
  // Seen from the front: the hammer with an eye at each tip, the dorsal fin above, the jaw and the pectoral fins below.
  front: { name: 'Front', paths: [
    'M8.75 7.2C9.25 5.4 9.65 3.9 10 2.7C10.35 3.9 10.75 5.4 11.25 7.2Z',
    'M.95 8.85C.95 7.85 1.6 7.3 2.5 7.25C5.2 7.05 7.6 6.5 10 6.5C12.4 6.5 14.8 7.05 17.5 7.25C18.4 7.3 19.05 7.85 19.05 8.85C19.05 9.9 18.35 10.45 17.45 10.35C14.75 10.05 12.6 9.75 10 9.75C7.4 9.75 5.25 10.05 2.55 10.35C1.65 10.45 .95 9.9 .95 8.85Z' + circ(2.55, 8.8, .75) + circ(17.45, 8.8, .75),
    'M7.5 9.5C7.5 11.85 8.55 13.2 10 13.2C11.45 13.2 12.5 11.85 12.5 9.5Z',
    'M8.7 11C7.25 11.8 5.65 12.75 4.1 14.05C5.8 13.95 7.45 13.4 8.95 12.6Z',
    'M11.3 11C12.75 11.8 14.35 12.75 15.9 14.05C14.2 13.95 12.55 13.4 11.05 12.6Z'
  ] }
};
// The badge slot (LoomTheme.MenuBar): a 7 pt dot at (15.2, 13.8) cut 5.2 around; working draws the braille spinner there.
let markSeq = 0;
function markSVG(name, { badge = '', px = 20 } = {}) {
  const m = MARKS[name], id = 'mk' + (++markSeq);
  const cut = badge === 'work' ? circ(14.9, 13.6, 5.6) : badge ? circ(15.2, 13.8, 5.2) : '';
  const shapes = m.paths.map(d => `<path d="${d}" fill-rule="evenodd"/>`).join('');
  const body = cut ? `<mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="20" height="20"><rect width="20" height="20" fill="#fff"/><path d="${cut}" fill="#000"/></mask><g mask="url(#${id})">${shapes}</g>` : shapes;
  const mark = badge === 'work' ? `<text class="spin" x="14.9" y="17.3" text-anchor="middle">⠋</text>`
    : badge ? `<circle class="mbdot ${badge}" cx="15.2" cy="13.8" r="3.5"/>` : '';
  return `<svg class="mbmark" viewBox="0 0 20 20" width="${px}" height="${px}" fill="currentColor" aria-hidden="true">${body}${mark}</svg>`;
}
