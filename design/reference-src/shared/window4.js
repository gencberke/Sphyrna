/* Repeated window parts. Their markup lives in shared/parts; every chapter gets the same chrome. */
$$('[data-session-header]').forEach(head => {
  const working = head.dataset.sessionHeader === 'work', state = $('[data-role=state]', head);
  state.classList.toggle('idle', !working);
  state.innerHTML = working ? `${mark('work')}Working <span class="mono">37s</span>` : 'Ready';
  if (head.dataset.sessionHeader === 'ended') {
    $('[data-role=pill]', head).innerHTML = '';
    $('[data-role=cgroup]', head).innerHTML = `<button class="more" title="More">${svg('more')}</button>`;
  }
  const host = head.closest('.appwin,.win');
  $('button[title=Inspector]', head).classList.toggle('on', !!host.querySelector('.insp,.i4insp'));
});
$$('[data-terminal-state=ready]').forEach(term => {
  $('[data-terminal-result]', term).textContent = '  ⎿  All 24 tests passed';
  $('[data-terminal-live]', term).innerHTML = '<span class="g">✓</span> Done · 4 files changed';
});
$$('[data-session-tabs]').forEach(tabs => {
  $('[data-role=tabmark]', tabs).innerHTML = tabs.dataset.sessionTabs === 'work' ? mark('work') : '';
});
$$('.swin').forEach(win => {
  const start = win.dataset.settingsStart || 'general';
  $$('.stabs [data-stab]', win).forEach(tab => {
    tab.classList.toggle('on', tab.dataset.stab === start);
    // Connections and Identity show one tab as context; the Settings chapter has all seven interactive panes.
    if (win.hasAttribute('data-settings-example') && tab.dataset.stab !== start) {
      tab.disabled = true;
      tab.title = 'See this tab in the Settings chapter';
    }
  });
  $$('.spane', win).forEach(pane => pane.hidden = pane.dataset.stab !== start);
});
const frameCaptions = new Map();
function frameCaption(win) {
  const kind = win.dataset.frame;
  const name = { app: 'App window', settings: 'Settings window', crop: 'Crop', desktop: 'macOS desktop' }[kind];
  const caption = frameCaptions.get(win) || document.createElement('p');
  caption.className = 'frame-caption';
  caption.textContent = `${name} · ${win.dataset.w} × ${win.dataset.h}`
    + (kind === 'crop' ? ` · ${win.dataset.crop}` : kind === 'settings' ? ' · separate window, without the app sidebar or status bar' : '');
  win.closest('.stage').after(caption);
  frameCaptions.set(win, caption);
}
$$('.win[data-frame]').forEach(frameCaption);
new MutationObserver(changes => changes.forEach(change => {
  if (frameCaptions.has(change.target)) frameCaption(change.target);
})).observe(document.body, { attributes: true, subtree: true, attributeFilter: ['data-w', 'data-h'] });
