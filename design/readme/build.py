"""Builds the README's pictures' pages, design/readme/<name>.html, from the Ink reference's documents.

Each picture is one window (or one part of a window) of a reference document, drawn by the reference's own CSS and
JavaScript (design/reference-src/), with neutral sample data in place of the reference's: no real project, branch,
session or name. The page sets the appearance, turns the art and the pins as the shot needs, shows the window alone on
a clear ground, and reports its size in data-shot-size, which scripts/release/readme-shots.sh reads before it renders
the PNG into assets/readme/. A page refuses to report a size while its window still shows a word from FORBIDDEN.

    python3 design/readme/build.py              # writes design/readme/<name>.html (the document travels compressed)
    python3 design/readme/build.py --plain DIR  # also writes each page uncompressed into DIR, for reading
"""
import base64, gzip, importlib.util, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__)) + '/'
_spec = importlib.util.spec_from_file_location('reference_build', HERE + '../reference-src/build.py')
REF = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(REF)

# ---------- the neutral sample data ----------
# The reference's sample sessions are the app's own development. Every page swaps them for these, everywhere in the
# document, so a window drawn by a script reads the same as one written in the markup.
NAMES = [
    ('Port the sidebar to Ink tokens', 'Add rate limits to checkout'),
    ('Review the gate failure', 'Review the failing deploy'),
    ('Release C health check', 'Nightly health check'),
    ('Remora spike S10', 'Search ranking spike'),
    ('Try a lighter inspector…', 'Try a lighter cart page…'),
    ('Weekly vault maintenance', 'Tag the new uploads'),
    ('Thesis outline', 'Playlist import'),
    ('Fix the side chat race', 'Fix the coupon rounding'),
    ('Map every sidebar token', 'Find every checkout route'),
    ('Port SidebarRow to Ink', 'Add the limiter middleware'),
    ('Find the footer tokens', 'Read the gateway config'),
    ("Check the tree colour's contrast", 'Check the limiter headers'),
    ('ui/ink-sidebar', 'feat/rate-limits'),
    ('Sources/LoomCatalogUI/SubagentRow.swift', 'src/middleware/rateLimit.ts'),
    ('Tests/LoomCatalogUITests/SubagentTreeTests.swift', 'test/rateLimit.test.ts'),
    ('Sources/LoomCatalogUI/Subagents/', 'src/middleware/'),
    ('Try the old sidebar spacing', 'Try the old cart layout'),
    ('Draw the Ink reference', 'Write the API changelog'),
    ('Sources/LoomCatalogUI/<span class="mhit">Sub</span>agentRow.swift', 'src/billing/<span class="mhit">Sub</span>scriptions.ts'),
    ('Tests/LoomCatalogUITests/<span class="mhit">Sub</span>agentTreeTests.swift', 'test/<span class="mhit">Sub</span>scriptions.test.ts'),
    ('Sources/LoomCatalogUI/<span class="mhit">Sub</span>agents/', 'src/billing/<span class="mhit">Sub</span>scriptions/'),
    ("'second-brain'", "'mixtape'"),
    ('>second-brain<', '>mixtape<'),
    ('second-brain · ', 'mixtape · '),
    ("name:'loom'", "name:'storefront'"),
    ("name: 'loom'", "name: 'storefront'"),
    ("p: 'loom'", "p: 'storefront'"),
    ('>loom<', '>storefront<'),
    ('loom · ', 'storefront · '),
    # Codex cannot be started in 1.6.0 (SPEC §1.2), so every sample session runs Claude Code.
    ("h:'codex'", "h:'claude'"),
    ("h: 'codex'", "h: 'claude'"),
    ("'codex')", "'claude')"),
    ('<span class="tx"><span class="hm codex"></span>', '<span class="tx"><span class="hm claude"></span>'),
]
# The project marks written in the markup: the reference's loom (orchid, L) and second-brain (aqua, S).
MARKS = [(r'(--tone:var\(--orchid\)"?[^<]*<span class="pmark[^"]*">)L<', r'\1S<'),
         (r'(--tone:var\(--aqua\)"?[^<]*<span class="pmark[^"]*">)S<', r'\1M<')]
# Words a picture may not show (checked on the window's text as drawn, case-insensitive).
FORBIDDEN = ['loom', 'second-brain', 'vault', 'thesis', 'gencberke', 'ink token', 'sidebar', 'remora spike', 'gate failure',
             'LoomCatalogUI', 'swift', 'D-7', 'D-8']

