# Phantom for macOS

## What It Is

Phantom is a macOS desktop tool that watches everything you do on screen — every mouse movement, click, drag, keystroke, and scroll — and produces a script that can do it again. You perform a task once while the recorder is running. It writes a self-contained Python workflow that replays your actions as real, consequential input events. The target application cannot tell the difference between the script and your hands.

## Why It Exists

AppleScript is the native automation language on macOS. It lets you tell applications to do things: open files, create documents, move windows. But it only works if the application cooperates. An app must ship a scripting dictionary — a structured description of its objects and commands — for AppleScript to address it meaningfully. Finder does this. Safari does. The iWork suite, some Adobe products, and a handful of professional tools do.

Most software does not. The entire generation of Electron-based applications — Slack, Discord, VS Code, Notion, Spotify — exposes no scripting interface at all. Neither do most cross-platform ports, indie utilities, games, or any application whose developer didn't prioritize macOS-native automation. This isn't a temporary gap. The trend is toward web-based application frameworks that have no concept of a scripting dictionary. The proportion of scriptable Mac apps is shrinking, not growing.

For unscriptable applications, the only automation path is direct input: moving the mouse, clicking at coordinates, typing characters. This is what Phantom enables. It doesn't try to understand the application's UI or interpret what buttons mean. It records exactly what you did — where your pointer went, what you pressed — and replays it at the operating system level using the same event pipeline that physical hardware feeds into.

The standard criticism of coordinate-based automation is that it breaks when something moves. If a window is in a different position, or the screen resolution changed, the coordinates land in the wrong place. Phantom handles this by recording the screen environment alongside the actions. Every workflow knows what resolution it was recorded at, where every window was, and which app was in front. Before replaying any input, it restores that environment. The coordinates stay valid because the context is preserved.

## How Recording Works

When the user presses Record, two things happen simultaneously: the app begins capturing input events, and it takes a snapshot of the current screen state.

### Input Capture

Phantom hooks into the macOS global event stream. Every input event that passes through the system — regardless of which application is focused — is observed and logged. The event types captured are:

**Mouse movement.** The pointer's screen coordinates are tracked continuously. Events are stored at the rate the OS delivers them, which on standard hardware is around 125 updates per second. Redundant data points (cursor stationary, or moving in a perfectly straight line) can be compressed during export, but are captured faithfully during recording so no information is lost.

**Clicks.** Each mouse button press and release is recorded separately, along with screen coordinates and which button was used (left, right, middle). Recording press and release as distinct events is what makes drag detection possible — a drag is simply a press, a series of movements, and a release.

**Keyboard input.** Every key press and release, including modifier state (Shift, Command, Option, Control). Modifier-only key events (pressing Shift without another key) are recorded because some applications respond to them. System-reserved shortcuts like Cmd+Tab are noted but flagged as non-reproducible.

**Scroll events.** Scroll wheel input at the cursor's current position, with both horizontal and vertical deltas preserved.

Every event carries a timestamp relative to the start of recording. These timestamps are what allow the replay to match the original timing — or to run faster or slower if the user adjusts the playback speed.

### Environment Snapshot

At the moment recording starts, the app captures:

- The display resolution — the effective resolution the OS is using, accounting for Retina scaling.
- The position and size of every visible window, and which application owns it.
- Which application is frontmost.

This data doesn't change during recording. It represents the stage on which the recorded actions were performed.

### What the User Sees

During recording, the app presents a compact floating overlay that stays above all other windows without capturing focus. It shows a live log of events as they're captured — clicks, keystrokes, movements — in a scrolling monospace display. A colored dot follows the cursor, and click events produce brief visual feedback. This is so the user can confirm recording is working and catch mistakes in real time. The overlay's own controls (Record, Stop, etc.) are excluded from the recording.

## How Playback Works

A recorded session produces a Python script called a **workflow**. Running a workflow is a two-phase process.

### Phase One: Environment Setup

The script starts by restoring the screen environment that existed during recording. It does this using AppleScript, invoked via subprocess calls to `osascript`. AppleScript is used here — and only here — because it is the best tool for talking to the window manager. It can tell specific applications to reposition and resize their windows, activate the correct app, and verify the current state of the desktop.

