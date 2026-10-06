#!/usr/bin/env python3
"""Models-free fixture only; no real provider command or raw envelope logging."""
import base64, json, os, pathlib, socket, struct, subprocess, tempfile, time, uuid

repo = pathlib.Path(__file__).resolve().parents[1]
run = pathlib.Path(os.environ.get('LOOM_OBSERVER_SMOKE_ROOT', str(pathlib.Path.home() / 'Library/Application Support/Loom-Dev/probe/runs' / ('observer-' + str(uuid.uuid4())))))
run.mkdir(parents=True, exist_ok=False)

class Client:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(5); self.s.connect(str(path)); self.id = 0
        self.s.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + base64.b64encode(b'0123456789abcdef') + b'\r\nSec-WebSocket-Version: 13\r\n\r\n')
        header = b''
        while not header.endswith(b'\r\n\r\n'): header += self.s.recv(1)
        assert b' 101 ' in header
    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.s.recv(n-len(data)); assert chunk; data += chunk
        return data
    def request(self, method, params):
        self.id += 1; raw = json.dumps(dict(id=self.id, method=method, params=params)).encode(); mask = b'1234'
        length = bytes([0x80 | len(raw)]) if len(raw) < 126 else b'\xfe' + struct.pack('!H', len(raw))
        self.s.sendall(b'\x81' + length + mask + bytes(v ^ mask[i % 4] for i,v in enumerate(raw)))
        while True:
            h = self.read(2); n = h[1] & 127
            if n == 126: n = struct.unpack('!H', self.read(2))[0]
            if n == 127: n = struct.unpack('!Q', self.read(8))[0]
            value = json.loads(self.read(n))
            if value.get('id') == self.id and 'method' not in value: return value

results = []
for mode in ['both','resume-only','neither','empty','different-turn','flood','disconnect','mismatch','timeout','pre-turn']:
    directory = run / mode; directory.mkdir(); state = directory / 'state'; state.mkdir()
    (state / 'codex-thread-fixture-thread.cwd').write_text(str(directory))
    short = tempfile.TemporaryDirectory(prefix='loom-observer-'); sock = pathlib.Path(short.name) / 's'
    env = dict(os.environ, LOOM_FAKE_STATE=str(state))
    if mode in ['mismatch','timeout','pre-turn']: env['LOOM_FAKE_OBSERVER_PREPARATION'] = mode
    server = subprocess.Popen([str(repo / '.build/debug/loom-fake-provider'),'app-server','--listen','unix://' + str(sock)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    probe = None; client = None
    try:
        deadline = time.monotonic() + 5
        while not sock.exists():
            assert time.monotonic() < deadline; time.sleep(.01)
        output = directory / 'output'
        probe = subprocess.Popen([str(repo / '.build/debug/loom-probe'), 'codex-observers','--enable-content-free-diagnostics',str(sock),'fixture-thread',str(output),'1'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        deadline = time.monotonic() + 6
        while not (output / 'ready.json').exists() and probe.poll() is None:
            assert time.monotonic() < deadline; time.sleep(.01)
        if mode not in ['mismatch','timeout']:
            assert (output / 'ready.json').exists()
            # Only the external fixture driver emits the test turn, after both ready acknowledgements.
            client = Client(sock)
            client.request('fixture/observerProbe',dict(threadId='fixture-thread',mode='empty' if mode == 'pre-turn' else mode))
        stdout, stderr = probe.communicate(timeout=8)
        snap = json.loads((output / 'snapshot.json').read_text())
        valid = mode in ['both','resume-only','neither']
        assert snap['comparisonWindowValid'] == valid, (mode,snap)
        if mode in ['mismatch','timeout']:
            assert probe.returncode != 0 and not (output / 'ready.json').exists()
        else:
            assert probe.returncode == 0
            audit = json.loads((state / 'observer-audit.json').read_text()); assert all(audit.values()), audit
        if valid:
            for name in ['A','B']:
                entries = snap[name]['entries']; requests = [e for e in entries if e['envelope']=='request' and e['routing']=='target-run']
                expected = mode == 'both' or (mode == 'resume-only' and name == 'B')
                assert bool(requests) == expected
                assert all(e['idType']=='number' for e in requests)
                assert any(e['decode']=='unknown-event' and e['method']=='other' for e in entries)
                assert any(e['method']=='serverRequest/resolved' and e['routing']=='target-run' for e in entries)
                assert any(e.get('threadMatch') is False and e['routing']=='unmatched' for e in entries)
        if mode == 'flood': assert snap['A']['dropped'] > 0 and snap['B']['dropped'] > 0
        if mode == 'disconnect': assert 'disconnect' in snap['A']['failures'] and 'disconnect' in snap['B']['failures']
        content = (output / 'snapshot.json').read_text() + stdout.decode() + stderr.decode()
        assert not any(secret in content for secret in ['private-','wrong-thread-canary','fixture-thread','diagnostic-turn'])
        results.append(dict(mode=mode,verified=True,comparisonWindowValid=valid,exit=probe.returncode))
    finally:
        if client: client.s.close()
        if probe and probe.poll() is None: probe.kill(); probe.wait()
        server.terminate(); server.wait(timeout=5); short.cleanup()
(run / 'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(dict(run=str(run),results=results),indent=2))
