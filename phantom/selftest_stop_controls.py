"""Focused regression checks for Phantom's emergency stop controls."""

import inspect
import os
import threading

from .api import Api
from .recorder import EventRecorder


def _check(name, check):
    try:
        check()
    except Exception as exc:
        print(f'FAIL {name}: {exc}')
        return False
    print(f'PASS {name}')
    return True


def _playback_hotkey_routes_to_stop():
    api = Api()
    api._playback_active = True
    stopped = []
    scripts = []
    api.stop_workflow = lambda: stopped.append(True) or {'status': 'stopped'}
    api._window = type(
        'Window',
        (),
        {'evaluate_js': lambda _self, script: scripts.append(script)},
    )()

    api._on_stop_hotkey()

    assert stopped == [True], 'playback stop callback was not invoked'
    assert scripts == ['onPlaybackStoppedByHotkey()'], (
        'playback UI was not notified that the shortcut stopped the run'
    )


def _playback_arms_hotkey_monitor():
    source = inspect.getsource(Api.run_workflow)
    assert 'self.recorder.start_stop_hotkey_monitor()' in source, (
        'playback does not arm the global stop-hotkey monitor'
    )


def _hotkey_only_monitor_can_fire():
    recorder = EventRecorder()
    fired = threading.Event()
    recorder.on_stop_hotkey = fired.set
    recorder._stop_hotkey_only = True

    assert recorder._keyboard_capture_active(), 'hotkey-only state is inactive'
    recorder._fire_stop_hotkey()
    assert fired.wait(0.5), 'hotkey-only callback did not fire'


def _chip_is_native_clickable():
    source = inspect.getsource(Api._enter_chip_mode)
    assert 'panel.setIgnoresMouseEvents_(False)' in source, (
        'chip window still ignores native mouse events'
    )


def _chip_click_stops_recording():
    ui_path = os.path.join(os.path.dirname(__file__), 'ui', 'index.html')
    with open(ui_path, 'r', encoding='utf-8') as handle:
        html = handle.read()
    assert "recChip.addEventListener('click'" in html, (
        'recording chip has no click handler'
    )
    assert "api('stop_recording')" in html, (
        'recording UI has no stop bridge call'
    )


def main():
    checks = (
        ('playback hotkey routing', _playback_hotkey_routes_to_stop),
        ('playback hotkey registration', _playback_arms_hotkey_monitor),
        ('hotkey-only monitor callback', _hotkey_only_monitor_can_fire),
        ('native chip clickability', _chip_is_native_clickable),
        ('chip stop click', _chip_click_stops_recording),
    )
    passed = sum(_check(name, check) for name, check in checks)
    if passed != len(checks):
        raise SystemExit(1)
    print('All stop-control regression checks passed.')


if __name__ == '__main__':
    main()
