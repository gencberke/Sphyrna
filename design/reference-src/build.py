"""Builds Sphyrna's Ink reference, design/reference.html, and its landing page, design/landing.html, from the parts in this folder.

Each document under docs/ is one page of the reference, assembled as the Ink previews were: the shared tokens and
parts, the document's own style and markup, then one script with the shared helpers, the art engine and the
document's own behaviour. The reference page holds every document and shows each in a frame of its own, so their
ids, styles and scripts never meet; the landing page shows one window from several of them, with plain copy around it.

    python3 design/reference-src/build.py            # writes design/reference.html and design/landing.html
    python3 design/reference-src/build.py --docs DIR # also writes each document on its own, for checks
"""
import base64, gzip, hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__)) + '/'
DESIGN = os.path.dirname(HERE.rstrip('/')) + '/'


def read(rel):
    return open(HERE + rel, encoding='utf-8').read().strip('\n')


def rep(s, old, new):
    assert s.count(old) == 1, (s.count(old), old[:80])
    return s.replace(old, new)


def data_url(rel):
    return 'data:image/png;base64,' + base64.b64encode(open(HERE + rel, 'rb').read()).decode()


HEAD = ('<!doctype html>\n<html lang="en" data-theme="dark"{html}>\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>{title}</title>\n'
        # errors are kept for the reference page and for checks
        '<script>window.__errs = []; addEventListener(\'error\', e => __errs.push(e.message + \' @\' + e.lineno + \':\' + e.colno));</script>\n'
        '<style>\n')

# A shark swimming in place, as the previews draw empty panes.
IN_PLACE = "const inPlace = (kind, L, cell) => ({ cell, fps: 12, alpha: .72, plankton: 0, wake: false, specs: [{ kind, L, depth: 1, speed: 0, fx: .5, fy: .5, angle: 0, center: true }] });\n"
LISTEN = ("document.addEventListener('visibilitychange', () => oceans.forEach(o => o.sync()));\n"
          "reduceMotion.addEventListener('change', () => oceans.forEach(o => o.sync()));\n")
DRAFT_SEA = "sea('ocean-draft', { cell: 11, alpha: .5, specs: [{ kind: 'hammerhead', L: 420, depth: .6, speed: 15 }, { kind: 'hammerhead', L: 270, depth: .95, speed: 21 }, { kind: 'whale', L: 760, depth: .24, speed: 7 }] });\n"


def build_doc(name):
    """One document of the reference, as a whole HTML page."""
    d = DOCS[name]
    css = ['shared/head.css'] + d['css'] + ['shared/media.css']
    style = HEAD.format(title=d['title'], html=d.get('html', '')) + '\n'.join(read(c) for c in css) + '\n</style>\n</head>\n'
    body = '\n\n'.join(read(b) for b in d['body'])
    body = rep(body, '<!--TOPBAR-->', read('shared/topbar.html'))
    for old, new in d.get('body_rep', []):
        body = rep(body, old, new() if callable(new) else new)
    parts = []
    for j in d['js']:
        parts.append(j[1:] if j.startswith('=') else read(j))
    js = '\n'.join(parts)
    for old, new in d.get('js_rep', []):
        js = rep(js, old, new() if callable(new) else new)
    script = '<script>\n(() => {\n' + js + '\n})();\n</script>\n<script>\n' + read('shared/bridge.js') + '\n</script>\n</body>\n</html>\n'
    return style + body + '\n\n' + script


