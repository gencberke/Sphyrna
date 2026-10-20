/* ---------- the landing page: each thing Sphyrna does, said plainly, with its window from the reference ---------- */
const FEATURES = [
  { id: 'sessions', kicker: 'Sessions', doc: 'chat', section: 'session', title: 'Every session in one window',
    text: 'Projects and their sessions share one sidebar, each session with its state: working, waiting for you, finished and unread, or failed. Open one and it fills the window while the others keep running. In Chat, Claude\'s answer is the page, each tool step is one quiet line, and a finished turn folds its work into one.' },
  { id: 'terminal', kicker: 'The terminal', doc: 'foundations', section: 'session', title: 'Or the terminal, untouched',
    text: 'A session can also run on the terminal face, exactly as Claude Code draws it, with its own keys and commands. One setting chooses the face. Sphyrna draws the window around the session and nothing inside it.' },
  { id: 'requests', kicker: 'Requests', doc: 'chat', section: 'requests', title: 'Requests wait where you act',
    text: 'An approval, a question or a plan waits above the composer, one at a time, with its choices in reach. Return never answers it by accident, and the session keeps one line of what you chose.' },
  { id: 'changes', kicker: 'Changes', doc: 'review', section: 'changes', title: 'See what changed',
    text: 'The Changes tab shows what the last turn, the whole session or the branch changed. Comment on any line, and Send to Claude delivers the comments as one message. A subagent\'s transcript opens in the same place. Nothing is staged or committed for you.' },
  { id: 'remora', kicker: 'Remora', doc: 'remora', section: 'brief', title: 'Where you left off, in a few lines',
    text: 'Home opens with a short brief from Remora: what moved in your sessions since you last looked, with a tile for each project that moved. Ask it which session touched a file or what finished yesterday, from Home or ⌘K. Remora only reads: it links and drafts, and never sends, starts or stops anything.',
    fine: 'To answer, Remora sends short excerpts to Claude through your own Claude Code login. Its memory stays on your Mac, where you can see it and clear it.' },
  { id: 'projects', kicker: 'Projects', doc: 'project', section: 'project', title: 'A page for each project',
    text: 'A project\'s sessions, its branches and its CLAUDE.md, one tab each. Presets start the tasks you run often, and the past seven days sit beside the list.' },
  { id: 'theme', kicker: 'Theme', doc: 'settings', section: 'tone', title: 'Ink or Paper, in your tone',
    text: 'Dark or light, a neutral, warm or cool cast over every grey, and Glass if you want the desktop to show through the sidebar. Settings also shows your plan limits first, and offers stale sessions for cleanup: it deletes only the ones you check.' },
  { id: 'outside', kicker: 'Outside the window', doc: 'identity', section: 'inplace', title: 'It tells you when a session needs you',
    text: 'The menu bar mark, a notification and the Dock badge show which sessions wait for you, so you can work somewhere else and come back when it matters.' }
];
const featuresEl = $('#features');
FEATURES.forEach((f, i) => {
  const sec = document.createElement('section');
  sec.className = 'feat'; sec.id = f.id;
  sec.innerHTML = `<div class="wrap"><div class="fhead"><span class="num">${String(i + 1).padStart(2, '0')}</span><span class="kicker">${f.kicker}</span>`
    + `<h2>${f.title}</h2><p>${f.text}</p>${f.fine ? `<p class="fine">${f.fine}</p>` : ''}</div></div>`;
  addFrame(sec, f.doc, [f.section], { title: f.title, bare: true, height: 820 });
  featuresEl.appendChild(sec);
});
// Home's band: one hammerhead on its loop (D-79), in a strip of its own above the name.
loopHammer($('#ocean-band'));
unpack().then(loadNext);
