"""
Screen environment capture for macOS.

Captures display resolution, window positions, and frontmost application
using Quartz, AppKit, and AppleScript.
"""

import subprocess


def capture_environment():
    """Capture the current screen environment.

    Returns:
        dict with keys: resolution, windows, frontmost_app
    """
    return {
        'resolution': get_resolution(),
        'windows': get_windows(),
        'frontmost_app': get_frontmost_app(),
    }


def get_resolution():
    """Get the main display's effective resolution.

    Returns:
        (width, height) tuple of integers.
    """
    try:
        from Quartz import CGDisplayBounds, CGMainDisplayID
        bounds = CGDisplayBounds(CGMainDisplayID())
        return (int(bounds.size.width), int(bounds.size.height))
    except ImportError:
        # Fallback: use system_profiler
        pass

    # Fallback using AppleScript
    try:
        script = '''
        tell application "Finder"
            set _b to bounds of window of desktop
            return ((item 3 of _b) as text) & "," & ((item 4 of _b) as text)
        end tell
        '''
        result = _run_applescript(script)
        if result:
            parts = result.split(',')
            return (int(parts[0].strip()), int(parts[1].strip()))
    except Exception:
        pass

    return (1920, 1080)  # Safe default


def get_windows():
    """Get positions and sizes of all visible windows.

    Returns:
        List of dicts with keys: app, name, x, y, w, h
    """
    try:
        from Quartz import (
            CGWindowListCopyWindowInfo,
            kCGWindowListOptionOnScreenOnly,
            kCGNullWindowID,
            kCGWindowListExcludeDesktopElements,
        )
        options = kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements
        window_list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)

        windows = []
        for win in window_list:
            # Skip windows without bounds or with zero size
            bounds = win.get('kCGWindowBounds')
            if not bounds:
                continue

            owner = win.get('kCGWindowOwnerName', '')
            name = win.get('kCGWindowName', '')
            layer = win.get('kCGWindowLayer', 0)

            # Skip system UI elements (menu bar, dock, etc.)
            if layer != 0:
                continue

            w = int(bounds.get('Width', 0))
            h = int(bounds.get('Height', 0))
            if w < 50 or h < 50:
                continue

            # Skip our own window
            if owner == 'Phantom' or owner == 'Python':
                continue

            windows.append({
                'app': owner,
                'name': name or 'Untitled',
                'x': int(bounds.get('X', 0)),
                'y': int(bounds.get('Y', 0)),
                'w': w,
                'h': h,
            })

        return windows
    except ImportError:
        pass

    # Fallback: AppleScript
    return _get_windows_applescript()


def _get_windows_applescript():
    """Fallback window capture using AppleScript."""
    script = '''
    set output to ""
    tell application "System Events"
        set procList to every process whose visible is true
        repeat with proc in procList
            set procName to name of proc
            try
                set winList to every window of proc
                repeat with win in winList
                    set winName to name of win
                    set {posX, posY} to position of win
                    set {sizeW, sizeH} to size of win
                    set output to output & procName & "||" & winName & "||" & posX & "||" & posY & "||" & sizeW & "||" & sizeH & "\\n"
                end repeat
            end try
        end repeat
    end tell
    return output
    '''
    result = _run_applescript(script)
    if not result:
        return []

    windows = []
    for line in result.strip().split('\n'):
        parts = line.strip().split('||')
        if len(parts) >= 6:
            try:
                windows.append({
                    'app': parts[0],
                    'name': parts[1],
                    'x': int(parts[2]),
                    'y': int(parts[3]),
                    'w': int(parts[4]),
                    'h': int(parts[5]),
                })
            except (ValueError, IndexError):
                continue
    return windows


def get_frontmost_app():
    """Get the name of the frontmost application.

    Returns:
        String application name.
    """
    try:
        from AppKit import NSWorkspace
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        return app.localizedName()
    except ImportError:
        pass

    # Fallback: AppleScript
    script = '''
    tell application "System Events"
        set frontApp to name of first application process whose frontmost is true
    end tell
    return frontApp
    '''
    result = _run_applescript(script)
    return result or 'Unknown'


def _run_applescript(script):
    """Run an AppleScript and return stdout."""
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=10,
            check=False,
        )
        return result.stdout.strip()
    except Exception:
        return None
