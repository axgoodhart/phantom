"""
Workflow script generator.

Takes recorded events and an environment snapshot and produces a
self-contained Python script that can restore the environment and
replay all input events using CoreGraphics.
"""

import re
from datetime import datetime


def parse_workflow_metadata(filepath):
    """Read the docstring of a workflow .py file and extract metadata.

    Looks for the standard header format:
        Workflow: <name>
        Recorded: <timestamp>
        Resolution: <w> x <h>
        Actions: <count>
        Duration: <seconds>s

    Returns a dict with keys name, date, resolution, actions, duration,
    or None if the file is not a valid workflow script.
    """
    try:
        with open(filepath, 'r') as f:
            head = ''
            for _ in range(25):
                line = f.readline()
                if not line:
                    break
                head += line
    except (OSError, UnicodeDecodeError):
        return None

    meta = {}
    m = re.search(r'Workflow:\s*(.+)', head)
    if not m:
        return None
    meta['name'] = m.group(1).strip()

    m = re.search(r'Recorded:\s*(.+)', head)
    meta['date'] = m.group(1).strip() if m else ''

    m = re.search(r'Resolution:\s*(\d+)\s*x\s*(\d+)', head)
    meta['resolution'] = f"{m.group(1)}x{m.group(2)}" if m else ''

    m = re.search(r'Actions:\s*(\d+)', head)
    meta['actions'] = int(m.group(1)) if m else 0

    m = re.search(r'Duration:\s*([\d.]+)', head)
    meta['duration'] = float(m.group(1)) if m else 0

    return meta


def generate_workflow(events, environment, name=None, speed=1.0,
                      record_resolution=True, record_windows=True):
    """Generate a self-contained Python workflow script.

    Args:
        events: List of recorded event dicts from EventRecorder.
        environment: Dict from capture_environment().
        name: Optional workflow name.
        speed: Default playback speed multiplier.
        record_resolution: Whether to enforce recorded resolution by default.
        record_windows: Whether to restore recorded windows by default.

    Returns:
        String containing the complete Python script.
    """
    if not name:
        name = datetime.now().strftime('Recording_%Y%m%d_%H%M%S')

    processed = _process_events(events)
    duration = events[-1]['timestamp'] if events else 0

    resolution = environment.get('resolution', (1920, 1080))
    windows = environment.get('windows', [])
    if not record_windows:
        windows = []
    frontmost = environment.get('frontmost_app', 'Finder')

    # Format the events as a compact list of tuples
    event_lines = _format_events(processed)

    # Format windows list
    windows_str = _format_windows(windows)

    script = _TEMPLATE.format(
        name=name,
        timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        width=resolution[0],
        height=resolution[1],
        action_count=len(processed),
        duration=duration,
        speed=speed,
        default_skip_resolution=repr(not record_resolution),
        default_skip_windows=repr(not record_windows),
        windows=windows_str,
        frontmost=repr(frontmost),
        events=event_lines,
    )

    return script


