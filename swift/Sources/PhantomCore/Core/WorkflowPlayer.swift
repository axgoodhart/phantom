import AppKit
import CoreGraphics
import Foundation

/// Replays a workflow as real input events.
///
/// The Python build spawned each workflow as a `python` subprocess and
/// scraped its stdout for progress. Here playback is a thread inside the app:
/// progress is a direct callback, stopping is immediate, and there is no
/// interpreter, temp file, or stdin prompt in the way.
public final class WorkflowPlayer {

    public struct Options: Sendable {
        public var speed: Double
        public var matchResolution: Bool
        public var matchWindows: Bool
        public var restoreResolutionAfter: Bool
        /// Total iterations; 0 means loop until stopped.
        public var loopCount: Int
        public var loopDelay: Double
        /// Optional URL polled between iterations; a failure is reported but
        /// never blocks the next run.
        public var pingURL: URL?
        public var playCompletionSound: Bool

        public init(speed: Double = 1.0, matchResolution: Bool = true,
                    matchWindows: Bool = true, restoreResolutionAfter: Bool = true,
                    loopCount: Int = 1, loopDelay: Double = 0,
                    pingURL: URL? = nil, playCompletionSound: Bool = false) {
            self.speed = speed
            self.matchResolution = matchResolution
            self.matchWindows = matchWindows
            self.restoreResolutionAfter = restoreResolutionAfter
            self.loopCount = loopCount
            self.loopDelay = loopDelay
            self.pingURL = pingURL
            self.playCompletionSound = playCompletionSound
        }
    }

    public enum Phase: Equatable, Sendable {
        case settingUp(String)
        case replaying(current: Int, total: Int, iteration: Int, totalIterations: Int)
        case waiting(secondsRemaining: Double, nextIteration: Int)
        case pinging
    }

    public enum Completion: Equatable, Sendable {
        case finished(iterations: Int)
        case cancelled
        case failed(String)
    }

    // MARK: - Callbacks (delivered on the main queue)

    public var onPhase: ((Phase) -> Void)?
    public var onWarning: ((String) -> Void)?
    public var onCompletion: ((Completion) -> Void)?

    // MARK: - State

    private let lock = NSLock()
    private var _isPlaying = false
    private var _cancelled = false
    private var thread: Thread?

    /// Mouse buttons and modifiers we have pressed but not released, so a
    /// mid-drag stop does not leave the system with a stuck button.
    private var heldButtons: Set<CGMouseButton> = []
    private var heldModifiers: Set<CGKeyCode> = []
    private var lastPosition: CGPoint = .zero

    public init() {}

    public var isPlaying: Bool { lock.withLock { _isPlaying } }
    private var isCancelled: Bool { lock.withLock { _cancelled } }

    // MARK: - Control

    @discardableResult
    public func play(_ workflow: Workflow, options: Options) -> Bool {
        let alreadyPlaying: Bool = lock.withLock {
            if _isPlaying { return true }
            _isPlaying = true
            _cancelled = false
            return false
        }
        guard !alreadyPlaying else { return false }

        let thread = Thread { [weak self] in
            self?.run(workflow: workflow, options: options)
        }
        thread.name = "com.alexgoodhart.Phantom.Playback"
        thread.qualityOfService = .userInteractive
        // A long recording holds a lot of scheduling state; the default
        // secondary-thread stack is plenty, but be explicit about intent.
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
        return true
    }

    public func stop() {
        lock.withLock { _cancelled = true }
    }

    // MARK: - Execution

