"""Shared path conventions for scripts/perf (same rules as scripts/dev-paths.sh).

Everything the scripts create (run directories, copied fixtures) and the app
under test must live outside ~/Documents: run hosts are separate
TCC-responsible apps and block on a Documents consent prompt there.
"""
import datetime, importlib.util, pathlib, sys

REPO = pathlib.Path(__file__).resolve().parents[2]
HOME = pathlib.Path.home()
DEV_ROOT = HOME / 'Library/Application Support/Loom-Dev'
DEFAULT_APP = DEV_ROOT / 'app/Loom Dev.app'
PROBE = DEV_ROOT / 'probe'
RUNS = PROBE / 'runs'


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
