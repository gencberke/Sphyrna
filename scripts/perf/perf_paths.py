"""Shared path conventions for scripts/perf (same rules as scripts/dev-paths.sh).

Everything the scripts create (run directories, copied fixtures) and the app
under test must live outside ~/Documents: run hosts are separate
TCC-responsible apps and block on a Documents consent prompt there.
"""
import datetime, hashlib, importlib.util, json, os, pathlib, sys

REPO = pathlib.Path(__file__).resolve().parents[2]
HOME = pathlib.Path.home()
DEV_ROOT = HOME / 'Library/Application Support/Loom-Dev'
DEFAULT_APP = DEV_ROOT / 'app/Loom Dev.app'
PROBE = DEV_ROOT / 'probe'
RUNS = PROBE / 'runs'
# Working directories of real-Claude runs. Outside HOME on purpose: Claude Code loads the CLAUDE.md of every ancestor
# folder of its working directory as project memory (also with an isolated CLAUDE_CONFIG_DIR), so a work dir under HOME
# would load the user's real ~/.claude/CLAUDE.md into the probe (spike S0).
WORK_ROOT = pathlib.Path('/private/tmp/loom-real')


def command_channel(directory):
    """Evidence command channel of one instance: distributed-notification name derived from the real path.
    Python side of the name; the Swift side is Sources/LoomLaunchOptions/LaunchOptions.swift and the shell side
    is scripts/dev-paths.sh `loom_command_channel`."""
    return 'local.loom.desktop.dev.command.' + hashlib.sha256(os.path.realpath(directory).encode()).hexdigest()[:16]


def default_run_dir(prefix):
    return RUNS / f"{prefix}-{datetime.datetime.now():%Y%m%dT%H%M%S}"


def refuse_documents(label, path):
    resolved = pathlib.Path(path).expanduser().resolve()
    documents = (HOME / 'Documents').resolve()
    if resolved == documents or documents in resolved.parents:
        raise SystemExit(
            f"{label} '{path}' is under ~/Documents. Run hosts are separate TCC-responsible apps and block on a "
            f"Documents consent prompt there. Use a path under ~/Library (default: {DEFAULT_APP.parent}).")
    return resolved


def trust_probe_workspace(claude_config, workspace):
    """Claude's folder-trust question defaults to "No, exit" (2.1.293), so Return would quit Claude: trust the fresh
    probe folder in the isolated profile instead of answering it. The external CLAUDE.md imports question that may follow
    is answered "No" in advance, which keeps the user's own imported rules out of the probe."""
    profile_json = pathlib.Path(claude_config).expanduser().resolve() / '.claude.json'
    if profile_json in (HOME / '.claude.json', HOME / '.claude' / '.claude.json'):
        raise SystemExit(f'{profile_json} is the user\'s real Claude profile; use the isolated probe profile.')
    profile = json.loads(profile_json.read_text()) if profile_json.exists() else {}
    entry = profile.setdefault('projects', {}).setdefault(str(pathlib.Path(workspace).resolve()), {})
    entry.update(hasTrustDialogAccepted=True, hasClaudeMdExternalIncludesApproved=False,
                 hasClaudeMdExternalIncludesWarningShown=True)
    tmp = profile_json.with_suffix('.json.perftmp'); tmp.write_text(json.dumps(profile, indent=2)); tmp.replace(profile_json)


def real_work_dir(claude_config, *parts):
    """A throwaway working directory for a real-Claude run: WORK_ROOT/<parts>, created and trusted in the isolated
    profile. Refuses a path under HOME (see WORK_ROOT)."""
    path = WORK_ROOT.joinpath(*parts)
    resolved = path.resolve()
    if resolved == HOME.resolve() or HOME.resolve() in resolved.parents:
        raise SystemExit(f'{path} is under HOME; a real-Claude work dir there loads the real ~/.claude/CLAUDE.md.')
    path.mkdir(parents=True, exist_ok=True)
    trust_probe_workspace(claude_config, path)
    return path


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def add_common_arguments(parser, prefix):
    parser.add_argument('--run-dir', type=pathlib.Path, default=None,
                        help=f'output directory (default: {RUNS}/{prefix}-<timestamp>; never under ~/Documents)')
    parser.add_argument('--app', type=pathlib.Path, required=True,
                        help='Loom Dev.app under test: a dedicated package under Loom-Dev/packages/<name>. '
                             f'Never the user\'s installed {DEFAULT_APP}.')


def resolve_common(args, prefix):
    app = refuse_documents('App path', args.app)
    if app.resolve() == DEFAULT_APP.resolve():
        sys.exit(f'{app} is the user\'s installed dev app; package a test copy under {DEV_ROOT / "packages"} instead.')
    run_dir = refuse_documents('Run directory', args.run_dir or default_run_dir(prefix))
    return app, run_dir
