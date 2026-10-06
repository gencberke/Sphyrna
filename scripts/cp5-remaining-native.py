#!/usr/bin/env python3
"""Prepare own Finder/link fixtures; validate redacted native observations.

No app launch, UI action, preferences, provider request, or process signal.
Main owns native execution. `--prepare <new absolute directory>` creates only
that exclusive directory. `--check <observations.json>` validates observations;
this does not establish that a human/native observation actually occurred.
"""
import argparse
import json
from pathlib import Path
import sys


def quote(path):
    return "'" + str(path).replace("'", "'\"'\"'") + "'"


def prepare(root):
    if not root.is_absolute():
        raise ValueError('Fixture directory must be absolute')
    probe = (Path.home() / 'Library/Application Support/Loom-Dev/probe').resolve()
    if root.resolve() == probe or not root.resolve().is_relative_to(probe):
        raise ValueError('Fixture directory must be strictly below the isolated Loom probe root')
    root.mkdir(parents=False, exist_ok=False)
    files = [root / 'first file.txt', root / "second ' file.txt", root / "folder ' with space"]
    files[0].write_text('CP5 own native file one\n')
    files[1].write_text('CP5 own native file two\n')
    files[2].mkdir()
    http = 'http://example.com/?loom-cp5-native=http'
    https = 'https://example.com/?loom-cp5-native=https'
    urls = [http, https, files[0].resolve().as_uri(), str(files[0].resolve())]
    labels = ['CP5_HTTP', 'CP5_HTTPS', 'CP5_LOCAL', 'CP5_ABSOLUTE']
    plan = {'fixtureRoot': str(root), 'finderSelection': [str(p) for p in files],
            'expectedQuotedInput': ' '.join(quote(p) for p in files),
            'linkFixtureArguments': ['native-links', str(files[0].resolve())],
            'linkLabels': dict(zip(labels, urls)), 'expectedLinkDestinations': urls,
            'absoluteLocalPath': str(files[0]), 'steps': [
        'Launch isolated evidence app with --evidence <dir> --data-root <dir>/data --fixture interactive; no model needed. Always name --data-root explicitly; send commands only through the per-instance channel (loom_send_command in scripts/dev-paths.sh).',
        'Select these three own items in Finder; drag the selection into focused Loom terminal.',
        'Capture native terminal before Return: all quoted paths in actual Finder order, no echo: completed-line output.',
        'Press native Return once: echo: contains exactly quoted paths in Finder order. Record before/after artifacts.',
        'For links, prepare fixtures strictly below ~/Library/Application Support/Loom-Dev/probe. Launch isolated evidence app with --evidence <dir> --data-root <dir>/data --fixture native-links <absolute own-file> using linkFixtureArguments; the fixture emits OSC8 bytes directly and stays alive for at most 300 seconds. Clipboard paste filters ESC and cannot supply this output.',
        'Inspect four separately rendered labels CP5_HTTP/CP5_HTTPS/CP5_LOCAL/CP5_ABSOLUTE against linkLabels; capture the native rendered terminal artifact. Native Cmd-click each label separately and record its actual destination.',
        'Observe CP5_RAW_PATH separately if the engine detects the unlinked absolute path. Missing raw-path detection remains unverified and is not inferred from CP5_ABSOLUTE OSC8 success.',
        'Record actual browser URL for HTTP and HTTPS, actual own file viewer/path for local links; Loom remains alive. Network response is irrelevant.',
        'In fake-provider working card (active/key window), record pulse with Reduce Motion off, then native System Settings on and pulse absent, then restore original preference.',
        'For real Claude manual denial, bind before/after selectedSessionID+selectedRunID; observe first exact own-marker Bash permission, choose native No once, then Waiting for you + empty selectedRequests + absent marker + no selectedIssue/stop failure. Record spent turn after native Return.',
        'Counts/turnComplete are absent from native snapshots: use independent tracker test/source evidence and explicitly leave native preservation unverified.',
        'Run requestedAppleXPCIsNeverSignaledAndScopeEmpties through main Swift check owner; do not infer A4 from another package or previous research.',
    ]}
    (root / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    return plan


def checks(observation):
    drop = observation.get('finderDrop', {})
    expected = drop.get('expectedPaths')
    ordered = drop.get('finderOrder')
    drop_ok = (isinstance(expected, list) and len(expected) == 3 and
               len(set(expected)) == 3 and isinstance(ordered, list) and
               sorted(ordered) == sorted(expected) and
               all(isinstance(p, str) and p.startswith('/') for p in expected) and
               drop.get('nativeFinderDrag') is True and drop.get('nativeReturn') is True and
               drop.get('beforeReturnCompletedLine') is False and
               drop.get('quotedInput') == ' '.join(quote(p) for p in ordered) and
               drop.get('afterReturnEcho') == 'echo: ' + ' '.join(quote(p) for p in ordered) and
               all(drop.get(k) for k in ('beforeArtifact', 'afterArtifact')))
    links = observation.get('links', [])
    required = {'http', 'https', 'file-url', 'absolute-path'}
    labels = {'http': 'CP5_HTTP', 'https': 'CP5_HTTPS',
              'file-url': 'CP5_LOCAL', 'absolute-path': 'CP5_ABSOLUTE'}
    link_ok = (isinstance(links, list) and len(links) == 4 and
               {item.get('kind') for item in links} == required and
               all(item.get('nativeLinkRendered') is True and item.get('renderedArtifact') and
                   item.get('label') == labels[item['kind']] and
                   item.get('nativeCmdClick') is True and item.get('expectedDestination') and
                   item.get('actualDestination') == item.get('expectedDestination') and
                   item.get('destinationArtifact') for item in links))
    motion = observation.get('reduceMotion', {})
    motion_ok = (motion.get('nativePreferenceObserved') is True and
                 motion.get('activeWorkingCard') is True and motion.get('offPulse') is True and
                 motion.get('onPulse') is False and motion.get('originalPreferenceRestored') is True and
                 motion.get('offVideoArtifact') and motion.get('onVideoArtifact'))
    denial = observation.get('claudeDenial', {})
    before, after = denial.get('before', {}).get('catalog', {}), denial.get('after', {}).get('catalog', {})
    denial_ok = (denial.get('realIsolatedProvider') is True and denial.get('nativeNo') is True and
                 denial.get('firstExactOwnCommand') is True and denial.get('markerAbsent') is True and
                 denial.get('submittedTurns') == 1 and denial.get('nativeArtifact') and
                 before.get('selectedSessionID') and before.get('selectedRunID') and
                 before.get('selectedIndicator') == 'Needs approval' and
                 before.get('selectedSessionID') == after.get('selectedSessionID') and
                 before.get('selectedRunID') == after.get('selectedRunID') and
                 after.get('selectedIndicator') == 'Waiting for you' and
                 after.get('selectedRequests') == [] and not after.get('selectedIssue') and
                 not after.get('selectedStopFailure'))
    return {name: bool(value) for name, value in [
        ('finderDrop', drop_ok), ('linkOpen', link_ok), ('reduceMotion', motion_ok),
        ('claudeManualDenialUI', denial_ok)]}


def self_test():
    assert not any(checks({}).values())
    paths = ['/tmp/own/first file', "/tmp/own/second ' file", '/tmp/own/folder']
    drop = {'expectedPaths': paths, 'finderOrder': paths, 'nativeFinderDrag': True,
            'nativeReturn': True, 'beforeReturnCompletedLine': False,
            'quotedInput': ' '.join(quote(p) for p in paths),
            'afterReturnEcho': 'echo: ' + ' '.join(quote(p) for p in paths),
            'beforeArtifact': 'before.png', 'afterArtifact': 'after.png'}
    assert checks({'finderDrop': drop})['finderDrop']
    for field, bad in [('nativeFinderDrag', False), ('beforeReturnCompletedLine', True),
                       ('quotedInput', 'unquoted'), ('finderOrder', paths[:2])]:
        assert not checks({'finderDrop': dict(drop, **{field: bad})})['finderDrop']
    labels = {'http': 'CP5_HTTP', 'https': 'CP5_HTTPS',
              'file-url': 'CP5_LOCAL', 'absolute-path': 'CP5_ABSOLUTE'}
    links = [{'kind': kind, 'label': labels[kind], 'nativeLinkRendered': True, 'renderedArtifact': 'rendered.png',
              'nativeCmdClick': True, 'expectedDestination': kind,
              'actualDestination': kind, 'destinationArtifact': kind + '.png'}
             for kind in ('http', 'https', 'file-url', 'absolute-path')]
    assert checks({'links': links})['linkOpen']
    assert not checks({'links': links[:3]})['linkOpen']
    assert not checks({'links': [dict(item, actualDestination='wrong') for item in links]})['linkOpen']
    assert not checks({'links': [dict(item, nativeLinkRendered=False) for item in links]})['linkOpen']
    assert not checks({'links': [dict(item, label='CP5_WRONG') for item in links]})['linkOpen']
    motion = {'nativePreferenceObserved': True, 'activeWorkingCard': True, 'offPulse': True,
              'onPulse': False, 'originalPreferenceRestored': True,
              'offVideoArtifact': 'off.mov', 'onVideoArtifact': 'on.mov'}
    assert checks({'reduceMotion': motion})['reduceMotion']
    assert not checks({'reduceMotion': dict(motion, onPulse=True)})['reduceMotion']
    before = {'selectedSessionID': 'own-session', 'selectedRunID': 'own-run',
              'selectedIndicator': 'Needs approval'}
    after = dict(before, selectedIndicator='Waiting for you', selectedRequests=[])
    denial = {'realIsolatedProvider': True, 'nativeNo': True, 'firstExactOwnCommand': True,
              'markerAbsent': True, 'submittedTurns': 1, 'nativeArtifact': 'denial.png',
              'before': {'catalog': before}, 'after': {'catalog': after}}
    assert checks({'claudeDenial': denial})['claudeManualDenialUI']
    assert not checks({'claudeDenial': dict(denial, markerAbsent=False)})['claudeManualDenialUI']
    assert not checks({'claudeDenial': dict(denial, after={'catalog': dict(after, selectedRunID='foreign')})})['claudeManualDenialUI']
    assert not checks({'claudeDenial': dict(denial, after={'catalog': dict(after, selectedIndicator='Finished')})})['claudeManualDenialUI']
    assert quote("/tmp/a'b") == "'/tmp/a'\"'\"'b'"
    return {'syntaxAndPureNegativeOracles': 'passed', 'nativeExecuted': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare', type=Path)
    group.add_argument('--check', type=Path)
    group.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.prepare:
        result = prepare(args.prepare)
    elif args.check:
        result = {'checks': checks(json.loads(args.check.read_text())),
                  'source': str(args.check), 'kind': 'main-supplied-native-observations',
                  'nativeTrackerCountsPreservation': 'unverified',
                  'rawAbsolutePathDetection': 'separate native observation required; OSC8 absolute target is not raw detection',
                  'OWN-A4': 'separate real run-scope test required'}
    else:
        result = self_test()
    print(json.dumps(result, indent=2))
    return 1 if args.check and not all(result['checks'].values()) else 0


if __name__ == '__main__':
    sys.exit(main())
