/* ---------- the reference: its chapters, each a set of frames, and the state they share ---------- */
// Each chapter shows sections of the documents, in frames; a section is numbered by its chapter, and a document's rules lead its part unnumbered.
const CHAPTERS = [
  { id: 'ink4', title: 'Ink v4', text: 'Approved (D-106): two planes, one control family at four heights, three elevations, a lifted sidebar with a card that carries its status, a window-wide status bar, a model and effort panel, and Connections. Approved on this reference (D-106); the v3 tokens and their switch are gone.',
    refs: ['DESIGN-V4', 'D-105', 'FB7-1', 'FB7-2'], frames: [['v4', ['rules', 'controls', 'tokens', 'sidebar', 'session', 'model', 'connections', 'pages']]] },
  { id: 'identity', title: 'Identity', text: 'The name, the app icon and the menu bar mark, and where they appear. From 1.6.0 the app is Sphyrna, the hammerhead\'s genus, and Home\'s assistant is Remora.',
    refs: ['DESIGN §6 Name and marks', 'D-77', 'D-83'], frames: [['identity', ['rules', 'icon', 'inplace', 'menubar']]] },
  { id: 'language', title: 'The language', text: 'The tokens of Ink and Paper, the type, the colours and the parts every surface is made of.',
    refs: ['DESIGN §2–§4, §6', 'D-74', 'D-75', 'D-78', 'D-81'], frames: [['foundations', ['tokens', 'parts']]] },
  { id: 'school', title: 'The school', text: 'The sharks, drawn in ASCII by one engine: who they are, where they swim and how they move.',
    refs: ['DESIGN §17', 'D-77', 'D-79', 'D-80'], frames: [['foundations', ['school']]] },
  { id: 'session', title: 'The session window', text: 'The window around a session: on the terminal face with the CLI untouched, and in Chat with the stream, its requests, the composer and the asides.',
    refs: ['DESIGN §2, §6, §7, §11, §12, §15, §16', 'D-75'], frames: [['foundations', ['session']], ['chat', ['rules', 'session', 'requests', 'composer', 'asides', 'parts']]] },
  { id: 'home', title: 'Home', text: 'The first launch, the band with its one hammerhead, Needs you, and Remora\'s brief with its states.',
    refs: ['DESIGN §9, §17, §20', 'D-65', 'D-79', 'D-80'], frames: [['edges', ['first']], ['remora', ['brief']]] },
  { id: 'remora', title: 'Remora', text: 'Asking, the memory, and Remora\'s two doors beyond Home. It reads, answers, links and drafts; it never sends, starts or stops anything.',
    refs: ['DESIGN §8, §20', 'D-64', 'D-80'], frames: [['remora', ['rules', 'asking', 'memory', 'beyond']]] },
  { id: 'project', title: 'Projects and new sessions', text: 'The project page with its tabs, narrow and empty, and the new-session page, where the model picks the harness.',
    refs: ['DESIGN §8, §10', 'D-76'], frames: [['project', ['rules', 'project', 'new', 'narrow', 'parts']]] },
  { id: 'review', title: 'The review surfaces', text: 'The Changes tab and every state it has, the Agents tab and its transcripts, and the one family of sheets.',
    refs: ['DESIGN §4, §6 Sheets, §13, §14, §16', 'D-78'], frames: [['review', ['rules', 'changes', 'states', 'agents', 'sheets']]] },
  { id: 'settings', title: 'Settings and About', text: 'One window with its sections as view tabs, the tones as casts of Ink\'s greys, and Glass over the desktop.',
    refs: ['DESIGN §2, §3 Tones, §6', 'D-63', 'D-81'], frames: [['settings', ['rules', 'settings', 'tone', 'parts']]] },
  { id: 'edges', title: 'The edges', text: 'A session that has ended, the banners, and what shows outside the window: the menu bar, the notification, the Dock and the alerts.',
    refs: ['DESIGN §19', 'D-79'], frames: [['edges', ['rules', 'ended', 'banners', 'outside']]] }
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
// The chapter list scrolls sideways when it must; a fade says so, and disappears at its end.
const refNavEl = $('#refNav');
function paintNavFade() {
  if (!refNavEl) return;
  const end = refNavEl.scrollLeft + refNavEl.clientWidth >= refNavEl.scrollWidth - 1;
  refNavEl.classList.toggle('fade', refNavEl.scrollWidth > refNavEl.clientWidth + 1 && !end);
  refNavEl.classList.toggle('end', end);
}
refNavEl.addEventListener('scroll', paintNavFade, { passive: true });
addEventListener('resize', paintNavFade);
sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 560, depth: .62, speed: 17 }, { kind: 'thresher', L: 320, depth: .9, speed: 22 }, { kind: 'whale', L: 860, depth: .26, speed: 8 }] });
paintTools();
paintNavFade();
unpack().then(loadNext);
