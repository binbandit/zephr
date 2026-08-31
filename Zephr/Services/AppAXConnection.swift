import ApplicationServices
import CoreGraphics
import Dispatch
import os
import ZephrCore

/// One actor per target application (§6.3) — the anti-stall design.
///
/// Every AX call for a pid runs here, on a dedicated dispatch queue rather
/// than the shared cooperative pool, so an app that answers AX requests
/// slowly (or never) blocks only its own queue. A 250 ms messaging timeout
/// bounds each call; repeated timeouts mark the app degraded and it is
/// skipped until the retry ladder clears it.
actor AppAXConnection {

    nonisolated let pid: pid_t
    nonisolated let bundleID: String?
    private nonisolated let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let app: AXElement
    private var windows: [WindowID: AXElement] = [:]
    private var nextSequence: UInt64 = 1

    /// Highest frame-batch generation this connection has run.
    private var writeGeneration: UInt64 = 0

    /// Degraded-app bookkeeping (§6.3): after a timeout, skip the app briefly.
    private var degradedUntil: ContinuousClock.Instant?
    private var timeoutStrikes = 0

    private static let log = Logger(subsystem: "dev.zephr", category: "ax")

    init(pid: pid_t, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
        // .userInitiated keeps command latency well inside the §6.3 budget
        // without pinning P-cores the way .userInteractive would (battery).
        self.queue = DispatchSerialQueue(label: "dev.zephr.ax.\(pid)", qos: .userInitiated)
        self.app = .application(pid: pid)
        // §6.3 deadlines. The process-global floor covers stray elements;
        // the per-element set is still required for every element we message
        // through, because per AXUIElement.h a timeout set on one element
        // applies to that element only (see AXElement.globalTimeoutFloor).
        _ = AXElement.globalTimeoutFloor
        self.app.setMessagingTimeout(AXElement.messagingDeadline)
    }

    private var isDegraded: Bool {
        if let until = degradedUntil, ContinuousClock.now < until { return true }
        degradedUntil = nil
        return false
    }

    private func noteTimeout() {
        timeoutStrikes += 1
        // Retry ladder: 100 ms / 500 ms / 2 s.
        let backoff: Duration = timeoutStrikes == 1 ? .milliseconds(100)
            : timeoutStrikes == 2 ? .milliseconds(500) : .seconds(2)
        degradedUntil = ContinuousClock.now + backoff
        Self.log.warning("pid \(self.pid) degraded (strike \(self.timeoutStrikes))")
    }

    private func noteSuccess() {
        timeoutStrikes = 0
        degradedUntil = nil
    }

    // MARK: - Registration

    /// Registers a window element, assigning a stable WindowID. IDs embed the
    /// pid so they stay unique process-wide with no shared allocator.
    func register(_ element: AXElement) -> (WindowID, WindowSnapshot)? {
        // §6.3 deadline before the FIRST read: the timeout set on the app
        // element does not cascade to this element (AXUIElement.h).
        element.setMessagingTimeout(AXElement.messagingDeadline)
        if let existing = id(for: element) {
            return snapshot(windows[existing]!).map { (existing, $0) }
        }
        guard element.string(kAXRoleAttribute) == kAXWindowRole else { return nil }
        guard let snap = snapshot(element) else { return nil }
        let id = WindowID(UInt64(UInt32(bitPattern: pid)) << 32 | nextSequence)
        nextSequence += 1
        windows[id] = element
        return (id, snap)
    }

    func unregister(_ id: WindowID) {
        windows.removeValue(forKey: id)
    }

    func id(for element: AXElement) -> WindowID? {
        windows.first { $0.value == element }?.key
    }

    func element(for id: WindowID) -> AXElement? {
        windows[id]
    }

    /// Every window element the app currently reports, each stamped with the
    /// §6.3 messaging deadline — a fresh token otherwise runs at the global
    /// default.
    ///
    /// `timedOut` keeps "the app did not answer" distinct from "the app has
    /// no windows". Conflating them makes a busy app look like one whose
    /// windows all vanished, which is how managed windows get purged.
    private func currentWindowElements() -> (timedOut: Bool, elements: [AXElement]) {
        let (err, value) = app.attributeResult(kAXWindowsAttribute)
        if err == .cannotComplete { return (true, []) }
        guard let items = value as? [AnyObject] else { return (false, []) }
        return (false, items.compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            let el = AXElement($0 as! AXUIElement)
            el.setMessagingTimeout(AXElement.messagingDeadline)
            return el
        })
    }

    func listWindows() -> [AXElement] {
        guard !isDegraded else { return [] }
        let (timedOut, elements) = currentWindowElements()
        if timedOut {
            noteTimeout()
            return []
        }
        return elements
    }

    func snapshot(_ element: AXElement) -> WindowSnapshot? {
        guard let frame = element.frame else {
            // Distinguish busy from gone (§6.3/§6.4): a timeout feeds the
            // retry ladder; a dead element is plain nil.
            if element.liveness == .unresponsive { noteTimeout() }
            return nil
        }
        return WindowSnapshot(
            title: element.string(kAXTitleAttribute) ?? "",
            role: element.string(kAXRoleAttribute),
            subrole: element.string(kAXSubroleAttribute),
            frame: frame,
            resizable: element.isSettableSize,
            minimized: element.bool(kAXMinimizedAttribute) ?? false,
            modal: element.bool(kAXModalAttribute) ?? false,
            fullscreen: (element.attribute("AXFullScreen") as? Bool) ?? false
        )
    }

    func snapshot(of id: WindowID) -> WindowSnapshot? {
        guard let el = windows[id] else { return nil }
        return snapshot(el)
    }

    /// What a geometry notification actually is: where the window sits now,
    /// and whether it just entered native fullscreen.
    struct Geometry: Sendable {
        var frame: CGRect
        var fullscreen: Bool
    }

    /// Reads `id`'s frame, and `AXFullScreen` only when that frame covers a
    /// whole display.
    ///
    /// Entering native fullscreen arrives as an ordinary resize (§6.4), so
    /// the engine has to be able to tell the two apart on the event itself
    /// rather than waiting for the audit. Filling a display is the cheap
    /// discriminator - a tile never does (the menu bar alone keeps it out of
    /// `frame`), a fullscreen window always does - so the ordinary path
    /// costs one AX read and only the suspicious case pays for a second
    /// (§6.3).
    func geometry(of id: WindowID, fullscreenIfFilling displays: [CGRect]) -> Geometry? {
        guard let el = windows[id] else { return nil }
        guard let frame = el.frame else {
            // Busy is not gone (§6.3): feed the retry ladder, report nothing.
            if el.liveness == .unresponsive { noteTimeout() }
            return nil
        }
        guard displays.contains(where: { frame.approximatelyEquals($0, tolerance: 2) }) else {
            return Geometry(frame: frame, fullscreen: false)
        }
        return Geometry(frame: frame, fullscreen: (el.attribute("AXFullScreen") as? Bool) ?? false)
    }

    func focusedWindowElement() -> AXElement? {
        guard let el = app.element(kAXFocusedWindowAttribute) else { return nil }
        el.setMessagingTimeout(AXElement.messagingDeadline)   // §6.3
        return el
    }

    // MARK: - Frame application

    struct WriteResult: Sendable {
        var applied: [WindowID: CGRect] = [:]   // read-back frames
        var vetoed: Set<WindowID> = []          // app refused the frame
        /// Sizes apps refused to shrink below. Their own minimum, not a
        /// refusal to be managed — the layout should respect it rather than
        /// give up on the window.
        var minimums: [WindowID: CGSize] = [:]
        /// A newer batch for this app already ran, so nothing was written
        /// and the empty `applied` says nothing about the app's health.
        var superseded = false
    }

    /// Applies a batch of frames with write coalescing (§6.3): no-op writes
    /// are skipped by the caller; Electron's AXEnhancedUserInterface is
    /// disabled around the batch (§6.4); each write is verified by read-back.
    ///
    /// `generation` orders batches. Each apply reaches this actor on its own
    /// task, and separate tasks are *not* delivered in the order they were
    /// created — so two applies issued A-then-B can run B-then-A, leaving
    /// windows at A's stale targets. The caller then records those as
    /// applied, the no-op filter skips them next time and the drift check
    /// compares against the same wrong expectation, so the mistake sticks
    /// instead of self-correcting. Batches older than the newest seen are
    /// dropped rather than written.
    func applyFrames(_ batch: [(WindowID, CGRect)], generation: UInt64 = 0) -> WriteResult {
        var result = WriteResult()
        guard generation == 0 || generation >= writeGeneration else {
            result.superseded = true
            return result
        }
        writeGeneration = max(writeGeneration, generation)
        guard !isDegraded, !batch.isEmpty else { return result }

        // Electron/Chromium workaround: frames misapply while the app has
        // AXEnhancedUserInterface set; toggle it off for the batch.
        let enhancedKey = "AXEnhancedUserInterface"
        let hadEnhancedUI = app.bool(enhancedKey) ?? false
        if hadEnhancedUI {
            app.set(enhancedKey, to: kCFBooleanFalse)
        }
        defer {
            if hadEnhancedUI { app.set(enhancedKey, to: kCFBooleanTrue) }
        }

        var sawTimeout = false
        batchLoop: for (id, target) in batch {
            guard let el = windows[id] else { continue }
            switch el.liveness {
            case .dead:
                continue batchLoop
            case .unresponsive:
                // Messaging timeout: the app is busy, not gone (§6.3). Stop
                // the batch — every further call would burn another 250 ms
                // on this queue — and let the retry ladder re-apply later;
                // unwritten windows keep their cached geometry.
                sawTimeout = true
                break batchLoop
            case .alive:
                break
            }
            // Size, then position, then size again. A window still at its
            // old size can have a move clamped to keep it on screen, and a
            // window moved first can have a grow clamped by the display it
            // has not left yet — so either single order fails on one of the
            // two directions. AeroSpace arrived at the same sequence
            // (their issues 143 and 335); doing it up front costs one write
            // and saves the corrective round trip below.
            el.set(kAXSizeAttribute, size: target.size)
            el.set(kAXPositionAttribute, point: target.origin)
            el.set(kAXSizeAttribute, size: target.size)

            guard var actual = el.frame else {
                if el.liveness == .unresponsive {
                    sawTimeout = true
                    break batchLoop
                }
                continue    // died mid-batch; the audit will purge it
            }
            if !actual.approximatelyEquals(target, tolerance: 2) {
                // One corrective pass for apps that clamp on the first write.
                el.set(kAXPositionAttribute, point: target.origin)
                el.set(kAXSizeAttribute, size: target.size)
                el.set(kAXPositionAttribute, point: target.origin)
                actual = el.frame ?? actual
            }
            result.applied[id] = actual

            // An app that came back *bigger* on an axis, and no smaller on
            // either, hit its own minimum size. That is not a refusal to be
            // tiled — it is us asking for something impossible — and
            // treating it as one is how an ordinary app like an editor ends
            // up permanently floated with a learned rule to match. Record
            // the size it insisted on so the layout can stop asking.
            let moved = abs(actual.origin.x - target.origin.x) > 10
                || abs(actual.origin.y - target.origin.y) > 10
            let fits = actual.width >= target.width - 2 && actual.height >= target.height - 2
            if fits {
                // Per axis, and only the axis that actually refused. Taking
                // the whole size would record the *other* dimension's
                // current value as a minimum too, which is how one window
                // came back claiming it could be neither shorter than 1025
                // nor taller than 240.
                var learned = CGSize.zero
                if actual.width > target.width + 10 { learned.width = actual.width }
                if actual.height > target.height + 10 { learned.height = actual.height }
                if learned != .zero {
                    result.minimums[id] = learned
                    continue
                }
            }

            // A window that accepts the size but refuses to *move* is a veto
            // too (§6.4 read-back veto) — position drift matters just as
            // much, e.g. a window sitting at stash coordinates off-screen.
            if abs(actual.width - target.width) > 10 || abs(actual.height - target.height) > 10 || moved {
                result.vetoed.insert(id)
            }
        }
        // Only a clean batch resets the §6.3 ladder — an unconditional
        // reset here would mean degraded state could never latch.
        if sawTimeout {
            noteTimeout()
        } else {
            noteSuccess()
        }
        return result
    }

    /// Presses the window's close button (leader q / ⌃⌥Q).
    func closeWindow(_ id: WindowID) {
        guard let el = windows[id], !isDegraded else { return }
        guard let button = el.element(kAXCloseButtonAttribute) else {
            if el.liveness == .unresponsive { noteTimeout() }   // §6.3 ladder
            return
        }
        button.setMessagingTimeout(AXElement.messagingDeadline)
        button.perform(kAXPressAction)
    }

    /// Orders `id` to the front *within* its application. Use for stacking
    /// only — this does not move the keyboard (see `focus`).
    func raise(_ id: WindowID) {
        guard let el = windows[id], !isDegraded else { return }
        let madeMain = el.set(kAXMainAttribute, to: kCFBooleanTrue)
        let raised = el.perform(kAXRaiseAction)
        if !madeMain, !raised, el.liveness == .unresponsive {
            noteTimeout()   // §6.3 ladder
        }
    }

    /// Makes `id` the window the user is typing into, and reports whether it
    /// worked.
    ///
    /// `kAXMain` and `AXRaise` only order windows inside an application;
    /// neither changes which app owns the keyboard. Zephr is an `LSUIElement`
    /// agent and is never frontmost when a focus command runs, so under
    /// macOS cooperative activation `NSRunningApplication.activate()` can be
    /// declined outright — the focus ring moves and the keystrokes keep
    /// going to the previous app, which reads as the whole product being
    /// broken. Setting `kAXFrontmost` on the application element is the
    /// public-API path that is not subject to that arbitration.
    ///
    /// Returns whether the AX writes were accepted. Whether the app truly
    /// came forward is the caller's to check on the main actor: reading
    /// `kAXFrontmost` back here still reports the pre-activation value,
    /// because activation completes asynchronously in the target app — so
    /// the read-back said "failed" for focus changes that visibly worked.
    func focus(_ id: WindowID) -> Bool {
        guard let el = windows[id], !isDegraded else { return false }
        let madeMain = el.set(kAXMainAttribute, to: kCFBooleanTrue)
        let raised = el.perform(kAXRaiseAction)
        let fronted = app.set(kAXFrontmostAttribute, to: kCFBooleanTrue)
        if !madeMain, !raised, !fronted, el.liveness == .unresponsive {
            noteTimeout()
            return false
        }
        return madeMain || raised || fronted
    }

    // MARK: - Audit (reconciliation input, §6.4)

    struct AuditResult: Sendable {
        /// Confirmed dead (`kAXErrorInvalidUIElement` only, §6.4) — already
        /// unregistered from this connection; the engine should remove them.
        var dead: [WindowID] = []
        /// Windows whose state could not be verified this cycle because the
        /// app timed out AX messaging or is degraded (§6.3). They are NOT
        /// dead: they stay registered on this connection, and the caller
        /// must keep them managed with cached geometry, drawing no
        /// conclusions from their absence in `frames` / `minimized` /
        /// `fullscreen`. A caller that ignores this field is still safe as
        /// long as it only *removes* windows listed in `dead`.
        var unresponsive: Set<WindowID> = []
        var unknown: [AXElement] = []
        var frames: [WindowID: CGRect] = [:]
        /// Only windows whose attribute actually answered. A failed or
        /// absent read must not read back as `false` — some toolkits post
        /// the miniaturize notification without ever exposing the
        /// attribute, and treating the gap as "not minimized" un-minimizes
        /// the window in the model on the very next audit.
        var minimized: [WindowID: Bool] = [:]
        var fullscreen: [WindowID: Bool] = [:]
    }

    func audit() -> AuditResult {
        var result = AuditResult()
        guard !isDegraded else {
            // Degraded (§6.3): nothing gets verified this cycle; report
            // every window unresponsive so the caller keeps cached state.
            result.unresponsive = Set(windows.keys)
            return result
        }

        var sawTimeout = false
        for (id, el) in windows {
            if sawTimeout {
                // AX messaging is per-process: after one timeout, each
                // further probe would burn another 250 ms. Report the rest
                // unverified instead.
                result.unresponsive.insert(id)
                continue
            }
            switch el.liveness {
            case .dead:
                // Only kAXErrorInvalidUIElement purges the ghost (§6.4).
                result.dead.append(id)
                continue
            case .unresponsive:
                // Messaging timeout: busy, not gone (§6.3). The window
                // stays registered with cached geometry.
                result.unresponsive.insert(id)
                sawTimeout = true
                continue
            case .alive:
                break
            }
            if let frame = el.frame {
                result.frames[id] = frame
            }
            if let value = el.bool(kAXMinimizedAttribute) {
                result.minimized[id] = value
            }
            if let value = el.attribute("AXFullScreen") as? Bool {
                result.fullscreen[id] = value
            }
        }
        for id in result.dead {
            windows.removeValue(forKey: id)
        }
        if sawTimeout {
            noteTimeout()
            return result
        }

        // Windows that exist but were never adopted (missed creation events).
        let (timedOut, elements) = currentWindowElements()
        if timedOut {
            noteTimeout()
            return result
        }
        let known = Set(windows.values)
        result.unknown = elements.filter { !known.contains($0) }
        noteSuccess()
        return result
    }
}
