"""
Playback watchdog: abort hotkey and sleep/wake detection.

Monitors for a global keyboard shortcut (Ctrl+Option+Cmd+P by default)
and macOS sleep/wake events. When triggered, calls the provided abort
callback to kill a running workflow.
"""

import threading

try:
    from Quartz import (
        CGEventMaskBit,
        CGEventTapCreate,
        CGEventTapEnable,
        CGEventGetFlags,
        CGEventGetIntegerValueField,
        CFMachPortCreateRunLoopSource,
        CFRunLoopAddSource,
        CFRunLoopGetCurrent,
        CFRunLoopRunInMode,
        CFRunLoopStop,
        kCFRunLoopDefaultMode,
        kCFRunLoopRunTimedOut,
        kCGEventKeyDown,
        kCGEventTapOptionListenOnly,
        kCGHeadInsertEventTap,
        kCGKeyboardEventKeycode,
        kCGSessionEventTap,
    )
    _QUARTZ_AVAILABLE = True
except ImportError:
    _QUARTZ_AVAILABLE = False

# Modifier flag masks
_MOD_CTRL = 0x00040000
_MOD_ALT = 0x00080000
_MOD_CMD = 0x00100000

# Default abort keycode: 'p' = 0x23
_ABORT_KEYCODE = 0x23
_ABORT_MODIFIERS = _MOD_CTRL | _MOD_ALT | _MOD_CMD


class PlaybackWatchdog:
    """Watches for abort hotkey and sleep/wake to kill a running playback."""

    def __init__(self, abort_callback):
        """
        Args:
            abort_callback: Called with no arguments when abort is triggered.
        """
        self._abort_callback = abort_callback
        self._active = False
        self._hotkey_enabled = True
        self._hotkey_thread = None
        self._hotkey_loop = None
        self._sleep_observer = None

    def start(self, hotkey_enabled=True):
        """Start monitoring for abort triggers."""
        if self._active:
            return
        self._active = True
        self._hotkey_enabled = hotkey_enabled

        if self._hotkey_enabled:
            self._start_hotkey_monitor()
        self._start_sleep_monitor()

    def stop(self):
        """Stop all monitoring."""
        self._active = False
        self._stop_hotkey_monitor()
        self._stop_sleep_monitor()

    def _trigger_abort(self, reason='unknown'):
        """Fire the abort callback."""
        if not self._active:
            return
        self._active = False
        print(f'[watchdog] Abort triggered: {reason}')
        try:
            self._abort_callback()
        except Exception as e:
            print(f'[watchdog] Abort callback error: {e}')

    # --- Hotkey monitoring ---

    def _start_hotkey_monitor(self):
        if not _QUARTZ_AVAILABLE:
            print('[watchdog] Quartz not available, hotkey disabled')
            return
        self._hotkey_thread = threading.Thread(
            target=self._run_hotkey_loop,
            daemon=True,
        )
        self._hotkey_thread.start()

    def _stop_hotkey_monitor(self):
        try:
            if self._hotkey_loop is not None:
                CFRunLoopStop(self._hotkey_loop)
        except Exception:
            pass
        if self._hotkey_thread:
            self._hotkey_thread.join(timeout=0.5)
            self._hotkey_thread = None
        self._hotkey_loop = None

    def _run_hotkey_loop(self):
        event_mask = CGEventMaskBit(kCGEventKeyDown)
        tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            event_mask,
            self._hotkey_callback,
            None,
        )
        if tap is None:
            print('[watchdog] Could not create hotkey event tap')
            return

        loop_source = CFMachPortCreateRunLoopSource(None, tap, 0)
        self._hotkey_loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(self._hotkey_loop, loop_source, kCFRunLoopDefaultMode)
        CGEventTapEnable(tap, True)

        while self._active:
            result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, False)
            if result != kCFRunLoopRunTimedOut and not self._active:
                break

        self._hotkey_loop = None

    def _hotkey_callback(self, _proxy, event_type, event, _refcon):
        try:
            if not self._active:
                return event
            keycode = int(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode))
            flags = int(CGEventGetFlags(event))

            if keycode == _ABORT_KEYCODE:
                if (flags & _ABORT_MODIFIERS) == _ABORT_MODIFIERS:
                    self._trigger_abort('hotkey Ctrl+Option+Cmd+P')
        except Exception:
            pass
        return event

    # --- Sleep/wake monitoring ---

    def _start_sleep_monitor(self):
        try:
            from AppKit import NSWorkspace, NSNotificationCenter
            center = NSWorkspace.sharedWorkspace().notificationCenter()

            self._sleep_observer = center.addObserverForName_object_queue_usingBlock_(
                'NSWorkspaceWillSleepNotification',
                None,
                None,
                lambda note: self._trigger_abort('machine going to sleep'),
            )
        except Exception as e:
            print(f'[watchdog] Could not register sleep observer: {e}')

    def _stop_sleep_monitor(self):
        if self._sleep_observer is None:
            return
        try:
            from AppKit import NSWorkspace
            center = NSWorkspace.sharedWorkspace().notificationCenter()
            center.removeObserver_(self._sleep_observer)
        except Exception:
            pass
        self._sleep_observer = None
