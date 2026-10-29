import Foundation

/// Writes a workflow as a standalone Python script.
///
/// Playback no longer needs Python, but a workflow you can read, edit, hand
/// to someone else, or drop into a larger automation pipeline was part of
/// the point of this tool. The generated script depends only on pyobjc.
public enum PythonExporter {

    public static func script(for workflow: Workflow) -> String {
        let timestamp = DateFormatter.pythonHeader.string(from: workflow.recordedAt)
        let events = workflow.events.map(tuple(for:)).joined(separator: "\n")
        let windows = workflow.environment.windows.map { window in
            "    {\"app\": \(quote(window.app)), \"name\": \(quote(window.name)), "
                + "\"x\": \(window.x), \"y\": \(window.y), "
                + "\"w\": \(window.w), \"h\": \(window.h)},"
        }.joined(separator: "\n")

        return """
        #!/usr/bin/env python3
        # -*- coding: utf-8 -*-
        \"\"\"
        Workflow: \(docstringSafe(workflow.name))
        Recorded: \(timestamp)
        Resolution: \(workflow.environment.width) x \(workflow.environment.height)
        Actions: \(workflow.actionCount)
        Duration: \(String(format: "%.1f", workflow.durationSeconds))s

        Exported from Phantom. Replays with pyobjc:
            pip install pyobjc-framework-Quartz
            python3 \(WorkflowStore.filename(for: workflow.name, recordedAt: workflow.recordedAt)
                        .replacingOccurrences(of: ".phantom", with: ".py"))
        \"\"\"

        import argparse
        import subprocess
        import sys
        import time

        try:
            from Quartz import (
                CGDisplayBounds,
                CGEventCreateKeyboardEvent,
                CGEventCreateMouseEvent,
                CGEventCreateScrollWheelEvent,
                CGEventPost,
                CGEventSetFlags,
                CGEventSetIntegerValueField,
                CGMainDisplayID,
                kCGEventLeftMouseDown,
                kCGEventLeftMouseDragged,
                kCGEventLeftMouseUp,
                kCGEventMouseMoved,
                kCGEventOtherMouseDown,
                kCGEventOtherMouseUp,
                kCGEventRightMouseDown,
                kCGEventRightMouseDragged,
                kCGEventRightMouseUp,
                kCGHIDEventTap,
                kCGMouseButtonCenter,
                kCGMouseButtonLeft,
                kCGMouseButtonRight,
                kCGMouseEventClickState,
                kCGScrollEventUnitLine,
                kCGScrollEventUnitPixel,
            )
        except ImportError:
            sys.exit("pyobjc-framework-Quartz is required: pip install pyobjc-framework-Quartz")

        WORKFLOW_NAME = \(quote(workflow.name))
        SPEED = \(workflow.options.defaultSpeed)
        MATCH_RESOLUTION = \(workflow.options.matchResolution ? "True" : "False")
        MATCH_WINDOWS = \(workflow.options.matchWindows ? "True" : "False")

        RESOLUTION = (\(workflow.environment.width), \(workflow.environment.height))
        FRONTMOST_APP = \(quote(workflow.environment.frontmostApp))
        WINDOWS = [
        \(windows)
        ]

        # (t, kind, ...) — mouse: x, y; key: keycode, flags; scroll: x, y, dx, dy
        EVENTS = [
        \(events)
        ]


        def run_applescript(script):
            try:
                result = subprocess.run(
                    ["osascript", "-e", script],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                return result.returncode == 0
            except Exception:
                return False


        def check_resolution():
            bounds = CGDisplayBounds(CGMainDisplayID())
            current = (int(bounds.size.width), int(bounds.size.height))
            if current == RESOLUTION:
                return True
            print(f"Warning: recorded at {RESOLUTION[0]}x{RESOLUTION[1]}, "
                  f"now {current[0]}x{current[1]}; coordinates may not line up.")
            return False


        def setup():
            if MATCH_RESOLUTION:
                check_resolution()
            if MATCH_WINDOWS:
                for window in WINDOWS:
                    app = window["app"].replace("\\\\", "\\\\\\\\").replace('"', '\\\\"')
                    title = window["name"].replace("\\\\", "\\\\\\\\").replace('"', '\\\\"')
                    run_applescript(f'tell application "{app}" to activate')
                    time.sleep(0.2)
                    run_applescript(f'''
        tell application "System Events" to tell process "{app}"
            set matched to false
            repeat with w in windows
                if name of w is "{title}" then
                    set position of w to {{{window["x"]}, {window["y"]}}}
                    set size of w to {{{window["w"]}, {window["h"]}}}
                    set matched to true
                    exit repeat
                end if
            end repeat
            if not matched and (count of windows) > 0 then
                set position of window 1 to {{{window["x"]}, {window["y"]}}}
                set size of window 1 to {{{window["w"]}, {window["h"]}}}
            end if
        end tell''')
            app = FRONTMOST_APP.replace("\\\\", "\\\\\\\\").replace('"', '\\\\"')
            run_applescript(f'tell application "{app}" to activate')
            time.sleep(0.5)


        def post_mouse(event_type, x, y, button=kCGMouseButtonLeft, click_state=0):
            event = CGEventCreateMouseEvent(None, event_type, (x, y), button)
            if click_state:
                CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_state)
            CGEventPost(kCGHIDEventTap, event)


        def post_key(keycode, key_down, flags):
            event = CGEventCreateKeyboardEvent(None, keycode, key_down)
            CGEventSetFlags(event, flags)
            CGEventPost(kCGHIDEventTap, event)


        def post_scroll(x, y, dx, dy, pixels):
            post_mouse(kCGEventMouseMoved, x, y)
            unit = kCGScrollEventUnitPixel if pixels else kCGScrollEventUnitLine
            CGEventPost(kCGHIDEventTap,
                        CGEventCreateScrollWheelEvent(None, unit, 2, int(dy), int(dx)))


        MOUSE_KINDS = {
            "move": (kCGEventMouseMoved, kCGMouseButtonLeft),
            "drag": (kCGEventLeftMouseDragged, kCGMouseButtonLeft),
            "right_drag": (kCGEventRightMouseDragged, kCGMouseButtonRight),
            "left_down": (kCGEventLeftMouseDown, kCGMouseButtonLeft),
            "left_up": (kCGEventLeftMouseUp, kCGMouseButtonLeft),
            "right_down": (kCGEventRightMouseDown, kCGMouseButtonRight),
            "right_up": (kCGEventRightMouseUp, kCGMouseButtonRight),
            "middle_down": (kCGEventOtherMouseDown, kCGMouseButtonCenter),
            "middle_up": (kCGEventOtherMouseUp, kCGMouseButtonCenter),
        }


        def replay(speed):
            total = len(EVENTS)
            start = time.perf_counter()
            for index, entry in enumerate(EVENTS):
                delay = (start + entry[0] / speed) - time.perf_counter()
                if delay > 0.0005:
                    time.sleep(delay)

                kind = entry[1]
                if kind in MOUSE_KINDS:
                    event_type, button = MOUSE_KINDS[kind]
                    click_state = entry[4] if len(entry) > 4 else 0
                    post_mouse(event_type, entry[2], entry[3], button, click_state)
                elif kind == "key_down":
                    post_key(entry[2], True, entry[3])
                elif kind == "key_up":
                    post_key(entry[2], False, entry[3])
                elif kind == "scroll":
                    pixels = len(entry) > 6 and (entry[6] or entry[7])
                    dx = entry[6] if pixels else entry[4]
                    dy = entry[7] if pixels else entry[5]
                    post_scroll(entry[2], entry[3], dx, dy, pixels)

                if (index + 1) % 500 == 0 or index == total - 1:
                    print(f"  Progress: {int((index + 1) / total * 100)}% ({index + 1}/{total})",
                          flush=True)


        if __name__ == "__main__":
            parser = argparse.ArgumentParser(description=f"Replay {WORKFLOW_NAME}")
            parser.add_argument("--speed", type=float, default=SPEED)
            parser.add_argument("--skip-setup", action="store_true")
            args = parser.parse_args()

            print(f"Workflow: {WORKFLOW_NAME}  ({len(EVENTS)} actions, {args.speed}x)")
            if not args.skip_setup:
                setup()
            replay(max(0.05, args.speed))
            print("Replay complete.")

        """
    }

    // MARK: - Literals

    private static func tuple(for event: PhantomEvent) -> String {
        let t = String(format: "%.4f", event.t)
        switch event.kind {
        case .keyDown, .keyUp:
            return "    (\(t), '\(event.kind.rawValue)', \(event.keycode ?? 0), \(event.flags ?? 0)),"
        case .scroll:
            return "    (\(t), 'scroll', \(event.x), \(event.y), "
                + "\(event.dx ?? 0), \(event.dy ?? 0), \(event.pdx ?? 0), \(event.pdy ?? 0)),"
        default:
            let clickState = event.clickState ?? 0
            return "    (\(t), '\(event.kind.rawValue)', \(event.x), \(event.y), \(clickState)),"
        }
    }

    /// A Python string literal that cannot break out of its quotes.
    private static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "'": escaped += "\\'"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "'\(escaped)'"
    }

    /// A name safe to sit inside the module docstring: no newlines to break
    /// the header, no triple quote to end it early.
    private static func docstringSafe(_ name: String) -> String {
        name
            .replacingOccurrences(of: "[\r\n\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\"\"\"", with: "\"")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension DateFormatter {
    static let pythonHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
