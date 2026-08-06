"""
Phantom CLI -- control Phantom from the command line.

Usage:
    phantom list
    phantom run <workflow> [--speed N] [--loop N] [--loop-delay N]
    phantom record
    phantom stop
    phantom status
    phantom delete <workflow>
    phantom rename <workflow> <new-name>

All commands output JSON to stdout for easy parsing by external tools.
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time

from .workflow import parse_workflow_metadata


# ---------- Paths ----------

WORKFLOWS_DIR = os.path.join(
    os.path.expanduser('~'),
    'Library', 'Application Support', 'Phantom', 'workflows',
)
STATE_DIR = os.path.join(
    os.path.expanduser('~'),
    'Library', 'Application Support', 'Phantom',
)
PID_FILE = os.path.join(STATE_DIR, 'playback.pid')
STATUS_FILE = os.path.join(STATE_DIR, 'playback.status.json')


# ---------- Output ----------

def _output(data, pretty=False):
    """Print result as JSON to stdout."""
    if pretty and data.get('status') == 'ok' and 'workflows' in data:
        _print_workflow_table(data['workflows'])
    print(json.dumps(data, indent=2 if pretty else None))


def _print_workflow_table(workflows):
    """Print a human-readable workflow table before the JSON."""
    if not workflows:
        print('No workflows found.\n')
        return
    print(f'{len(workflows)} workflow(s):\n')
    for w in workflows:
        name = w.get('name', '?')
        actions = w.get('actions', 0)
        duration = w.get('duration', 0)
        filename = w.get('filename', '')
        print(f'  {name:<30} {actions:>5} actions  {duration:>6.1f}s  {filename}')
    print()


# ---------- Workflow Resolution ----------

def _resolve_workflow(identifier):
    """Find a workflow by filename or name.

    Tries: exact filename, filename+.py, exact name match, partial name match.
    Returns (filepath, filename) or (None, None).
    """
    os.makedirs(WORKFLOWS_DIR, exist_ok=True)

    # Exact filename
    if identifier.endswith('.py'):
        filepath = os.path.join(WORKFLOWS_DIR, identifier)
        real = os.path.realpath(filepath)
        if os.path.isfile(real) and real.startswith(os.path.realpath(WORKFLOWS_DIR)):
            return filepath, identifier

    # Filename without .py
    candidate = identifier if identifier.endswith('.py') else identifier + '.py'
    filepath = os.path.join(WORKFLOWS_DIR, candidate)
    real = os.path.realpath(filepath)
    if os.path.isfile(real) and real.startswith(os.path.realpath(WORKFLOWS_DIR)):
        return filepath, candidate

    # Search by name (case-insensitive exact, then partial)
    needle = identifier.lower()
    exact_match = None
    partial_match = None

    for filename in os.listdir(WORKFLOWS_DIR):
        if not filename.endswith('.py'):
            continue
        filepath = os.path.join(WORKFLOWS_DIR, filename)
        if not os.path.isfile(filepath):
            continue
        meta = parse_workflow_metadata(filepath)
        if meta is None:
            continue
        name_lower = meta.get('name', '').lower()
        if name_lower == needle and exact_match is None:
            exact_match = (filepath, filename)
        elif needle in name_lower and partial_match is None:
            partial_match = (filepath, filename)

    if exact_match:
        return exact_match
    if partial_match:
        return partial_match

    return None, None


# ---------- State File Helpers ----------

def _read_status():
    """Read the playback status file, or None."""
    try:
        with open(STATUS_FILE, 'r') as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _is_pid_alive(pid):
    """Check if a process with the given PID is running."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _cleanup_state_files():
    """Remove PID and status files."""
    for path in (PID_FILE, STATUS_FILE):
        try:
            os.unlink(path)
        except OSError:
            pass


