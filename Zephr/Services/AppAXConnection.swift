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
        self.app.setMessagingTimeout(0.25)
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
        if let existing = id(for: element) {
            return snapshot(windows[existing]!).map { (existing, $0) }
        }
        guard element.string(kAXRoleAttribute) == kAXWindowRole else { return nil }
        guard let snap = snapshot(element) else { return nil }
        let id = WindowID(UInt64(UInt32(bitPattern: pid)) << 32 | nextSequence)
        nextSequence += 1
        element.setMessagingTimeout(0.25)
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

    func listWindows() -> [AXElement] {
        guard !isDegraded else { return [] }
        return app.elements(kAXWindowsAttribute)
    }

    func snapshot(_ element: AXElement) -> WindowSnapshot? {
        guard let frame = element.frame else { return nil }
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

    func focusedWindowElement() -> AXElement? {
        app.element(kAXFocusedWindowAttribute)
    }

    // MARK: - Frame application

    struct WriteResult: Sendable {
        var applied: [WindowID: CGRect] = [:]   // read-back frames
        var vetoed: Set<WindowID> = []          // app refused the frame
    }

    /// Applies a batch of frames with write coalescing (§6.3): no-op writes
    /// are skipped by the caller; Electron's AXEnhancedUserInterface is
    /// disabled around the batch (§6.4); each write is verified by read-back.
    func applyFrames(_ batch: [(WindowID, CGRect)]) -> WriteResult {
        var result = WriteResult()
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

        for (id, target) in batch {
            guard let el = windows[id] else { continue }
            guard el.isAlive else { continue }
            el.set(kAXPositionAttribute, point: target.origin)
            el.set(kAXSizeAttribute, size: target.size)

            guard var actual = el.frame else {
                noteTimeout()
                continue
            }
            if !actual.approximatelyEquals(target, tolerance: 2) {
                // One corrective pass for apps that clamp on the first write.
                el.set(kAXPositionAttribute, point: target.origin)
                el.set(kAXSizeAttribute, size: target.size)
                el.set(kAXPositionAttribute, point: target.origin)
                actual = el.frame ?? actual
            }
            result.applied[id] = actual
            if abs(actual.width - target.width) > 10 || abs(actual.height - target.height) > 10 {
                result.vetoed.insert(id)
            }
        }
        noteSuccess()
        return result
    }

    /// Presses the window's close button (leader q / ⌃⌥Q).
    func closeWindow(_ id: WindowID) {
        guard let el = windows[id], !isDegraded else { return }
        el.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }

    /// Raises a window above its app siblings and marks it main.
    func raise(_ id: WindowID) {
        guard let el = windows[id], !isDegraded else { return }
        el.set(kAXMainAttribute, to: kCFBooleanTrue)
        el.perform(kAXRaiseAction)
    }

    // MARK: - Audit (reconciliation input, §6.4)

    struct AuditResult: Sendable {
        var dead: [WindowID] = []
        var unknown: [AXElement] = []
        var frames: [WindowID: CGRect] = [:]
        var minimized: Set<WindowID> = []
        var fullscreen: Set<WindowID> = []
    }

    func audit() -> AuditResult {
        var result = AuditResult()
        guard !isDegraded else { return result }

        for (id, el) in windows {
            guard el.isAlive else {
                result.dead.append(id)
                continue
            }
            if let frame = el.frame {
                result.frames[id] = frame
            }
            if el.bool(kAXMinimizedAttribute) == true {
                result.minimized.insert(id)
            }
            if (el.attribute("AXFullScreen") as? Bool) == true {
                result.fullscreen.insert(id)
            }
        }
        for id in result.dead {
            windows.removeValue(forKey: id)
        }

        // Windows that exist but were never adopted (missed creation events).
        let known = Set(windows.values)
        for el in app.elements(kAXWindowsAttribute) where !known.contains(el) {
            result.unknown.append(el)
        }
        return result
    }
}
