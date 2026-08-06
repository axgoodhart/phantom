"""
Main application entry point.

Creates the pywebview windows (control panel + transparent overlay)
and starts the application event loop.
"""

import os
import threading
import webview

from .api import Api


def get_ui_path(filename):
    """Get the absolute path to a UI file."""
    base = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, 'ui', filename)


def _apply_overlay_properties():
    """Apply click-through properties to the overlay NSWindow.

    MUST be called on the main thread (AppKit requirement).
    """
    try:
        from AppKit import NSApplication
        app = NSApplication.sharedApplication()
        for ns_window in app.windows():
            title = ns_window.title()
            if title and 'Overlay' in title:
                ns_window.setIgnoresMouseEvents_(True)
                ns_window.setLevel_(1000)  # Above most windows
                ns_window.setCollectionBehavior_(1 << 0)  # Join all spaces
                print('[overlay] Set click-through and level')
                return
    except Exception as e:
        print(f'[overlay] Could not set click-through: {e}')


def make_overlay_click_through(overlay_window):
    """Schedule overlay click-through setup on the main thread."""
    import time
    from PyObjCTools.AppHelper import callAfter
    # Brief delay to let the window fully initialize
    time.sleep(0.5)
    callAfter(_apply_overlay_properties)


def setup_overlay(api_instance, overlay_window):
    """Configure the overlay window after creation."""
    api_instance.set_overlay_window(overlay_window)
    # Run on a background thread that dispatches to main thread
    threading.Thread(
        target=make_overlay_click_through,
        args=(overlay_window,),
        daemon=True,
    ).start()


def _patch_pynput_keyboard_context():
    """Pre-initialize pynput's keyboard layout data on the main thread.

    macOS 15+ requires TISCopyCurrentKeyboardInputSource (and the underlying
    TSMGetInputSourceProperty) to be called from the main thread.  pynput's
    keyboard listener calls this from its own background thread, which causes
    a SIGTRAP crash.

    Fix: call it once NOW (on the main thread), cache the result, and
    monkey-patch pynput's keycode_context to yield the cached data.
    """
    try:
        import contextlib
        import pynput._util.darwin as _darwin

        with _darwin.keycode_context() as ctx:
            cached_context = ctx

        @contextlib.contextmanager
        def _cached_keycode_context():
            yield cached_context

        _darwin.keycode_context = _cached_keycode_context

        # Also patch the imported reference in the keyboard module,
        # since `from pynput._util.darwin import keycode_context`
        # creates a separate binding that won't see the patch above.
        import pynput.keyboard._darwin as _kbd_darwin
        _kbd_darwin.keycode_context = _cached_keycode_context

        print('[pynput] Keyboard layout cached on main thread')
    except Exception as e:
        print(f'[pynput] Could not cache keyboard layout: {e}')


def main():
    """Launch the Phantom application."""
    # Must run on main thread before any pynput keyboard listener starts
    _patch_pynput_keyboard_context()

    # Permission prompting is handled by the UI's permission modal, which
    # sequences the Accessibility and Automation dialogs instead of firing
    # both system prompts at once on startup.

    api = Api()

    # Get screen size for the overlay
    screen_width, screen_height = 1920, 1080
    try:
        from Quartz import CGDisplayBounds, CGMainDisplayID
        bounds = CGDisplayBounds(CGMainDisplayID())
        screen_width = int(bounds.size.width)
        screen_height = int(bounds.size.height)
    except ImportError:
        pass

    # Place the control panel near the bottom-left corner of the main display.
    panel_width = 320
    panel_height = 700
    panel_margin = 24
    panel_x = max(0, min(panel_margin, screen_width - panel_width))
    panel_y = max(0, screen_height - panel_height - panel_margin)

    # Create the main control panel window
    panel = webview.create_window(
        'Phantom',
        url=get_ui_path('index.html'),
        width=panel_width,
        height=panel_height,
        x=panel_x,
        y=panel_y,
        resizable=True,
        on_top=True,
        js_api=api,
        min_size=(280, 500),
        frameless=True,
        transparent=True,
        opacity=0.6,
        easy_drag=False,
    )
    api.set_window(panel)

    # Create the transparent overlay window
    overlay = webview.create_window(
        'Phantom Overlay',
        url=get_ui_path('overlay.html'),
        width=screen_width,
        height=screen_height,
        x=0,
        y=0,
        resizable=False,
        frameless=True,
        transparent=True,
        on_top=True,
        js_api=api,
    )

    def on_panel_loaded():
        setup_overlay(api, overlay)

    panel.events.loaded += on_panel_loaded

    # Start the application
    # On macOS, pywebview uses the cocoa backend by default
    webview.start(debug=False)
