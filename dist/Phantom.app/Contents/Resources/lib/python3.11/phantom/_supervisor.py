"""
Background playback supervisor for Phantom CLI.

Launched by `phantom run` as a detached process. Runs a workflow script
as a subprocess, tracks progress via status files, and handles looping.

State files are written to ~/Library/Application Support/Phantom/:
  - playback.pid         — this process's PID
  - playback.status.json — progress and state info
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


STATE_DIR = os.path.join(
    os.path.expanduser('~'),
    'Library', 'Application Support', 'Phantom',
)
PID_FILE = os.path.join(STATE_DIR, 'playback.pid')
STATUS_FILE = os.path.join(STATE_DIR, 'playback.status.json')

_child_proc = None


def _write_status(data):
    """Write status data to the status file."""
    data['updated_at'] = time.time()
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATUS_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f)
    os.replace(tmp, STATUS_FILE)


def _cleanup():
    """Remove PID file. Leave status file for final read."""
    try:
        os.unlink(PID_FILE)
    except OSError:
        pass


def _handle_sigterm(_signum, _frame):
    """Handle SIGTERM: kill child, update status, exit."""
    global _child_proc
    if _child_proc and _child_proc.poll() is None:
        try:
            _child_proc.terminate()
            _child_proc.wait(timeout=3)
        except Exception:
            try:
                _child_proc.kill()
            except Exception:
                pass

    _write_status({
        **_read_current_status(),
        'state': 'stopped',
    })
    _cleanup()
    sys.exit(0)


def _read_current_status():
    """Read current status file or return empty dict."""
    try:
        with open(STATUS_FILE, 'r') as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--filepath', required=True)
    parser.add_argument('--speed', type=float, default=1.0)
    parser.add_argument('--loop', type=int, default=1)
    parser.add_argument('--loop-delay', type=float, default=0)
    parser.add_argument('--skip-resolution', action='store_true')
    parser.add_argument('--skip-windows', action='store_true')
    args = parser.parse_args()

    # Register signal handler
    signal.signal(signal.SIGTERM, _handle_sigterm)

    # Write PID file
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

    # Parse workflow metadata
    meta = parse_workflow_metadata(args.filepath) or {}
    workflow_name = meta.get('name', os.path.basename(args.filepath))
    total_actions = meta.get('actions', 0)

    # Build workflow command
    cmd = [
        sys.executable, args.filepath,
        '--speed', str(args.speed),
        '--no-prompt', '--non-interactive', '--force',
    ]
    if args.skip_resolution:
        cmd.append('--skip-resolution')
    if args.skip_windows:
        cmd.append('--skip-windows')

    total_loops = args.loop  # 0 = infinite
    progress_re = re.compile(r'Progress:\s*(\d+)%\s*\((\d+)/(\d+)\)')

    base_status = {
        'workflow': workflow_name,
        'filename': os.path.basename(args.filepath),
        'speed': args.speed,
        'loop': total_loops,
        'loop_delay': args.loop_delay,
        'started_at': time.time(),
    }

    iteration = 0
    while True:
        iteration += 1

        # Check loop limit (0 = infinite)
        if total_loops > 0 and iteration > total_loops:
            break

        _write_status({
            **base_status,
            'state': 'running',
            'current_loop': iteration,
            'progress_pct': 0,
            'progress_current': 0,
            'progress_total': total_actions,
        })

        global _child_proc
        try:
            _child_proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )

            # Feed input for any prompts
            try:
                _child_proc.stdin.write('y\n\n')
                _child_proc.stdin.flush()
            except OSError:
                pass

            # Read stdout and parse progress
            for line in _child_proc.stdout:
                m = progress_re.search(line)
                if m:
                    _write_status({
                        **base_status,
                        'state': 'running',
                        'current_loop': iteration,
                        'progress_pct': int(m.group(1)),
                        'progress_current': int(m.group(2)),
                        'progress_total': int(m.group(3)),
                    })

            _child_proc.wait()
            exit_code = _child_proc.returncode
            _child_proc = None

            if exit_code != 0:
                _write_status({
                    **base_status,
                    'state': 'error',
                    'current_loop': iteration,
                    'exit_code': exit_code,
                })
                _cleanup()
                sys.exit(1)

        except Exception as e:
            _write_status({
                **base_status,
                'state': 'error',
                'current_loop': iteration,
                'message': str(e),
            })
            _cleanup()
            sys.exit(1)

        # Check if more loops remain
        next_needed = total_loops == 0 or iteration < total_loops
        if next_needed and args.loop_delay > 0:
            _write_status({
                **base_status,
                'state': 'waiting',
                'current_loop': iteration,
                'next_loop': iteration + 1,
                'progress_pct': 100,
                'progress_current': total_actions,
                'progress_total': total_actions,
            })
            time.sleep(args.loop_delay)

    # Done
    _write_status({
        **base_status,
        'state': 'completed',
        'current_loop': iteration,
        'progress_pct': 100,
        'progress_current': total_actions,
        'progress_total': total_actions,
    })
    _cleanup()


if __name__ == '__main__':
    main()