# ---------- the pictures ----------
# doc: the reference document; target: the element pictured; theme: dark (Ink) or light (Paper); art: the sharks swim;
# steps: clicks in order, by selector; css: extra rules for the picture; pad: the clear margin around it, for the shadow;
# text: replacements for this picture only, each found at least once; clip: [x, y, w, h] of the target, in points;
# swap: (start, end, part) puts parts/<part> in place of what lies between the first start and the next end.
SHOTS = {
    # the session on the Chat face beside the sidebar, while Claude works: the reference's frame A with a neutral transcript
    'window': dict(doc='chat', target='#winA', theme='dark', art=True, pad=28,
                   text=[('Then run the whole UI suite and list the three slowest tests.', 'Then run the whole suite and list the three slowest tests.')],
                   swap=[('<div class="scroller"><div class="col">\n', '              </div></div>\n              <div class="dock">', 'window-col.html')]),
    # the same session on the terminal face, as Claude Code draws it, with the inspector's Overview beside it
    'terminal': dict(doc='foundations', target='#winA', theme='dark', art=True, pad=28,
                     swap=[('<div class="term">', '</div>\n          </div>\n          <aside class="insp"', 'terminal-term.html')],
                     text=[('~/…/loom-v2/wt/ink', '~/code/storefront'),
                           ('<span class="f">LoomTheme+Sidebar.swift</span><span class="pm"><span class="add">+42</span><span class="del">−18</span>',
                            '<span class="f">checkout.ts</span><span class="pm"><span class="add">+3</span><span class="del">−1</span>'),
                           ('<span class="f">SidebarRow.swift</span><span class="pm"><span class="add">+31</span><span class="del">−12</span></span></div>\n'
                            '                <div class="mini"><span class="f">SidebarFooter.swift</span><span class="pm"><span class="add">+9</span><span class="del">−4</span></span></div>\n'
                            '                <div class="mini"><span class="f">SidebarInkTests.swift</span><span class="pm"><span class="add">+46</span>',
                            '<span class="f">rateLimit.ts</span><span class="pm"><span class="add">+38</span>')]),
    # the Front mark in the menu bar with its menu open: what needs you, what is working, and the commands
    'menu-bar': dict(doc='edges', target='#winD', theme='dark', art=False, pad=0, steps=['#mbMenu'], clip=[700, 0, 580, 290]),
    # a session's subagents in the inspector's Agents tab, one of them open and at work
    'agents': dict(doc='review', target='#winG', theme='dark', art=True, pad=28,
                   swap=[('const AGENTS0 = [\n', '\n];\nconst AG = ', 'agents-list.js')],
                   text=[('Now the subagent rows: one branch per row, and the last one curves. A subagent\'s own subagents branch one step further.',
                          'Add the limiter, and check the headers survive the gateway. Use subagents.'),
                         ('The guide has to run on for every ancestor that still has a sibling below, so it belongs to each row and not to the list.',
                          'The headers depend on the gateway, not the code, so that check can run beside the change.'),
                         ("I'll have one explorer check the tree colour's contrast while an implementer draws the branch shape. Two smaller ones map the offsets and the tests first.",
                          "I'll have one explorer check the headers while an implementer adds the limiter. Two smaller ones map the routes and the tests first."),
                         ('Sources/LoomCatalogUI/SubagentRow.swift  <span class="add">+24</span> <span class="del">−9</span>',
                          'src/middleware/rateLimit.ts  <span class="add">+38</span>'),
                         ('<b>implementer:</b> Draw each branch inside its row, so it scrolls with it',
                          '<b>implementer:</b> Add the limiter in its own file, keyed by the customer id')]),
    # Settings → Usage: the plan limits first, then where the tokens went; the window drawn taller to show the days
    'usage': dict(doc='settings', target='#winB', theme='dark', art=False, pad=28, steps=['#winB [data-stab=usage]'],
                  css='#winB{height:820px!important}'),
    # the Rising icon as the identity page draws it, masked into macOS's rounded square
    'icon': dict(doc='identity', target='#bigIcon', theme='dark', art=False, pad=0),
}

