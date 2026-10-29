import AppKit
import CoreGraphics
import Foundation

/// Captures global input through a single `CGEventTap`.
///
/// The tap runs listen-only on its own thread and run loop. It serves two
/// jobs: recording a workflow, and watching for the force-stop chord while a
/// workflow plays back. Both need the same tap, so one class owns it and
/// tracks which jobs are currently active.
public final class EventRecorder {

    public enum Backend: String {
        case none
        case eventTap
    }

    /// Control-Option-Command-Escape: stops recording or playback from anywhere.
    public static let stopHotkeyDescription = "⌃⌥⌘⎋"

    // MARK: - Callbacks

    /// Called on a background thread whenever the force-stop chord is pressed.
    public var onStopHotkey: (() -> Void)?
    /// Called on the main queue when the tap is disabled and cannot be restored.
    public var onTapFailure: ((String) -> Void)?

    // MARK: - State

    private let lock = NSLock()
    private var _events: [PhantomEvent] = []
    private var _pending: [PhantomEvent] = []
    private var _isRecording = false
    private var _hotkeyOnly = false
    private var _excludedRect: CGRect?
    private var _lastMouse: CGPoint = .zero

    private var startTime: TimeInterval = 0
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private let tapReady = DispatchSemaphore(value: 0)
    private let tapFinished = DispatchSemaphore(value: 0)
    private var tapCreated = false

    private var leftDown = false
    private var rightDown = false
    private var middleDown = false
    private var modifierState: [CGKeyCode: Bool] = [:]
    private var stopHotkeyFired = false

    public private(set) var backend: Backend = .none

    public init() {}

    // MARK: - Public state

    public var isRecording: Bool { lock.withLock { _isRecording } }

    public var events: [PhantomEvent] { lock.withLock { _events } }

    public var eventCount: Int { lock.withLock { _events.count } }

    public var duration: Double { lock.withLock { _events.last?.t ?? 0 } }

    public var lastMousePosition: CGPoint { lock.withLock { _lastMouse } }

    /// Drains the buffer the UI polls to draw the live event log.
    public func drainPendingEvents() -> [PhantomEvent] {
        lock.withLock {
            let pending = _pending
            _pending.removeAll(keepingCapacity: true)
            return pending
        }
    }

    public func clear() {
        lock.withLock {
            _events.removeAll()
            _pending.removeAll()
        }
    }

    // MARK: - Exclusion zone

    /// Screen region to drop events from, in global top-left coordinates.
    /// Phantom's own panel lives here so clicking Stop never lands in the
    /// workflow.
    public func setExclusionZone(_ rect: CGRect) {
        lock.withLock { _excludedRect = rect }
    }

    public func clearExclusionZone() {
        lock.withLock { _excludedRect = nil }
    }

    // MARK: - Recording lifecycle

    @discardableResult
    public func startRecording() -> Bool {
        let alreadyRecording: Bool = lock.withLock {
            if _isRecording { return true }
            _events.removeAll()
            _pending.removeAll()
            _isRecording = true
            return false
        }
        guard !alreadyRecording else { return true }

        startTime = ProcessInfo.processInfo.systemUptime
        leftDown = false
        rightDown = false
        middleDown = false
        modifierState.removeAll()
        stopHotkeyFired = false
        return ensureTapRunning()
    }

    public func stopRecording() {
        lock.withLock { _isRecording = false }
        stripUnreleasedModifiers()
        releaseTapIfIdle()
    }

    /// Watches only for the force-stop chord — used while a workflow plays.
    @discardableResult
    public func startHotkeyMonitor() -> Bool {
        guard !isRecording, !lock.withLock({ _hotkeyOnly }) else { return true }
        lock.withLock { _hotkeyOnly = true }
        stopHotkeyFired = false
        return ensureTapRunning()
    }

    public func stopHotkeyMonitor() {
        guard lock.withLock({ _hotkeyOnly }) else { return }
        lock.withLock { _hotkeyOnly = false }
        releaseTapIfIdle()
    }

    private var isCaptureActive: Bool {
        lock.withLock { _isRecording || _hotkeyOnly }
    }

    /// Drops modifier key-downs left without a matching key-up. Recording
    /// usually ends while the stop chord is still held; replaying half of it
    /// would wedge the system's modifier state.
    private func stripUnreleasedModifiers() {
        lock.withLock {
            for keycode in Keymap.modifierKeycodes {
                guard let index = _events.lastIndex(where: {
                    $0.keycode == keycode && $0.kind.isKey
                }) else { continue }
                if _events[index].kind == .keyDown {
                    _events.remove(at: index)
                }
            }
        }
    }

    // MARK: - Tap plumbing

    private func ensureTapRunning() -> Bool {
        if tapThread?.isExecuting == true, tapCreated { return true }

        tapCreated = false
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "com.alexgoodhart.Phantom.EventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Do not report success until the tap actually exists: without
        // Accessibility permission CGEvent.tapCreate returns nil.
        _ = tapReady.wait(timeout: .now() + 1.0)
        backend = tapCreated ? .eventTap : .none
        return tapCreated
    }