    private func run(workflow: Workflow, options: Options) {
        var completion: Completion = .finished(iterations: 0)
        var switchedResolution = false

        defer {
            releaseHeldInput()
            if switchedResolution, options.restoreResolutionAfter {
                DisplayModeMatcher.restoreOriginal()
            }
            lock.withLock {
                _isPlaying = false
                _cancelled = false
            }
            let result = completion
            let shouldChime = options.playCompletionSound && result.isSuccess
            DispatchQueue.main.async { [weak self] in
                if shouldChime { Chime.play() }
                self?.onCompletion?(result)
            }
        }

        // --- Phase one: put the stage back the way it was ---
        if options.matchResolution {
            emit(.settingUp("Matching resolution"))
            switch DisplayModeMatcher.match(workflow.environment.resolution) {
            case .alreadyMatching:
                break
            case .switched:
                switchedResolution = true
            case .noMatchingMode(let current, let wanted):
                warn("No display mode matches \(Int(wanted.width))x\(Int(wanted.height)); "
                     + "running at \(Int(current.width))x\(Int(current.height))")
            case .failed(let message):
                warn(message)
            }
        }

        if isCancelled { completion = .cancelled; return }

        if options.matchWindows, !workflow.environment.windows.isEmpty {
            emit(.settingUp("Restoring windows"))
            let result = WindowRestorer.restore(
                windows: workflow.environment.windows,
                matchTitles: workflow.environment.windowNamesAvailable,
                shouldCancel: { [weak self] in self?.isCancelled ?? true },
                progress: { [weak self] label in self?.emit(.settingUp("Restoring \(label)")) }
            )
            if result.failed > 0 {
                warn("Positioned \(result.positioned)/\(result.total) windows"
                     + (result.messages.first.map { " — \($0)" } ?? ""))
            }
        }

        if isCancelled { completion = .cancelled; return }

        emit(.settingUp("Activating \(workflow.environment.frontmostApp)"))
        if !WindowRestorer.activate(appNamed: workflow.environment.frontmostApp) {
            warn("Could not activate \(workflow.environment.frontmostApp)")
        }
        Thread.sleep(forTimeInterval: 0.5)

        // --- Phase two: replay ---
        let totalIterations = options.loopCount
        var iteration = 0
        while !isCancelled {
            iteration += 1
            if totalIterations > 0, iteration > totalIterations {
                iteration -= 1
                break
            }

            replay(workflow.events, options: options,
                   iteration: iteration, totalIterations: totalIterations)

            if isCancelled { break }

            let moreToGo = totalIterations == 0 || iteration < totalIterations
            guard moreToGo else { break }

            if let url = options.pingURL {
                emit(.pinging)
                if !Ping.check(url) {
                    warn("Ping failed for \(url.absoluteString) — continuing")
                }
            }

            if options.loopDelay > 0 {
                let deadline = ProcessInfo.processInfo.systemUptime + options.loopDelay
                while !isCancelled {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 { break }
                    emit(.waiting(secondsRemaining: remaining, nextIteration: iteration + 1))
                    Thread.sleep(forTimeInterval: min(remaining, 0.1))
                }
            }
        }

        completion = isCancelled ? .cancelled : .finished(iterations: iteration)
    }

    private func replay(_ events: [PhantomEvent], options: Options,
                        iteration: Int, totalIterations: Int) {
        guard !events.isEmpty else { return }
        let speed = max(0.05, options.speed)
        let total = events.count

        // Schedule against one absolute start time so per-event overhead
        // cannot accumulate into drift over a long recording.
        let start = ProcessInfo.processInfo.systemUptime
        var lastProgressReport = start

        for (index, event) in events.enumerated() {
            if isCancelled { return }

            let deadline = start + event.t / speed
            waitUntil(deadline)
            if isCancelled { return }

            post(event)

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressReport > 0.05 || index == total - 1 {
                lastProgressReport = now
                emit(.replaying(current: index + 1, total: total,
                                iteration: iteration, totalIterations: totalIterations))
            }
        }
    }