SHOT_JS = r"""
/* ---------- the README picture: one window alone, at 100 %, on a clear ground ---------- */
(() => {
  const S = __SHOT__, FORBIDDEN = __FORBIDDEN__;
  const q = s => document.querySelector(s);
  const flip = (s, want) => { const el = q(s); if (el && el.classList.contains('on') !== want) el.parentElement.click(); };
  const theme = q(`#themeSeg [data-theme-set="${S.theme}"]`); if (theme && !theme.classList.contains('on')) theme.click();
  flip('#swAmbient', !!S.art); flip('#swPins', false); flip('#swZoom', true);
  const fail = msg => { document.documentElement.dataset.shotError = msg; };
  for (const step of S.steps || []) { const el = q(step); if (!el) return fail('no step ' + step); el.click(); }
  const target = q(S.target);
  if (!target) return fail('no target ' + S.target);
  const css = document.createElement('style');
  css.textContent = 'html,body{background:transparent!important;margin:0!important;padding:0!important}html{overflow:hidden!important}body{overflow:visible!important}'
    + '.stage,.stage.zoomed{overflow:visible!important}' + (S.css || '');
  document.head.appendChild(css);
  document.body.querySelectorAll('*').forEach(el => {
    if (!el.contains(target) && !target.contains(el) && !/^(SCRIPT|STYLE)$/.test(el.tagName)) el.style.display = 'none';
  });
  function shoot() {
    const text = target.innerText.toLowerCase();
    const bad = FORBIDDEN.find(w => text.includes(w.toLowerCase()));
    if (bad) return fail('shows "' + bad + '"');
    if ((window.__errs || []).length) return fail('script error: ' + window.__errs[0]);
    const r = target.getBoundingClientRect(), c = S.clip || [0, 0, r.width, r.height], p = S.pad || 0;
    document.body.style.transformOrigin = '0 0';
    document.body.style.transform = `translate(${p - r.left - c[0]}px, ${p - r.top - c[1]}px)`;
    document.documentElement.dataset.shotSize = `${Math.ceil(c[2] + 2 * p)}x${Math.ceil(c[3] + 2 * p)}`;
  }
  addEventListener('load', () => setTimeout(shoot, 400));
})();
"""

LOADER = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<!-- Generated by design/readme/build.py from design/reference-src/; do not edit. Rendered by scripts/release/readme-shots.sh. -->
</head>
<body>
<script type="text/plain" id="doc">{payload}</script>
<script>
(async () => {{
  const bytes = Uint8Array.from(atob(document.getElementById('doc').textContent.trim()), c => c.charCodeAt(0));
  const html = await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).text();
  document.open(); document.write(html); document.close();
}})();
</script>
</body>
</html>
"""


def neutral(html):
    for old, new in NAMES:
        html = html.replace(old, new)
    for pat, new in MARKS:
        html = re.sub(pat, new, html)
    return html


def page(name, shot):
    html = REF.build_doc(shot['doc'])
    for start, end, part in shot.get('swap', []):
        a = html.index(start) + len(start)
        b = html.index(end, a)
        html = html[:a] + open(HERE + 'parts/' + part, encoding='utf-8').read() + html[b:]
    for old, new in shot.get('text', []):
        assert old in html, (name, old[:80])
        html = html.replace(old, new)
    html = neutral(html)
    conf = {k: shot[k] for k in ('target', 'theme', 'art', 'steps', 'css', 'pad', 'clip') if k in shot}
    js = SHOT_JS.replace('__SHOT__', json.dumps(conf)).replace('__FORBIDDEN__', json.dumps(FORBIDDEN))
    at = html.rindex('<script>\n/* ---------- the bridge')
    return html[:at] + '<script>' + js + '</script>\n' + html[at:]


def main():
    plain = sys.argv[sys.argv.index('--plain') + 1] if '--plain' in sys.argv else None
    if plain:
        os.makedirs(plain, exist_ok=True)
    for name, shot in SHOTS.items():
        html = page(name, shot)
        if plain:
            open(os.path.join(plain, name + '.html'), 'w', encoding='utf-8').write(html)
        payload = base64.b64encode(gzip.compress(html.encode('utf-8'), 9, mtime=0)).decode()
        out = LOADER.format(title=f'Sphyrna · README · {name}', payload=payload)
        open(HERE + name + '.html', 'w', encoding='utf-8').write(out)
        print(f'{name:10s} {len(out) // 1024:4d} KB')


if __name__ == '__main__':
    main()
