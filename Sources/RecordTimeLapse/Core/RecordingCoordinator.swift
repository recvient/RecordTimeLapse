import Foundation
import AppKit
import ScreenCaptureKit

/// The brain. Owns the recording lifecycle/state machine and wires the capture engine, the
/// segmented encoder, the power/disk observers, and the App-Nap activity token together.
/// `@MainActor` so it can mutate the view model directly; the heavy per-frame encode happens
/// off-main inside the capture callback.
@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()

    let model = RecorderModel()
    private let settings = AppSettings.shared
    // One engine instance per capture session (created in startCapture, discarded on stop) —
    // its callbacks are immutable, which keeps the off-main delivery thread race-free.
    private var capture: CaptureEngine?
    private let power = PowerStateObserver()

    private var manager: SegmentManager?
    private var target: CaptureTarget?
    private var activityToken: (any NSObjectProtocol)?
    private var uiTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var statsTick = 0

    // Pause is the OR of two independent sources so overlapping events can't deadlock:
    // a user pause is never auto-resumed; an auto-pause is never cancelled by a user resume.
    private var userPaused = false
    private var autoPaused = false
    private var lastAutoReason: String?

    // Monotonic token for display-change rebuilds: notification bursts spawn overlapping
    // async rebuilds, and without this a slower, stale rebuild could overwrite a newer target.
    private var rebuildGeneration = 0

    // Serialises stop(): concurrent callers (disk-low + Quit) await the same finalisation.
    private var stopTask: Task<Void, Never>?

    // Tick index after which a transient statusMessage (e.g. "Capture recovered…") is cleared.
    private var transientMessageExpiryTick: Int?
    private static let noFramesWarning = "No frames captured yet — check displays and Screen Recording permission."

    private init() {
        model.permissionGranted = PermissionService.isGranted
        power.onPause  = { [weak self] reason in self?.autoPause(reason) }
        power.onResume = { [weak self] in self?.autoResume() }
    }

    func refreshPermission() {
        model.permissionGranted = PermissionService.isGranted
    }

    // MARK: - Start / Stop

    func start() async {
        guard case .idle = model.state else { return }

        guard await PermissionService.requestIfNeeded() else {
            model.permissionGranted = false
            model.statusMessage = "Grant Screen Recording in System Settings"
            PermissionService.openSystemSettings()
            return
        }
        model.permissionGranted = true

        do {
            let target = try await DisplayProvider.makeTarget(
                targetDisplayID: settings.targetDisplayID,
                resolutionCap: settings.resolutionCap,
                showsCursor: settings.showsCursor,
                interval: settings.captureInterval)
            self.target = target

            let manager = try SegmentManager(
                width: target.pixelWidth, height: target.pixelHeight,
                fps: settings.outputFPS, codec: settings.codec,
                outputFolder: settings.outputFolder,
                framesPerSegment: settings.framesPerSegment)
            self.manager = manager

            beginActivity()
            if settings.pauseOnSleep { power.start() }
            observeScreenChanges()

            model.frameCount = 0
            model.activeSeconds = 0
            model.estimatedBytes = 0
            model.diskWarning = nil
            model.lastOutputURL = nil
            model.statusMessage = nil
            userPaused = false
            autoPaused = false
            lastAutoReason = nil
            model.state = .recording

            startCapture()
            startUITimer()
            Log.app.info("Recording started")
        } catch {
            Log.app.error("start failed: \(error.localizedDescription)")
            model.statusMessage = "Could not start: \(error.localizedDescription)"
            teardown()
            manager = nil
            target = nil
            model.state = .idle
        }
    }

    func stop() async {
        // Already stopping? Wait for that finalisation rather than starting a second one.
        if let t = stopTask { await t.value; return }
        switch model.state {
        case .recording, .paused: break
        default: return
        }
        let t = Task { @MainActor in await self.performStop() }
        stopTask = t
        await t.value
        stopTask = nil
    }

    private func performStop() async {
        capture?.cancelDelivery()
        let engine = capture
        capture = nil
        await engine?.stop()
        stopUITimer()
        teardown()

        model.state = .finalizing
        let mgr = manager
        manager = nil
        model.statusMessage = "Finalizing…"

        let url = await mgr?.finishAndStitch()

        if let mgr { model.frameCount = mgr.totalFrames }
        model.lastOutputURL = url
        if let url {
            model.estimatedBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? model.estimatedBytes
        }
        model.statusMessage = url != nil ? "Saved \(url!.lastPathComponent)" : "Stopped — no frames captured"
        model.state = .idle
        target = nil
        Log.app.info("Recording stopped. Output: \(url?.lastPathComponent ?? "none")")
    }

    /// Tears down observers / activity token but NOT the manager (the caller finalises it).
    private func teardown() {
        power.stop()
        removeScreenObserver()
        endActivity()
    }

    // MARK: - Pause / Resume (two independent sources, reconciled)

    func togglePauseByUser() {
        userPaused.toggle()
        reconcileCapture()
    }

    private func autoPause(_ reason: String) {
        guard manager != nil, !autoPaused else { return }
        autoPaused = true
        lastAutoReason = reason
        reconcileCapture()
    }

    private func autoResume() {
        guard manager != nil, autoPaused else { return }
        autoPaused = false
        lastAutoReason = nil
        reconcileCapture()
    }

    /// Single source of truth: capture is running iff neither pause source is active.
    private func reconcileCapture() {
        guard manager != nil else { return }
        if case .finalizing = model.state { return }
        let shouldPause = userPaused || autoPaused
        // User pause shows a plain "Paused"; auto-pause names its cause.
        let label = userPaused ? "Paused" : "Paused — \(lastAutoReason ?? "system")"

        switch (shouldPause, model.state) {
        case (true, .recording):
            stopCaptureEngine()
            model.state = .paused(reason: label)
        case (false, .paused):
            model.state = .recording
            startCapture()
        case (true, .paused):
            model.state = .paused(reason: label)   // refresh label only
        default:
            break
        }
    }

    // MARK: - Capture wiring

    private func startCapture() {
        guard let target, let manager else { return }
        // Closure captures `manager` directly (not self.manager) so it can't race on teardown.
        let engine = CaptureEngine(
            interval: settings.captureInterval,
            onFrame: { pixelBuffer in manager.append(pixelBuffer) },
            onStreamError: { [weak self] error in
                Task { @MainActor in self?.handleStreamError(error) }
            })
        capture = engine
        Task { @MainActor in
            do {
                try await engine.start(target: target)
            } catch {
                // Only react if this engine is still the active one.
                if self.capture === engine { self.handleStreamError(error) }
            }
        }
    }

    /// Delivery stops synchronously; the stream teardown completes in the background.
    private func stopCaptureEngine() {
        capture?.cancelDelivery()
        let engine = capture
        capture = nil
        Task { await engine?.stop() }
    }

    /// The stream died mid-recording (display gone, permission revoked, WindowServer hiccup).
    /// Try one rebuild against the current display state; if that fails, pause with a message
    /// instead of silently showing "Recording" forever.
    private func handleStreamError(_ error: Error) {
        guard model.isRecording, manager != nil else { return }
        Log.capture.error("Capture interrupted: \(error.localizedDescription)")
        stopCaptureEngine()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        Task { @MainActor in
            guard generation == self.rebuildGeneration, self.model.isRecording,
                  let manager = self.manager else { return }
            do {
                let newTarget = try await DisplayProvider.makeTarget(
                    targetDisplayID: self.settings.targetDisplayID,
                    resolutionCap: self.settings.resolutionCap,
                    showsCursor: self.settings.showsCursor,
                    interval: self.settings.captureInterval,
                    fixedCanvas: (manager.width, manager.height))
                guard generation == self.rebuildGeneration, self.model.isRecording else { return }
                self.target = newTarget
                if case .recording = self.model.state, self.capture == nil {
                    self.startCapture()
                    self.setTransientStatus("Capture recovered after an interruption.")
                }
            } catch {
                self.model.statusMessage = "Capture failed — recording paused. Check displays/permission."
                self.autoPause("capture error")
            }
        }
    }

    // MARK: - App Nap / power assertion

    private func beginActivity() {
        let options: ProcessInfo.ActivityOptions = settings.preventIdleSleep
            ? [.userInitiated, .idleDisplaySleepDisabled]      // keep Mac + display awake, record through idle
            : [.userInitiatedAllowingIdleSystemSleep]          // prevent App Nap, but allow idle sleep (we pause)
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: "Recording time-lapse")
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - UI stats timer

    private func startUITimer() {
        uiTimer?.invalidate()
        statsTick = 0
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.uiTick() }
        }
        // Generous tolerance lets the kernel coalesce these wake-ups with other work —
        // a 1 Hz exact-deadline timer over 12 h is 43k avoidable precise wakeups.
        uiTimer?.tolerance = 0.5
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    private func uiTick() {
        guard let manager else { return }
        if case .recording = model.state { model.activeSeconds += 1 }
        statsTick += 1

        let frames = manager.totalFrames
        if statsTick % 2 == 0 {
            model.frameCount = frames
            model.estimatedBytes = manager.bytesOnDisk
        }

        // Fatal encoder failure: stop and finalise — the already-rotated segments are intact,
        // so stopping SAVES data. (stop() is reentrancy-safe via stopTask.)
        if let fatal = manager.fatalMessage {
            if model.statusMessage != fatal { model.statusMessage = fatal }
            Task { await self.stop() }
            return
        }
        if let warn = manager.warningMessage, model.statusMessage != warn {
            model.statusMessage = warn
        }
        // No frame-count stall heuristic: with stream capture, a silent stretch is the normal
        // idle-suppression behavior on a static screen. Hard failures arrive via
        // SCStreamDelegate.didStopWithError → handleStreamError. The one undetectable case —
        // a recording that never produced a single frame — gets a soft warning: the user just
        // clicked Start (the menu closing alone changes the screen), so 30 s of literally
        // nothing means the capture isn't working.
        if case .recording = model.state, frames == 0, model.activeSeconds > 30,
           model.statusMessage == nil {
            model.statusMessage = Self.noFramesWarning
        }
        if frames > 0, model.statusMessage == Self.noFramesWarning {
            model.statusMessage = nil
        }

        // Expire transient messages so "recovered" doesn't stick around for hours.
        if let expiry = transientMessageExpiryTick, statsTick >= expiry {
            transientMessageExpiryTick = nil
            model.statusMessage = nil
        }

        if statsTick % 10 == 0 {
            if DiskSpaceMonitor.isLow(forVolumeContaining: settings.outputFolder) {
                model.diskWarning = "Low disk space — stopping to keep your recording safe."
                Task { await self.stop() }
            }
        }
    }

    // MARK: - Display reconfiguration

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScreenChange() }
        }
    }

    private func removeScreenObserver() {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
    }

    private func handleScreenChange() {
        guard model.isRecording else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        Task { @MainActor in
            guard self.model.isRecording, let manager = self.manager else { return }
            do {
                // Canvas pinned to the encoder dims: SCK GPU-fits the (possibly different)
                // display into the same buffer size, so zero-copy append stays valid.
                let newTarget = try await DisplayProvider.makeTarget(
                    targetDisplayID: self.settings.targetDisplayID,
                    resolutionCap: self.settings.resolutionCap,
                    showsCursor: self.settings.showsCursor,
                    interval: self.settings.captureInterval,
                    fixedCanvas: (manager.width, manager.height))
                // A newer rebuild superseded this one while we awaited — discard the stale target.
                guard generation == self.rebuildGeneration, self.model.isRecording else { return }
                self.target = newTarget
                if case .recording = self.model.state {
                    if let engine = self.capture {
                        // Seamless: swap the content filter on the live stream, no restart.
                        do {
                            try await engine.update(filter: newTarget.filter)
                        } catch {
                            guard generation == self.rebuildGeneration,
                                  case .recording = self.model.state else { return }
                            self.stopCaptureEngine()
                            self.startCapture()
                        }
                    } else {
                        self.startCapture()
                    }
                }
                Log.capture.info("Display reconfigured — capture target rebuilt")
            } catch {
                Log.capture.error("rebuild target failed: \(error.localizedDescription)")
            }
        }
    }

    /// Show a short-lived status line (auto-cleared by uiTick after ~10 s).
    private func setTransientStatus(_ message: String) {
        model.statusMessage = message
        transientMessageExpiryTick = statsTick + 10
    }

    /// Called when capture-affecting settings (interval, cursor) change mid-recording:
    /// the stream's minimumFrameInterval is baked at creation, so rebuild the target
    /// (pinned to the existing encoder canvas) and restart the engine. ~50 ms, seamless.
    func captureSettingsChanged() {
        guard case .recording = model.state, let manager else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        Task { @MainActor in
            do {
                let newTarget = try await DisplayProvider.makeTarget(
                    targetDisplayID: self.settings.targetDisplayID,
                    resolutionCap: self.settings.resolutionCap,
                    showsCursor: self.settings.showsCursor,
                    interval: self.settings.captureInterval,
                    fixedCanvas: (manager.width, manager.height))
                guard generation == self.rebuildGeneration,
                      case .recording = self.model.state else { return }
                self.target = newTarget
                self.stopCaptureEngine()
                self.startCapture()
                Log.capture.info("Capture settings applied mid-recording")
            } catch {
                Log.capture.error("apply settings failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Output helpers

    func revealLastOutput() {
        guard let url = model.lastOutputURL else {
            NSWorkspace.shared.open(settings.outputFolder)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(settings.outputFolder)
    }
}
