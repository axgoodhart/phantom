# Sour Apple Branch — State Summary

**Branch:** `sour-apple`
**Base commit:** `d421382` (fixes/round-1 — "Fix button reliability, window positioning, add abort hotkey, and mini playback mode")
**Date:** 2026-04-01

This branch preserves a set of changes made across multiple Claude Code sessions that introduced bugs or incomplete features. It's kept for reference while we revert to a stable baseline and re-approach each feature properly.

---

## What Was Changed (718 lines across 5 files)

### phantom/api.py (+227 lines)
- Added screenshot capture on recording start (`_capture_screenshot_jpeg`)
- Added ghost screenshot display during playback (`_load_ghost_screenshot`, `showGhostScreenshot`)
- Added gesture event preview (magnify, rotate, swipe, smart_magnify, space_switch)
- Added `begin_recording_from_overlay` screenshot parameter
- Added screenshot save as companion `.jpg` alongside workflow `.py`

### phantom/recorder.py (+220 lines)
- Added raw trackpad gesture capture via Quartz CGEvent tap (magnify, rotate, swipe, smart_magnify)
- Added private CGS functions for desktop space tracking (CGSMainConnectionID, CGSGetActiveSpace, CGSCopyManagedDisplaySpaces)
- Added NSWorkspace notification observer for space switch detection
- Extended keyboard event tap mask to include gesture event types

### phantom/workflow.py (+108 lines)
- Added gesture event processing (magnify, rotate, swipe, smart_magnify, space_switch)
- Added `post_gesture()`, `post_swipe()`, `post_space_switch()` replay functions
- Added CGEvent-based gesture replay using private field IDs from WebKit source

### phantom/ui/overlay.html (+202 lines)
- Added CSS for gesture indicators (pinch, rotate, swipe, zoom)
- Added CSS for space switch indicator
- Added `showGesture()` and `showSpaceSwitch()` JS functions

### phantom/app.py (-1 line)
- Removed `opacity=0.6` from panel window creation

---

## Known Issues (Why This Was Reverted)

### 1. Screenshot feature — no visible effect
- **Status:** Fully implemented but silently broken
- **Root cause:** Ghost screenshot display passes a massive base64 data URL through `evaluate_js()`, which likely fails. The `try/except` swallows the error silently.
- **Files:** `api.py` line ~886

### 2. Abort hotkey doesn't work
- **Status:** Pre-existing from commit d421382, not introduced here
- **Root cause:** `CGEventTapCreate()` in watchdog.py silently returns None when Accessibility permissions aren't granted. No user-facing warning — just a print statement.
- **Files:** `watchdog.py` lines 121-123

### 3. Quitting the app doesn't stop the running workflow
- **Status:** Pre-existing from commit d421382
- **Root cause:** No `panel.events.closing` handler in `app.py`. The workflow subprocess is never terminated on quit, leaving it running as an orphaned process.
- **Fix needed:** Add window close handler that calls `api.stop_workflow()`

### 4. Multi-touch gestures misclassified as "magnify"
- **Status:** Introduced in this branch
- **Root cause:** Raw CGEvent gesture capture was added when the intent was effect-based detection only. macOS sends intermediate magnify events during 3/4-finger gesture recognition before the system decides the final gesture type. These noise events get recorded as real pinch gestures.
- **What should have been done:** Only detect the *effects* of system gestures (space switch notifications, Mission Control activation, etc.), not raw gesture events.

### 5. Mini playback progress bar never updates
- **Status:** Pre-existing from commit d421382
- **Root cause:** The Python monitor thread parses subprocess stdout for `Progress:\s*(\d+)%\s*\((\d+)/(\d+)\)` and calls `updatePlaybackProgress()`. Either the regex doesn't match actual output, or the subprocess isn't flushing stdout.
- **Files:** `api.py` line ~940, `index.html` line ~2153

### 6. Abrupt playback start — no transition
- **Status:** Pre-existing from commit d421382
- **Root cause:** Recording has a dedicated overlay prompt with countdown and SPACE-to-start. Playback has only an HTML modal with options — clicking "Start" immediately begins execution with no countdown or visual transition.
- **Files:** `index.html` lines ~1964-2046

---

## Salvageable Ideas

### Space switch detection (KEEP approach, redo implementation)
- The `NSWorkspaceActiveSpaceDidChangeNotification` + `CGSGetActiveSpace` approach for detecting desktop space changes works and was verified on this system.
- The direction detection via `CGSCopyManagedDisplaySpaces` ordered space list is correct.
- Replay via `Ctrl+Arrow` keyboard simulation is the right approach.
- Should be re-implemented cleanly without the raw gesture capture.

### Screenshot capture concept (KEEP concept, fix bridge)
- The capture/save/load pipeline works. Only the JS bridge call for display fails.
- Need to fix the `evaluate_js` call — either chunk the data, use a file URL, or pass through pywebview's proper data channel.

### Ghost screenshot overlay (KEEP)
- The CSS/JS in overlay.html for displaying the ghost screenshot is correct and well-styled.