def _get_python_executable():
    """Return the Python interpreter to use for running workflows.

    Prefers the bundled Python from Phantom.app (which has Accessibility
    permissions) over the system Python.
    """
    # If running inside the .app bundle, use the same interpreter
    if getattr(sys, 'frozen', None):
        return sys.executable

    # Check for Phantom.app installations
    for app_path in [
        '/Applications/Phantom.app',
        os.path.expanduser('~/Applications/Phantom.app'),
        os.path.join(os.path.dirname(__file__), '..', 'dist', 'Phantom.app'),
    ]:
        python_path = os.path.join(app_path, 'Contents', 'MacOS', 'python')
        if os.path.isfile(python_path):
            return python_path

    # Fallback to current Python (development mode)
    return sys.executable


def _env_for_python(python_exe):
    """Build the environment for launching a Python subprocess.

    The bundled Contents/MacOS/python helper resolves its stdlib against the
    build machine's Python framework unless PYTHONHOME/PYTHONPATH point at the
    bundle's Resources directory (the app stub sets these itself; a terminal
    invocation does not).
    """
    env = os.environ.copy()
    marker = os.path.join('Contents', 'MacOS', 'python')
    if python_exe.endswith(marker):
        resources = os.path.join(
            python_exe[: -len(marker)], 'Contents', 'Resources'
        )
        if os.path.isdir(resources):
            env['PYTHONHOME'] = resources
            env['PYTHONPATH'] = resources
    return env


def _find_app_bundle():
    """Find the Phantom.app bundle path, or None."""
    for app_path in [
        '/Applications/Phantom.app',
        os.path.expanduser('~/Applications/Phantom.app'),
        os.path.join(os.path.dirname(__file__), '..', 'dist', 'Phantom.app'),
    ]:
        if os.path.isdir(app_path):
            return os.path.abspath(app_path)
    return None


# ---------- Commands ----------

def cmd_list():
    """List all saved workflows."""
    os.makedirs(WORKFLOWS_DIR, exist_ok=True)
    workflows = []

    try:
        for filename in os.listdir(WORKFLOWS_DIR):
            if not filename.endswith('.py'):
                continue
            filepath = os.path.join(WORKFLOWS_DIR, filename)
            if not os.path.isfile(filepath):
                continue
            meta = parse_workflow_metadata(filepath)
            if meta is None:
                continue
            meta['filename'] = filename
            try:
                meta['mtime'] = os.path.getmtime(filepath)
            except OSError:
                meta['mtime'] = 0
            workflows.append(meta)
    except OSError as e:
        return {'status': 'error', 'message': str(e)}

    workflows.sort(key=lambda w: w['mtime'], reverse=True)
    return {'status': 'ok', 'count': len(workflows), 'workflows': workflows}


def cmd_run(identifier, speed=1.0, loop=1, loop_delay=0,
            skip_resolution=False, skip_windows=False):
    """Launch a workflow via the background supervisor."""
    filepath, filename = _resolve_workflow(identifier)
    if filepath is None:
        return {'status': 'error', 'message': f'Workflow not found: {identifier}'}

    meta = parse_workflow_metadata(filepath)

    # Check if something is already running
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, 'r') as f:
                pid = int(f.read().strip())
            if _is_pid_alive(pid):
                return {
                    'status': 'error',
                    'message': 'A workflow is already running. Use "phantom stop" first.',
                }
        except (ValueError, OSError):
            pass
        _cleanup_state_files()

    # Launch the supervisor as a detached process
    python_exe = _get_python_executable()
    supervisor_cmd = [
        python_exe, '-m', 'phantom._supervisor',
        '--filepath', os.path.abspath(filepath),
        '--speed', str(speed),
        '--loop', str(loop),
        '--loop-delay', str(loop_delay),
    ]
    if skip_resolution:
        supervisor_cmd.append('--skip-resolution')
    if skip_windows:
        supervisor_cmd.append('--skip-windows')

    proc = subprocess.Popen(
        supervisor_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=_env_for_python(python_exe),
    )

    workflow_name = meta.get('name', filename) if meta else filename
    return {
        'status': 'started',
        'pid': proc.pid,
        'workflow': workflow_name,
        'filename': filename,
    }