The setup phase:

1. Checks the current display resolution against the recorded value. If they don't match, the workflow warns the user and stops. Optionally, if `displayplacer` or a similar tool is available, it can attempt to set the resolution — but this is not a default behavior.
2. Iterates through the recorded window positions. For each window, it tells the owning application to set the window's position and size to the recorded values via System Events.
3. Activates the application that was frontmost when recording started.

After setup, the screen matches the state it was in when the user pressed Record. The coordinates in the interaction phase are now valid.

### Phase Two: Input Replay

The script replays every recorded event using `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, and `CGEventPost` from Apple's CoreGraphics framework, accessed through Python's `pyobjc` bindings. These are not simulated or visual — they are real input events injected into the same OS-level pipeline that hardware input travels through. The target application receives them as if they came from the user's physical mouse and keyboard.

Mouse movements are replayed as a sequence of `kCGEventMouseMoved` events. Clicks are press/release pairs at the recorded coordinates. Drags are a press, a sequence of `kCGEventLeftMouseDragged` events tracing the recorded path, and a release. Keystrokes are press/release pairs with the correct modifier flags. Scroll events are posted with the recorded deltas at the recorded cursor position.

Timing between events matches the original recording by default. The workflow accepts a speed multiplier so users can run it faster for repetitive tasks where exact timing isn't important, or slower for debugging.

### Why Python, Not Pure AppleScript

The generated workflows are Python scripts, not AppleScript files. AppleScript is used as a tool within them for window management, but the input simulation and overall orchestration are Python.

The reason is capability. AppleScript can click at coordinates and send keystrokes through System Events, but it cannot move the mouse pointer to an arbitrary position without clicking. It has no concept of a mouse drag as a continuous path. It cannot post scroll events. For an application like a modular synth, a drawing tool, or anything with sliders, knobs, or drag-based interaction, AppleScript can't do the job.

CoreGraphics can. It operates at the level the OS itself uses to process input. Every type of input event the hardware can produce, CoreGraphics can synthesize. Python, through `pyobjc`, gives clean access to this.

Python also stays in control of the workflow execution. It manages timing, handles errors, calls `osascript` for window management when needed, and can be extended with logic (loops, conditionals, reading from files) without hitting AppleScript's limitations as a general-purpose language.

## The Workflow as a Unit

A workflow file is self-contained. It includes the environment snapshot, the recorded events, and all the logic to set up and replay. A user can:

- Run it on a different day when their windows are rearranged. The setup phase fixes the layout.
- Share it with someone else who has the same applications and screen resolution.
- Chain multiple workflows together with a simple wrapper script for multi-step routines.
- Edit it by hand. It's a Python file with readable structure — not a binary blob.

## What It Requires

**macOS Accessibility permission.** Any application that monitors global input events or posts synthetic input must be granted Accessibility access by the user. This is a one-time authorization in System Settings > Privacy & Security > Accessibility. The app prompts for it on first launch. Once granted, it persists unless the user revokes it or the app bundle is replaced.

**A consistent display environment for playback.** Workflows are valid at the resolution they were recorded at. The setup phase handles window positions, but it cannot fix a resolution mismatch. If the user's display configuration has changed, they need to either restore it or re-record the workflow.

**macOS 13 (Ventura) or later.** This provides the baseline for the Accessibility APIs, System Events behavior, and permissions model the app depends on.

**Python dependencies.** The recorder itself uses `pynput` for event capture during recording and `pyobjc` for CoreGraphics access during playback. These are bundled into the `.app` package — the end user does not need Python installed.

## User Interface

The interface is a floating overlay built in HTML/CSS/JS, rendered in a native window. Its design is drawn from the included `watcher.html` prototype: dark background, green (#00ff88) accent color, monospace text, compact layout. It includes:

- **Record / Stop controls.** Start and stop a recording session.
- **A live event log.** A scrolling list of captured events in compact text. Gives the user real-time confirmation that recording is working.
- **A cursor indicator.** A colored dot that follows the pointer, with visual feedback on clicks and keystrokes.
- **An optional grid overlay.** Thin lines drawn across the screen at adjustable intervals for spatial reference.
- **Export.** After recording, generates the workflow file and lets the user choose where to save it.
- **Preview replay.** Plays back the recorded events visually in the overlay (moves the indicator dot, shows clicks and keystrokes) without posting real input. For verifying a recording looks right before committing to a file.

The overlay does not steal focus. The user interacts normally with their applications while it's present. Events on the overlay's own controls are excluded from recording.

---

## Tech Stack

### Language: Python 3

The entire application is Python. The recorder, the UI host, the script generator, and the generated workflow files themselves.

Python is chosen for three reasons. First, the hard parts of this project — global event capture, synthetic input, window management — are all solved by existing Python libraries with mature macOS support (`pynput`, `pyobjc`, `osascript` via subprocess). Second, the generated workflows being Python files means they're readable, editable, and extensible by anyone, including AI tools. Third, Python has the deepest pool of reference material and examples for AI-assisted development, which matters because AI is doing the implementation.

### Key Libraries

**`pynput`** — Global mouse and keyboard listener. Used during recording to capture all input events system-wide. Provides `on_move`, `on_click`, `on_scroll` for mouse and `on_press`, `on_release` for keyboard. This is the recording engine.

**`pyobjc` (`pyobjc-framework-Quartz`)** — Python bindings for Apple's CoreGraphics and Quartz frameworks. Used in generated workflows to post synthetic input events via `CGEventCreateMouseEvent`, `CGEventCreateKeyboardEvent`, `CGEventPost`, and `CGEventCreateScrollWheelEvent`. This is the playback engine.

**`subprocess` (stdlib)** — Calls `osascript` to run AppleScript commands for window management during the setup phase of workflows. No additional library needed.

**`pywebview`** — Hosts the HTML/CSS/JS interface in a native macOS window. Provides the bridge between the Python backend and the web-based UI. Allows the overlay to float above other windows without stealing focus.

### Packaging

The application is packaged as a macOS `.app` bundle using `py2app`. This bundles the Python interpreter, all dependencies, and the HTML/CSS/JS assets into a single distributable application. The end user double-clicks it like any other Mac app. No Python installation required. Bundle size will be in the range of 30-50MB due to the included interpreter — functionally irrelevant.

### Generated Workflow Structure

A workflow file is a standalone `.py` script with this structure:

```python
#!/usr/bin/env python3
"""
Workflow: [user-provided name or timestamp]
Recorded: [date and time]
Resolution: [width x height]
Actions: [count]
"""