DOCS = {
    'v4': {
        'title': 'Sphyrna · Ink v4 · The proposal',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/settings.css', 'docs/v4/v4.css'],
        'body': ['docs/v4/body.html'],
        'js': ['shared/base.js', 'shared/engine.js', 'docs/v4/v4.js'],
    },
    'foundations': {
        'title': 'Sphyrna · Ink · Foundations',
        'css': ['shared/chat.css', 'shared/harness.css'],
        'body': ['docs/foundations/body.html'],
        'js': ['shared/base.js', 'shared/frame.js', 'shared/engine.js', 'docs/foundations/own.js'],
    },
    'chat': {
        'title': 'Sphyrna · Ink · The chat',
        'css': ['shared/chat.css', 'shared/harness.css'],
        'body': ['docs/chat/body.html'],
        'js': ['shared/base.js', 'shared/frame.js', 'shared/engine.js',
               "=sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 520, depth: .66, speed: 16 }, { kind: 'thresher', L: 300, depth: .9, speed: 23 }, { kind: 'whale', L: 820, depth: .26, speed: 8 }] });\n"
               + IN_PLACE + "sea('empty-side-a', inPlace('whale', 130, 6));\nsea('empty-agents-c', inPlace('hammerhead', 130, 6));\nsea('empty-side-p', inPlace('whale', 130, 6));\n" + LISTEN,
               'docs/chat/chat.js'],
        # the chat's session has one subagent at work and one finished
        'js_rep': [("""    { id:'ink', t:'Port the sidebar to Ink tokens', st:'work', h:'claude', meta:'now', subs:[
      { st:'work', type:'explorer', d:'Map every sidebar token', e:'2m' },
      { st:'work', type:'implementer', d:'Port SidebarRow to Ink', e:'now', subs:[
        { st:'work', type:'explorer', d:'Find the footer tokens', e:'now' } ] },
      { st:'done', type:'2 finished' } ] },""", """    { id:'ink', t:'Port the sidebar to Ink tokens', st:'work', h:'claude', meta:'now', subs:[
      { st:'work', type:'explorer', d:"Check the tree colour's contrast", e:'52s' },
      { st:'done', type:'1 finished' } ] },""")],
    },
    'project': {
        'title': 'Sphyrna · Ink · The project page',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/project.css'],
        'body': ['docs/project/body.html'],
        'js': ['shared/base.js', 'shared/frame.js', 'shared/engine.js',
               "=sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 540, depth: .64, speed: 16 }, { kind: 'whale', L: 840, depth: .26, speed: 8 }] });\n"
               + DRAFT_SEA + IN_PLACE + "sea('empty-proj', inPlace('hammerhead', 120, 6));\n" + LISTEN,
               'docs/project/project.js'],
    },
    'settings': {
        'title': 'Sphyrna · Ink · Settings and About',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/project.css', 'shared/settings.css', 'shared/sheets.css'],
        'body': ['docs/settings/body.html'],
        'js': ['shared/base.js', 'shared/frame.js', 'shared/engine.js',
               "=sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 520, depth: .66, speed: 16 }, { kind: 'whale', L: 820, depth: .26, speed: 8 }] });\n"
               + DRAFT_SEA + LISTEN,
               'docs/settings/settings.js'],
        'body_rep': [('<!--ICON-->', lambda: data_url('docs/edges/icon-256.png'))],
    },
    'review': {
        'title': 'Sphyrna · Ink · The review surfaces',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/project.css', 'shared/sheets.css', 'docs/review/review.css'],
        'body': ['docs/review/body.html'],
        'js': ['shared/base.js', 'shared/engine.js',
               "=sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 520, depth: .66, speed: 16 }, { kind: 'thresher', L: 300, depth: .9, speed: 20 }, { kind: 'whale', L: 820, depth: .26, speed: 8 }] });\n" + LISTEN,
               'docs/review/review.js'],
        'js_rep': [('<!--ICON128-->', lambda: data_url('docs/review/icon-128.png'))],
    },
    'edges': {
        'title': 'Sphyrna · Ink · The edges',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/project.css', 'docs/edges/edge.css'],
        'body': ['docs/edges/body.html'],
        'js': ['shared/base.js', 'shared/engine.js',
               "=sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 520, depth: .66, speed: 16 }, { kind: 'thresher', L: 300, depth: .9, speed: 20 }, { kind: 'whale', L: 820, depth: .26, speed: 8 }] });\n" + LISTEN,
               'shared/marks.js', 'shared/band.js', 'docs/edges/edge.js'],
        'js_rep': [('<!--ICON-->', lambda: data_url('docs/edges/icon-256.png'))],
    },
    'remora': {
        'title': 'Sphyrna · Ink · Remora',
        'css': ['shared/chat.css', 'shared/harness.css', 'shared/project.css', 'docs/remora/base.css', 'docs/remora/remora.css'],
        'body': ['docs/remora/top.html', 'docs/remora/sections.html'],
        'js': ['shared/base.js', 'shared/engine.js', "=document.addEventListener('visibilitychange', () => oceans.forEach(o => o.sync()));\n",
               'shared/iconart.js', 'docs/remora/remora.js'],
    },
    'identity': {
        'title': 'Sphyrna · Ink · Identity',
        'css': ['shared/settings.css', 'docs/identity/identity.css'],
        'body': ['docs/identity/body.html'],
        'js': ['shared/base.js', 'shared/engine.js', 'shared/iconart.js', 'shared/marks.js', 'docs/identity/identity.js'],
        # the identity page shows the reduced motion beside the full one, with a switch of its own
        'js_rep': [("const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');",
                    "const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');\n"
                    "// This page plays the motion even when macOS asks to reduce it; the top bar's Reduce Motion switch shows the reduced version.\n"
                    "let motionOff = false;\nconst motionReduced = () => motionOff;"),
                   ("!document.hidden && !this.opt.still", "!document.hidden && !motionReduced() && !this.opt.still")],
    },
}


