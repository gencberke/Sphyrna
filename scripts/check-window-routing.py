"""Exercise check.sh's real argument routing with a recording Swift stub; no Swift or window test runs."""
from pathlib import Path
import json, os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parent.parent

def probe(flags):
    with tempfile.TemporaryDirectory(prefix='loom-check-routing-', dir='/private/tmp') as tmp:
        fixture = Path(tmp)
        for name in ['check.sh', 'dev-paths.sh', 'with-build-slot.sh', 'check-theme-literals.sh', 'check-user-wording.sh', 'check-user-wording.allow', 'check-selectable-labels.sh', 'test-ledger.py', 'release/allowlist.sh']:
            src = root/'scripts'/name
            dst = fixture/'scripts'/name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src,dst)
        # The guards read the real Sources/ and Tests/; the fixture has neither, and routing is what it checks.
        for name in ['check-source-guards.py', 'check-tests.py']:
            (fixture/'scripts'/name).write_text('print("guard stub")\n')
        for name in ['LoomCatalogUI', 'loom-app', 'LoomCore', 'LoomChat', 'LoomLaunchOptions', 'LoomRemora']:
            (fixture/'Sources'/name).mkdir(parents=True)
            (fixture/'Sources'/name/'Fixture.swift').write_text('// Isolated routing fixture.\n')
        (fixture/'bin').mkdir()
        stub=fixture/'bin/swift'
        stub.write_text('#!'+sys.executable+'\nimport json,os,sys\nwith open(os.environ["LOOM_ROUTING_CAPTURE"],"a") as f:f.write(json.dumps(sys.argv[1:])+"\\n")\nif sys.argv[1]=="test":\n print("Test run started.")\n print("Test run with 0 tests passed after 0.001 seconds.")\n')
        stub.chmod(0o755)
        subprocess.run(['git','init','-q',tmp],check=True,capture_output=True)
        capture=fixture/'swift-args.jsonl'
        env=dict(os.environ,PATH=str(fixture/'bin')+os.pathsep+os.environ['PATH'],LOOM_ROUTING_CAPTURE=str(capture),LOOM_BUILD_LOCK=str(fixture/'slot.lock'),LOOM_CHECK_LOG_DIR=str(fixture/'logs'))
        p=subprocess.run([str(fixture/'scripts/check.sh'),'--scratch',str(fixture/'build'),'--suite','InspectorResizeWindowTests',*flags],cwd=tmp,env=env,capture_output=True,text=True)
        calls=[json.loads(x) for x in capture.read_text().splitlines()] if capture.exists() else []
        tests=[a for a in calls if a and a[0]=='test']
        return p.returncode,tests,p.stdout+p.stderr

code,calls,output=probe([])
assert code==0,output
assert len(calls)==1,calls
args=calls[0]
pairs=list(zip(args,args[1:]))
assert ('--skip','WindowEventTests') in pairs, f'FAIL: offscreen check passes {args!r} to Swift without skipping the shown-window namespace'
print('PASS: ordinary --suite routes the complete WindowEventTests namespace to --skip (recording Swift stub)')
code,calls,output=probe(['--windows'])
assert code==2 and not calls,(code,calls,output)
print('PASS: --windows without --idle is refused before Swift is called')
code,calls,output=probe(['--windows','--idle'])
assert code==0 and len(calls)==1,(code,calls,output)
assert not any(a=='--skip' for a in calls[0]),calls
print('PASS: the explicit idle window route includes the namespace (recording Swift stub only)')
