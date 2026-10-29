import AppKit
import Combine
import CoreGraphics
import Foundation

/// The single coordinator behind the UI: recording, preview, the workflow
/// library, and playback.
///
/// In the Python build this role was split between `api.py` and a few
/// thousand lines of JavaScript that called into it. Here the views observe
/// this object directly, so there is no bridge to keep in sync.
@MainActor
public final class AppState: ObservableObject {

    public enum Mode: String { case record, playback }

    public enum Activity: Equatable {
        case ready
        case recording
        case stopped
        case previewing
        case playing
    }

    public struct LogEntry: Identifiable, Equatable {
        public let id = UUID()
        public var time: Double
        public var text: String
        public var category: PhantomEvent.Category
    }

    // MARK: - Published state

    @Published public var mode: Mode = .record
    @Published public var activity: Activity = .ready
    @Published public var statusText = "Ready"

    @Published public var permissions = Permissions.Status(accessibility: false,
                                                           screenRecording: false)
    @Published public var permissionsBypassed = false
    @Published public var showPermissionSheet = false

    // Recording
    @Published public var isRecording = false
    @Published public var eventCount = 0
    @Published public var recordingDuration: Double = 0
    @Published public var log: [LogEntry] = []
    @Published public var environment: EnvironmentSnapshot?
    @Published public var hasRecording = false
    @Published public var recordingSaved = false
    @Published public var workflowName = ""
    @Published public var exportSpeed: Double = 1.0
    @Published public var isChipMode = false

    // Preview
    @Published public var isPreviewing = false
    @Published public var previewProgress: Double = 0
    @Published public var previewSpeed: Double = 1.0

    // Grid
    @Published public var gridVisible = false
    @Published public var gridSize: Double = 50

    // Library
    @Published public var workflows: [WorkflowMetadata] = []
    @Published public var showWorkflowBrowser = false
    @Published public var selectedWorkflow: WorkflowMetadata?
    @Published public var loadedWorkflow: WorkflowMetadata?

    // Playback
    @Published public var showPlaybackOptions = false
    @Published public var playbackOptions = PlaybackFormOptions()
    @Published public var isPlaying = false
    @Published public var playbackProgress: Double = 0
    @Published public var loopStatus = ""

    @Published public var toast: String?
    @Published public var showQuitConfirmation = false

    /// Form state for the playback options sheet.
    public struct PlaybackFormOptions: Equatable {
        public var speed: Double = 1.0
        public var matchResolution = true
        public var matchWindows = true
        public var playCompletionSound = false
        public var loopInfinite = false
        public var loopCount = 1
        public var loopDelay: Double = 0
        public var pingURL = ""

        public init() {}
    }

    // MARK: - Collaborators

    public let recorder = EventRecorder()
    public let player = WorkflowPlayer()
    public let overlay = OverlayState()
    public let store: WorkflowStore

    public weak var panel: PanelController?
    public weak var overlayWindow: OverlayController?

    private var loadedWorkflowBody: Workflow?
    private var recordedEnvironment: EnvironmentSnapshot?
    private var recordOptions = WorkflowOptions()
    private var frontmostBeforePrompt: String?

    private var logPollTimer: Timer?
    private var permissionTimer: Timer?
    private var previewThread: Thread?
    /// Shared with the preview thread; a plain flag would mean hopping to
    /// the main actor for every event just to ask "should I stop?".
    private let previewCancelled = AtomicFlag()
    private var toastTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    /// The live log is a scrolling display, not an archive; the full
    /// recording is kept by the recorder.
    private let maxLogEntries = 200
    private var moveSkipCounter = 0