    private func releaseTapIfIdle() {
        guard !isCaptureActive else { return }
        guard tapThread != nil else { return }

        if let runLoop = tapRunLoop { CFRunLoopStop(runLoop) }
        // Wait for the tap thread to finish tearing down. Starting a new tap
        // while the old one is still cleaning up would have the two threads
        // writing the same fields.
        _ = tapFinished.wait(timeout: .now() + 1.0)

        tapRunLoop = nil
        tapThread = nil
        tapCreated = false
        backend = .none
    }

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
    }()

    private func runTapLoop() {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let recorder = Unmanaged<EventRecorder>.fromOpaque(refcon).takeUnretainedValue()
            recorder.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: EventRecorder.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            tapReady.signal()
            tapFinished.signal()
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let runLoop = CFRunLoopGetCurrent()
        tapRunLoop = runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        tapCreated = true
        tapReady.signal()

        // Wake periodically so a stop request is noticed promptly.
        while isCaptureActive {
            let result = CFRunLoopRunInMode(.defaultMode, 0.25, false)
            if result == .stopped || result == .finished { break }
        }

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapFinished.signal()
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that blocks for too long, or when the user
        // triggers certain secure inputs. Re-enable rather than going deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard isCaptureActive else { return }
        // Never re-record what we are replaying.
        guard !PhantomEventSource.isSynthetic(event) else { return }

        if type == .keyDown {
            let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keycode == Keymap.escapeKeycode, isStopChord(event.flags) {
                fireStopHotkey()
                return
            }
        }

        guard isRecording else { return }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            recordMotion(event)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            recordButton(type: type, event: event)
        case .scrollWheel:
            recordScroll(event)
        case .keyDown, .keyUp:
            recordKey(type: type, event: event)
        case .flagsChanged:
            recordFlagsChanged(event)
        default:
            break
        }
    }

    private func isStopChord(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && flags.contains(.maskCommand)
    }

    private func fireStopHotkey() {
        let shouldFire: Bool = lock.withLock {
            if stopHotkeyFired { return false }
            stopHotkeyFired = true
            return true
        }
        guard shouldFire, let callback = onStopHotkey else { return }
        // A fresh thread: stopping from inside the tap callback would
        // deadlock on the run loop this callback is running on.
        Thread.detachNewThread(callback)
    }

    private func timestamp() -> Double {
        ProcessInfo.processInfo.systemUptime - startTime
    }

    private func isExcluded(_ point: CGPoint) -> Bool {
        guard let rect = lock.withLock({ _excludedRect }) else { return false }
        return rect.contains(point)
    }

    private func record(_ event: PhantomEvent) {
        lock.withLock {
            _events.append(event)
            _pending.append(event)
        }
    }

    private func recordMotion(_ event: CGEvent) {
        let point = event.location
        guard !isExcluded(point) else { return }
        lock.withLock { _lastMouse = point }

        let kind: PhantomEvent.Kind
        if leftDown {
            kind = .drag
        } else if rightDown {
            kind = .rightDrag
        } else {
            kind = .move
        }
        record(PhantomEvent(t: timestamp(), kind: kind, x: Int(point.x), y: Int(point.y)))
    }

    private func recordButton(type: CGEventType, event: CGEvent) {
        let point = event.location
        guard !isExcluded(point) else { return }
        lock.withLock { _lastMouse = point }

        let kind: PhantomEvent.Kind
        switch type {
        case .leftMouseDown: leftDown = true; kind = .leftDown
        case .leftMouseUp: leftDown = false; kind = .leftUp
        case .rightMouseDown: rightDown = true; kind = .rightDown
        case .rightMouseUp: rightDown = false; kind = .rightUp
        case .otherMouseDown: middleDown = true; kind = .middleDown
        case .otherMouseUp: middleDown = false; kind = .middleUp
        default: return
        }

        // Carrying click state through is what lets a recorded double-click
        // replay as a double-click rather than two unrelated clicks.
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        record(PhantomEvent(t: timestamp(), kind: kind, x: Int(point.x), y: Int(point.y),
                            clickState: max(1, clickState)))
    }

    private func recordScroll(_ event: CGEvent) {
        let point = event.location
        guard !isExcluded(point) else { return }

        let lineY = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineX = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let pixelY = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let pixelX = Int(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

        // Trackpads emit a stream of pixel-precise events whose line deltas
        // are mostly zero. Keeping the pixel deltas is what makes a replayed
        // trackpad scroll look like the original instead of a stutter.
        guard lineX != 0 || lineY != 0 || pixelX != 0 || pixelY != 0 else { return }

        record(PhantomEvent(t: timestamp(), kind: .scroll, x: Int(point.x), y: Int(point.y),
                            dx: lineX, dy: lineY,
                            pdx: pixelX == 0 ? nil : pixelX,
                            pdy: pixelY == 0 ? nil : pixelY))
    }

    private func recordKey(type: CGEventType, event: CGEvent) {
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Keymap.recordedFlagMask)
        record(PhantomEvent(
            t: timestamp(),
            kind: type == .keyDown ? .keyDown : .keyUp,
            keycode: keycode,
            flags: flags.rawValue
        ))
    }

    private func recordFlagsChanged(_ event: CGEvent) {
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Keymap.recordedFlagMask)

        // Caps Lock reports a toggle, never a press and release. Synthesise
        // both so replay reproduces the toggle.
        if keycode == Keymap.capsLockKeycode {
            record(PhantomEvent(t: timestamp(), kind: .keyDown, keycode: keycode,
                                flags: flags.rawValue))
            record(PhantomEvent(t: timestamp(), kind: .keyUp, keycode: keycode,
                                flags: flags.rawValue))
            return
        }

        guard let mask = Keymap.modifierFlag(for: keycode) else { return }
        let pressed = event.flags.contains(mask)
        let wasPressed = modifierState[keycode] ?? false
        guard pressed != wasPressed else { return }
        modifierState[keycode] = pressed

        record(PhantomEvent(
            t: timestamp(),
            kind: pressed ? .keyDown : .keyUp,
            keycode: keycode,
            flags: flags.rawValue
        ))
    }
}

extension NSLock {
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