def cmd_record():
    """Launch Phantom GUI for recording."""
    app_path = _find_app_bundle()
    if app_path:
        subprocess.Popen(['open', '-a', app_path])
        return {'status': 'launching', 'mode': 'app_bundle', 'path': app_path}

    # Development mode: launch GUI in-process (will block)
    from .app import main as gui_main
    gui_main()
    return {'status': 'completed', 'mode': 'development'}


def cmd_stop():
    """Stop the currently running workflow."""
    if not os.path.exists(PID_FILE):
        return {'status': 'not_running'}

    try:
        with open(PID_FILE, 'r') as f:
            pid = int(f.read().strip())
    except (ValueError, OSError):
        _cleanup_state_files()
        return {'status': 'not_running'}

    if not _is_pid_alive(pid):
        _cleanup_state_files()
        return {'status': 'not_running'}

    # Send SIGTERM to the process group (supervisor + workflow child)
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Fallback: signal just the supervisor
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    # Brief wait for cleanup
    for _ in range(10):
        if not _is_pid_alive(pid):
            break
        time.sleep(0.1)

    _cleanup_state_files()
    return {'status': 'stopped'}


def cmd_status():
    """Check playback status."""
    if not os.path.exists(PID_FILE):
        return {'status': 'idle'}

    try:
        with open(PID_FILE, 'r') as f:
            pid = int(f.read().strip())
    except (ValueError, OSError):
        _cleanup_state_files()
        return {'status': 'idle'}

    alive = _is_pid_alive(pid)
    status_data = _read_status()

    if not alive:
        state = status_data.get('state', 'unknown') if status_data else 'unknown'
        result = {'status': 'finished', 'last_state': state}
        if status_data:
            result.update(status_data)
        _cleanup_state_files()
        return result

    if status_data:
        elapsed = time.time() - status_data.get('started_at', time.time())
        return {
            'status': status_data.get('state', 'running'),
            'elapsed': round(elapsed, 1),
            **status_data,
        }

    return {'status': 'running', 'pid': pid}


def cmd_delete(identifier):
    """Delete a workflow."""
    filepath, filename = _resolve_workflow(identifier)
    if filepath is None:
        return {'status': 'error', 'message': f'Workflow not found: {identifier}'}

    try:
        os.unlink(filepath)
        return {'status': 'deleted', 'filename': filename}
    except OSError as e:
        return {'status': 'error', 'message': str(e)}


# Basic macOS virtual-key code → label map (subset of common keys)
_KEYCODES = {
    0: 'a', 1: 's', 2: 'd', 3: 'f', 4: 'h', 5: 'g', 6: 'z', 7: 'x',
    8: 'c', 9: 'v', 11: 'b', 12: 'q', 13: 'w', 14: 'e', 15: 'r',
    16: 'y', 17: 't', 18: '1', 19: '2', 20: '3', 21: '4', 22: '6',
    23: '5', 24: '=', 25: '9', 26: '7', 27: '-', 28: '8', 29: '0',
    30: ']', 31: 'o', 32: 'u', 33: '[', 34: 'i', 35: 'p', 36: 'return',
    37: 'l', 38: 'j', 39: "'", 40: 'k', 41: ';', 42: '\\', 43: ',',
    44: '/', 45: 'n', 46: 'm', 47: '.', 48: 'tab', 49: 'space',
    50: '`', 51: 'delete', 53: 'escape', 55: 'cmd', 56: 'shift',
    57: 'caps', 58: 'option', 59: 'ctrl', 60: 'rshift', 61: 'roption',
    62: 'rctrl', 63: 'fn', 76: 'enter', 96: 'f5', 97: 'f6', 98: 'f7',
    99: 'f3', 100: 'f8', 101: 'f9', 103: 'f11', 109: 'f10', 111: 'f12',
    115: 'home', 116: 'pgup', 117: 'fwddel', 118: 'f4', 119: 'end',
    120: 'f2', 121: 'pgdown', 122: 'f1', 123: '←', 124: '→',
    125: '↓', 126: '↑',
}


