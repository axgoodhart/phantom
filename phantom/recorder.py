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
        CGEventGetDoubleValueField,
        CGEventGetFlags,
        CGEventGetIntegerValueField,
        CGEventGetLocation,
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

# Private CGEvent types for trackpad gestures (stable, used by WebKit)
_kCGEventRotate = 18
_kCGEventGesture = 29
_kCGEventMagnify = 30
_kCGEventSwipe = 31
_kCGEventSmartMagnify = 32

# Private CGEvent field IDs for gesture data (from WebKit source)
_GESTURE_PHASE_FIELD = 132
_GESTURE_MAGNIFY_FIELD = 113
_GESTURE_ROTATE_FIELD = 114

# Private CGS functions for desktop space tracking (used by yabai, Amethyst)
_CGS_AVAILABLE = False
_cgs = {}
try:
    import objc as _objc
    for _fw_path in (
        '/System/Library/PrivateFrameworks/SkyLight.framework',
        '/System/Library/Frameworks/CoreGraphics.framework',
    ):
        try:
            _cgs_bundle = _objc.loadBundle('_CGS', _cgs, bundle_path=_fw_path)
            _objc.loadBundleFunctions(_cgs_bundle, _cgs, [
                ('CGSMainConnectionID', b'I'),
                ('CGSGetActiveSpace', b'QI'),
                ('CGSCopyManagedDisplaySpaces', b'@I'),
            ])
            if 'CGSMainConnectionID' in _cgs:
                _CGS_AVAILABLE = True
                break
        except Exception:
            continue
except Exception:
    pass

try:
    from AppKit import NSWorkspace as _NSWorkspace
    _WORKSPACE_AVAILABLE = True
except Exception:
    _WORKSPACE_AVAILABLE = False


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

        # Desktop space tracking
        self._space_observer = None
        self._current_space_id = None
        self._space_order = []

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

        self._start_space_tracking()

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
        self._stop_space_tracking()
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
        """Run the Quartz keyboard + gesture event tap loop in a background thread."""
        event_mask = (
            CGEventMaskBit(kCGEventKeyDown)
            | CGEventMaskBit(kCGEventKeyUp)
            | CGEventMaskBit(kCGEventFlagsChanged)
            | CGEventMaskBit(_kCGEventRotate)
            | CGEventMaskBit(_kCGEventMagnify)
            | CGEventMaskBit(_kCGEventSwipe)
            | CGEventMaskBit(_kCGEventSmartMagnify)
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
        """Low-level Quartz keyboard and gesture callback."""
        try:
            if not self.is_recording:
                return event

            if event_type in (kCGEventKeyDown, kCGEventKeyUp, kCGEventFlagsChanged):
                keycode = int(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode))
                flags = int(CGEventGetFlags(event))

                if event_type == kCGEventKeyDown:
                    self._record_keyboard_event('keydown', keycode, flags)
                elif event_type == kCGEventKeyUp:
                    self._record_keyboard_event('keyup', keycode, flags)
                elif event_type == kCGEventFlagsChanged:
                    self._handle_flags_changed(keycode, flags)
            elif event_type in (_kCGEventMagnify, _kCGEventRotate,
                                _kCGEventSwipe, _kCGEventSmartMagnify):
                self._record_gesture_event(event_type, event)
        except Exception:
            # Never let callback exceptions break capture.
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

    # --- Desktop space tracking ---

    def _start_space_tracking(self):
        """Begin monitoring desktop space changes."""
        if not (_CGS_AVAILABLE and _WORKSPACE_AVAILABLE):
            return
        try:
            conn = _cgs['CGSMainConnectionID']()
            self._current_space_id = int(_cgs['CGSGetActiveSpace'](conn))
            self._space_order = self._get_space_order(conn)

            center = _NSWorkspace.sharedWorkspace().notificationCenter()
            self._space_observer = (
                center.addObserverForName_object_queue_usingBlock_(
                    'NSWorkspaceActiveSpaceDidChangeNotification',
                    None, None,
                    self._on_space_changed,
                )
            )
        except Exception:
            self._space_observer = None

    def _stop_space_tracking(self):
        """Stop monitoring desktop space changes."""
        if self._space_observer is not None:
            try:
                center = _NSWorkspace.sharedWorkspace().notificationCenter()
                center.removeObserver_(self._space_observer)
            except Exception:
                pass
            self._space_observer = None
        self._current_space_id = None
        self._space_order = []

    def _get_space_order(self, conn):
        """Get the ordered list of space IDs for the main display."""
        try:
            displays = _cgs['CGSCopyManagedDisplaySpaces'](conn)
            if not displays or len(displays) == 0:
                return []
            spaces = displays[0].get('Spaces', [])
            return [int(s.get('id64', 0)) for s in spaces]
        except Exception:
            return []

    def _on_space_changed(self, notification):
        """NSWorkspace callback for desktop space changes."""
        if not self.is_recording:
            return
        try:
            conn = _cgs['CGSMainConnectionID']()
            new_id = int(_cgs['CGSGetActiveSpace'](conn))
            old_id = self._current_space_id

            if new_id == old_id:
                return

            # Refresh in case spaces were added/removed
            self._space_order = self._get_space_order(conn)

            direction = 'right'
            if old_id in self._space_order and new_id in self._space_order:
                old_idx = self._space_order.index(old_id)
                new_idx = self._space_order.index(new_id)
                direction = 'right' if new_idx > old_idx else 'left'

            self._current_space_id = new_id

            self._record({
                'type': 'space_switch',
                'direction': direction,
                'timestamp': self._timestamp(),
            })
        except Exception:
            pass

    # --- Gesture callbacks ---

    def _record_gesture_event(self, event_type, event):
        """Record a trackpad gesture event from the Quartz tap."""
        location = CGEventGetLocation(event)
        x, y = int(location.x), int(location.y)
        if self._is_excluded(x, y):
            return

        self._last_mouse_x = x
        self._last_mouse_y = y
        t = self._timestamp()

        if event_type == _kCGEventMagnify:
            try:
                value = CGEventGetDoubleValueField(event, _GESTURE_MAGNIFY_FIELD)
            except Exception:
                value = 0.0
            try:
                phase = int(CGEventGetIntegerValueField(event, _GESTURE_PHASE_FIELD))
            except Exception:
                phase = 0
            self._record({
                'type': 'magnify', 'x': x, 'y': y,
                'value': round(value, 6), 'phase': phase,
                'timestamp': t,
            })
        elif event_type == _kCGEventRotate:
            try:
                value = CGEventGetDoubleValueField(event, _GESTURE_ROTATE_FIELD)
            except Exception:
                value = 0.0
            try:
                phase = int(CGEventGetIntegerValueField(event, _GESTURE_PHASE_FIELD))
            except Exception:
                phase = 0
            self._record({
                'type': 'rotate', 'x': x, 'y': y,
                'value': round(value, 6), 'phase': phase,
                'timestamp': t,
            })
        elif event_type == _kCGEventSwipe:
            try:
                from AppKit import NSEvent as _NSEvent
                ns_ev = _NSEvent.eventWithCGEvent_(event)
                dx = round(ns_ev.deltaX(), 6) if ns_ev else 0
                dy = round(ns_ev.deltaY(), 6) if ns_ev else 0
            except Exception:
                dx = dy = 0
            self._record({
                'type': 'swipe', 'x': x, 'y': y,
                'dx': dx, 'dy': dy,
                'timestamp': t,
            })
        elif event_type == _kCGEventSmartMagnify:
            self._record({
                'type': 'smart_magnify', 'x': x, 'y': y,
                'timestamp': t,
            })

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