def page(docs, name):
    """A page of frames, the reference or the landing page: its own bar and copy, with the documents it shows stored once each, in pieces."""
    p = PAGES[name]
    blocks, index = {}, {}
    shared = [read(r) for r in SHARED_PIECES] + [data_url(i) for i in SHARED_IMAGES]
    for doc in p['docs'] or docs:
        html, keys, pos = docs[doc], [], 0
        # cut the document at each shared piece it contains, so those pieces are stored once
        cuts = sorted((html.find(piece), piece) for piece in shared if piece and html.find(piece) >= 0)
        for at, piece in cuts:
            if at < pos:
                continue
            if at > pos:
                keys.append(store(blocks, html[pos:at]))
            keys.append(store(blocks, piece)); pos = at + len(piece)
        if pos < len(html):
            keys.append(store(blocks, html[pos:]))
        assert ''.join(blocks[k] for k in keys) == html, doc
        index[doc] = keys
    # the documents travel compressed, so the page stays small enough for every viewer (the app's browser pane opens up to 1 MB)
    payload = json.dumps({'blocks': blocks, 'docs': index}, ensure_ascii=False, separators=(',', ':'))
    payload = base64.b64encode(gzip.compress(payload.encode('utf-8'), compresslevel=9, mtime=0)).decode()
    body = read(p['body'])
    assert '<!--ICON-->' in body
    body = body.replace('<!--ICON-->', data_url('docs/edges/icon-256.png'))
    css = ['shared/head.css'] + p['css'] + ['shared/media.css']
    js = ['shared/base.js', 'shared/engine.js'] + p['js']
    return (HEAD.format(title=p['title'], html=p.get('html', '')) + '\n'.join(read(c) for c in css) + '\n</style>\n</head>\n' + body
            + '\n\n<script type="text/plain" id="ref-docs">' + payload + '</script>\n'
            + '<script>\n(() => {\n' + '\n'.join(read(j) for j in js) + '\n})();\n</script>\n</body>\n</html>\n')


PAGES = {
    # every document, chapter by chapter, with its notes and parts
    'reference.html': {'title': 'Sphyrna · Ink · Design reference', 'css': ['shell/shell.css'], 'body': 'shell/body.html',
                       'js': ['shell/frames.js', 'shell/shell.js'], 'docs': None},
    # one window for each thing Sphyrna does, from the same documents
    'landing.html': {'title': 'Sphyrna', 'css': ['landing/landing.css'], 'body': 'landing/body.html',
                     'js': ['shared/band.js', 'shell/frames.js', 'landing/landing.js'], 'docs': ['chat', 'foundations', 'review', 'remora', 'project', 'settings', 'identity']},
}


def store(blocks, text):
    key = hashlib.sha1(text.encode()).hexdigest()[:10]
    blocks[key] = text
    return key


SHARED_PIECES = ['shared/head.css', 'shared/chat.css', 'shared/harness.css', 'shared/project.css', 'shared/settings.css', 'shared/sheets.css',
                 'shared/base.js', 'shared/frame.js', 'shared/engine.js', 'shared/iconart.js', 'shared/marks.js', 'shared/band.js', 'shared/bridge.js']

SHARED_IMAGES = ['docs/edges/icon-256.png', 'docs/review/icon-128.png']


def main():
    docs = {name: build_doc(name) for name in DOCS}
    if '--docs' in sys.argv:
        out = sys.argv[sys.argv.index('--docs') + 1]
        os.makedirs(out, exist_ok=True)
        for name, html in docs.items():
            open(os.path.join(out, name + '.html'), 'w', encoding='utf-8').write(html)
    print('\n'.join(f'{n:14s} {len(h) // 1024:5d} KB' for n, h in docs.items()))
    for name in PAGES:
        html = page(docs, name)
        open(DESIGN + name, 'w', encoding='utf-8').write(html)
        print(f'{name:14s} {len(html) // 1024:5d} KB')


if __name__ == '__main__':
    main()
