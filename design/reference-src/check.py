"""Check the reference's repeated window contract without building Swift."""
from html.parser import HTMLParser
import re
import build


class Node:
    def __init__(self, tag, attrs=(), parent=None):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent
        self.children = []

    def has(self, cls):
        return cls in self.attrs.get('class', '').split()

    def all(self):
        for child in self.children:
            yield child
            yield from child.all()


class Tree(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.root = self.current = Node('root')
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs, self.current)
        self.current.children.append(node)
        if tag not in {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}:
            self.current = node

    def handle_endtag(self, tag):
        node = self.current
        while node.parent:
            if node.tag == tag:
                self.current = node.parent
                return
            node = node.parent


def check():
    windows = 0
    for name in build.DOCS:
        html = build.build_doc(name)
        assert '<!--PART:' not in html, f'{name}: unexpanded shared part'
        tree = Tree(html)
        for win in (n for n in tree.root.all() if n.has('win') or n.has('appwin')):
            windows += 1
            label = f'{name}/{win.attrs.get("id", "sample")}'
            kind = win.attrs.get('data-frame')
            assert kind in {'app', 'settings', 'crop', 'desktop'}, f'{label}: declare the frame kind'
            nodes = list(win.all())
            if kind == 'app':
                assert win.attrs.get('data-h') == '860', f'{label}: app frames are 860 high'
                assert sum(n.has('i4side') for n in nodes) == 1, f'{label}: one complete sidebar'
                assert sum(n.has('i4status') for n in nodes) == 1, f'{label}: one window-wide status bar'
                assert any(n.has('dhead') or n.has('phead') for n in nodes), f'{label}: missing title row'
                assert not any(n.has('chat') for n in nodes), f'{label}: frozen Chat face in a live window'
                for head in (n for n in nodes if n.has('dhead') and not n.has('bare') and not n.has('ref-pagehead')):
                    assert 'data-session-header' in head.attrs, f'{label}: session header bypasses the shared part'
                    models = [n for n in head.all() if n.has('session-model-readout')]
                    assert len(models) == 1 and models[0].tag == 'span', f'{label}: one read-only current-model readout'
                    assert not any(n.has('ref-choice') for n in head.all()), f'{label}: draft pickers do not belong in the session header'
                    assert not any(n.tag == 'button' for n in models[0].all()), f'{label}: current-model readout cannot imply mutation'
                    tabs = [n for n in nodes if 'data-session-tabs' in n.attrs]
                    assert len(tabs) == 1 and tabs[0].parent is head.parent, f'{label}: tabs must span the whole pane above the inspector'
            elif kind == 'settings':
                assert (win.attrs.get('data-w'), win.attrs.get('data-h')) == ('680', '520'), f'{label}: Settings size'
                assert not any(n.has('i4side') or n.has('i4status') for n in nodes), f'{label}: Settings is a separate window'
                tabs = [n.attrs.get('data-stab') for n in nodes if n.tag == 'button' and 'data-stab' in n.attrs]
                assert tabs == ['general', 'connections', 'theme', 'usage', 'sessions', 'remora', 'about'], f'{label}: Settings tabs differ'
            elif kind == 'crop':
                assert win.attrs.get('data-crop'), f'{label}: name the omitted frame parts'
        if name in {'v4', 'settings'}:
            assert build.read('shared/parts/connections.html') in html, f'{name}: use the complete shared Connections content'
            assert 'so it is not drawn twice' not in html, f'{name}: Connections is a placeholder'
            css = re.search(r'<style>(.*?)</style>', html, re.S)[1]
            for harness in ['opencode', 'agy', 'pi']:
                assert re.search(r'^\.hm\.' + harness + r'\{', css, re.M), f'{name}: {harness} mark must be shared, not scoped to the v4 chapter'
    print(f'reference: PASS ({windows} declared frames; app, Settings, crops and desktop)')


if __name__ == '__main__':
    check()