    /// Sleeps until `deadline`, then spins for the last fraction of a
    /// millisecond. `Thread.sleep` alone overshoots enough to smear the
    /// timing of fast key repeats.
    private func waitUntil(_ deadline: TimeInterval) {
        let spinThreshold = 0.0012
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            if isCancelled { return }
            if remaining > spinThreshold {
                Thread.sleep(forTimeInterval: min(remaining - spinThreshold, 0.05))
            } else {
                while ProcessInfo.processInfo.systemUptime < deadline {}
                return
            }
        }
    }

    // MARK: - Posting

    private func post(_ event: PhantomEvent) {
        let source = PhantomEventSource.shared
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))

        switch event.kind {
        case .move:
            postMouse(.mouseMoved, at: point, button: .left, source: source)
        case .drag:
            postMouse(.leftMouseDragged, at: point, button: .left, source: source)
        case .rightDrag:
            postMouse(.rightMouseDragged, at: point, button: .right, source: source)
        case .leftDown:
            heldButtons.insert(.left)
            postMouse(.leftMouseDown, at: point, button: .left,
                      clickState: event.clickState, source: source)
        case .leftUp:
            heldButtons.remove(.left)
            postMouse(.leftMouseUp, at: point, button: .left,
                      clickState: event.clickState, source: source)
        case .rightDown:
            heldButtons.insert(.right)
            postMouse(.rightMouseDown, at: point, button: .right,
                      clickState: event.clickState, source: source)
        case .rightUp:
            heldButtons.remove(.right)
            postMouse(.rightMouseUp, at: point, button: .right,
                      clickState: event.clickState, source: source)
        case .middleDown:
            heldButtons.insert(.center)
            postMouse(.otherMouseDown, at: point, button: .center,
                      clickState: event.clickState, source: source)
        case .middleUp:
            heldButtons.remove(.center)
            postMouse(.otherMouseUp, at: point, button: .center,
                      clickState: event.clickState, source: source)
        case .keyDown, .keyUp:
            guard let keycode = event.keycode else { return }
            let down = event.kind == .keyDown
            if Keymap.modifierKeycodes.contains(keycode) {
                if down { heldModifiers.insert(keycode) } else { heldModifiers.remove(keycode) }
            }
            postKey(keycode, down: down, flags: event.eventFlags, source: source)
        case .scroll:
            postScroll(event, at: point, source: source)
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton,
                           clickState: Int? = nil, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button)
        else { return }

        // Some applications (games, 3D tools) read the movement delta rather
        // than the absolute position, so fill it in.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - lastPosition.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - lastPosition.y))
        lastPosition = point

        if let clickState, clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        PhantomEventSource.stamp(event)
        event.post(tap: .cghidEventTap)
    }

    private func postKey(_ keycode: CGKeyCode, down: Bool, flags: CGEventFlags,
                         source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
        else { return }
        event.flags = flags
        PhantomEventSource.stamp(event)
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(_ event: PhantomEvent, at point: CGPoint, source: CGEventSource?) {
        // Scroll events land wherever the pointer is, so move there first.
        postMouse(.mouseMoved, at: point, button: .left, source: source)

        let usePixels = event.pdx != nil || event.pdy != nil
        let unit: CGScrollEventUnit = usePixels ? .pixel : .line
        let vertical = Int32(usePixels ? (event.pdy ?? 0) : (event.dy ?? 0))
        let horizontal = Int32(usePixels ? (event.pdx ?? 0) : (event.dx ?? 0))

        guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: unit,
                                   wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        PhantomEventSource.stamp(scroll)
        scroll.post(tap: .cghidEventTap)
    }

    /// Releases anything still held down. Stopping mid-drag would otherwise
    /// leave the mouse button stuck for the user.
    private func releaseHeldInput() {
        let source = PhantomEventSource.shared
        let point = lastPosition

        for button in heldButtons {
            let type: CGEventType
            switch button {
            case .left: type = .leftMouseUp
            case .right: type = .rightMouseUp
            default: type = .otherMouseUp
            }
            postMouse(type, at: point, button: button, source: source)
        }
        heldButtons.removeAll()

        for keycode in heldModifiers {
            postKey(keycode, down: false, flags: [], source: source)
        }
        heldModifiers.removeAll()
    }

    // MARK: - Reporting

    private func emit(_ phase: Phase) {
        DispatchQueue.main.async { [weak self] in self?.onPhase?(phase) }
    }

    private func warn(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onWarning?(message) }
    }
}

extension WorkflowPlayer.Completion {
    public var isSuccess: Bool {
        if case .finished = self { return true }
        return false
    }
}

/// Between-run availability check for looped workflows.
enum Ping {
    static func check(_ url: URL) -> Bool {
        var succeeded = false
        for method in ["HEAD", "GET"] {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = method
            request.setValue("Phantom/2.0", forHTTPHeaderField: "User-Agent")

            let semaphore = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    succeeded = true
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 12)
            if succeeded { return true }
        }
        return false
    }
}