def _process_events(raw_events):
    """Process raw recorded events into optimized workflow events.

    - Compresses redundant mouse movements
    - Tags drag events (mouse moves while a button is held)
    - Converts to compact tuple format
    """
    processed = []
    left_down = False
    right_down = False
    last_move_x = None
    last_move_y = None
    last_move_t = None

    for event in raw_events:
        t = event['timestamp']
        etype = event['type']

        if etype == 'mousemove':
            x, y = event['x'], event['y']
            is_left_drag = event.get('left_held', False) or left_down
            is_right_drag = event.get('right_held', False) or right_down

            if is_left_drag:
                processed.append((round(t, 4), 'drag', x, y))
                last_move_x, last_move_y, last_move_t = x, y, t
            elif is_right_drag:
                processed.append((round(t, 4), 'right_drag', x, y))
                last_move_x, last_move_y, last_move_t = x, y, t
            else:
                # Compress: skip if very close to last move
                if last_move_x is not None:
                    dx = abs(x - last_move_x)
                    dy = abs(y - last_move_y)
                    dt = t - (last_move_t or 0)
                    if dx < 2 and dy < 2 and dt < 0.008:
                        continue

                processed.append((round(t, 4), 'move', x, y))
                last_move_x, last_move_y, last_move_t = x, y, t

        elif etype == 'mousedown':
            x, y = event['x'], event['y']
            button = event.get('button', 'left')
            if button == 'left':
                left_down = True
                processed.append((round(t, 4), 'left_down', x, y))
            elif button == 'right':
                right_down = True
                processed.append((round(t, 4), 'right_down', x, y))
            elif button == 'middle':
                processed.append((round(t, 4), 'middle_down', x, y))

        elif etype == 'mouseup':
            x, y = event['x'], event['y']
            button = event.get('button', 'left')
            if button == 'left':
                left_down = False
                processed.append((round(t, 4), 'left_up', x, y))
            elif button == 'right':
                right_down = False
                processed.append((round(t, 4), 'right_up', x, y))
            elif button == 'middle':
                processed.append((round(t, 4), 'middle_up', x, y))

        elif etype == 'keydown':
            kc = event.get('keycode')
            mods = event.get('modifiers', 0)
            if kc is not None:
                processed.append((round(t, 4), 'key_down', kc, mods))

        elif etype == 'keyup':
            kc = event.get('keycode')
            mods = event.get('modifiers', 0)
            if kc is not None:
                processed.append((round(t, 4), 'key_up', kc, mods))

        elif etype == 'scroll':
            x, y = event['x'], event['y']
            dx, dy = event.get('dx', 0), event.get('dy', 0)
            processed.append((round(t, 4), 'scroll', x, y, dx, dy))

    return processed


def _format_events(events):
    """Format processed events as Python source code."""
    if not events:
        return '[]'

    lines = ['[']
    for ev in events:
        lines.append(f'    {ev!r},')
    lines.append(']')
    return '\n'.join(lines)


def _format_windows(windows):
    """Format window list as Python source code."""
    if not windows:
        return '[]'

    lines = ['[']
    for w in windows:
        lines.append(
            f'    {{"app": {w["app"]!r}, "name": {w["name"]!r}, '
            f'"x": {w["x"]}, "y": {w["y"]}, "w": {w["w"]}, "h": {w["h"]}}},'
        )
    lines.append(']')
    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# Workflow template
# ---------------------------------------------------------------------------