def _decode_mods(flags):
    """Decode CGEventFlags bitmask to modifier name list."""
    parts = []
    if flags & (1 << 20): parts.append('Shift')
    if flags & (1 << 22): parts.append('Ctrl')
    if flags & (1 << 23): parts.append('Opt')
    if flags & (1 << 24): parts.append('Cmd')
    return parts


def _describe_event(ev):
    """Convert a raw event tuple to a human-readable string."""
    t = ev[0]
    kind = ev[1]
    ts = f'{t:.2f}s'

    if kind == 'move':
        return f'{ts}  move  ({ev[2]}, {ev[3]})'
    elif kind == 'left_down':
        return f'{ts}  ↓ left  ({ev[2]}, {ev[3]})'
    elif kind == 'left_up':
        return f'{ts}  ↑ left  ({ev[2]}, {ev[3]})'
    elif kind == 'right_down':
        return f'{ts}  ↓ right  ({ev[2]}, {ev[3]})'
    elif kind == 'right_up':
        return f'{ts}  ↑ right  ({ev[2]}, {ev[3]})'
    elif kind == 'drag':
        return f'{ts}  drag  ({ev[2]}, {ev[3]})'
    elif kind == 'right_drag':
        return f'{ts}  right drag  ({ev[2]}, {ev[3]})'
    elif kind == 'middle_down':
        return f'{ts}  ↓ middle  ({ev[2]}, {ev[3]})'
    elif kind == 'middle_up':
        return f'{ts}  ↑ middle  ({ev[2]}, {ev[3]})'
    elif kind in ('key_down', 'key_up'):
        kc = ev[2]
        mods = ev[3]
        key_name = _KEYCODES.get(kc, f'key{kc}')
        mod_parts = _decode_mods(mods)
        key_str = '+'.join(mod_parts + [key_name]) if mod_parts else key_name
        arrow = '↓' if kind == 'key_down' else '↑'
        return f'{ts}  {arrow} key  {key_str}'
    elif kind == 'scroll':
        return f'{ts}  scroll  ({ev[2]}, {ev[3]})  dx={ev[4]} dy={ev[5]}'
    else:
        return f'{ts}  {kind}  {ev[2:]}'


def cmd_inspect(identifier):
    """Read and describe events from a workflow file."""
    import ast as _ast

    filepath, filename = _resolve_workflow(identifier)
    if filepath is None:
        return {'status': 'error', 'message': f'Workflow not found: {identifier}'}

    meta = parse_workflow_metadata(filepath)

    try:
        with open(filepath, 'r') as f:
            source = f.read()
    except OSError as e:
        return {'status': 'error', 'message': str(e)}

    # Parse the source and find the EVENTS assignment
    try:
        tree = _ast.parse(source)
    except SyntaxError as e:
        return {'status': 'error', 'message': f'Parse error: {e}'}

    events_node = None
    for node in _ast.walk(tree):
        if isinstance(node, _ast.Assign):
            for target in node.targets:
                if isinstance(target, _ast.Name) and target.id == 'EVENTS':
                    events_node = node.value
                    break
        if events_node is not None:
            break

    if events_node is None:
        return {'status': 'error', 'message': 'No EVENTS found in workflow'}

    try:
        events = _ast.literal_eval(_ast.unparse(events_node))
    except Exception as e:
        return {'status': 'error', 'message': f'Failed to parse EVENTS: {e}'}

    readable = [_describe_event(ev) for ev in events]

    return {
        'status': 'ok',
        'filename': filename,
        'metadata': meta,
        'events': readable,
        'count': len(readable),
    }


