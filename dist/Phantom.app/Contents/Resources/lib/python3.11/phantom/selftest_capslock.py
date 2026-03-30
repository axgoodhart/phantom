"""
Caps Lock regression self-test.

Runs local, permission-free checks against the keyboard mapping and recorder
callbacks so Caps Lock regressions are caught before manual app testing.
"""

from pynput import keyboard

from . import keymap
from .recorder import EventRecorder


def run():
    # 1) Keymap should resolve caps lock safely.
    caps = keyboard.Key.caps_lock
    kc = keymap.get_keycode(caps)
    display = keymap.key_display_name(caps)
    assert kc == 0x39, f"Expected caps lock keycode 0x39, got {kc!r}"
    assert display == 'CapsLock', f"Unexpected display name: {display!r}"

    # 2) Legacy callback path (pynput callback handlers) must not throw.
    recorder = EventRecorder()
    recorder.is_recording = True
    recorder.start_time = 0.0
    for _ in range(1000):
        recorder._on_press(caps)
        recorder._on_release(caps)
    assert len(recorder.events) == 2000
    assert recorder.events[0]['key'] == 'CapsLock'

    # 3) Native Quartz event recording helper path must produce valid events.
    recorder2 = EventRecorder()
    recorder2.start_time = 0.0
    recorder2._record_keyboard_event('keydown', 0x39, 0)
    recorder2._record_keyboard_event('keyup', 0x39, 0)
    assert recorder2.events[0]['key'] == 'CapsLock'
    assert recorder2.events[1]['keycode'] == 0x39

    print('Caps Lock self-test passed')


if __name__ == '__main__':
    run()