_TEMPLATE = '''#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Workflow: {name}
Recorded: {timestamp}
Resolution: {width} x {height}
Actions: {action_count}
Duration: {duration:.1f}s
"""

import os
import subprocess
import time
import sys

try:
    from Quartz import (
        CGEventCreateMouseEvent,
        CGEventCreateKeyboardEvent,
        CGEventCreateScrollWheelEvent,
        CGEventPost,
        CGEventSetFlags,
        CGDisplayBounds,
        CGDisplayCopyAllDisplayModes,
        CGDisplayCopyDisplayMode,
        CGDisplayModeGetHeight,
        CGDisplayModeGetPixelHeight,
        CGDisplayModeGetPixelWidth,
        CGDisplayModeGetRefreshRate,
        CGDisplayModeGetWidth,
        CGDisplaySetDisplayMode,
        CGMainDisplayID,
        kCGEventMouseMoved,
        kCGEventLeftMouseDown,
        kCGEventLeftMouseUp,
        kCGEventLeftMouseDragged,
        kCGEventRightMouseDown,
        kCGEventRightMouseUp,
        kCGEventRightMouseDragged,
        kCGEventOtherMouseDown,
        kCGEventOtherMouseUp,
        kCGHIDEventTap,
        kCGScrollEventUnitLine,
        kCGMouseButtonLeft,
        kCGMouseButtonRight,
        kCGMouseButtonCenter,
    )
except ImportError:
    print("Error: pyobjc-framework-Quartz is required.")
    print("Install with: pip install pyobjc-framework-Quartz")
    sys.exit(1)


SPEED = {speed}

# --- Prompt control ---
# FORCE: continue on resolution mismatch without asking
# NON_INTERACTIVE: suppress interactive prompts
FORCE = False
NON_INTERACTIVE = False
DEBUG = False

# --- Environment options ---
SKIP_RESOLUTION = {default_skip_resolution}
SKIP_WINDOWS = {default_skip_windows}

# --- Environment recorded at capture time ---
RESOLUTION = ({width}, {height})
WINDOWS = {windows}
FRONTMOST_APP = {frontmost}

# --- Recorded events ---
# Format: (timestamp, event_type, ...)
# Mouse events: (t, type, x, y)
# Key events:   (t, type, keycode, modifier_flags)
# Scroll events: (t, 'scroll', x, y, dx, dy)
EVENTS = {events}


def run_applescript(script):
    """Run an AppleScript command via osascript.

    Returns (stdout_string, success_bool).
    """
    if DEBUG:
        print(f"  [DEBUG] Running AppleScript:")
        for line in script.strip().splitlines():
            print(f"    | {{line}}")
    try:
        env = os.environ.copy()
        env['LANG'] = 'en_US.UTF-8'
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=10, env=env
        )
        stdout = result.stdout.strip()
        stderr = result.stderr.strip()
        if DEBUG:
            print(f"  [DEBUG] returncode={{result.returncode}} stdout={{stdout!r}} stderr={{stderr!r}}")
        if result.returncode != 0:
            if stderr:
                print(f"  AppleScript warning: {{stderr}}")
            return stdout, False
        return stdout, True
    except Exception as e:
        print(f"  AppleScript error: {{e}}")
        return None, False


def _current_resolution():
    bounds = CGDisplayBounds(CGMainDisplayID())
    return (int(bounds.size.width), int(bounds.size.height))


def _pick_best_display_mode(display_id, target):
    """Pick a display mode matching target (logical or pixel dimensions)."""
    modes = CGDisplayCopyAllDisplayModes(display_id, None) or []
    current_mode = CGDisplayCopyDisplayMode(display_id)

    current_logical = None
    current_pixel = None
    current_hz = 0.0
    if current_mode is not None:
        current_logical = (
            int(CGDisplayModeGetWidth(current_mode)),
            int(CGDisplayModeGetHeight(current_mode)),
        )
        current_pixel = (
            int(CGDisplayModeGetPixelWidth(current_mode)),
            int(CGDisplayModeGetPixelHeight(current_mode)),
        )
        current_hz = float(CGDisplayModeGetRefreshRate(current_mode) or 0.0)

    ranked = []
    for idx, mode in enumerate(modes):
        logical = (
            int(CGDisplayModeGetWidth(mode)),
            int(CGDisplayModeGetHeight(mode)),
        )
        pixel = (
            int(CGDisplayModeGetPixelWidth(mode)),
            int(CGDisplayModeGetPixelHeight(mode)),
        )
        if target != logical and target != pixel:
            continue

        hz = float(CGDisplayModeGetRefreshRate(mode) or 0.0)
        is_hidpi = logical != pixel
        score = 0
        if current_logical is not None and current_pixel is not None:
            if logical == current_logical:
                score += 4
            if pixel == current_pixel:
                score += 4
            if hz and current_hz and abs(hz - current_hz) < 0.2:
                score += 2
        if is_hidpi:
            score += 1
        if hz:
            score += 1
        ranked.append((score, idx, mode, logical, pixel, hz, is_hidpi))

    if not ranked:
        return None

    ranked.sort(reverse=True)
    return ranked[0]


def _try_set_resolution_coregraphics():
    """Try to set resolution using CoreGraphics display modes."""
    display_id = CGMainDisplayID()
    selected = _pick_best_display_mode(display_id, RESOLUTION)
    if selected is None:
        print("  No CoreGraphics display mode matches the recorded resolution.")
        return False

    _, _, mode, logical, pixel, hz, is_hidpi = selected
    mode_desc = (
        f"logical={{logical[0]}}x{{logical[1]}} "
        f"pixel={{pixel[0]}}x{{pixel[1]}} "
        f"hz={{hz:.2f}} "
        f"hidpi={{is_hidpi}}"
    )
    print(f"  Attempting CoreGraphics mode switch: {{mode_desc}}")
    try:
        err = CGDisplaySetDisplayMode(display_id, mode, None)
        if err != 0:
            print(f"  CoreGraphics mode switch failed (code {{err}}).")
            return False
    except Exception as e:
        print(f"  CoreGraphics mode switch error: {{e}}")
        return False

    time.sleep(1)
    after = _current_resolution()
    if after == RESOLUTION:
        print(f"  Resolution set to {{after[0]}}x{{after[1]}} via CoreGraphics.")
        return True

    print(f"  CoreGraphics switched mode, but bounds are {{after[0]}}x{{after[1]}}.")
    return False


def _try_set_resolution_displayplacer():
    """Fallback: try setting resolution with displayplacer."""
    import re
    import shutil

    dp = shutil.which('displayplacer')
    if not dp:
        print("  Tip: Install displayplacer (brew install jakehilborn/jakehilborn/displayplacer)")
        print("       to enable fallback resolution switching.")
        return False

    print("  Attempting fallback resolution switch via displayplacer...")
    try:
        list_result = subprocess.run(
            [dp, 'list'], capture_output=True, text=True, timeout=10
        )
        list_out = list_result.stdout or ''
        m = re.search(r'Persistent\\s+screen\\s+id:\\s*([0-9A-Fa-fx]+)', list_out)
        if m:
            cmd = [dp, f'id:{{m.group(1)}}', f'res:{{RESOLUTION[0]}}x{{RESOLUTION[1]}}']
        else:
            cmd = [dp, f'res:{{RESOLUTION[0]}}x{{RESOLUTION[1]}}']

        set_result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if set_result.returncode != 0:
            err = (set_result.stderr or '').strip()
            print(f"  displayplacer failed: {{err or 'unknown error'}}")
            return False
    except Exception as e:
        print(f"  displayplacer error: {{e}}")
        return False

    time.sleep(1)
    after = _current_resolution()
    if after == RESOLUTION:
        print(f"  Resolution set to {{after[0]}}x{{after[1]}} via displayplacer.")
        return True

    print(f"  displayplacer ran, but bounds are {{after[0]}}x{{after[1]}}.")
    return False


def check_resolution():
    """Verify display resolution matches recording, attempt auto-fix."""
    current = _current_resolution()
    if current == RESOLUTION:
        return

    print(f"  Warning: Resolution mismatch!")
    print(f"  Expected: {{RESOLUTION[0]}}x{{RESOLUTION[1]}}")
    print(f"  Current:  {{current[0]}}x{{current[1]}}")

    if _try_set_resolution_coregraphics():
        return
    if _try_set_resolution_displayplacer():
        return

    if FORCE:
        print("  Continuing despite unresolved mismatch (--force).")
        return

    if NON_INTERACTIVE or not sys.stdin.isatty():
        print("  Aborting: cannot prompt in non-interactive mode.")
        print("  Re-run with --force to continue despite mismatch.")
        sys.exit(2)

    resp = input("  Continue anyway? (y/n): ").strip().lower()
    if resp != 'y':
        print("  Aborted.")
        sys.exit(2)


def setup_windows():
    """Restore window positions from recording."""
    ok_count = 0
    fail_count = 0

    for win in WINDOWS:
        app = win['app']
        title = win.get('name', '')
        x, y, w, h = win['x'], win['y'], win['w'], win['h']

        if DEBUG:
            print(f"  [DEBUG] Window: app={{app!r}} title={{title!r}} pos=({{x}},{{y}}) size=({{w}},{{h}})")

        # Escape quotes for AppleScript strings
        safe_app = app.replace('\\\\', '\\\\\\\\').replace('"', '\\\\"')
        safe_title = title.replace('\\\\', '\\\\\\\\').replace('"', '\\\\"')

        # Activate the app first
        _, activated = run_applescript(f'tell application "{{safe_app}}" to activate')
        if not activated:
            print(f"    Could not activate {{app}}")
            fail_count += 1
            continue

        time.sleep(0.3)

        # Try matching by window title first, fall back to window 1
        script = f\'\'\'
tell application "System Events"
    tell process "{{safe_app}}"
        set matched to false
        repeat with w in windows
            if name of w is "{{safe_title}}" then
                set position of w to {{{{{{x}}, {{y}}}}}}
                set size of w to {{{{{{w}}, {{h}}}}}}
                set matched to true
                exit repeat
            end if
        end repeat
        if not matched then
            if (count of windows) > 0 then
                set position of window 1 to {{{{{{x}}, {{y}}}}}}
                set size of window 1 to {{{{{{w}}, {{h}}}}}}
                set matched to true
            end if
        end if
        return matched
    end tell
end tell
\'\'\'
        result, success = run_applescript(script)
        if success:
            ok_count += 1
        else:
            label = f'{{app}} - "{{title}}"' if title else app
            print(f"    Failed to position: {{label}}")
            fail_count += 1

    if ok_count > 0 or fail_count > 0:
        total = ok_count + fail_count
        print(f"  Positioned {{ok_count}}/{{total}} window(s).")


def activate_frontmost():
    """Activate the app that was frontmost during recording."""
    script = f'tell application "{{FRONTMOST_APP}}" to activate'
    _, ok = run_applescript(script)
    if not ok:
        print(f"  Could not activate {{FRONTMOST_APP}}")


def setup():
    """Restore the screen environment from recording time."""
    print("Setting up environment...")
    if not SKIP_RESOLUTION:
        check_resolution()
    if WINDOWS and not SKIP_WINDOWS:
        print(f"  Restoring {{len(WINDOWS)}} window(s)...")
        setup_windows()
    elif SKIP_WINDOWS:
        print("  Skipping window restoration.")
    print(f"  Activating {{FRONTMOST_APP}}...")
    activate_frontmost()
    time.sleep(0.5)
    print("  Environment ready.\\n")


def post_mouse(event_type, x, y, button=kCGMouseButtonLeft):
    """Post a mouse event."""
    event = CGEventCreateMouseEvent(None, event_type, (x, y), button)
    CGEventPost(kCGHIDEventTap, event)


def post_key(keycode, key_down, flags=0):
    """Post a keyboard event."""
    event = CGEventCreateKeyboardEvent(None, keycode, key_down)
    if flags:
        CGEventSetFlags(event, flags)
    CGEventPost(kCGHIDEventTap, event)


def post_scroll(x, y, dx, dy):
    """Post a scroll wheel event at a position."""
    # Move to scroll position
    move = CGEventCreateMouseEvent(None, kCGEventMouseMoved, (x, y), kCGMouseButtonLeft)
    CGEventPost(kCGHIDEventTap, move)
    # Scroll
    event = CGEventCreateScrollWheelEvent(None, kCGScrollEventUnitLine, 2, int(dy), int(dx))
    CGEventPost(kCGHIDEventTap, event)


def replay():
    """Replay recorded input events."""
    total = len(EVENTS)
    print(f"Replaying {{total}} events (speed: {{SPEED}}x)...")

    last_t = 0
    for i, entry in enumerate(EVENTS):
        t = entry[0]
        event_type = entry[1]

        # Timing
        delay = (t - last_t) / SPEED
        if delay > 0.0005:
            time.sleep(delay)
        last_t = t

        # Dispatch
        if event_type == 'move':
            post_mouse(kCGEventMouseMoved, entry[2], entry[3])

        elif event_type == 'left_down':
            post_mouse(kCGEventLeftMouseDown, entry[2], entry[3])

        elif event_type == 'left_up':
            post_mouse(kCGEventLeftMouseUp, entry[2], entry[3])

        elif event_type == 'right_down':
            post_mouse(kCGEventRightMouseDown, entry[2], entry[3], kCGMouseButtonRight)

        elif event_type == 'right_up':
            post_mouse(kCGEventRightMouseUp, entry[2], entry[3], kCGMouseButtonRight)

        elif event_type == 'drag':
            post_mouse(kCGEventLeftMouseDragged, entry[2], entry[3])

        elif event_type == 'right_drag':
            post_mouse(kCGEventRightMouseDragged, entry[2], entry[3], kCGMouseButtonRight)

        elif event_type == 'middle_down':
            post_mouse(kCGEventOtherMouseDown, entry[2], entry[3], kCGMouseButtonCenter)

        elif event_type == 'middle_up':
            post_mouse(kCGEventOtherMouseUp, entry[2], entry[3], kCGMouseButtonCenter)

        elif event_type == 'key_down':
            post_key(entry[2], True, entry[3])

        elif event_type == 'key_up':
            post_key(entry[2], False, entry[3])

        elif event_type == 'scroll':
            post_scroll(entry[2], entry[3], entry[4], entry[5])

        # Progress indicator
        if (i + 1) % 500 == 0 or i == total - 1:
            pct = int((i + 1) / total * 100)
            if sys.stdout.isatty():
                print(f"  Progress: {{pct}}% ({{i + 1}}/{{total}})", end="\\r")
            else:
                print(f"  Progress: {{pct}}% ({{i + 1}}/{{total}})", flush=True)

    print(f"\\nReplay complete. {{total}} events played.")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Replay recorded actions")
    parser.add_argument('--speed', type=float, default=SPEED,
                        help='Playback speed multiplier (default: %(default)s)')
    parser.add_argument('--skip-setup', action='store_true',
                        help='Skip environment setup phase')
    parser.add_argument('--no-prompt', action='store_true',
                        help='Skip the ENTER prompt and start replay immediately')
    parser.add_argument('--skip-resolution', action='store_true',
                        help='Skip resolution matching')
    parser.add_argument('--skip-windows', action='store_true',
                        help='Skip window arrangement restoration')
    parser.add_argument('--match-resolution', action='store_true',
                        help='Force resolution matching even if workflow default skips it')
    parser.add_argument('--match-windows', action='store_true',
                        help='Force window restoration even if workflow default skips it')
    parser.add_argument('--force', action='store_true',
                        help='Continue on resolution mismatch without prompt')
    parser.add_argument('--non-interactive', action='store_true',
                        help='Suppress interactive prompts')
    parser.add_argument('--debug', action='store_true',
                        help='Print detailed debug output during setup')
    args = parser.parse_args()

    SPEED = args.speed
    FORCE = args.force
    NON_INTERACTIVE = args.non_interactive
    DEBUG = args.debug
    SKIP_RESOLUTION = SKIP_RESOLUTION or args.skip_resolution
    SKIP_WINDOWS = SKIP_WINDOWS or args.skip_windows
    if args.match_resolution:
        SKIP_RESOLUTION = False
    if args.match_windows:
        SKIP_WINDOWS = False

    print("=" * 50)
    print(f"  Workflow: {name}")
    print(f"  Actions:  {{len(EVENTS)}}")
    print(f"  Speed:    {{SPEED}}x")
    print("=" * 50 + "\\n")

    if not args.skip_setup:
        setup()

    if not args.no_prompt:
        input("Press ENTER to begin replay...")
        print()
    replay()
'''