    public init(store: WorkflowStore = .shared) {
        self.store = store

        recorder.onStopHotkey = { [weak self] in
            Task { @MainActor in self?.handleStopHotkey() }
        }
        player.onPhase = { [weak self] phase in
            Task { @MainActor in self?.handlePlaybackPhase(phase) }
        }
        player.onWarning = { [weak self] message in
            Task { @MainActor in self?.showToast(message) }
        }
        player.onCompletion = { [weak self] completion in
            Task { @MainActor in self?.handlePlaybackCompletion(completion) }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        refreshPermissions()
        refreshWorkflows()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    public func shutdown() {
        if isRecording { recorder.stopRecording() }
        stopPreview()
        if isPlaying { player.stop() }
        recorder.stopHotkeyMonitor()
        logPollTimer?.invalidate()
        permissionTimer?.invalidate()
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        permissions = Permissions.status()
        // Surface the sheet as long as the required permission is missing.
        // Nothing here works without it, so hiding the fact helps no one.
        showPermissionSheet = !permissions.isReady && !permissionsBypassed
    }

    public func requestAccessibility() {
        _ = Permissions.hasAccessibility(prompt: true)
        refreshPermissions()
    }

    public func requestScreenRecording() {
        Permissions.requestScreenRecording()
        refreshPermissions()
    }

    public func openSettings(_ pane: Permissions.Pane) {
        Permissions.openSettings(pane)
    }

    private var permissionsSatisfied: Bool {
        permissions.isReady || permissionsBypassed
    }

    // MARK: - Recording

    /// Step one: put the options prompt on the overlay. The overlay takes
    /// mouse input for this, so the panel does not have to steal focus.
    public func beginRecordingFlow() {
        guard permissionsSatisfied else {
            showPermissionSheet = true
            return
        }
        guard !isRecording else { return }

        let frontmost = ScreenEnvironment.frontmostApp()
        frontmostBeforePrompt = frontmost == "Phantom" ? nil : frontmost

        overlay.promptRecordResolution = true
        overlay.promptRecordWindows = true
        overlay.promptBusy = false
        overlay.promptIsError = false
        overlay.promptMessage = "Press SPACE or click BEGIN to commence recording."
        overlay.countdownValue = nil
        overlay.promptVisible = true
        overlayWindow?.setInteractive(true)
        statusText = "Press SPACE or BEGIN on the overlay"
    }

    public func cancelRecordingPrompt() {
        countdownTask?.cancel()
        countdownTask = nil
        overlay.promptVisible = false
        overlay.countdownValue = nil
        overlay.promptBusy = false
        overlayWindow?.setInteractive(false)
        frontmostBeforePrompt = nil
        if !isRecording { statusText = "Ready" }
    }

    /// Step two: count down, then start capturing.
    public func confirmRecordingPrompt() {
        guard overlay.promptVisible, !overlay.promptBusy else { return }
        overlay.promptBusy = true

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for value in [3, 2, 1] {
                guard !Task.isCancelled, self.overlay.promptVisible else {
                    self.overlay.promptBusy = false
                    self.overlay.countdownValue = nil
                    return
                }
                self.overlay.countdownValue = value
                self.overlay.promptMessage = "Beginning in \(value)..."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, self.overlay.promptVisible else {
                self.overlay.promptBusy = false
                self.overlay.countdownValue = nil
                return
            }
            self.overlay.countdownValue = nil

            // Return focus to whatever the user was working in before
            // capturing, so the first recorded events land in that app and
            // the snapshot names it as frontmost.
            if let frontmost = self.frontmostBeforePrompt {
                WindowRestorer.activate(appNamed: frontmost)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            self.startRecording(
                recordResolution: self.overlay.promptRecordResolution,
                recordWindows: self.overlay.promptRecordWindows
            )
        }
    }

    private func startRecording(recordResolution: Bool, recordWindows: Bool) {
        overlay.promptVisible = false
        overlay.promptBusy = false
        overlayWindow?.setInteractive(false)

        recordOptions = WorkflowOptions(
            matchResolution: recordResolution,
            matchWindows: recordWindows,
            defaultSpeed: 1.0
        )

        var snapshot = ScreenEnvironment.capture(includeWindows: recordWindows)
        // If activation did not take, fall back to the app we noted before
        // the prompt rather than recording "Phantom" as frontmost.
        if snapshot.frontmostApp == "Phantom", let frontmost = frontmostBeforePrompt {
            snapshot.frontmostApp = frontmost
        }
        recordedEnvironment = snapshot
        environment = snapshot
        frontmostBeforePrompt = nil

        applyPanelExclusionZone()

        guard recorder.startRecording() else {
            statusText = "Ready"
            showToast("Could not start capture — check Accessibility permission")
            showPermissionSheet = true
            return
        }

        isRecording = true
        hasRecording = false
        recordingSaved = false
        eventCount = 0
        recordingDuration = 0
        log.removeAll()
        moveSkipCounter = 0
        activity = .recording
        statusText = "Recording..."

        overlay.showCursor()
        startLogPolling()
        panel?.enterChipMode()
        isChipMode = true
    }

    public func stopRecording() {
        guard isRecording else { return }
        recorder.stopRecording()
        recorder.clearExclusionZone()
        stopLogPolling()
        drainRecorderEvents()

        isRecording = false
        isChipMode = false
        panel?.exitChipMode()
        overlay.hideCursor()

        eventCount = recorder.eventCount
        recordingDuration = recorder.duration
        hasRecording = eventCount > 0
        activity = hasRecording ? .stopped : .ready
        statusText = hasRecording
            ? String(format: "Stopped: %d events, %.1fs", eventCount, recordingDuration)
            : "Stopped: nothing captured"
    }

    public func clearRecording() {
        recorder.clear()
        eventCount = 0
        recordingDuration = 0
        hasRecording = false
        recordingSaved = false
        log.removeAll()
        environment = nil
        recordedEnvironment = nil
        activity = .ready
        statusText = "Ready"
    }

    private func handleStopHotkey() {
        if isRecording {
            stopRecording()
            showToast("Recording stopped by \(EventRecorder.stopHotkeyDescription)")
        } else if isPlaying {
            stopPlayback()
            showToast("Workflow stopped by \(EventRecorder.stopHotkeyDescription)")
        } else if isPreviewing {
            stopPreview()
        }
    }

    /// Keeps clicks on Phantom's own panel out of the recording.
    private func applyPanelExclusionZone() {
        guard let frame = panel?.globalFrame else {
            recorder.clearExclusionZone()
            return
        }
        recorder.setExclusionZone(frame.insetBy(dx: -8, dy: -8))
    }

    public func updateExclusionZoneForChip() {
        guard isRecording else { return }
        applyPanelExclusionZone()
    }

    /// Used when the panel is about to move: the zone should cover where it
    /// is going, not where it currently is.
    public func setExclusionZone(cocoaFrame: CGRect) {
        guard isRecording else { return }
        recorder.setExclusionZone(
            Coordinates.globalRect(fromCocoa: cocoaFrame).insetBy(dx: -8, dy: -8)
        )
    }

    // MARK: - Live log

    private func startLogPolling() {
        logPollTimer?.invalidate()
        // 20 Hz: fast enough to feel live, slow enough that a 125 Hz event
        // stream does not drive SwiftUI updates one event at a time.
        logPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainRecorderEvents() }
        }
    }

    private func stopLogPolling() {
        logPollTimer?.invalidate()
        logPollTimer = nil
    }

    private func drainRecorderEvents() {
        let events = recorder.drainPendingEvents()
        guard !events.isEmpty else { return }

        eventCount = recorder.eventCount
        recordingDuration = events.last?.t ?? recordingDuration

        for event in events {
            // Mouse movement dominates the stream; log a sample of it so the
            // interesting events stay visible.
            if event.category == .move {
                moveSkipCounter += 1
                if moveSkipCounter % 20 != 0 { continue }
            }
            log.append(LogEntry(time: event.t, text: event.displayText, category: event.category))

            if event.kind == .keyDown {
                overlay.showKey(Keymap.displayName(for: event.keycode ?? 0, shift: event.hasShift))
            }
        }
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
    }

    // MARK: - Saving

    public func saveRecording() {
        let events = recorder.events
        guard !events.isEmpty else {
            showToast("No events to save")
            return
        }

        let typed = workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? defaultRecordingName() : WorkflowStore.sanitize(name: typed)
        var options = recordOptions
        options.defaultSpeed = exportSpeed

        let workflow = Workflow(
            name: name,
            environment: recordedEnvironment ?? ScreenEnvironment.capture(),
            options: options,
            events: WorkflowBuilder.compress(events)
        )

        do {
            let url = try store.save(workflow)
            recordingSaved = true
            refreshWorkflows()
            showToast("Saved: \(url.lastPathComponent)")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func defaultRecordingName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "Recording_\(formatter.string(from: Date()))"
    }

    /// Writes the current recording as a standalone Python script, keeping
    /// the "share it with someone else" story the original format had.
    public func exportRecordingAsPython(to url: URL) {
        let events = recorder.events
        guard !events.isEmpty else {
            showToast("No events to export")
            return
        }
        let workflow = Workflow(
            name: workflowName.isEmpty ? defaultRecordingName() : workflowName,
            environment: recordedEnvironment ?? ScreenEnvironment.capture(),
            options: recordOptions,
            events: WorkflowBuilder.compress(events)
        )
        do {
            try PythonExporter.script(for: workflow).write(to: url, atomically: true, encoding: .utf8)
            showToast("Exported \(url.lastPathComponent)")
        } catch {
            showToast("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Library

    public func refreshWorkflows() {
        workflows = store.list()
    }

    public func loadWorkflow(_ metadata: WorkflowMetadata) {
        do {
            let workflow = try store.load(at: metadata.url)
            loadedWorkflowBody = workflow
            loadedWorkflow = metadata
            playbackOptions.speed = workflow.options.defaultSpeed
            playbackOptions.matchResolution = workflow.options.matchResolution
            playbackOptions.matchWindows = workflow.options.matchWindows
            showWorkflowBrowser = false
            showToast("Loaded: \(metadata.name)")
        } catch {
            showToast("Could not load: \(error.localizedDescription)")
        }
    }

    public func unloadWorkflow() {
        loadedWorkflow = nil
        loadedWorkflowBody = nil
    }

    public func deleteWorkflow(_ metadata: WorkflowMetadata) {
        do {
            try store.delete(at: metadata.url)
            if loadedWorkflow?.url == metadata.url { unloadWorkflow() }
            if selectedWorkflow?.url == metadata.url { selectedWorkflow = nil }
            refreshWorkflows()
            showToast("Deleted \(metadata.name)")
        } catch {
            showToast("Delete failed: \(error.localizedDescription)")
        }
    }

    public func renameWorkflow(_ metadata: WorkflowMetadata, to newName: String) {
        do {
            _ = try store.rename(at: metadata.url, to: newName)
            refreshWorkflows()
            if loadedWorkflow?.url == metadata.url {
                loadedWorkflow = store.metadata(for: metadata.url)
            }
        } catch {
            showToast("Rename failed: \(error.localizedDescription)")
        }
    }

    /// Rewrites a Python-era workflow in the native format.
    public func convertWorkflow(_ metadata: WorkflowMetadata) {
        do {
            let url = try store.convertLegacy(at: metadata.url)
            refreshWorkflows()
            showToast("Converted to \(url.lastPathComponent)")
        } catch {
            showToast("Convert failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Preview

    /// Replays visually in the overlay without posting any real input.
    public func startPreview(ofLoadedWorkflow: Bool) {
        guard !isPreviewing, !isPlaying else { return }

        let events: [PhantomEvent]
        let speed: Double
        if ofLoadedWorkflow {
            guard let workflow = loadedWorkflowBody else { return }
            events = workflow.events
            speed = playbackOptions.speed
        } else {
            events = recorder.events
            speed = previewSpeed
        }
        guard !events.isEmpty else { return }

        isPreviewing = true
        previewProgress = 0
        previewCancelled.value = false
        activity = .previewing
        statusText = "Previewing..."
        overlay.showCursor()

        let thread = Thread { [weak self] in
            self?.runPreview(events: events, speed: max(0.05, speed))
        }
        thread.name = "com.alexgoodhart.Phantom.Preview"
        previewThread = thread
        thread.start()
    }

    public func stopPreview() {
        guard isPreviewing else { return }
        previewCancelled.value = true
    }

    private nonisolated func runPreview(events: [PhantomEvent], speed: Double) {
        let cancelled = previewCancelled
        let start = ProcessInfo.processInfo.systemUptime
        let total = events.count
        var lastReport = start

        for (index, event) in events.enumerated() {
            if cancelled.value { break }

            let deadline = start + event.t / speed
            while !cancelled.value {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(0.02, remaining))
            }
            if cancelled.value { break }

            DispatchQueue.main.async { self.renderPreview(event) }

            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport > 0.05 || index == total - 1 {
                lastReport = now
                let progress = Double(index + 1) / Double(total)
                DispatchQueue.main.async {
                    self.previewProgress = progress
                    self.statusText = "Preview: \(index + 1)/\(total) (\(Int(progress * 100))%)"
                }
            }
        }

        DispatchQueue.main.async { self.finishPreview() }
    }

    private func renderPreview(_ event: PhantomEvent) {
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        switch event.kind {
        case .move, .drag, .rightDrag:
            overlay.moveCursor(to: point)
        case .leftDown, .rightDown, .middleDown:
            overlay.showClick(at: point)
        case .keyDown:
            overlay.showKey(Keymap.displayName(for: event.keycode ?? 0, shift: event.hasShift))
        case .scroll:
            overlay.showScroll(at: point, isDown: (event.dy ?? event.pdy ?? 0) < 0)
        default:
            break
        }
    }

    private func finishPreview() {
        isPreviewing = false
        previewCancelled.value = false
        previewThread = nil
        overlay.hideCursor()
        overlay.clearTransients()
        activity = hasRecording && mode == .record ? .stopped : .ready
        statusText = activity == .stopped
            ? String(format: "%d events recorded", eventCount)
            : "Ready"
    }

    // MARK: - Playback

    public func openPlaybackOptions() {
        guard permissionsSatisfied else {
            showPermissionSheet = true
            return
        }
        guard loadedWorkflowBody != nil, !isPlaying, !isPreviewing else { return }
        showPlaybackOptions = true
    }

    public func startPlayback() {
        guard let workflow = loadedWorkflowBody else { return }
        showPlaybackOptions = false

        let options = WorkflowPlayer.Options(
            speed: playbackOptions.speed,
            matchResolution: playbackOptions.matchResolution,
            matchWindows: playbackOptions.matchWindows,
            restoreResolutionAfter: true,
            loopCount: playbackOptions.loopInfinite ? 0 : max(1, playbackOptions.loopCount),
            loopDelay: max(0, playbackOptions.loopDelay),
            pingURL: URL(string: playbackOptions.pingURL.trimmingCharacters(in: .whitespaces)),
            playCompletionSound: playbackOptions.playCompletionSound
        )

        guard player.play(workflow, options: options) else { return }

        isPlaying = true
        playbackProgress = 0
        loopStatus = ""
        activity = .playing
        statusText = "Running workflow..."
        // Watch for the force-stop chord for the duration of the run.
        recorder.startHotkeyMonitor()
    }

    public func stopPlayback() {
        guard isPlaying else { return }
        player.stop()
    }

    private func handlePlaybackPhase(_ phase: WorkflowPlayer.Phase) {
        switch phase {
        case .settingUp(let label):
            statusText = label
        case .replaying(let current, let total, let iteration, let totalIterations):
            playbackProgress = total > 0 ? Double(current) / Double(total) : 0
            statusText = "Playback: \(current)/\(total) (\(Int(playbackProgress * 100))%)"
            if totalIterations != 1 {
                loopStatus = totalIterations == 0
                    ? "Run \(iteration) of ∞"
                    : "Run \(iteration)/\(totalIterations)"
            }
        case .waiting(let remaining, let next):
            loopStatus = String(format: "Waiting %.1fs — run %d next", remaining, next)
        case .pinging:
            loopStatus = "Pinging..."
        }
    }

    private func handlePlaybackCompletion(_ completion: WorkflowPlayer.Completion) {
        isPlaying = false
        playbackProgress = 0
        loopStatus = ""
        activity = .ready
        recorder.stopHotkeyMonitor()

        switch completion {
        case .finished(let iterations):
            statusText = "Ready"
            showToast(iterations > 1 ? "Workflow complete (\(iterations) runs)" : "Workflow complete")
        case .cancelled:
            statusText = "Ready"
        case .failed(let message):
            statusText = "Workflow failed"
            showToast("Workflow failed: \(message)")
        }
    }

    // MARK: - Grid

    public func setGrid(visible: Bool) {
        gridVisible = visible
        overlay.gridVisible = visible
        overlay.gridSize = CGFloat(gridSize)
    }

    public func setGridSize(_ size: Double) {
        gridSize = size
        overlay.gridSize = CGFloat(size)
    }

    // MARK: - Mode

    public var canSwitchToPlayback: Bool {
        !isRecording && !isPreviewing && (!hasRecording || recordingSaved)
    }

    public func switchMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        if newMode == .playback, !canSwitchToPlayback { return }
        if newMode == .record, isPlaying { return }

        mode = newMode
        if newMode == .record { unloadWorkflow() }
        if newMode == .playback { refreshWorkflows() }
    }

    // MARK: - Toast

    public func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Quit

    /// Asks first when quitting would throw away a recording in progress or
    /// interrupt a running workflow.
    public func requestQuit() {
        if isRecording || isPlaying {
            showQuitConfirmation = true
            return
        }
        quit()
    }

    public func quit() {
        showQuitConfirmation = false
        shutdown()
        NSApp.terminate(nil)
    }

    public var quitConfirmationMessage: String {
        if isRecording { return "Recording is in progress. Quit and discard it?" }
        if isPlaying { return "A workflow is running. Quit and stop it?" }
        return "Quit Phantom?"
    }
}


/// A boolean two threads can share without either waiting on the other.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ initial: Bool = false) { storage = initial }

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