import subprocess
import time
from Quartz import (
    CGEventCreateMouseEvent,
    CGEventCreateKeyboardEvent,
    CGEventCreateScrollWheelEvent,
    CGEventPost,
    kCGEventMouseMoved,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventLeftMouseDragged,
    kCGHIDEventTap,
    # ... other constants as needed
)

SPEED = 1.0  # Playback speed multiplier

# --- Environment recorded at capture time ---
RESOLUTION = (2560, 1440)
WINDOWS = [
    {"app": "Safari", "name": "Window Title", "x": 0, "y": 25, "w": 1280, "h": 800},
    # ...
]
FRONTMOST_APP = "Safari"

def setup():
    """Restore the screen environment from recording time."""
    # Check resolution
    # Position windows via osascript
    # Activate frontmost app

def replay():
    """Replay recorded input events."""
    # Series of CGEventPost calls with time.sleep() for timing

if __name__ == "__main__":
    setup()
    replay()
```

The workflow has no dependency on Phantom itself. It only needs `pyobjc-framework-Quartz` installed (or the user can run it from within the Phantom environment). It's a plain Python script that can be run with `python3 workflow.py`, inspected, modified, or integrated into larger automation pipelines.

### Existing Prototype

The project directory includes `Phantom.py`, a working prototype that records clicks and keystrokes via `pynput` and exports AppleScript. It demonstrates the core recording loop and serves as a starting point. The full implementation extends it with mouse movement tracking, drag detection, CoreGraphics-based playback, environment capture, and the web-based UI.

The directory also includes `watcher.html`, a functional prototype of the overlay interface with the visual design (grid, cursor indicator, event log, control panel) that the final UI will use.
