"""
pywebview API bridge.

Exposes Python functionality to the JavaScript frontend via pywebview's
API mechanism. Handles recording lifecycle, event polling, export, and preview.
"""

import logging
import os
import re
import subprocess
import sys
import threading
import time
import json
import tempfile

log = logging.getLogger('Phantom')
logging.basicConfig(
    level=logging.DEBUG if os.environ.get('PHANTOM_DEBUG') else logging.INFO,
    format='[%(levelname)s] %(name)s: %(message)s',
)

from .recorder import EventRecorder
from .environment import capture_environment, get_frontmost_app
from .workflow import generate_workflow, parse_workflow_metadata


class Api:
    """API class exposed to the pywebview JavaScript frontend."""

    def __init__(self):
        self.recorder = EventRecorder()
        self.recorder.on_stop_hotkey = self._on_stop_hotkey
        self.environment = None
        self._window = None        # Set by app.py after window creation
        self._overlay_window = None  # Set by app.py for the overlay
        self._record_prompt_visible = False
        self._chip_active = False
        self._panel_saved_frame = None
        self._record_options = {
            'record_resolution': True,
            'record_windows': True,
        }
        self._pre_prompt_frontmost_app = None

        # Preview state
        self._preview_active = False
        self._preview_thread = None

        # Playback state
        self._playback_process = None
        self._playback_thread = None
        self._playback_active = False
        self._playback_metadata = None
        self._playback_filepath = None
        self._playback_temp_filepath = None
        self._playback_play_sound = False
        self._playback_cancelled = False

        # Loop state
        self._loop_count = 1        # Total iterations (0 = infinite)
        self._loop_delay = 0        # Seconds between runs
        self._loop_ping_url = None  # URL to check between runs
        self._loop_iteration = 0    # Current iteration (1-based)
        self._loop_cmd = None       # Command to re-launch

    def set_window(self, window):
        self._window = window

    def set_overlay_window(self, window):
        self._overlay_window = window

    # --- Recording ---

    def _set_overlay_mouse_passthrough(self, passthrough=True, focus=False):
        """Enable or disable overlay click-through mode."""
        try:
            from AppKit import NSApplication
            from PyObjCTools.AppHelper import callAfter

            def _apply():
                app = NSApplication.sharedApplication()
                for ns_window in app.windows():
                    title = ns_window.title()
                    if title and 'Overlay' in title:
                        ns_window.setIgnoresMouseEvents_(bool(passthrough))
                        if focus:
                            ns_window.makeKeyAndOrderFront_(None)
                        return

            callAfter(_apply)
        except Exception:
            # Best-effort only; failures should not block recording.
            pass

    def _activate_application(self, app_name):
        """Best-effort activate an application by name."""
        if not app_name:
            return
        try:
            safe_name = str(app_name).replace('\\', '\\\\').replace('"', '\\"')
            script = f'tell application "{safe_name}" to activate'
            subprocess.run(
                ['osascript', '-e', script],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
        except Exception:
            pass

    def _begin_recording(self, record_resolution=True, record_windows=True):
        """Internal shared recording start implementation."""
        if self.recorder.is_recording:
            return {'status': 'already_recording'}

        self._record_options = {
            'record_resolution': bool(record_resolution),
            'record_windows': bool(record_windows),
        }

        # Capture environment before recording starts
        self.environment = capture_environment()
        if not self._record_options['record_windows']:
            self.environment['windows'] = []
        if self._pre_prompt_frontmost_app:
            self.environment['frontmost_app'] = self._pre_prompt_frontmost_app

        # Exclude the control panel's screen region so clicks on Phantom's own
        # buttons (especially Stop) don't end up in the workflow.
        self._apply_panel_exclusion_zone()

        # Start recording
        self.recorder.start()

        self._record_prompt_visible = False

        return {
            'status': 'recording',
            'environment': self.environment,
            'record_options': self._record_options,
            'keyboard_backend': self.recorder.keyboard_backend,
        }

    # --- Recording chip mode ---
    #
    # While recording, the control panel collapses into a small stop chip
    # pinned to the bottom-left corner. The chip and the ⌃⌥⌘⎋ hotkey both
    # stop recording. If the native transform fails, the panel stays full-size
    # with its regular Stop button, protected by the exclusion zone.

    _CHIP_WIDTH = 216
    _CHIP_HEIGHT = 64
    _CHIP_MARGIN = 24
    _PANEL_MIN_SIZE = (280, 500)  # Matches create_window(min_size=...)

    def _find_panel_window(self, app):
        for ns_window in app.windows():
            if ns_window.title() == 'Phantom':
                return ns_window
        return None

    def _enter_chip_mode(self):
        """Collapse the control panel into a clickable recording stop chip."""
        if self._chip_active:
            return
        try:
            from AppKit import NSApplication, NSScreen
            from Foundation import NSMakeRect, NSMakeSize
            from PyObjCTools.AppHelper import callAfter
        except Exception:
            return

        def _apply():
            try:
                panel = self._find_panel_window(NSApplication.sharedApplication())
                if panel is None:
                    return
                self._panel_saved_frame = panel.frame()
                panel.setMinSize_(NSMakeSize(1, 1))
                panel.setIgnoresMouseEvents_(False)
                panel.setFrame_display_animate_(
                    NSMakeRect(self._CHIP_MARGIN, self._CHIP_MARGIN,
                               self._CHIP_WIDTH, self._CHIP_HEIGHT),
                    True, True,
                )
                self._chip_active = True
                # Keep the stop click out of the captured workflow. AppKit uses
                # bottom-left coordinates; pynput uses top-left coordinates.
                screen_height = float(NSScreen.mainScreen().frame().size.height)
                chip_y = int(screen_height - self._CHIP_MARGIN - self._CHIP_HEIGHT)
                self.recorder.set_exclusion_zone(
                    self._CHIP_MARGIN,
                    chip_y,
                    self._CHIP_WIDTH,
                    self._CHIP_HEIGHT,
                )

                def _notify_ui():
                    if self._window:
                        try:
                            self._window.evaluate_js('enterChipMode()')
                        except Exception:
                            pass
                threading.Thread(target=_notify_ui, daemon=True).start()
            except Exception:
                pass

        callAfter(_apply)

    def _exit_chip_mode(self):
        """Restore the control panel from chip mode."""
        if not self._chip_active:
            return
        self._chip_active = False
        saved_frame = self._panel_saved_frame
        self._panel_saved_frame = None
        try:
            from AppKit import NSApplication
            from Foundation import NSMakeSize
            from PyObjCTools.AppHelper import callAfter
        except Exception:
            return

        def _apply():
            try:
                panel = self._find_panel_window(NSApplication.sharedApplication())
                if panel is None:
                    return
                panel.setIgnoresMouseEvents_(False)
                panel.setMinSize_(NSMakeSize(*self._PANEL_MIN_SIZE))
                if saved_frame is not None:
                    panel.setFrame_display_animate_(saved_frame, True, True)
            except Exception:
                pass

        callAfter(_apply)
        if self._window:
            try:
                self._window.evaluate_js('exitChipMode()')
            except Exception:
                pass

    def _on_stop_hotkey(self):
        """Recorder callback: ⌃⌥⌘⎋ pressed during recording or playback."""
        if self.recorder.is_recording:
            result = self.stop_recording()
            if result.get('status') != 'stopped':
                return
            if self._window:
                try:
                    self._window.evaluate_js(
                        f'onRecordingStoppedByHotkey({json.dumps(result)})'
                    )
                except Exception:
                    pass
            return

        if self._playback_active:
            result = self.stop_workflow()
            if result.get('status') != 'stopped':
                return
            if self._window:
                try:
                    self._window.evaluate_js('onPlaybackStoppedByHotkey()')
                except Exception:
                    pass

    def _apply_panel_exclusion_zone(self):
        """Set the recorder's exclusion rect to the control panel's bounds."""
        try:
            win = self._window
            if win is None:
                return
            x, y = int(win.x), int(win.y)
            w, h = int(win.width), int(win.height)
            margin = 8  # Small buffer around the panel edges
            self.recorder.set_exclusion_zone(
                x - margin, y - margin, w + 2 * margin, h + 2 * margin
            )
        except Exception:
            # Best-effort; recording proceeds without exclusion.
            log.warning('Could not determine panel bounds for exclusion zone',
                        exc_info=True)
            self.recorder.clear_exclusion_zone()

    def show_recording_prompt(self):
        """Show the pre-record options prompt on the full-screen overlay."""
        if self.recorder.is_recording:
            return {'status': 'already_recording'}
        if not self._overlay_window:
            return {'status': 'error', 'message': 'Overlay window not available'}

        try:
            frontmost = get_frontmost_app()
            if frontmost and frontmost != 'Phantom':
                self._pre_prompt_frontmost_app = frontmost
        except Exception:
            self._pre_prompt_frontmost_app = None

        self._record_prompt_visible = True
        self._set_overlay_mouse_passthrough(False, focus=True)

        try:
            self._overlay_window.evaluate_js('showRecordPrompt()')
            return {'status': 'shown'}
        except Exception as e:
            self._record_prompt_visible = False
            self._set_overlay_mouse_passthrough(True)
            return {'status': 'error', 'message': str(e)}

    def dismiss_recording_prompt(self):
        """Hide the pre-record options prompt without starting recording."""
        self._record_prompt_visible = False
        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('hideRecordPrompt()')
            except Exception:
                pass
        self._set_overlay_mouse_passthrough(True)
        self._pre_prompt_frontmost_app = None
        if self._window:
            try:
                self._window.evaluate_js('onRecordingPromptDismissed()')
            except Exception:
                pass
        return {'status': 'dismissed'}

    def begin_recording_from_overlay(self, record_resolution=True, record_windows=True):
        """Begin recording from overlay prompt interaction."""
        if self._pre_prompt_frontmost_app:
            self._activate_application(self._pre_prompt_frontmost_app)

        result = self._begin_recording(
            record_resolution=record_resolution,
            record_windows=record_windows,
        )
        if result.get('status') != 'recording':
            return result

        # Restore click-through so underlying apps receive input during recording.
        self._set_overlay_mouse_passthrough(True)
        if self._pre_prompt_frontmost_app:
            self._activate_application(self._pre_prompt_frontmost_app)
        self._pre_prompt_frontmost_app = None

        # Notify the control panel window to switch into recording state.
        if self._window:
            try:
                payload = json.dumps(result)
                self._window.evaluate_js(f'onRecordingBeganFromOverlay({payload})')
            except Exception:
                pass

        # Collapse the panel into the click-through recording chip.
        self._enter_chip_mode()

        return result

    def start_recording(self, record_resolution=True, record_windows=True):
        """Start recording input events and capture environment."""
        result = self._begin_recording(
            record_resolution=record_resolution,
            record_windows=record_windows,
        )
        if result.get('status') != 'recording':
            return result

        # Show overlay cursor indicator
        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('showCursor()')
            except Exception:
                pass

        # Collapse the panel into the click-through recording chip.
        self._enter_chip_mode()

        return result

    def stop_recording(self):
        """Stop recording and return summary."""
        if not self.recorder.is_recording:
            return {'status': 'not_recording'}

        self.recorder.stop()
        self.recorder.clear_exclusion_zone()
        self._exit_chip_mode()

        # Hide overlay cursor
        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('hideCursor()')
            except Exception:
                pass

        event_count = len(self.recorder.events)
        duration = self.recorder.events[-1]['timestamp'] if event_count > 0 else 0

        return {
            'status': 'stopped',
            'event_count': event_count,
            'duration': round(duration, 1),
        }

    def get_pending_events(self):
        """Get new events since last poll (for live event log)."""
        events = self.recorder.get_pending_events()

        # Live key-down popup in overlay during active recording.
        if self.recorder.is_recording and self._overlay_window:
            for ev in events:
                if ev.get('type') != 'keydown':
                    continue
                key = ev.get('key', '?')
                safe_key = key.replace('\\', '\\\\').replace("'", "\\'")
                try:
                    self._overlay_window.evaluate_js(f"showKeyPress('{safe_key}')")
                except Exception:
                    pass

        # Return compact event summaries for the UI
        summaries = []
        for ev in events:
            summaries.append(_summarize_event(ev))
        return summaries

    def get_mouse_position(self):
        """Get the last recorded mouse position."""
        x, y = self.recorder.last_mouse_position
        return {'x': x, 'y': y}

    def get_recording_state(self):
        """Get current recording state."""
        return {
            'is_recording': self.recorder.is_recording,
            'event_count': len(self.recorder.events),
        }

    # --- Permissions ---

    def get_permissions_status(self):
        """Return current permission status.

        The automation check is only performed once Accessibility is granted:
        probing automation sends a real Apple Event, which triggers the system
        consent dialog. Sequencing the two avoids stacking multiple permission
        dialogs at first launch.
        """
        accessibility = _check_accessibility(prompt=False)
        automation = _check_automation(prompt=False) if accessibility else False
        return {
            'accessibility': accessibility,
            'automation': automation,
        }

    def request_permissions(self):
        """Prompt for required permissions and return status."""
        return {
            'accessibility': _check_accessibility(prompt=True),
            'automation': _check_automation(prompt=True),
        }

    def request_accessibility(self):
        """Prompt for Accessibility permission."""
        _check_accessibility(prompt=True)
        _trigger_accessibility_probe()
        return {'accessibility': _check_accessibility(prompt=False)}

    def request_automation(self):
        """Prompt for Automation permission."""
        _trigger_automation_probe()
        return {'automation': _check_automation(prompt=False)}

    def open_accessibility_settings(self):
        """Open the Accessibility privacy settings pane."""
        return {'ok': _open_settings_pane('Privacy_Accessibility')}

    def open_automation_settings(self):
        """Open the Automation privacy settings pane."""
        return {'ok': _open_settings_pane('Privacy_Automation')}

    def play_chime(self):
        """Play a short alert sound."""
        return _play_chime()

    # --- Export ---

    def export_workflow(self, name=None, speed=1.0):
        """Generate workflow script and prompt for save location.

        Returns the generated script content. The actual file save
        is handled via pywebview's file dialog.
        """
        if not self.recorder.events:
            return {'status': 'no_events'}

        if self.environment is None:
            self.environment = capture_environment()

        script = generate_workflow(
            self.recorder.events,
            self.environment,
            name=name or None,
            speed=speed,
            record_resolution=self._record_options.get('record_resolution', True),
            record_windows=self._record_options.get('record_windows', True),
        )

        return {
            'status': 'ok',
            'script': script,
            'event_count': len(self.recorder.events),
        }

    def save_workflow(self, name=None, speed=1.0):
        """Generate and save workflow to the app's workflows folder."""
        result = self.export_workflow(name=name, speed=speed)
        if result['status'] != 'ok':
            return result

        script = result['script']
        safe_name = name or 'workflow'
        filename = _slugify_filename(safe_name)
        workflows_dir = _get_workflows_dir()
        filepath = os.path.join(workflows_dir, filename)

        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(script)
            os.chmod(filepath, 0o755)

            meta = parse_workflow_metadata(filepath)
            if meta:
                meta['filename'] = filename
            return {
                'status': 'saved',
                'filename': filename,
                'path': filepath,
                'metadata': meta,
                'event_count': result['event_count'],
            }
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    # --- Workflow Management ---

    def list_workflows(self):
        """Scan the workflows folder and return metadata for all saved workflows."""
        workflows_dir = _get_workflows_dir()
        workflows = []
        try:
            for filename in os.listdir(workflows_dir):
                if not filename.endswith('.py'):
                    continue
                filepath = os.path.join(workflows_dir, filename)
                if not os.path.isfile(filepath):
                    continue
                meta = parse_workflow_metadata(filepath)
                if meta is None:
                    continue
                meta['filename'] = filename
                # Capture mtime now so a file deleted mid-listing can't
                # break the sort below.
                try:
                    meta['mtime'] = os.path.getmtime(filepath)
                except OSError:
                    meta['mtime'] = 0
                workflows.append(meta)
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

        # Sort newest first by file modification time
        workflows.sort(key=lambda w: w['mtime'], reverse=True)
        return {'status': 'ok', 'workflows': workflows}

    def load_workflow_by_filename(self, filename):
        """Load a specific workflow by filename from the workflows folder."""
        workflows_dir = _get_workflows_dir()
        filepath = os.path.join(workflows_dir, filename)

        # Security: ensure the resolved path is within the workflows dir
        real_path = os.path.realpath(filepath)
        real_dir = os.path.realpath(workflows_dir)
        if not real_path.startswith(real_dir + os.sep):
            return {'status': 'error', 'message': 'Invalid filename'}

        if not os.path.isfile(filepath):
            return {'status': 'error', 'message': 'Workflow file not found'}

        meta = parse_workflow_metadata(filepath)
        if meta is None:
            return {'status': 'error', 'message': 'Not a valid workflow file'}

        meta['filename'] = filename
        self._playback_metadata = meta
        self._playback_filepath = filepath
        return {'status': 'ok', 'metadata': meta}

    def delete_workflow(self, filename):
        """Delete a workflow file from the workflows folder."""
        workflows_dir = _get_workflows_dir()
        filepath = os.path.join(workflows_dir, filename)

        # Security: path traversal guard
        real_path = os.path.realpath(filepath)
        real_dir = os.path.realpath(workflows_dir)
        if not real_path.startswith(real_dir + os.sep):
            return {'status': 'error', 'message': 'Invalid filename'}

        if not os.path.isfile(filepath):
            return {'status': 'error', 'message': 'File not found'}

        try:
            os.unlink(filepath)
            # If the deleted workflow was loaded for playback, clear it
            if self._playback_filepath == filepath:
                self._playback_filepath = None
                self._playback_metadata = None
            return {'status': 'deleted', 'filename': filename}
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    def rename_workflow(self, filename, new_name):
        """Rename a workflow by updating its docstring metadata."""
        workflows_dir = _get_workflows_dir()
        filepath = os.path.join(workflows_dir, filename)

        # Security: path traversal guard
        real_path = os.path.realpath(filepath)
        real_dir = os.path.realpath(workflows_dir)
        if not real_path.startswith(real_dir + os.sep):
            return {'status': 'error', 'message': 'Invalid filename'}

        if not os.path.isfile(filepath):
            return {'status': 'error', 'message': 'File not found'}

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
        except Exception as e:
            return {'status': 'error', 'message': str(e)}

    # --- Preview ---

    def start_preview(self, speed=1.0):
        """Start visual preview of recorded events in the overlay."""
        if not self.recorder.events or self._preview_active:
            return {'status': 'unavailable'}

        self._preview_active = True
        self._preview_thread = threading.Thread(
            target=self._run_preview,
            args=(speed,),
            daemon=True,
        )
        self._preview_thread.start()
        return {'status': 'previewing'}

    def stop_preview(self):
        """Stop the current preview."""
        self._preview_active = False
        return {'status': 'stopped'}

    def is_preview_active(self):
        return self._preview_active

    def start_workflow_preview(self, speed=1.0):
        """Start visual preview of a loaded workflow file in the overlay."""
        if self._preview_active:
            return {'status': 'unavailable'}
        if not self._playback_filepath:
            return {'status': 'no_workflow'}

        tuples = _extract_workflow_events(self._playback_filepath)
        if not tuples:
            return {'status': 'error', 'message': 'Could not parse workflow events'}

        self._preview_active = True
        self._preview_thread = threading.Thread(
            target=self._run_workflow_preview,
            args=(tuples, speed),
            daemon=True,
        )
        self._preview_thread.start()
        return {'status': 'previewing'}

    def _run_workflow_preview(self, tuples, speed):
        """Run preview of workflow-file events in a background thread."""
        total = len(tuples)

        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('showCursor()')
            except Exception:
                pass

        last_t = 0
        for i, tup in enumerate(tuples):
            if not self._preview_active:
                break

            t = tup[0]
            delay = (t - last_t) / speed
            if delay > 0.001:
                remaining = delay
                while remaining > 0 and self._preview_active:
                    time.sleep(min(remaining, 0.05))
                    remaining -= 0.05
            last_t = t

            event = _workflow_tuple_to_preview_event(tup)
            self._preview_event(event)

            if self._window and (i % 50 == 0 or i == total - 1):
                pct = int((i + 1) / total * 100)
                try:
                    self._window.evaluate_js(
                        f'updatePreviewProgress({pct}, {i + 1}, {total})'
                    )
                except Exception:
                    pass

        self._preview_active = False

        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('hideCursor()')
            except Exception:
                pass

        if self._window:
            try:
                self._window.evaluate_js('onPreviewComplete()')
            except Exception:
                pass

    def _run_preview(self, speed):
        """Run preview playback in a background thread."""
        events = self.recorder.events
        total = len(events)

        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('showCursor()')
            except Exception:
                pass

        last_t = 0
        for i, event in enumerate(events):
            if not self._preview_active:
                break

            t = event['timestamp']
            delay = (t - last_t) / speed
            if delay > 0.001:
                # Sleep in small increments so we can check for stop
                remaining = delay
                while remaining > 0 and self._preview_active:
                    time.sleep(min(remaining, 0.05))
                    remaining -= 0.05
            last_t = t

            # Send event to overlay for visual display
            self._preview_event(event)

            # Send progress to main window
            if self._window and (i % 50 == 0 or i == total - 1):
                pct = int((i + 1) / total * 100)
                try:
                    self._window.evaluate_js(
                        f'updatePreviewProgress({pct}, {i + 1}, {total})'
                    )
                except Exception:
                    pass

        self._preview_active = False

        if self._overlay_window:
            try:
                self._overlay_window.evaluate_js('hideCursor()')
            except Exception:
                pass

        if self._window:
            try:
                self._window.evaluate_js('onPreviewComplete()')
            except Exception:
                pass

    def _preview_event(self, event):
        """Send a single event to the overlay for visual display."""
        if not self._overlay_window:
            return

        etype = event['type']
        try:
            if etype == 'mousemove':
                self._overlay_window.evaluate_js(
                    f'moveCursor({event["x"]}, {event["y"]})'
                )
            elif etype == 'mousedown':
                self._overlay_window.evaluate_js(
                    f'showClick({event["x"]}, {event["y"]})'
                )
            elif etype == 'keydown':
                key = event.get('key', '?')
                # Escape quotes for JS string
                safe_key = key.replace('\\', '\\\\').replace("'", "\\'")
                self._overlay_window.evaluate_js(
                    f"showKeyPress('{safe_key}')"
                )
            elif etype == 'scroll':
                self._overlay_window.evaluate_js(
                    f'showScroll({event["x"]}, {event["y"]}, {event.get("dy", 0)})'
                )
        except Exception:
            pass

    # --- Playback ---

    def run_workflow(self, speed=1.0, match_resolution=True, match_windows=True,
                     play_completion_sound=False, loop_count=1, loop_delay=0,
                     loop_ping_url=None):
        """Launch the loaded workflow as a subprocess, optionally looping."""
        if self._playback_active or not self._playback_filepath:
            return {'status': 'unavailable'}

        self._cleanup_playback_temp_file()

        filepath = self._playback_filepath
        run_filepath = filepath
        cmd = [sys.executable, run_filepath, '--speed', str(speed), '--no-prompt']

        warning = None
        supports_skip_resolution = _workflow_supports_flag(filepath, '--skip-resolution')
        supports_skip_windows = _workflow_supports_flag(filepath, '--skip-windows')
        supports_match_resolution = _workflow_supports_flag(filepath, '--match-resolution')
        supports_match_windows = _workflow_supports_flag(filepath, '--match-windows')

        # Always honor explicit "match" requests when workflow supports forcing.
        if match_resolution and supports_match_resolution:
            cmd.append('--match-resolution')
        if match_windows and supports_match_windows:
            cmd.append('--match-windows')

        # For legacy workflows without --match-* support, patch static defaults
        # into a temp copy when needed so "match" still works.
        force_match_resolution = (
            match_resolution
            and not supports_match_resolution
            and _workflow_default_skip(filepath, 'SKIP_RESOLUTION') is True
        )
        force_match_windows = (
            match_windows
            and not supports_match_windows
            and _workflow_default_skip(filepath, 'SKIP_WINDOWS') is True
        )
        if force_match_resolution or force_match_windows:
            patched = _create_workflow_match_override(
                filepath,
                force_match_resolution=force_match_resolution,
                force_match_windows=force_match_windows,
            )
            if patched:
                run_filepath = patched
                cmd[1] = run_filepath
                self._playback_temp_filepath = run_filepath
            else:
                warning = (
                    'Could not patch workflow defaults for strict matching; '
                    'using original workflow settings.'
                )

        if not match_resolution or not match_windows:
            if supports_skip_resolution or supports_skip_windows:
                if not match_resolution and supports_skip_resolution:
                    cmd.append('--skip-resolution')
                if not match_windows and supports_skip_windows:
                    cmd.append('--skip-windows')
                # If the workflow only supports one flag, skip setup entirely
                # to avoid partial mismatches that can't be controlled.
                if (not match_resolution and not supports_skip_resolution) or (
                        not match_windows and not supports_skip_windows):
                    cmd.append('--skip-setup')
                    warning = (
                        'This workflow does not support separate resolution/window '
                        'matching. Skipping all environment matching.'
                    )
            else:
                cmd.append('--skip-setup')
                warning = (
                    'This workflow does not support environment options. '
                    'Skipping all environment matching.'
                )

        self._playback_play_sound = bool(play_completion_sound)

        # Store loop config
        self._loop_count = max(0, int(loop_count))  # 0 = infinite
        self._loop_delay = max(0, float(loop_delay))
        self._loop_ping_url = loop_ping_url.strip() if loop_ping_url else None
        self._loop_iteration = 1
        self._loop_cmd = cmd[:]  # Save for re-launches

        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            # Feed input proactively for workflows that prompt:
            # - Older templates may prompt for ENTER before replay
            # - Current templates prompt on resolution mismatch (y/n)
            # Sending 'y' then an extra newline covers both cases without
            # closing stdin so additional prompts can still read if needed.
            try:
                proc.stdin.write('y\n\n')
                proc.stdin.flush()
            except OSError:
                pass

            self._playback_process = proc
            self._playback_active = True
            self._playback_cancelled = False
            self.recorder.start_stop_hotkey_monitor()
            self._playback_thread = threading.Thread(
                target=self._monitor_playback,
                daemon=True,
            )
            self._playback_thread.start()
            result = {'status': 'running'}
            if warning:
                result['warning'] = warning
            return result
        except Exception as e:
            self._cleanup_playback_temp_file()
            return {'status': 'error', 'message': str(e)}

    def stop_workflow(self):
        """Terminate the running workflow subprocess and cancel any loop."""
        if not self._playback_active or not self._playback_process:
            return {'status': 'not_running'}

        self._playback_play_sound = False
        self._playback_active = False  # Signal loop to stop
        self._playback_cancelled = True

        proc = self._playback_process
        try:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        except Exception:
            pass

        self._loop_cmd = None
        self.recorder.stop_stop_hotkey_monitor()
        self._cleanup_playback_temp_file()
        return {'status': 'stopped'}

    def clear_workflow(self):
        """Unload the current workflow metadata."""
        self._playback_metadata = None
        self._playback_filepath = None
        return {'status': 'cleared'}

    def is_playback_active(self):
        return self._playback_active

    def _monitor_playback(self):
        """Background thread: read subprocess stdout, handle looping."""
        from collections import deque

        progress_re = re.compile(r'Progress:\s*(\d+)%\s*\((\d+)/(\d+)\)')
        total_loops = self._loop_count  # 0 = infinite
        error_message = None

        while self._playback_active:
            iteration = self._loop_iteration
            is_looping = total_loops != 1
            loop_label = (
                f'∞' if total_loops == 0
                else f'{iteration}/{total_loops}'
            )

            # Update loop status in UI
            if is_looping and self._window:
                try:
                    safe = loop_label.replace("'", "\\'")
                    self._window.evaluate_js(
                        f"updateLoopStatus('Run {safe}')"
                    )
                except Exception:
                    pass

            proc = self._playback_process

            # Read stdout progress from this run, keeping a tail of output
            # so failures can be reported to the user.
            output_tail = deque(maxlen=15)
            try:
                for line in proc.stdout:
                    if not self._playback_active:
                        break
                    line = line.rstrip('\n\r')
                    if line.strip():
                        output_tail.append(line.strip())
                    m = progress_re.search(line)
                    if m and self._window:
                        pct, current, total = m.group(1), m.group(2), m.group(3)
                        try:
                            self._window.evaluate_js(
                                f'updatePlaybackProgress({pct}, {current}, {total})'
                            )
                        except Exception:
                            pass
            except Exception:
                pass

            # Wait for process to finish
            try:
                proc.wait(timeout=5)
            except Exception:
                pass

            if not self._playback_active:
                break

            # Surface workflow failures instead of reporting success.
            rc = proc.returncode
            if rc is not None and rc != 0:
                detail = '; '.join(list(output_tail)[-3:]) or f'exit code {rc}'
                error_message = detail
                break

            # Check if we should loop again
            self._loop_iteration += 1
            if total_loops != 0 and self._loop_iteration > total_loops:
                break  # All iterations done

            # --- Between-run delay and ping ---
            if self._loop_ping_url:
                if self._window:
                    try:
                        self._window.evaluate_js(
                            "updateLoopStatus('Pinging...')"
                        )
                    except Exception:
                        pass
                ping_ok = self._ping_check(self._loop_ping_url)
                if not ping_ok and self._window:
                    try:
                        self._window.evaluate_js(
                            "updateLoopStatus('Ping failed — continuing')"
                        )
                    except Exception:
                        pass
                    # Brief pause to show the message
                    time.sleep(1.5)

            if self._loop_delay > 0 and self._playback_active:
                if self._window:
                    try:
                        self._window.evaluate_js(
                            f"updateLoopStatus('Waiting {self._loop_delay}s...')"
                        )
                    except Exception:
                        pass
                # Sleep in small increments so stop is responsive
                remaining = self._loop_delay
                while remaining > 0 and self._playback_active:
                    time.sleep(min(remaining, 0.2))
                    remaining -= 0.2

            if not self._playback_active:
                break

            # Re-launch the subprocess for the next iteration
            try:
                proc = subprocess.Popen(
                    self._loop_cmd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                try:
                    proc.stdin.write('y\n\n')
                    proc.stdin.flush()
                except OSError:
                    pass
                self._playback_process = proc
            except Exception:
                break

        # All done
        cancelled = self._playback_cancelled
        self._playback_active = False
        self._playback_process = None
        self.recorder.stop_stop_hotkey_monitor()
        self._cleanup_playback_temp_file()
        play_sound = self._playback_play_sound
        self._playback_play_sound = False

        if play_sound and not error_message:
            _play_chime()

        if self._window:
            try:
                if error_message:
                    self._window.evaluate_js(
                        f'onPlaybackError({json.dumps(error_message)})'
                    )
                elif not cancelled:
                    self._window.evaluate_js('onPlaybackComplete()')
            except Exception:
                pass

    def _ping_check(self, url):
        """Check if a URL responds with 2xx. Returns True on success."""
        import urllib.request
        import urllib.error
        try:
            req = urllib.request.Request(url, method='HEAD')
            req.add_header('User-Agent', 'Phantom/1.0')
            resp = urllib.request.urlopen(req, timeout=10)
            return 200 <= resp.status < 300
        except Exception:
            # Retry with GET in case HEAD is not supported
            try:
                req = urllib.request.Request(url, method='GET')
                req.add_header('User-Agent', 'Phantom/1.0')
                resp = urllib.request.urlopen(req, timeout=10)
                return 200 <= resp.status < 300
            except Exception:
                return False

    def _cleanup_playback_temp_file(self):
        """Delete temp workflow copy if one was created."""
        if not self._playback_temp_filepath:
            return
        try:
            os.unlink(self._playback_temp_filepath)
        except Exception:
            pass
        self._playback_temp_filepath = None

    # --- Grid ---

    def toggle_grid(self, visible, size=50):
        """Show or hide the grid overlay."""
        if self._overlay_window:
            try:
                if visible:
                    self._overlay_window.evaluate_js(f'showGrid({size})')
                else:
                    self._overlay_window.evaluate_js('hideGrid()')
            except Exception:
                pass

    # --- Utility ---

    def get_event_count(self):
        return len(self.recorder.events)

    def get_recording_duration(self):
        if not self.recorder.events:
            return 0
        return round(self.recorder.events[-1]['timestamp'], 1)

    def clear_recording(self):
        """Discard the current recording."""
        self.recorder.events = []
        self.environment = None
        return {'status': 'cleared'}

    def quit_app(self):
        """Stop all activity and close the application.

        Window destruction happens on a separate thread after this bridge
        call has returned: destroying the calling window synchronously from
        the JS bridge deadlocks it (the window being torn down is the one
        servicing the call). A watchdog guarantees the process exits even if
        native teardown hangs.
        """
        try:
            if self.recorder.is_recording:
                self.recorder.stop()
                self.recorder.clear_exclusion_zone()
        except Exception:
            pass
        self._preview_active = False
        try:
            if self._playback_active:
                self.stop_workflow()
            else:
                self.recorder.stop_stop_hotkey_monitor()
        except Exception:
            pass

        def _force_exit():
            time.sleep(2.0)
            os._exit(0)

        def _shutdown():
            time.sleep(0.2)  # Let the bridge call return first
            import webview
            for window in list(webview.windows):
                try:
                    window.destroy()
                except Exception:
                    pass

        threading.Thread(target=_force_exit, daemon=True).start()
        threading.Thread(target=_shutdown, daemon=True).start()
        return {'status': 'quitting'}


def _get_workflows_dir():
    """Return the path to the app's workflows directory, creating it if needed."""
    base = os.path.join(
        os.path.expanduser('~'),
        'Library', 'Application Support', 'Phantom', 'workflows',
    )
    os.makedirs(base, exist_ok=True)
    return base


def _slugify_filename(name):
    """Create a safe filename from a workflow name with timestamp."""
    from datetime import datetime
    slug = re.sub(r'[^a-zA-Z0-9]+', '_', name).strip('_').lower()
    if not slug:
        slug = 'workflow'
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    return f'{slug}_{timestamp}.py'


def _summarize_event(event):
    """Create a compact summary of an event for the UI."""
    etype = event['type']
    t = round(event.get('timestamp', 0), 3)

    if etype == 'mousemove':
        return {
            'type': 'move',
            'time': t,
            'text': f"Move ({event['x']}, {event['y']})",
            'x': event['x'],
            'y': event['y'],
        }
    elif etype == 'mousedown':
        btn = event.get('button', 'left')
        return {
            'type': 'click',
            'time': t,
            'text': f"{btn.title()} down ({event['x']}, {event['y']})",
            'x': event['x'],
            'y': event['y'],
        }
    elif etype == 'mouseup':
        btn = event.get('button', 'left')
        return {
            'type': 'click',
            'time': t,
            'text': f"{btn.title()} up ({event['x']}, {event['y']})",
            'x': event['x'],
            'y': event['y'],
        }
    elif etype == 'keydown':
        return {
            'type': 'key',
            'time': t,
            'text': f"Key down: {event.get('key', '?')}",
        }
    elif etype == 'keyup':
        return {
            'type': 'key',
            'time': t,
            'text': f"Key up: {event.get('key', '?')}",
        }
    elif etype == 'scroll':
        return {
            'type': 'scroll',
            'time': t,
            'text': f"Scroll ({event['x']}, {event['y']}) dy={event.get('dy', 0)}",
        }
    else:
        return {
            'type': 'unknown',
            'time': t,
            'text': f"{etype}",
        }


def _check_accessibility(prompt=False):
    """Check Accessibility permission and optionally prompt."""
    try:
        from ApplicationServices import (
            AXIsProcessTrustedWithOptions,
            kAXTrustedCheckOptionPrompt,
            AXIsProcessTrusted,
        )
    except Exception:
        log.error('Failed to import accessibility APIs from ApplicationServices', exc_info=True)
        return False

    try:
        opts = {kAXTrustedCheckOptionPrompt: bool(prompt)}
        trusted = bool(AXIsProcessTrustedWithOptions(opts))
        log.debug('AXIsProcessTrustedWithOptions(prompt=%s) = %s', prompt, trusted)
        if trusted:
            return True
    except Exception:
        log.warning('AXIsProcessTrustedWithOptions failed', exc_info=True)
        try:
            if bool(AXIsProcessTrusted()):
                return True
        except Exception:
            log.warning('AXIsProcessTrusted also failed', exc_info=True)

    # Fallback: verify actual event tap capability (what pynput needs).
    return _can_create_event_tap()


def _check_automation(prompt=False):
    """Check Apple Events automation permission via System Events."""
    script = 'tell application "System Events" to get name of first process'
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        log.debug('Automation check: rc=%d, stderr=%s', result.returncode, result.stderr.strip())
        if result.returncode == 0:
            return True
        if not prompt:
            return False
        # A second run can trigger the system prompt if needed.
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return result.returncode == 0
    except Exception:
        log.error('Automation check failed', exc_info=True)
        return False


def _play_chime():
    """Play a short system alert sound."""
    sound_path = '/System/Library/Sounds/Glass.aiff'
    if not os.path.exists(sound_path):
        sound_path = '/System/Library/Sounds/Ping.aiff'
    try:
        subprocess.Popen(
            ['afplay', sound_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False


def _workflow_supports_flag(filepath, flag):
    """Detect whether a workflow script supports a given CLI flag."""
    try:
        with open(filepath, 'r') as f:
            for line in f:
                if flag in line:
                    return True
        return False
    except Exception:
        return False


def _workflow_default_skip(filepath, var_name):
    """Read static SKIP_* default from a workflow script, if present."""
    pattern = re.compile(rf'^\s*{re.escape(var_name)}\s*=\s*(True|False)\s*$')
    try:
        with open(filepath, 'r') as f:
            for line in f:
                m = pattern.match(line.strip())
                if m:
                    return m.group(1) == 'True'
    except Exception:
        return None
    return None


def _create_workflow_match_override(filepath, force_match_resolution=False,
                                    force_match_windows=False):
    """Create a temp workflow copy with SKIP_* defaults forced to False."""
    try:
        with open(filepath, 'r') as f:
            src = f.read()

        if force_match_resolution:
            src = re.sub(
                r'^\s*SKIP_RESOLUTION\s*=\s*True\s*$',
                'SKIP_RESOLUTION = False',
                src,
                flags=re.MULTILINE,
            )
        if force_match_windows:
            src = re.sub(
                r'^\s*SKIP_WINDOWS\s*=\s*True\s*$',
                'SKIP_WINDOWS = False',
                src,
                flags=re.MULTILINE,
            )

        fd, temp_path = tempfile.mkstemp(prefix='Phantom_playback_', suffix='.py')
        with os.fdopen(fd, 'w') as f:
            f.write(src)
        os.chmod(temp_path, 0o755)
        return temp_path
    except Exception:
        return None


def _extract_workflow_events(filepath):
    """Extract the EVENTS list from a workflow .py file.

    Parses the ``EVENTS = [...]`` assignment using ast.literal_eval so no
    code is executed.  Returns a list of tuples, or None on failure.
    """
    import ast

    try:
        with open(filepath, 'r') as f:
            src = f.read()
    except Exception:
        return None

    m = re.search(r'^EVENTS\s*=\s*', src, re.MULTILINE)
    if not m:
        return None

    # Find the balanced bracket expression starting at the '['
    start = src.index('[', m.end() - 1)
    depth = 0
    end = start
    for i in range(start, len(src)):
        if src[i] == '[':
            depth += 1
        elif src[i] == ']':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    try:
        return ast.literal_eval(src[start:end])
    except Exception:
        return None


def _workflow_tuple_to_preview_event(tup):
    """Convert a compact workflow event tuple to a dict for _preview_event.

    Tuple formats (from _process_events):
        Mouse:  (t, 'move'/'drag'/'left_down'/'left_up'/..., x, y)
        Key:    (t, 'key_down'/'key_up', keycode, modifiers)
        Scroll: (t, 'scroll', x, y, dx, dy)
    """
    t = tup[0]
    etype = tup[1]

    if etype in ('move', 'drag', 'right_drag'):
        return {'timestamp': t, 'type': 'mousemove', 'x': tup[2], 'y': tup[3]}
    elif etype in ('left_down', 'right_down', 'middle_down'):
        return {'timestamp': t, 'type': 'mousedown', 'x': tup[2], 'y': tup[3]}
    elif etype in ('left_up', 'right_up', 'middle_up'):
        return {'timestamp': t, 'type': 'mouseup', 'x': tup[2], 'y': tup[3]}
    elif etype == 'key_down':
        from phantom.keymap import key_display_name_from_keycode
        keycode = tup[2]
        mods = tup[3] if len(tup) > 3 else 0
        shift = bool(mods & 0x020000)  # kCGEventFlagMaskShift
        name = key_display_name_from_keycode(keycode, shift=shift)
        return {'timestamp': t, 'type': 'keydown', 'key': name}
    elif etype == 'key_up':
        return {'timestamp': t, 'type': 'keyup'}
    elif etype == 'scroll':
        return {
            'timestamp': t, 'type': 'scroll',
            'x': tup[2], 'y': tup[3],
            'dx': tup[4] if len(tup) > 4 else 0,
            'dy': tup[5] if len(tup) > 5 else 0,
        }
    return {'timestamp': t, 'type': etype}


def _open_settings_pane(pane):
    """Open a System Settings privacy pane."""
    url = f'x-apple.systempreferences:com.apple.preference.security?{pane}'
    try:
        subprocess.Popen(
            ['open', url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False


def _run_on_main_thread(func, timeout=2.0):
    """Run a callable on the main thread and return its value."""
    try:
        from AppKit import NSThread
        from PyObjCTools.AppHelper import callAfter
    except Exception:
        return func()

    if NSThread.isMainThread():
        return func()

    result = {'value': False}
    done = threading.Event()

    def _runner():
        try:
            result['value'] = func()
        finally:
            done.set()

    callAfter(_runner)
    done.wait(timeout)
    return result['value']


def _trigger_accessibility_probe():
    """Attempt a minimal action that requires Accessibility permission."""
    return bool(_run_on_main_thread(_trigger_accessibility_probe_core))


def _trigger_accessibility_probe_core():
    return _can_create_event_tap()


def _can_use_accessibility_api():
    """Return True if AX API access succeeds."""
    try:
        from ApplicationServices import (
            AXUIElementCreateSystemWide,
            AXUIElementCopyAttributeValue,
            kAXFocusedUIElementAttribute,
            kAXErrorSuccess,
        )
    except Exception:
        log.error('Failed to import AX UI element APIs', exc_info=True)
        return False

    try:
        sys_elem = AXUIElementCreateSystemWide()
        err, _value = AXUIElementCopyAttributeValue(
            sys_elem,
            kAXFocusedUIElementAttribute,
            None,
        )
        ok = err == kAXErrorSuccess
        log.debug('AX API probe: err=%s, ok=%s', err, ok)
        return ok
    except Exception:
        log.warning('AX API probe failed', exc_info=True)
        return False



def _can_create_event_tap():
    """Return True if an event tap can be created (Accessibility granted)."""
    try:
        from Quartz import (
            CGEventTapCreate,
            CGEventMaskBit,
            kCGEventKeyDown,
            kCGHIDEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
        )
    except Exception:
        log.error('Failed to import CGEventTap APIs from Quartz', exc_info=True)
        return False

    def _tap_callback(proxy, etype, event, refcon):
        return event

    try:
        tap = CGEventTapCreate(
            kCGHIDEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit(kCGEventKeyDown),
            _tap_callback,
            None,
        )
        ok = tap is not None
        log.debug('Event tap probe: %s', 'ok' if ok else 'failed (None)')
        return ok
    except Exception:
        log.warning('Event tap creation failed', exc_info=True)
        return False


def _trigger_automation_probe():
    """Attempt an explicit Apple Event action that should trigger Automation."""
    script = '''
    tell application "System Events"
        tell process "Finder"
            set frontmost to true
            if (count of windows) > 0 then
                set _ to name of front window
            end if
        end tell
    end tell
    '''
    try:
        subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return True
    except Exception:
        return False