def cmd_rename(identifier, new_name):
    """Rename a workflow by updating its docstring metadata."""
    filepath, filename = _resolve_workflow(identifier)
    if filepath is None:
        return {'status': 'error', 'message': f'Workflow not found: {identifier}'}

    try:
        with open(filepath, 'r') as f:
            content = f.read()

        safe_name = re.sub(r'[\r\n\t]+', ' ', str(new_name)).strip()
        # Function replacement: avoids re.sub interpreting backslashes
        # or group references in the user-supplied name.
        new_content = re.sub(
            r'^(Workflow:\s*)(.+)$',
            lambda m: m.group(1) + safe_name,
            content,
            count=1,
            flags=re.MULTILINE,
        )
        with open(filepath, 'w') as f:
            f.write(new_content)

        meta = parse_workflow_metadata(filepath)
        if meta:
            meta['filename'] = filename
        return {'status': 'ok', 'metadata': meta}
    except OSError as e:
        return {'status': 'error', 'message': str(e)}


# ---------- Main ----------

def cli_main():
    """Entry point for the Phantom CLI."""
    parser = argparse.ArgumentParser(
        prog='phantom',
        description='Phantom CLI — control Phantom from the command line.',
    )
    parser.add_argument(
        '--pretty', action='store_true',
        help='Include human-readable output alongside JSON',
    )
    sub = parser.add_subparsers(dest='command')

    # phantom list
    sub.add_parser('list', help='List saved workflows')

    # phantom run
    p_run = sub.add_parser('run', help='Run a workflow')
    p_run.add_argument('workflow', help='Workflow name or filename')
    p_run.add_argument('--speed', type=float, default=1.0,
                       help='Playback speed multiplier')
    p_run.add_argument('--loop', type=int, default=1,
                       help='Number of times to loop (0 = infinite)')
    p_run.add_argument('--loop-delay', type=float, default=0,
                       help='Seconds to wait between loops')
    p_run.add_argument('--skip-resolution', action='store_true',
                       help='Skip resolution matching')
    p_run.add_argument('--skip-windows', action='store_true',
                       help='Skip window arrangement restoration')

    # phantom record
    sub.add_parser('record', help='Open Phantom for recording')

    # phantom stop
    sub.add_parser('stop', help='Stop current playback')

    # phantom status
    sub.add_parser('status', help='Check playback status')

    # phantom delete
    p_del = sub.add_parser('delete', help='Delete a workflow')
    p_del.add_argument('workflow', help='Workflow name or filename')

    # phantom rename
    p_ren = sub.add_parser('rename', help='Rename a workflow')
    p_ren.add_argument('workflow', help='Workflow name or filename')
    p_ren.add_argument('new_name', help='New name for the workflow')

    # phantom inspect
    p_ins = sub.add_parser('inspect', help='Show events in a workflow')
    p_ins.add_argument('workflow', help='Workflow name or filename')

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(1)

    # Dispatch
    if args.command == 'list':
        result = cmd_list()
    elif args.command == 'run':
        result = cmd_run(
            args.workflow,
            speed=args.speed,
            loop=args.loop,
            loop_delay=args.loop_delay,
            skip_resolution=args.skip_resolution,
            skip_windows=args.skip_windows,
        )
    elif args.command == 'record':
        result = cmd_record()
    elif args.command == 'stop':
        result = cmd_stop()
    elif args.command == 'status':
        result = cmd_status()
    elif args.command == 'delete':
        result = cmd_delete(args.workflow)
    elif args.command == 'rename':
        result = cmd_rename(args.workflow, args.new_name)
    elif args.command == 'inspect':
        result = cmd_inspect(args.workflow)
    else:
        parser.print_help()
        sys.exit(1)

    _output(result, pretty=args.pretty)

    # Exit with non-zero if error
    if result.get('status') == 'error':
        sys.exit(1)
