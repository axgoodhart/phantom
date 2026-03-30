"""
Global event recorder using pynput.

Captures mouse movement, clicks, keyboard events, and scroll wheel
input system-wide. Events are stored with timestamps and made available
via a thread-safe queue for UI updates.
"""

import time
import threading
from pynput import mouse, keyboard

from . import keymap

try:
    from Quartz import (
        CFMachPortCreateRunLoopSource,
        CFRunLoopAddSource,
        CFRunLoopGetCurrent,
        CFRunLoopRunInMode,
        CFRunLoopStop,
        CGEventGetFlags,
        CGEventGetIntegerValueField,
        CGEventMaskBit,
        CGEventTapCreate,
        CGEventTapEnable,
        kCFRunLoopDefaultMode,
        kCFRunLoopRunTimedOut,
        kCGEventFlagsChanged,
        kCGEventKeyDown,
        kCGEventKeyUp,
        kCGEventTapOptionListenOnly,
        kCGHeadInsertEventTap,
        kCGKeyboardEventKeycode,
        kCGSessionEventTap,
    )
    _QUARTZ_AVAILABLE = True
except Exception:
    _QUARTZ_AVAILABLE = False


class EventRecorder:
    """Records global input events using pynput."""

    def __init__(self):
        self.events = []
        self.is_recording = False
        self.start_time = 0

        # Thread-safe pending events for UI polling
        self._pending = []
        self._lock = threading.Lock()

        # Listeners
        self._mouse_listener = None
        self._keyboard_listener = None
        self._keyboard_thread = None
        self._keyboard_loop = None
        self._keyboard_flags = 0
        self._modifier_key_state = {}
        self.keyboard_backend = 'none'

        # State tracking
        self._left_down = False
        self._right_down = False
        self._modifiers = {
            'shift': False,
            'ctrl': False,
            'alt': False,
            'cmd': False,
        }

        # Exclusion zone (control panel bounds in screen coords)
        self._exclude_rect = None

        # Last mouse position for UI
        self._last_mouse_x = 0
        self._last_mouse_y = 0

    def set_exclusion_zone(self, x, y, w, h):
        """Set a screen region to exclude from recording (the control panel)."""
        self._exclude_rect = (x, y, x + w, y + h)

    def clear_exclusion_zone(self):
        self._exclude_rect = None

    def _is_excluded(self, x, y):
        if self._exclude_rect is None:
            return False
        x1, y1, x2, y2 = self._exclude_rect
        return x1 <= x <= x2 and y1 <= y <= y2

    def start(self):
        """Start recording events."""
        self.events = []
        with self._lock:
            self._pending = []
        self.is_recording = True
        self.start_time = time.time()
        self._left_down = False
        self._right_down = False
        self._modifiers = {k: False for k in self._modifiers}

        self._mouse_listener = mouse.Listener(
            on_move=self._on_move,
            on_click=self._on_click,
            on_scroll=self._on_scroll,
        )
        self._mouse_listener.start()
        # Prefer native Quartz tap on macOS; fallback to pynput keyboard listener.
        if not self._start_quartz_keyboard_capture():
            self._keyboard_listener = keyboard.Listener(
                on_press=self._on_press,
                on_release=self._on_release,
            )
            self._keyboard_listener.start()
            self.keyboard_backend = 'pynput'
        else:
            self.keyboard_backend = 'quartz'

    def stop(self):
        """Stop recording events."""
        self.is_recording = False
        if self._mouse_listener:
            self._mouse_listener.stop()
            self._mouse_listener = None
        if self._keyboard_listener:
            self._keyboard_listener.stop()
            self._keyboard_listener = None
        self._stop_quartz_keyboard_capture()
        self.keyboard_backend = 'none'

    def _timestamp(self):
        return time.time() - self.start_time

    def _modifier_flags(self):
        flags = 0
        if self._modifiers['shift']:
            flags |= keymap.MODIFIER_FLAGS['shift']
        if self._modifiers['ctrl']:
            flags |= keymap.MODIFIER_FLAGS['ctrl']
        if self._modifiers['alt']:
            flags |= keymap.MODIFIER_FLAGS['alt']
        if self._modifiers['cmd']:
            flags |= keymap.MODIFIER_FLAGS['cmd']
        return flags

    def _record(self, event):
        """Append event to both the full list and the pending queue."""
        self.events.append(event)
        with self._lock:
            self._pending.append(event)

    def get_pending_events(self):
        """Get and clear pending events for UI display. Thread-safe."""
        with self._lock:
            events = self._pending
            self._pending = []
        return events

    @property
    def last_mouse_position(self):
        return (self._last_mouse_x, self._last_mouse_y)

    # --- Mouse callbacks ---

    def _on_move(self, x, y):
        if not self.is_recording:
            return
        ix, iy = int(x), int(y)
        if self._is_excluded(ix, iy):
            return

        self._last_mouse_x = ix
        self._last_mouse_y = iy

        self._record({
            'type': 'mousemove',
            'x': ix,
            'y': iy,
            'timestamp': self._timestamp(),
            'left_held': self._left_down,
            'right_held': self._right_down,
        })

    def _on_click(self, x, y, button, pressed):
        if not self.is_recording:
            return
        ix, iy = int(x), int(y)
        if self._is_excluded(ix, iy):
            return

        self._last_mouse_x = ix
        self._last_mouse_y = iy

        button_name = button.name  # 'left', 'right', 'middle'

        if button_name == 'left':
            self._left_down = pressed
        elif button_name == 'right':
            self._right_down = pressed

        event_type = 'mousedown' if pressed else 'mouseup'
        self._record({
            'type': event_type,
            'x': ix,
            'y': iy,
            'button': button_name,
            'timestamp': self._timestamp(),
        })

    def _on_scroll(self, x, y, dx, dy):
        if not self.is_recording:
            return
        ix, iy = int(x), int(y)
        if self._is_excluded(ix, iy):
            return

        self._record({
            'type': 'scroll',
            'x': ix,
            'y': iy,
            'dx': int(dx),
            'dy': int(dy),
            'timestamp': self._timestamp(),
        })

    # --- Keyboard callbacks ---

    def _start_quartz_keyboard_capture(self):
        """Start keyboard capture via native Quartz event tap."""
        if not _QUARTZ_AVAILABLE:
            return False
        if self._keyboard_thread and self._keyboard_thread.is_alive():
            return True

        self._keyboard_flags = 0
        self._modifier_key_state = {}
        self._keyboard_thread = threading.Thread(
            target=self._run_quartz_keyboard_loop,
            daemon=True,
        )
        self._keyboard_thread.start()

        # Give the tap thread a brief moment to initialize.
        time.sleep(0.05)
        return self._keyboard_thread.is_alive()

    def _stop_quartz_keyboard_capture(self):
        """Stop the Quartz keyboard tap loop."""
        try:
            if self._keyboard_loop is not None:
                CFRunLoopStop(self._keyboard_loop)
        except Exception:
            pass

        if self._keyboard_thread:
            self._keyboard_thread.join(timeout=0.5)
            self._keyboard_thread = None
        self._keyboard_loop = None

    def _run_quartz_keyboard_loop(self):
        """Run the Quartz keyboard event tap loop in a background thread."""
        event_mask = (
            CGEventMaskBit(kCGEventKeyDown)
            | CGEventMaskBit(kCGEventKeyUp)
            | CGEventMaskBit(kCGEventFlagsChanged)
        )
        tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            event_mask,
            self._quartz_keyboard_callback,
            None,
        )
        if tap is None:
            return

        loop_source = CFMachPortCreateRunLoopSource(None, tap, 0)
        self._keyboard_loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(self._keyboard_loop, loop_source, kCFRunLoopDefaultMode)
        CGEventTapEnable(tap, True)

        while self.is_recording:
            result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, False)
            if result != kCFRunLoopRunTimedOut and not self.is_recording:
                break

        self._keyboard_loop = None

    def _quartz_keyboard_callback(self, _proxy, event_type, event, _refcon):
        """Low-level Quartz keyboard callback."""
        try:
            if not self.is_recording:
                return event

            keycode = int(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode))
            flags = int(CGEventGetFlags(event))

            if event_type == kCGEventKeyDown:
                self._record_keyboard_event('keydown', keycode, flags)
            elif event_type == kCGEventKeyUp:
                self._record_keyboard_event('keyup', keycode, flags)
            elif event_type == kCGEventFlagsChanged:
                self._handle_flags_changed(keycode, flags)
        except Exception:
            # Never let keyboard callback exceptions break capture.
            pass
        return event

    def _modifier_mask_for_keycode(self, keycode):
        if keycode in (0x38, 0x3C):  # shift_l, shift_r
            return keymap.MODIFIER_FLAGS['shift']
        if keycode in (0x3B, 0x3E):  # ctrl_l, ctrl_r
            return keymap.MODIFIER_FLAGS['ctrl']
        if keycode in (0x3A, 0x3D):  # alt_l, alt_r
            return keymap.MODIFIER_FLAGS['alt']
        if keycode in (0x37, 0x36):  # cmd_l, cmd_r
            return keymap.MODIFIER_FLAGS['cmd']
        return None

    def _record_keyboard_event(self, event_type, keycode, flags):
        modifier_flags = 0
        if flags & keymap.MODIFIER_FLAGS['shift']:
            modifier_flags |= keymap.MODIFIER_FLAGS['shift']
        if flags & keymap.MODIFIER_FLAGS['ctrl']:
            modifier_flags |= keymap.MODIFIER_FLAGS['ctrl']
        if flags & keymap.MODIFIER_FLAGS['alt']:
            modifier_flags |= keymap.MODIFIER_FLAGS['alt']
        if flags & keymap.MODIFIER_FLAGS['cmd']:
            modifier_flags |= keymap.MODIFIER_FLAGS['cmd']

        display = keymap.key_display_name_from_keycode(
            keycode,
            shift=bool(flags & keymap.MODIFIER_FLAGS['shift']),
        )
        self._record({
            'type': event_type,
            'key': display,
            'keycode': int(keycode),
            'modifiers': modifier_flags,
            'timestamp': self._timestamp(),
        })

    def _handle_flags_changed(self, keycode, flags):
        # Caps Lock emits only a toggle event on macOS: synthesize press+release.
        if keycode == 0x39:
            self._record_keyboard_event('keydown', keycode, flags)
            self._record_keyboard_event('keyup', keycode, flags)
            self._keyboard_flags = flags
            return

        mask = self._modifier_mask_for_keycode(keycode)
        if mask is None:
            self._keyboard_flags = flags
            return

        is_pressed = bool(flags & mask)
        previous_pressed = self._modifier_key_state.get(keycode, False)

        if is_pressed and not previous_pressed:
            self._record_keyboard_event('keydown', keycode, flags)
        elif (not is_pressed) and previous_pressed:
            self._record_keyboard_event('keyup', keycode, flags)

        self._modifier_key_state[keycode] = is_pressed
        self._keyboard_flags = flags

    def _on_press(self, key):
        if not self.is_recording:
            return

        try:
            # Update modifier state
            self._update_modifier(key, True)

            kc = keymap.get_keycode(key)
            display = keymap.key_display_name(key)
            if kc is None and display:
                # Fallback path for keys pynput cannot map directly.
                kc = keymap.get_keycode_for_name(display)

            self._record({
                'type': 'keydown',
                'key': display,
                'keycode': kc,
                'modifiers': self._modifier_flags(),
                'timestamp': self._timestamp(),
            })
        except Exception:
            # Keep the listener alive even if one key is malformed.
            pass

    def _on_release(self, key):
        if not self.is_recording:
            return

        try:
            kc = keymap.get_keycode(key)
            display = keymap.key_display_name(key)
            if kc is None and display:
                kc = keymap.get_keycode_for_name(display)

            self._record({
                'type': 'keyup',
                'key': display,
                'keycode': kc,
                'modifiers': self._modifier_flags(),
                'timestamp': self._timestamp(),
            })

            # Update modifier state after recording (release event keeps the flag)
            self._update_modifier(key, False)
        except Exception:
            pass

    def _update_modifier(self, key, pressed):
        """Track modifier key state."""
        try:
            name = key.name
        except AttributeError:
            return
        if not isinstance(name, str):
            return

        if 'shift' in name:
            self._modifiers['shift'] = pressed
        elif 'ctrl' in name:
            self._modifiers['ctrl'] = pressed
        elif 'alt' in name:
            self._modifiers['alt'] = pressed
        elif 'cmd' in name:
            self._modifiers['cmd'] = pressed
