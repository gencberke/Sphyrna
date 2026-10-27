/* ---------- the reference: its chapters, each a set of frames, and the state they share ---------- */
// Each chapter shows sections of the documents, in frames; a section is numbered by its chapter, and a document's rules lead its part unnumbered.
const CHAPTERS = [
  { id: 'ink4', title: 'Ink v4', text: 'The design language, approved on this reference (D-106): six rules, one control family at four heights, the tokens, the type and three elevations.',
    refs: ['DESIGN §0', 'D-105', 'D-106'], frames: [['v4', ['rules', 'controls', 'tokens']]] },
  { id: 'sidebar', title: 'The sidebar', text: 'The sidebar in its two views, on a plane one step lighter than the content: the search, the nav rows, the project heads and the session card, which carries the session\'s status.',
    refs: ['DESIGN §0.5', 'FB7-1', 'D-106'], frames: [['v4', ['sidebar']]] },
  { id: 'session', title: 'The session window', text: 'The window around a session: the header, the tab row, the terminal left untouched, the inspector and the status bar with its popover.',
    refs: ['DESIGN §0.5', 'D-75', 'D-100', 'D-106'], frames: [['v4', ['session']]] },
  { id: 'model', title: 'The model and the effort', text: 'Two pickers side by side: the model panel with search, a rail of harness marks and every model grouped by harness; and the effort menu with only the chosen model\'s levels.',
    refs: ['DESIGN §0.5', 'FB6-7', 'FB6-8', 'D-106'], frames: [['v4', ['model']]] },
  { id: 'pages', title: 'The draft and Home', text: 'The new-session question, its composer and its one model chip; then Home, with its first launch, its statement, its lists and the accounts in the status bar.',
    refs: ['DESIGN §0.2, §0.5', 'D-65', 'D-106'], frames: [['v4', ['pages']], ['edges', ['first']], ['remora', ['brief']]] },
  { id: 'project', title: 'Projects and new sessions', text: 'The project page with its tabs, narrow and empty.',
    refs: ['DESIGN §0.5', 'D-76'], frames: [['project', ['project', 'narrow']]] },
  { id: 'settings', title: 'Settings and About', text: 'One window with its sections as view tabs, Connections among them, and the tones as casts of Ink\'s greys.',
    refs: ['DESIGN §2, §3 Tones, §6', 'D-63', 'D-81', 'D-98', 'D-106'], frames: [['v4', ['connections']], ['settings', ['settings', 'tone']]] },
  { id: 'review', title: 'The review surfaces', text: 'The Changes tab and every state it has, the Agents tab and its transcripts, and the one family of sheets.',
    refs: ['DESIGN §4, §6 Sheets, §13, §14, §16', 'D-78'], frames: [['review', ['changes', 'states', 'agents', 'sheets']]] },
  { id: 'remora', title: 'Remora', text: 'Asking, the memory, and Remora\'s two doors beyond Home. It reads, answers, links and drafts; it never sends, starts or stops anything.',
    refs: ['DESIGN §8, §20', 'D-64', 'D-80'], frames: [['remora', ['asking', 'memory', 'beyond']]] },
  { id: 'edges', title: 'The edges', text: 'A session that has ended, the banners, and what shows outside the window: the menu bar, the notification, the Dock and the alerts.',
    refs: ['DESIGN §19', 'D-79'], frames: [['edges', ['ended', 'banners', 'outside']]] },
  { id: 'identity', title: 'Identity', text: 'The name, the app icon and the menu bar mark, and where they appear. From 1.6.0 the app is Sphyrna, the hammerhead\'s genus, and Home\'s assistant is Remora.',
    refs: ['DESIGN §6 Name and marks', 'D-77', 'D-83'], frames: [['identity', ['icon', 'inplace', 'menubar']]] }
];
const chaptersEl = $('#chapters'), nav = $('#refNav');

CHAPTERS.forEach((c, i) => {
  const n = String(i + 1).padStart(2, '0');
  const sec = document.createElement('section');
  sec.className = 'chapter'; sec.id = c.id;
  sec.innerHTML = `<div class="wrap"><div class="chead"><span class="num">${n}</span><h2>${c.title}</h2><p>${c.text}</p><div class="refs">${c.refs.map(r => `<span>${r}</span>`).join('')}</div></div></div>`;
  let k = 0;
  c.frames.forEach(([doc, only]) => {
    // 'rules' is a v3 preamble; in the v4 chapter it is the first real section.
    const nums = {}; only.filter(id => id !== 'rules' || doc === 'v4').forEach(id => nums[id] = `${n}.${++k}`);
    addFrame(sec, doc, only, { title: `${c.title}: ${only.join(', ')}`, nums });
  });
  chaptersEl.appendChild(sec);
  nav.insertAdjacentHTML('beforeend', `<a href="#${c.id}">${c.title}</a>`);
});
// The bar marks the chapter being read.
const seen = new IntersectionObserver(es => es.forEach(e => {
  if (e.isIntersecting) $$('#refNav a').forEach(a => a.classList.toggle('on', a.getAttribute('href') === '#' + e.target.id));
}), { rootMargin: '-45% 0px -50% 0px' });
$$('.chapter').forEach(c => seen.observe(c));
paintTools();
unpack().then(loadNext);
