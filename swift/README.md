# Phantom (Swift)

A native macOS rewrite of Phantom — the input recorder and replayer — with no
Python, no embedded interpreter, and no web view. One 3 MB binary that is both
the app and its CLI.

```bash
./Scripts/build_app.sh          # universal build → build/Phantom.app
open build/Phantom.app
```

Grant **Accessibility** when asked (System Settings → Privacy & Security →
Accessibility). Nothing else is required.

---

## What changed from the Python build

The behaviour is the same; the machinery underneath it is not.

| Concern | Python | Swift |
|---|---|---|
| Input capture | `pynput` + a second Quartz tap for keys, with a main-thread monkey-patch for macOS 15 | one `CGEventTap` for mouse, keys and scroll, on its own run loop, that re-enables itself when macOS disables it |
| Playback | generated a `.py` script, ran it as a subprocess, scraped stdout for progress, fed `y\n` to its prompts | runs in-process; progress is a callback and Stop takes effect on the next event |
| Window restore | one `osascript` process per window, via System Events | the Accessibility API directly — the permission Phantom already holds |
| Interface | 3,000 lines of HTML/CSS/JS in `pywebview`, driven by `evaluate_js` strings | SwiftUI views observing one `AppState` |
| CLI playback | detached supervisor process, PID file, status JSON file | a Unix socket to the running app, which is the process that holds the permission |
| Bundle | ~30 MB (interpreter + pyobjc + pynput) | 3 MB native, 5 MB universal |

Three things got better rather than merely different:

- **Double-clicks replay as double-clicks.** Click state is captured and
  re-posted, so applications see the gesture the user actually made.
- **Trackpad scrolling replays smoothly.** Pixel-precise deltas are recorded
  alongside line deltas; the old build kept only line deltas, which a trackpad
  mostly reports as zero.
- **Stopping mid-drag no longer leaves a stuck mouse button.** Anything still
  held down when playback ends is released.

Two deliberate behaviour changes:

- The playback confirmation still chimes after 20 seconds, but no longer
  cancels itself after 35. Nothing that posts real input starts or stops on a
  timer.
- **Automation permission is no longer required.** Window restore uses the
  Accessibility API and app activation uses AppKit, so there are no Apple
  Events to authorise. Exported Python scripts still use AppleScript, so
  running *those* will ask.

---

## Your existing workflows still work

Workflows recorded by the Python build are read directly — they appear in the
library marked `PY`, load, preview, and play like any other. Nothing is
executed while reading them; only the header, `WINDOWS`, `FRONTMOST_APP`, and
`EVENTS` are parsed.

Convert one to the native format when you want to (the original is left alone):

```bash
phantom convert testworkflow_20260806_154353.py
```

New recordings are saved as `.phantom` — JSON with a readable header and one
event per line, so a 75,000-event workflow stays greppable and diffs line by
line:

```json
{
  "actionCount" : 1080,
  "durationSeconds" : 22.586,
  "environment" : { "width" : 1496, "height" : 935, ... },
  "name" : "Testworkflow",
  "events" : [
{"k":"move","t":0.8893,"x":990,"y":447},
{"k":"left_down","t":1.204,"x":412,"y":388,"cs":1},
{"k":"key_down","t":2.010,"vk":1,"f":1048576},
  ]
}
```

To hand a workflow to someone who does not have Phantom, export a standalone
Python script — the old format, still self-contained, needing only pyobjc:

```bash
phantom export "Testworkflow" --to ~/Desktop/testworkflow.py
```

---

## Command line

The app bundle *is* the CLI. Link it onto your `PATH`:

```bash
ln -sf /Applications/Phantom.app/Contents/MacOS/Phantom /usr/local/bin/phantom
```

```
WORKFLOWS
  list                          List saved workflows
  inspect <workflow>            Print a workflow's events
  rename <workflow> <name>      Rename a workflow
  delete <workflow>             Delete a workflow
  convert <workflow>            Rewrite a legacy .py workflow as .phantom
  export <workflow> [--to P]    Write a standalone Python script

PLAYBACK
  run <workflow> [--speed N] [--loop N] [--loop-delay N]
                 [--skip-resolution] [--skip-windows]
  stop
  status

RECORDING
  record                        Open Phantom and start the record prompt

DIAGNOSTICS
  doctor                        Report permissions, paths, and app state
```

Every command prints JSON; add `--pretty` for a table first. A workflow can be
named by filename, exact name, or a fragment of its name.

`run`, `stop`, and `status` are handed to the running app over a Unix socket at
`~/Library/Application Support/Phantom/control.sock`, launching it if needed.
That is not indirection for its own sake: macOS only lets a process trusted for
Accessibility post input, and a binary invoked from Terminal is not that
process — the app bundle is.

---

## Recording

Press **Record**, and the options prompt appears on the overlay. Choose whether
to capture the display resolution and the window arrangement, then press
**SPACE** or **BEGIN**. After a three-second countdown the panel collapses into
a small chip in the corner and capture begins.

Stop with the chip, or with **⌃⌥⌘⎋** from anywhere.

While recording, the panel's own screen region is excluded from capture, so
clicking Stop never ends up in the workflow.

> Keystrokes are stored as readable text in the workflow file. Don't type
> passwords while recording.

---

## Playback

Load a workflow, press **Run**, and confirm. Before any input is posted,
Phantom restores the stage:

1. matches the recorded display resolution, if asked to, and puts it back afterwards
2. moves each recorded window back to its position and size
3. activates the app that was frontmost

Then it replays, scheduling every event against one absolute start time so
per-event overhead cannot accumulate into drift. Speed, loop count, delay
between runs, and an optional URL to poll between runs are all per-run choices.

**⌃⌥⌘⎋** stops playback immediately.

---

## Layout

```
Sources/PhantomCore/
  Core/         Recording, playback, and the workflow format
    EventRecorder        CGEventTap capture (replaces recorder.py)
    WorkflowPlayer       In-process replay (replaces the generated script + supervisor)
    Workflow             Document model and file format (replaces workflow.py)
    WorkflowStore        The workflows folder (replaces api.py's file handling)
    LegacyPythonWorkflow Reads .py workflows from the Python build
    PythonExporter       Writes standalone .py scripts
    WindowRestorer       AX-based window restore (replaces the osascript setup phase)
    DisplayModeMatcher   Resolution matching and restore
    ScreenEnvironment    Resolution, windows, frontmost app (replaces environment.py)
    Keymap               Virtual keycodes (replaces keymap.py)
    Permissions          Accessibility and Screen Recording
  App/          Windows, coordination, entry point (replaces app.py and api.py)
  UI/           SwiftUI views (replaces ui/index.html and ui/overlay.html)
  CLI/          Command line and control socket (replaces cli.py and _supervisor.py)
```

---

## Building

```bash
swift build                     # development
swift test                      # 30 tests, no permissions needed
./Scripts/build_app.sh          # universal .app, ad-hoc signed
./Scripts/build_app.sh --debug  # quick native build
```

Ad-hoc signing means macOS treats each rebuild as a new application and asks
for Accessibility again, because TCC ties the grant to the code signature. Sign
with a stable identity to keep the grant across updates:

```bash
DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)" ./Scripts/build_app.sh
```

For distribution, notarise as well:

```bash
ditto -c -k --keepParent build/Phantom.app build/Phantom.zip
xcrun notarytool submit build/Phantom.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple build/Phantom.app
```

The bundle identifier is unchanged (`com.alexgoodhart.Phantom`), so keep only
one Phantom installed at a time.
