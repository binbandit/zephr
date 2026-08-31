import AppKit
import os
import ZephrCore

/// Observable state for the menu bar and HUD.
@MainActor
@Observable
final class AppState {
    var currentWorkspace: Int = 1
    var axTrusted: Bool = false
    var layerState: HotkeyService.LayerState = .inactive
    var secureInputActive: Bool = false
    var managedWindowCount: Int = 0
    var configError: String?
    var launchAtLogin: Bool = false
    var paused: Bool = false
    var workspaceNames: [Int: String] = [:]
    /// Active workspace per connected display, in display order.
    var displayWorkspaces: [Int] = []
    /// Whether the status-bar item is shown (config `menu-bar-icon`).
    var showMenuBarIcon: Bool = true
}

/// The MainActor orchestrator (§6.2 WorkspaceEngine): owns the ZephrCore
/// model as the source of truth for intent, reconciles observed reality
/// against it, and fans AX work out to per-app actors. All UI and services
/// talk to this type.
@MainActor
final class TilingEngine {

    nonisolated(unsafe) static weak var shared: TilingEngine?

    let model = WorkspaceModel()
    var config = LayoutConfig.default
    var rules = RuleSet()

    struct ManagedWindow {
        let id: WindowID
        let pid: pid_t
        let bundleID: String?
        let element: AXElement
        var title: String
        var floating: Bool
        var minimized: Bool = false
        /// Why this window is out of the layout, if it is.
        ///
        /// The reasons stack: an app the user hides while one of its windows
        /// already sits on another Space has two, and lifting either one
        /// alone must not bring the window back. Only `.minimized` is
        /// something AX reports — for the other two the window describes
        /// itself as perfectly ordinary, which is why the audit cannot be
        /// left to decide on its own.
        var withdrawnFor: Set<WithdrawReason> = []
        /// Native fullscreen: unmanaged but palette-listed (§6.4).
        var fullscreen: Bool = false
        var lastAppliedFrame: CGRect?
        /// Read-back after the last write settled. Snapping apps (Terminal's
        /// character grid) land a few points off target forever; convergence
        /// accepts either frame so we stop re-issuing writes (§6.3).
        var lastSettledFrame: CGRect?
        var lastVisibleFrame: CGRect
        /// The frame the window had when Zephr first saw it — quitting puts
        /// every window back exactly here (§6.6).
        var originalFrame: CGRect
        var vetoStrikes: Int = 0
        /// Workspace the window was in when it minimized or went native
        /// fullscreen — restoring puts it back there, not wherever the user
        /// happens to be (§4.4).
        var suspendedWorkspace: Int?
    }

    private(set) var windows: [WindowID: ManagedWindow] = [:]
    private(set) var connections: [pid_t: AppAXConnection] = [:]
    /// Apps *we* hid for the stash — never touch apps the user hid (⌘H).
    private var hiddenApps: Set<pid_t> = []
    /// Pids with an in-flight `maybeHideApp` probe.
    private var hideProbesInFlight: Set<pid_t> = []
    private var displays: [DisplayInfo] = []
    /// Recent frame writes, to tell our own echo events from user drift.
    private var pendingWrites: [WindowID: (frame: CGRect, at: ContinuousClock.Instant)] = [:]
    private var reapplyDebounce: [DisplayID: Task<Void, Never>] = [:]
    private var auditTimer: Task<Void, Never>?
    private var started = false
    /// Last observer event or command — gates the idle audit (battery).
    private var lastActivity = ContinuousClock.now
    /// Display profiles by fingerprint (§4.5), persisted in state.json.
    private var profiles: [String: ModelSnapshot] = [:]
    private var profileCaptureEnabled = false
    /// The saved profile for the launch arrangement, held immutable until
    /// adoption quiesces (§4.5) — a fixed startup delay loses the reboot
    /// race and the next capture would clobber the good profile.
    private var pendingRestore: ModelSnapshot?
    private var lastAdoptionAt = ContinuousClock.now
    /// Pids whose windows are not currently verifiable (§6.3): the last
    /// audit reported unresponsive windows, or a frame batch aborted on a
    /// messaging timeout. Their windows keep cached geometry, profiles are
    /// not captured while any app is in this state, and the first clean
    /// audit afterwards re-applies their displays (§6.4 convergence).
    private var unresponsivePids: Set<pid_t> = []
    /// At most one audit in flight per pid (§6.3): a slow-but-alive app must
    /// not accumulate queued audits faster than they drain.
    private var auditsInFlight: Set<pid_t> = []

    let hub: ObserverHub
    let displayService: DisplayService
    let stateStore: StateStore
    let appState: AppState
    var focusBorder: FocusBorderController?
    /// Event fan-out (§4.8): workspace_changed, focus_changed,
    /// window_managed/unmanaged, display_changed → zephrctl subscribers.
    var onEvent: ((String, [String: String]) -> Void)?
    private var workspaceCallbacks: [String] = []
    private var lastAnnouncedWorkspace: Int?

    private static let log = Logger(subsystem: "dev.zephr", category: "engine")

    init(hub: ObserverHub, displayService: DisplayService, stateStore: StateStore, appState: AppState) {
        self.hub = hub
        self.displayService = displayService
        self.stateStore = stateStore
        self.appState = appState
        Self.shared = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Self.log.info("engine starting: adopting existing windows")

        displays = displayService.current()
        model.syncDisplays(displays.map(\.id))
        displayService.onChange = { [weak self] in self?.displaysChanged() }

        hub.onEvent = { [weak self] event in self?.handle(event) }

        // Crash recovery (§6.6) runs before adoption or profile matching can
        // look at the wreckage: if the last run died mid-flight, unhide the
        // apps we hid and pull windows still parked at stash coordinates
        // back on screen (invariant 1).
        let saved = stateStore.load()
        profiles = saved?.profiles ?? [:]
        if let saved, !saved.cleanShutdown {
            recoverFromCrash(saved)
        }

        let workspaceNC = NSWorkspace.shared.notificationCenter
        workspaceNC.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated {
                // AX needs a beat after launch before windows respond (§6.4).
                guard let engine = TilingEngine.shared else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    engine.attachApp(app)
                }
            }
        }
        workspaceNC.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { TilingEngine.shared?.detachApp(pid: pid) }
        }
        // Switching native Space moves windows out from under us with no AX
        // notification at all (§6.4). Debounced past the transition, which
        // animates for a few hundred ms and reports a half-settled window
        // list while it does.
        workspaceNC.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TilingEngine.shared?.scheduleSpaceReconcile() }
        }
        // ⌘H (§6.4): an app's windows leave the screen without a single AX
        // notification, so without this the layout holds tiles for windows
        // nobody can see until the app comes back.
        workspaceNC.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { TilingEngine.shared?.noteAppHidden(pid: pid) }
        }
        workspaceNC.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { TilingEngine.shared?.noteAppUnhidden(pid: pid) }
        }
        workspaceNC.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { TilingEngine.shared?.appActivated(pid: pid) }
        }

        for app in NSWorkspace.shared.runningApplications {
            attachApp(app)
        }

        // Battery: the audit is activity-gated. Busy periods get a 3 s
        // reconciliation pass; at idle we only deep-sweep every ~30 s, and
        // the tolerance lets the OS coalesce the wakeups (§6.3 idle budget).
        auditTimer = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3), tolerance: .seconds(1))
                tick += 1
                guard let self else { return }
                let idle = ContinuousClock.now - self.lastActivity > .seconds(10)
                if !idle || tick % 10 == 0 {
                    self.audit()
                }
                // Backstop for a missed Space notification. The deep sweep
                // only, so an idle desktop still costs one window-list read
                // every ~30 s.
                if tick % 10 == 0 { self.reconcileSpaces() }
            }
        }

        // Session restore (§4.5): the profile for this arrangement stays
        // pending — and capture stays off — until adoption *quiesces* (no
        // new adoptions for a few seconds). A fixed delay structurally fails
        // on login: most apps adopt their windows long after it, the profile
        // matches almost nothing, and the next capture would overwrite the
        // saved profile with a near-empty model. While pending, `adopt()`
        // places late windows from the profile (see below).
        pendingRestore = profile(matching: ProfileEngine.fingerprint(currentSlots()))
        Task {
            let began = ContinuousClock.now
            while ContinuousClock.now - began < .seconds(30) {
                try? await Task.sleep(for: .seconds(1))
                if ContinuousClock.now - self.lastAdoptionAt > .seconds(3) { break }
            }
            self.restoreSession()
            self.profileCaptureEnabled = true
            self.persistSoon()
        }
    }

    /// §6.6 crash recovery: the previous run died without its restore pass,
    /// so apps we hid are still hidden and stashed windows still sit at
    /// off-screen coordinates with no manager running them. Unhide, then
    /// move every stashed-looking window to its recorded frame (or a visible
    /// fallback). The per-app AX sweep runs off the MainActor with short
    /// per-element timeouts; recovery must never be the thing that freezes
    /// the launch it is recovering (invariant 1 without breaking 3).
    private func recoverFromCrash(_ saved: StateStore.Snapshot) {
        Self.log.warning("unclean shutdown detected — recovering windows (§6.6)")

        for record in saved.hiddenApps ?? [] {
            if let app = NSRunningApplication(processIdentifier: record.pid),
               record.bundleID == nil || app.bundleIdentifier == record.bundleID {
                app.unhide()
            } else if let bundleID = record.bundleID {
                // After a reboot the pid was recycled; fall back to bundle id.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    app.unhide()
                }
            }
        }

        let displayFrames = displays.map(\.frame)
        // Restore targets: recorded frames that are visible on the *current*
        // arrangement. A record whose own frame looks stashed (or sat on a
        // display that's gone) can't serve as a target; those windows get a
        // centered fallback instead.
        var candidates: [String: [StateStore.WindowRecord]] = [:]
        var recordedBundles: Set<String> = []
        for record in saved.windows {
            guard let bundleID = record.bundleID else { continue }
            recordedBundles.insert(bundleID)
            if !StashPlanner.looksStashed(record.frame, displays: displayFrames) {
                candidates[bundleID, default: []].append(record)
            }
        }
        guard !recordedBundles.isEmpty else { return }
        let visible = displays.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let targets: [(pid: pid_t, bundleID: String)] = NSWorkspace.shared.runningApplications
            .compactMap { app in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      recordedBundles.contains(bundleID) else { return nil }
                return (app.processIdentifier, bundleID)
            }
        guard !targets.isEmpty else { return }

        // Off the MainActor (§6.3, invariant 3). Every probe below is a
        // synchronous AX round trip, and a crash relaunch is precisely when
        // other apps are also restoring and slow to answer: run this inline
        // and `apps x windows x 5 x 100 ms` of it lands on the main thread,
        // freezing the menu bar, the permission gate and the event tap. One
        // task per app so a wedged app delays only its own recovery.
        for (pid, bundleID) in targets {
            let pool = candidates[bundleID] ?? []
            Task.detached {
                var pool = pool
                let axApp = AXElement.application(pid: pid)
                axApp.setMessagingTimeout(0.1)
                for element in axApp.elements(kAXWindowsAttribute) {
                    element.setMessagingTimeout(0.1)
                    guard let frame = element.frame,
                          StashPlanner.looksStashed(frame, displays: displayFrames) else { continue }
                    // A hidden app whose windows sit at stash coordinates is
                    // our hide with near-certainty — the hide raced the
                    // debounced persist and went unrecorded, so the
                    // `hiddenApps` loop above missed it. Unhide before
                    // placing (§4.4), or the recovered windows come back
                    // invisible and the layout keeps a hole (invariant 1).
                    await MainActor.run {
                        let app = NSRunningApplication(processIdentifier: pid)
                        if app?.isHidden == true { app?.unhide() }
                    }
                    let title = element.string(kAXTitleAttribute) ?? ""
                    var target = CGRect(
                        x: visible.midX - frame.width / 2,
                        y: visible.midY - frame.height / 2,
                        width: frame.width, height: frame.height
                    )
                    if !pool.isEmpty {
                        // Exact title first, then FIFO per bundle — the same
                        // heuristic profile matching uses (§4.5).
                        let idx = pool.firstIndex { $0.title == title } ?? 0
                        target = pool.remove(at: idx).frame
                    }
                    element.set(kAXPositionAttribute, point: target.origin)
                    element.set(kAXSizeAttribute, size: target.size)
                }
            }
        }
    }

    /// Orderly shutdown: every window returns to the exact frame it had
    /// before Zephr managed it, apps unhidden, snapshot marked clean.
    /// Synchronous AX on purpose — we're exiting. Invisible windows (stashed
    /// or minimized) go first: single-instance takeover force-kills us after
    /// a grace period, and a truncated pass must still have rescued the
    /// windows nobody can see (§6.6, invariant 1). Minimized windows get
    /// their frame written too — un-minimizing later must not reveal a
    /// window parked at stash coordinates with no manager running. Short
    /// per-element timeouts keep the whole pass bounded (§6.3).
    func shutdownRestore() {
        for pid in hiddenApps {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        hiddenApps.removeAll()
        // A partition, not a sort: this only needs invisible-before-visible,
        // and as a comparator `isVisible` (two dictionary lookups and a tree
        // walk) ran O(n log n) times on the shutdown path.
        var invisible: [ManagedWindow] = []
        var visible: [ManagedWindow] = []
        for mw in windows.values {
            if isVisible(mw.id) { visible.append(mw) } else { invisible.append(mw) }
        }
        for mw in (invisible + visible) where !mw.fullscreen {
            mw.element.setMessagingTimeout(0.1)
            mw.element.set(kAXPositionAttribute, point: mw.originalFrame.origin)
            mw.element.set(kAXSizeAttribute, size: mw.originalFrame.size)
        }
        stateStore.saveNow(windows: snapshotRecords(), profiles: profiles, hiddenApps: [], clean: true)
    }

    // MARK: - App attach/detach

    private func attachApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              // The launch path delays 500 ms before attaching; an app that
              // died in that window already fired its termination
              // notification, and attaching now would leak a connection the
              // audit polls forever (§6.4).
              !app.isTerminated,
              connections[pid] == nil else { return }
        if let bundleID = app.bundleIdentifier,
           rules.action(bundleID: bundleID, title: nil) == .ignore {
            return
        }
        let conn = AppAXConnection(pid: pid, bundleID: app.bundleIdentifier)
        connections[pid] = conn
        hub.watchApp(pid: pid)
        Task {
            let elements = await conn.listWindows()
            for element in elements {
                await self.adopt(element: element, pid: pid)
            }
            // Adopting an app the user had already hidden would tile windows
            // that are not on screen — the same hole, just created at launch.
            if app.isHidden { self.noteAppHidden(pid: pid) }
        }
    }

    private func detachApp(pid: pid_t) {
        guard let conn = connections.removeValue(forKey: pid) else { return }
        hub.unwatchApp(pid: pid)
        hiddenApps.remove(pid)
        unresponsivePids.remove(pid)
        // An in-flight audit's task discards its own stale result (it
        // checks connection identity); the in-flight marker is cleared
        // here so a re-attached pid can be audited again immediately.
        auditsInFlight.remove(pid)
        let managed = windows.values.filter { $0.pid == pid }
        // Normally the app is gone and there is nothing to rescue. But the
        // audit also detaches a pid `NSRunningApplication` no longer
        // resolves, and `disablePracticeWindows` detaches directly — if the
        // app is in fact alive, its stashed windows would be dropped from
        // the model while still parked off-screen, invisible to
        // shutdownRestore, `leader w` and the audit alike (invariant 1).
        // Hand them back to their last on-screen frames on the way out.
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            let stranded = managed.filter { !isVisible($0.id) && !$0.minimized }
            if !stranded.isEmpty {
                if app.isHidden { app.unhide() }
                // The detached connection still holds these ids; reusing it
                // keeps the rescue a single batch with no re-registration.
                let batch = stranded.map { ($0.id, $0.lastVisibleFrame) }
                nextWriteGeneration += 1
                let generation = nextWriteGeneration
                Task { _ = await conn.applyFrames(batch, generation: generation) }
            }
        }
        for mw in managed {
            windows.removeValue(forKey: mw.id)
            model.removeWindow(mw.id)
        }
        if !managed.isEmpty { applyAll() }
    }

    private func appActivated(pid: pid_t) {
        guard let conn = connections[pid] else { return }
        Task {
            guard let element = await conn.focusedWindowElement(),
                  let id = await conn.id(for: element) else { return }
            self.noteFocused(id)
        }
    }

    // MARK: - Adoption (classification per §4.3)

    private static let floatSubroles: Set<String> = ["AXDialog", "AXSystemDialog"]

    /// Tutorial practice windows (§4.1): the only windows of our own that
    /// Zephr manages, identified by title.
    static let practiceWindowPrefix = "Zephr Practice"

    /// Lets the tutorial's practice windows be tiled like any other app's.
    func enablePracticeWindows() {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard connections[pid] == nil else { return }
        let conn = AppAXConnection(pid: pid, bundleID: Bundle.main.bundleIdentifier)
        connections[pid] = conn
        hub.watchApp(pid: pid)
    }

    func disablePracticeWindows() {
        detachApp(pid: pid_t(ProcessInfo.processInfo.processIdentifier))
    }

    private func adopt(element: AXElement, pid: pid_t) async {
        guard let conn = connections[pid] else { return }
        guard let (id, snap) = await conn.register(element) else { return }
        guard windows[id] == nil else { return }

        // Own windows: only the tutorial's practice windows are managed.
        if pid == pid_t(ProcessInfo.processInfo.processIdentifier),
           !snap.title.hasPrefix(Self.practiceWindowPrefix) {
            await conn.unregister(id)
            return
        }

        // Native fullscreen stays out of the tree but is tracked so it shows
        // in the palette (marked) and re-tiles when it leaves fullscreen (§6.4).
        if snap.fullscreen {
            lastAdoptionAt = ContinuousClock.now
            windows[id] = ManagedWindow(
                id: id, pid: pid, bundleID: conn.bundleID, element: element,
                title: snap.title, floating: false, fullscreen: true,
                lastVisibleFrame: snap.frame, originalFrame: snap.frame
            )
            hub.watchWindow(pid: pid, element: element, id: id)
            return
        }
        if let subrole = snap.subrole,
           subrole != kAXStandardWindowSubrole as String,
           !Self.floatSubroles.contains(subrole) {
            await conn.unregister(id)
            return
        }

        let ruleAction = rules.action(bundleID: conn.bundleID, title: snap.title)
        if ruleAction == .ignore {
            await conn.unregister(id)
            return
        }

        let floats: Bool
        switch ruleAction {
        case .float: floats = true
        case .tile: floats = false
        default:
            floats = Self.floatSubroles.contains(snap.subrole ?? "")
                || snap.modal
                || !snap.resizable
                || (snap.frame.width < config.floatIfSmallerThan.width
                    && snap.frame.height < config.floatIfSmallerThan.height)
        }

        var workspaceID: Int?
        if case .workspace(let n) = ruleAction { workspaceID = n }
        if workspaceID == nil, let pending = pendingRestore, let bundleID = conn.bundleID {
            // Session restore (§4.5): while the launch profile is pending,
            // late-adopted windows are placed from it — on a reboot most
            // apps adopt long after startup, and falling back to the active
            // workspace would scatter the layout the quiesce pass restores.
            workspaceID = Self.profileWorkspace(
                for: WindowFingerprint(bundleID: bundleID, title: snap.title),
                in: pending
            )
        }
        if workspaceID == nil {
            workspaceID = displayContaining(snap.frame.center).map {
                model.activeWorkspace(on: $0.id).id
            }
        }

        lastAdoptionAt = ContinuousClock.now
        windows[id] = ManagedWindow(
            id: id, pid: pid, bundleID: conn.bundleID, element: element,
            title: snap.title, floating: floats, minimized: snap.minimized,
            fullscreen: false, lastVisibleFrame: snap.frame, originalFrame: snap.frame
        )
        // Record *why* it is out of the layout, not just that it is —
        // `restore` lifts a named reason, so a window adopted while already
        // minimized would otherwise never be allowed back.
        if snap.minimized { windows[id]?.withdrawnFor.insert(.minimized) }
        hub.watchWindow(pid: pid, element: element, id: id)

        if !snap.minimized {
            model.insertWindow(id, workspace: workspaceID, floating: floats, frame: snap.frame)
            applyAll()
        }
        appState.managedWindowCount = windows.count
        onEvent?("window_managed", ["window": "\(id.raw)", "app": conn.bundleID ?? "", "title": snap.title])
    }

    // MARK: - Observer events

    private func handle(_ event: ObserverHub.Event) {
        lastActivity = ContinuousClock.now
        switch event {
        case .windowCreated(let pid, let element):
            Task { await self.adopt(element: element, pid: pid) }

        case .appFocusChanged(let pid, let element):
            guard let element, let conn = connections[pid] else { return }
            Task {
                if let id = await conn.id(for: element) { self.noteFocused(id) }
            }

        case .windowDestroyed(let id):
            removeWindow(id)

        case .windowMoved(let id), .windowResized(let id):
            handleGeometryEvent(id)

        case .windowTitleChanged(let id):
            guard let mw = windows[id], let conn = connections[mw.pid] else { return }
            Task {
                if let snap = await conn.snapshot(of: id) {
                    self.windows[id]?.title = snap.title
                }
            }

        case .windowMiniaturized(let id):
            withdraw(id, reason: .minimized)

        case .windowDeminiaturized(let id):
            restore(id, reason: .minimized)
        }
    }

    enum WithdrawReason: Hashable {
        case minimized      // the user minimized this window
        case appHidden      // the user hid the whole app (⌘H)
        case offSpace       // the window is on another native Space
    }

    /// Minimize transitions, shared by the notification handlers and the
    /// audit's minimized diff (§6.4). Leaving the tree records the workspace
    /// the window came from so restoring — even days later from the Dock —
    /// puts it back there, not wherever focus happens to be (§4.4).
    /// Takes a window out of the layout for `reason`, remembering where it
    /// was so it can go back. Idempotent per reason, and a no-op when the
    /// window is already out for a different one.
    private func withdraw(_ id: WindowID, reason: WithdrawReason) {
        guard let mw = windows[id], !mw.withdrawnFor.contains(reason) else { return }
        windows[id]?.withdrawnFor.insert(reason)
        guard !mw.minimized else { return }   // already out of the tree
        windows[id]?.suspendedWorkspace = model.workspace(containing: id)?.id
        windows[id]?.minimized = true
        model.removeWindow(id)
        applyAll()
        focusModelFallback()
    }

    /// Lifts one reason. The window only returns once nothing else is
    /// holding it out — un-hiding an app must not un-minimize the window
    /// the user minimized inside it.
    private func restore(_ id: WindowID, reason: WithdrawReason) {
        guard let mw = windows[id], mw.withdrawnFor.contains(reason) else { return }
        windows[id]?.withdrawnFor.remove(reason)
        guard windows[id]?.withdrawnFor.isEmpty == true, mw.minimized else { return }
        windows[id]?.minimized = false
        windows[id]?.suspendedWorkspace = nil
        model.insertWindow(id, workspace: mw.suspendedWorkspace, floating: mw.floating, frame: mw.lastVisibleFrame)
        applyAll()
    }

    /// Coalesces Space reconciles and waits out the transition animation.
    func scheduleSpaceReconcile() {
        spaceDebounce?.cancel()
        spaceDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.reconcileSpaces()
        }
    }

    /// Withdraws windows that are on another native Space and brings back
    /// the ones that returned (§6.4).
    ///
    /// Only windows the model currently *shows* are judged. A stashed window
    /// is parked off-display on purpose and can be missing from the
    /// on-screen list for that reason alone; judging those would empty every
    /// inactive workspace at once.
    ///
    /// The pass is symmetric on purpose: everything previously withdrawn is
    /// restored first, then the whole set is judged together. Tracking
    /// arrivals and departures separately needs two different rules for one
    /// question, and the coalesced apply means the intermediate state is
    /// never written to any window.
    private func reconcileSpaces() {
        guard !paused else { return }
        let onScreen = SpaceProbe.onScreenWindowsByPID()
        // No information — an API failure must never read as "every window
        // left the Space" (invariant 1).
        guard !onScreen.isEmpty else { return }

        for id in windows.keys where windows[id]?.withdrawnFor.contains(.offSpace) == true {
            restore(id, reason: .offSpace)
        }

        var candidates: [SpaceMembership.Candidate] = []
        for mw in windows.values
        where !mw.minimized && !mw.fullscreen && isVisible(mw.id) {
            candidates.append(.init(
                id: mw.id,
                pid: mw.pid,
                frame: mw.lastSettledFrame ?? mw.lastAppliedFrame ?? mw.lastVisibleFrame))
        }
        for id in SpaceMembership.absent(candidates: candidates, onScreenByPID: onScreen) {
            withdraw(id, reason: .offSpace)
        }
    }

    /// The user hid an app. Withdraw its windows from the layout exactly
    /// as minimizing each one would, so the tiles close instead of holding
    /// space for windows that are not on screen.
    ///
    /// Zephr's own stash-hides are excluded: those windows are already
    /// off-screen by design and belong to workspaces the user has simply
    /// switched away from.
    func noteAppHidden(pid: pid_t) {
        guard !hiddenApps.contains(pid) else { return }
        for id in windows.keys where windows[id]?.pid == pid {
            withdraw(id, reason: .appHidden)
        }
    }

    func noteAppUnhidden(pid: pid_t) {
        for id in windows.keys where windows[id]?.pid == pid {
            restore(id, reason: .appHidden)
        }
    }

    private func removeWindow(_ id: WindowID) {
        guard let mw = windows.removeValue(forKey: id) else { return }
        let wasFocused = model.focusedWindow == id
        model.removeWindow(id)
        pendingWrites.removeValue(forKey: id)
        // Drop the window's six AXObserver registrations too. `unregister`
        // only clears the AX connection's map; without this the observer keeps
        // a registration (and a dead AXUIElement) per notification for the
        // app's whole lifetime — 1200 stale entries after 200 window closes,
        // against the §6.3 RSS budget.
        hub.unwatchWindow(pid: mw.pid, element: mw.element)
        if let conn = connections[mw.pid] {
            Task { await conn.unregister(id) }
        }
        applyAll()
        if wasFocused { focusModelFallback() }
        appState.managedWindowCount = windows.count
        onEvent?("window_unmanaged", ["window": "\(id.raw)", "app": mw.bundleID ?? ""])
    }

    /// Moved/resized events: our own writes echo back — ignore those. Real
    /// drift during a mouse drag auto-floats the window (§4.3); anything else
    /// re-converges to the model via a debounced re-apply.
    private func handleGeometryEvent(_ id: WindowID) {
        if let pending = pendingWrites[id],
           ContinuousClock.now - pending.at < .seconds(1) {
            return
        }
        guard !paused else { return }
        guard let mw = windows[id], !mw.minimized,
              let ws = model.workspace(containing: id) else { return }

        // Stashed windows have nothing to track (§4.4): a late echo of our
        // own stash write must never be recorded as the window's real frame —
        // for a float that would bake the off-screen position into the model
        // and, via the next capture, into the saved profile (invariant 1).
        guard isVisible(id) else { return }

        if ws.isFloating(id) {
            // Track the float's new frame as its truth.
            guard let conn = connections[mw.pid] else { return }
            Task {
                if let snap = await conn.snapshot(of: id) {
                    ws.setFloatingFrame(id, frame: snap.frame)
                    self.windows[id]?.lastVisibleFrame = snap.frame
                    self.persistSoon()
                }
            }
            return
        }

        if NSEvent.pressedMouseButtons & 1 != 0 {
            // Title-bar drag on a tiled window: float it for the drag and
            // offer drop targets to re-tile (§4.3) — but only if the cursor
            // is actually on this window. Apps resize their own windows
            // during unrelated drags, and floating those would pop the
            // wrong window out and let dragEnded retile it (§6.4).
            guard let conn = connections[mw.pid] else { return }
            Task {
                guard let snap = await conn.snapshot(of: id) else { return }
                guard let cursor = self.cursorInGlobalCG(), snap.frame.contains(cursor) else { return }
                guard let ws = self.model.workspace(containing: id), !ws.isFloating(id) else { return }
                _ = ws.toggleFloat(id, defaultFrame: snap.frame)
                ws.setFloatingFrame(id, frame: snap.frame)
                self.windows[id]?.floating = true
                self.applyAll()
                self.beginDragSession(id)
            }
            return
        }

        // App moved itself: snap back to the model.
        if let home = ws.homeDisplay { scheduleReapply(home) }
    }

    // MARK: - Drag drop-zones (§4.3)

    var dropOverlay: DropZoneOverlay?
    var gapResizer: GapResizeController?
    private var dragSession: (id: WindowID, monitors: [Any], target: (WindowID, Direction)?)?
    private var dragWatchdog: Task<Void, Never>?

    private func beginDragSession(_ id: WindowID) {
        guard dragSession == nil else { return }
        // The mouse may already be up if the drag was a flick; stay floating.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        var monitors: [Any] = []
        // Global monitors never see this process's own events, so a drag of a
        // tutorial practice window would never deliver its mouse-up and would
        // strand the session — which `guard dragSession == nil` then turns
        // into "drag-to-retile is dead until relaunch". Watch locally too.
        for mask in [NSEvent.EventTypeMask.leftMouseDragged, .leftMouseUp] {
            let ended = mask == .leftMouseUp
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
                MainActor.assumeIsolated {
                    ended ? TilingEngine.shared?.dragEnded() : TilingEngine.shared?.dragMoved()
                }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated {
                    ended ? TilingEngine.shared?.dragEnded() : TilingEngine.shared?.dragMoved()
                }
                return event
            }) { monitors.append(m) }
        }
        dragSession = (id, monitors, nil)

        // The button can be released in the window between the check above and
        // the monitors being installed — exactly the flick the comment warns
        // about — in which case no mouse-up is ever delivered. Re-check now,
        // and keep a watchdog for anything else that swallows the event.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { dragEnded(); return }
        dragWatchdog = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self?.dragEnded()
        }
    }

    private func cursorInGlobalCG() -> CGPoint? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        else { return nil }
        let cocoa = NSEvent.mouseLocation
        return CGPoint(x: cocoa.x, y: primary.frame.height - cocoa.y)
    }

    private func dragMoved() {
        guard let session = dragSession, let point = cursorInGlobalCG() else { return }
        guard let display = displayContaining(point) else { return }
        let ws = model.activeWorkspace(on: display.id)

        var found: (WindowID, Direction, CGRect)?
        for (candidate, frame) in ws.lastSolvedFrames
        where candidate != session.id && !ws.isFloating(candidate) && frame.contains(point) {
            // Nearest edge decides the drop side.
            let dx = (point.x - frame.midX) / max(frame.width, 1)
            let dy = (point.y - frame.midY) / max(frame.height, 1)
            let edge: Direction = abs(dx) >= abs(dy)
                ? (dx < 0 ? .left : .right)
                : (dy < 0 ? .up : .down)
            var zone = frame
            switch edge {
            case .left: zone.size.width /= 2
            case .right: zone.origin.x += frame.width / 2; zone.size.width /= 2
            case .up: zone.size.height /= 2
            case .down: zone.origin.y += frame.height / 2; zone.size.height /= 2
            }
            found = (candidate, edge, zone)
            break
        }

        dragSession?.target = found.map { ($0.0, $0.1) }
        dropOverlay?.update(frame: found?.2)
    }

    private func dragEnded() {
        guard let session = dragSession else { return }
        dragWatchdog?.cancel()
        dragWatchdog = nil
        for monitor in session.monitors { NSEvent.removeMonitor(monitor) }
        dropOverlay?.update(frame: nil)
        dragSession = nil

        if let (target, edge) = session.target,
           let ws = model.workspace(containing: session.id),
           ws.contains(target),
           ws.retile(session.id, at: target, edge: edge) {
            windows[session.id]?.floating = false
            applyAll()
            focusWindow(session.id)
        }
    }

    // MARK: - Gap drag-resize (§4.3)

    func gapBoundaries() -> [GapResizeController.Boundary] {
        var out: [GapResizeController.Boundary] = []
        let slack = config.innerGap + 4
        for info in displays {
            let ws = model.activeWorkspace(on: info.id)
            let frames = ws.lastSolvedFrames.filter { !ws.isFloating($0.key) }
            let items = Array(frames)
            for i in items.indices {
                for j in items.indices where i != j {
                    let (a, fa) = items[i]
                    let (_, fb) = items[j]
                    // Vertical boundary: a directly left of b.
                    let gapX = fb.minX - fa.maxX
                    let yOverlap = min(fa.maxY, fb.maxY) - max(fa.minY, fb.minY)
                    if gapX >= -1, gapX <= slack, yOverlap >= 24 {
                        out.append(.init(
                            window: a, direction: .right,
                            rect: CGRect(
                                x: fa.maxX - max(0, (8 - gapX) / 2),
                                y: max(fa.minY, fb.minY),
                                width: max(8, gapX), height: yOverlap
                            )
                        ))
                    }
                    // Horizontal boundary: a directly above b (CG y-down).
                    let gapY = fb.minY - fa.maxY
                    let xOverlap = min(fa.maxX, fb.maxX) - max(fa.minX, fb.minX)
                    if gapY >= -1, gapY <= slack, xOverlap >= 24 {
                        out.append(.init(
                            window: a, direction: .down,
                            rect: CGRect(
                                x: max(fa.minX, fb.minX),
                                y: fa.maxY - max(0, (8 - gapY) / 2),
                                width: xOverlap, height: max(8, gapY)
                            )
                        ))
                    }
                }
            }
        }
        return out
    }

    func gapDrag(window id: WindowID, direction: Direction, deltaPixels: CGFloat) {
        guard let ws = model.workspace(containing: id) else { return }
        if ws.dragResize(id, direction: direction, deltaPixels: deltaPixels, minRatio: config.minRatio),
           let home = ws.homeDisplay {
            applyDisplay(home)
        }
    }

    private func scheduleReapply(_ display: DisplayID) {
        reapplyDebounce[display]?.cancel()
        reapplyDebounce[display] = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.applyDisplay(display)
            // Drift correction changes real geometry, so the snapshot has to
            // follow it; `applyDisplay` no longer persists on its own.
            self.persistSoon()
        }
    }

    // MARK: - Commands

    /// §6.3: latency instrumentation — `zephr` signposts in Instruments.
    private static let signposter = OSSignposter(subsystem: "dev.zephr", category: "perf")

    func perform(_ command: Command) {
        lastActivity = ContinuousClock.now
        guard !paused || command == .togglePause else { return }
        let interval = Self.signposter.beginInterval("command")
        defer { Self.signposter.endInterval("command", interval) }
        switch command {
        case .focus(let dir):
            guard let ws = model.focusedWorkspace else { return }
            if let f = ws.focusedWindow, let neighbor = ws.neighbor(of: f, direction: dir) {
                focusWindow(neighbor)
            } else if let next = displayNeighbor(direction: dir) {
                focusDisplay(next)
            }

        case .move(let dir):
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            switch ws.move(f, direction: dir) {
            case .moved:
                applyAll()
                focusWindow(f)
            case .hitEdge:
                if let next = displayNeighbor(direction: dir) {
                    let target = model.activeWorkspace(on: next.id)
                    model.moveWindow(f, toWorkspace: target.id)
                    applyAll()
                    focusWindow(f)
                }
            case .notTiled:
                // Nudge floats by a step.
                if let frame = ws.floating[f] {
                    var moved = frame
                    let step: CGFloat = 50
                    switch dir {
                    case .left: moved.origin.x -= step
                    case .right: moved.origin.x += step
                    case .up: moved.origin.y -= step
                    case .down: moved.origin.y += step
                    }
                    ws.setFloatingFrame(f, frame: moved)
                    applyAll()
                }
            }

        case .goToWorkspace(let n):
            let affected = model.activateWorkspace(n)
            for d in affected { applyDisplay(d) }
            if let target = model.focusedWorkspace?.focusedWindow ?? model.focusedWorkspace?.fallbackFocus() {
                focusWindow(target)
            } else {
                // Empty workspace (§4.4): take focus away from the app we
                // just stashed — otherwise keystrokes keep editing a now
                // invisible document. Zephr has no regular windows, so
                // activating ourselves parks the keyboard safely.
                NSRunningApplication.current.activate()
            }
            syncAppState()

        case .moveToWorkspace(let n):
            guard let f = model.focusedWindow else { return }
            model.moveWindow(f, toWorkspace: n)
            applyAll()
            focusModelFallback()

        case .toggleFloat:
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            let defaultFrame = defaultFloatFrame(on: ws.homeDisplay)
            if let floating = ws.toggleFloat(f, defaultFrame: defaultFrame) {
                windows[f]?.floating = floating
                applyAll()
                focusWindow(f)
            }

        case .toggleMonocle:
            guard let ws = model.focusedWorkspace else { return }
            ws.toggleMonocle()
            applyAll()

        case .splitPreselect(let orientation):
            model.focusedWorkspace?.setPreselect(orientation)

        case .cycleLayout:
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            ws.cycleLayout(f)
            applyAll()

        case .resize(let dir, let fine):
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            let step = fine ? config.resizeStepFine : config.resizeStep
            // Push the window's edge in `dir`; at a hard edge, pull the
            // opposite boundary instead so the key always does something.
            if !ws.resize(f, direction: dir, delta: step, minRatio: config.minRatio) {
                _ = ws.resize(f, direction: dir.opposite, delta: -step, minRatio: config.minRatio)
            }
            applyAll()

        case .shrink, .grow:
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            let delta: CGFloat = command == .grow ? config.resizeStep : -config.resizeStep
            _ = ws.resizeShare(f, delta: delta, minRatio: config.minRatio)
            applyAll()

        case .balance:
            guard let ws = model.focusedWorkspace, let f = ws.focusedWindow else { return }
            ws.balance(f)
            applyAll()

        case .rescueWindows:
            guard let current = model.focusedWorkspace?.id else { return }
            // Rescue means *everything* back (§4.4, invariant 1): unhide
            // every app with a managed window, not just the ones we think we
            // hid — after a crash `hiddenApps` starts empty while apps are
            // still hidden.
            for pid in Set(windows.values.map(\.pid)) {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }
            hiddenApps.removeAll()
            model.rescueAllWindows(into: current)
            applyAll()

        case .focusNextDisplay:
            guard displays.count > 1,
                  let current = model.focusedDisplay,
                  let idx = displays.firstIndex(where: { $0.id == current }) else { return }
            focusDisplay(displays[(idx + 1) % displays.count])

        case .closeWindow:
            guard let f = model.focusedWindow, let mw = windows[f],
                  let conn = connections[mw.pid] else { return }
            Task { await conn.closeWindow(f) }
            // Removal flows through the destroyed notification / audit.

        case .toggleWorkspaceFloatMode:
            guard let ws = model.focusedWorkspace else { return }
            ws.floatByDefault.toggle()

        case .togglePause:
            setPaused(!paused)
        }
    }

    // MARK: - Pause (§4.3 "never fights you": presentations, games, sharing)

    private(set) var paused = false
    var onPauseChange: ((Bool) -> Void)?

    /// Paused: every window restored on screen, apps unhidden, nothing
    /// enforced, hotkeys released. Resume re-applies the model.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        appState.paused = value
        onPauseChange?(value)
        if value {
            for pid in hiddenApps {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }
            hiddenApps.removeAll()
            var perApp: [pid_t: [(WindowID, CGRect)]] = [:]
            for mw in windows.values where !isVisible(mw.id) && !mw.minimized {
                perApp[mw.pid, default: []].append((mw.id, mw.lastVisibleFrame))
            }
            let now = ContinuousClock.now
            for (pid, batch) in perApp {
                guard let conn = connections[pid] else { continue }
                for (id, frame) in batch { pendingWrites[id] = (frame, now) }
                nextWriteGeneration += 1
                let generation = nextWriteGeneration
                // Record the results like every other write path. Dropping
                // them leaves `lastAppliedFrame` holding the stash frame the
                // window no longer occupies, so on resume the no-op filter
                // sees the stash target as already applied and skips it —
                // every inactive workspace's windows stay piled on top of
                // the active layout, and the audit can't correct it because
                // its drift check only looks at visible windows.
                //
                // Stamped so an apply still in flight when the user paused
                // cannot land afterwards and re-stash what we just released.
                Task {
                    self.noteWriteResults(await conn.applyFrames(batch, generation: generation))
                }
            }
            focusBorder?.update(frame: nil)
            gapResizer?.clear()
            dropOverlay?.update(frame: nil)
        } else {
            applyAll()
            focusModelFallback()
        }
    }

    // MARK: - Focus

    /// Settings "pick the focused window" rule helper.
    func focusedWindowInfo() -> (bundleID: String, title: String)? {
        guard let f = model.focusedWindow, let mw = windows[f], let bundleID = mw.bundleID else { return nil }
        return (bundleID, mw.title)
    }

    /// Palette entry point: focus any managed window, switching workspace
    /// (and display) as needed. Fullscreen windows are summoned by
    /// activating their app (their Space takes over).
    func focusManagedWindow(_ id: WindowID) {
        guard let ws = model.workspace(containing: id) else {
            if let mw = windows[id], mw.fullscreen, let conn = connections[mw.pid] {
                Task {
                    await conn.raise(id)
                    NSRunningApplication(processIdentifier: mw.pid)?
                        .activate()
                }
            }
            return
        }
        if !isVisible(id), let home = ws.homeDisplay {
            let affected = model.activateWorkspace(ws.id, on: home)
            for d in affected { applyDisplay(d) }
        }
        focusWindow(id)
    }

    struct PaletteWindow {
        let id: WindowID
        let title: String
        let app: String
        let workspace: Int?    // nil = native fullscreen, marked in the UI
        let icon: NSImage?
    }

    func paletteWindows() -> [PaletteWindow] {
        windows.values.compactMap { mw in
            guard !mw.minimized else { return nil }
            let ws = model.workspace(containing: mw.id)
            guard ws != nil || mw.fullscreen else { return nil }
            let running = NSRunningApplication(processIdentifier: mw.pid)
            return PaletteWindow(
                id: mw.id,
                title: mw.title,
                app: running?.localizedName ?? mw.bundleID ?? "?",
                workspace: ws?.id,
                icon: running?.icon
            )
        }
        .sorted { ($0.workspace ?? 99, $0.app) < ($1.workspace ?? 99, $1.app) }
    }

    private func noteFocused(_ id: WindowID) {
        guard windows[id] != nil else { return }
        model.noteFocused(id)
        reapplyForFocusDependentLayout(id)
        syncAppState()
    }

    private func focusWindow(_ id: WindowID) {
        guard let mw = windows[id], let conn = connections[mw.pid] else { return }
        model.noteFocused(id)
        reapplyForFocusDependentLayout(id)
        syncAppState()
        Task {
            _ = await conn.focus(id)
            // Verify against the real frontmost app, not an AX read-back:
            // activation completes asynchronously inside the target, so
            // `kAXFrontmost` still reads false here even when it worked.
            // Cooperative activation can also decline outright while another
            // app is mid-transition, which is what the retry is for — losing
            // a focus command silently is the worst failure this product
            // has, so it is worth one extra round trip to be sure.
            try? await Task.sleep(for: .milliseconds(80))
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != mw.pid
            else { return }
            NSRunningApplication(processIdentifier: mw.pid)?.activate()
            try? await Task.sleep(for: .milliseconds(150))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != mw.pid {
                Self.log.warning("focus did not take for window \(id.raw) (pid \(mw.pid))")
            }
        }
    }

    /// Accordion and monocle solve differently depending on focus: the
    /// accordion expands `lastFocusedIndex`, monocle maximizes the focused
    /// window. Focus changes must re-apply those layouts or the newly
    /// focused window keeps its collapsed sliver (§4.3); write coalescing
    /// makes the plain-tiles no-op case free (§6.3).
    private func reapplyForFocusDependentLayout(_ id: WindowID) {
        guard let ws = model.workspace(containing: id),
              let home = ws.homeDisplay else { return }
        var focusDependent = ws.monocle
        var node = ws.node(for: id)?.parent
        while !focusDependent, let n = node {
            if n.layout == .accordion { focusDependent = true }
            node = n.parent
        }
        if focusDependent { applyDisplay(home) }
    }

    private func focusModelFallback() {
        if let f = model.focusedWorkspace?.focusedWindow ?? model.focusedWorkspace?.fallbackFocus() {
            focusWindow(f)
        }
    }

    private func focusDisplay(_ display: DisplayInfo) {
        model.focusDisplay(display.id)
        let ws = model.activeWorkspace(on: display.id)
        if let target = ws.focusedWindow ?? ws.fallbackFocus() {
            focusWindow(target)
        }
        syncAppState()
    }

    private func displayNeighbor(direction: Direction) -> DisplayInfo? {
        guard let currentID = model.focusedDisplay,
              let current = displays.first(where: { $0.id == currentID }) else { return nil }
        let c = current.frame.center
        let candidates = displays.filter { info in
            guard info.id != currentID else { return false }
            let o = info.frame.center
            switch direction {
            case .left: return o.x < c.x
            case .right: return o.x > c.x
            case .up: return o.y < c.y
            case .down: return o.y > c.y
            }
        }
        return candidates.min { a, b in
            hypot(a.frame.center.x - c.x, a.frame.center.y - c.y)
                < hypot(b.frame.center.x - c.x, b.frame.center.y - c.y)
        }
    }

    // MARK: - Apply (model → screen)

    /// The AppKit screen the next command will land on.
    ///
    /// HUDs must follow the engine's focused display rather than
    /// `NSScreen.main`: Zephr is an agent app that never activates, so
    /// AppKit's "main" screen is wherever the frontmost *other* app happens
    /// to be keyed — on a multi-display setup that is regularly not the
    /// screen the user is driving (§4.4).
    var focusedScreen: NSScreen? {
        model.focusedDisplay.flatMap(DisplayService.screen(for:))
    }

    private var spaceDebounce: Task<Void, Never>?

    /// Monotonic stamp ordering frame batches; see `applyFrames`.
    private var nextWriteGeneration: UInt64 = 0

    /// Rolling cross-app drift tally for the Mission Control heuristic.
    private var driftWindowStart: ContinuousClock.Instant?
    private var driftWindowSeen = 0
    private var driftWindowEligible = 0

    /// Set between an `applyAll()` request and the coalesced solve.
    private var applyScheduled = false
    /// Whether the gap-resize boundaries need recomputing (layout changed).
    private var gapBoundariesStale = true

    /// Whether a window floats.
    ///
    /// The workspace is authoritative while the window is in the tree;
    /// `ManagedWindow.floating` is the remembered value for windows
    /// currently outside it — minimized, native-fullscreen, or belonging to
    /// a hidden app — and is what puts them back correctly.
    private func isFloating(_ id: WindowID) -> Bool {
        guard let mw = windows[id] else { return false }
        return model.workspace(containing: id)?.isFloating(id) ?? mw.floating
    }

    private func isVisible(_ id: WindowID) -> Bool {
        guard let ws = model.workspace(containing: id),
              let home = ws.homeDisplay else { return false }
        return model.activeWorkspaceByDisplay[home] == ws.id
    }

    /// Re-layout every display, coalesced.
    ///
    /// Callers fire this from inside loops: adoption hits it once per window
    /// at launch, and one audit tick can hit it once per window again. Each
    /// call used to solve *every* display and walk every app's frames, so 30
    /// windows coming up meant 30 full re-layouts of the whole desktop. The
    /// work is deferred to the end of the current main-actor turn and runs
    /// once no matter how many times it was requested (§6.3).
    func applyAll() {
        guard !applyScheduled else { return }
        applyScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.applyNow()
        }
    }

    private func applyNow() {
        for display in displays { applyDisplay(display.id) }
        // Both are whole-desktop concerns, so they belong here rather than
        // inside `applyDisplay` — running them per display repeated a
        // full-tree profile capture and a state write for every monitor.
        updateAppHiding()
        persistSoon()
        syncAppState()
    }

    private func applyDisplay(_ displayID: DisplayID) {
        guard !paused else { return }
        guard let info = displays.first(where: { $0.id == displayID }) else { return }
        let active = model.activeWorkspace(on: displayID)
        let solved = Solver.solve(workspace: active, in: info.visibleFrame, config: config)
        gapBoundariesStale = true

        var perApp: [pid_t: [(WindowID, CGRect)]] = [:]
        var raises: [pid_t: [WindowID]] = [:]

        for (id, placement) in solved.placements {
            guard windows[id] != nil else { continue }
            perApp[windows[id]!.pid, default: []].append((id, placement.frame))
            windows[id]?.lastVisibleFrame = placement.frame
        }
        for id in solved.raiseOrder {
            guard let mw = windows[id] else { continue }
            raises[mw.pid, default: []].append(id)
        }

        // Stash every other workspace homed on this display (§4.4).
        let allFrames = displays.map(\.frame)
        for ws in model.workspaces.values
        where ws.homeDisplay == displayID && ws.id != active.id {
            for id in ws.allWindows {
                guard let mw = windows[id], !mw.minimized else { continue }
                let stashed = StashPlanner.stashFrame(
                    for: mw.lastVisibleFrame,
                    on: info.frame,
                    allDisplays: allFrames
                )
                perApp[mw.pid, default: []].append((id, stashed))
            }
        }

        // Unhide before placing (§4.4): apps regaining a visible window.
        let visiblePids = Set(solved.placements.keys.compactMap { windows[$0]?.pid })
        for pid in visiblePids where hiddenApps.contains(pid) {
            NSRunningApplication(processIdentifier: pid)?.unhide()
            hiddenApps.remove(pid)
        }

        for (pid, batch) in perApp {
            guard let conn = connections[pid] else { continue }
            let work = batch.filter { id, frame in
                !(windows[id]?.lastAppliedFrame?.approximatelyEquals(frame) ?? false)
            }
            let raiseList = raises[pid] ?? []
            guard !work.isEmpty || !raiseList.isEmpty else { continue }
            // Stamp at issue so echoes arriving mid-write are suppressed (and
            // the drag heuristic can't fire on our own writes); the stamp is
            // refreshed on completion in `noteWriteResults` so the window
            // covers slow apps whose echo lands over a second after issue.
            let now = ContinuousClock.now
            for (id, frame) in work { pendingWrites[id] = (frame, now) }
            nextWriteGeneration += 1
            let generation = nextWriteGeneration
            Task {
                let result = await conn.applyFrames(work, generation: generation)
                // A newer apply for this pid already landed; this batch was
                // never written, so it must not be recorded as applied nor
                // read as evidence the app is unresponsive.
                guard !result.superseded else { return }
                for id in raiseList { await conn.raise(id) }
                self.noteWriteResults(result)
                // Short batch = aborted batch (§6.3): `applyFrames` stops
                // at the first messaging timeout, so anything past the
                // abort was never written. Retrying immediately would just
                // burn the busy app's queue — instead mark the pid
                // unresponsive so the first clean audit re-applies its
                // displays (§6.4 convergence). Without this, an aborted
                // stash batch leaves windows sitting on top of the wrong
                // workspace indefinitely on an idle desktop. Skip a pid
                // that detached mid-write: with no connection to audit,
                // the marker could never be cleared.
                if result.applied.count < work.count, self.connections[pid] === conn {
                    self.unresponsivePids.insert(pid)
                }
            }
        }

    }

    private func noteWriteResults(_ result: AppAXConnection.WriteResult) {
        let now = ContinuousClock.now
        for (id, actual) in result.applied {
            // The window may have been removed while the write was in
            // flight; don't resurrect its bookkeeping.
            guard windows[id] != nil else { continue }
            let target = pendingWrites[id]?.frame
            // Convergence for snapping apps (§6.3): Terminal-style grids
            // settle a few points off target and stay there. Read-back
            // within tolerance counts as applied — record the *target* so
            // the work filter skips the window next apply, and the settled
            // frame so the audit doesn't call it drift. (Tolerance matches
            // the veto threshold in `applyFrames`.)
            if let target, actual.approximatelyEquals(target, tolerance: 10) {
                windows[id]?.lastAppliedFrame = target
            } else {
                windows[id]?.lastAppliedFrame = actual
            }
            windows[id]?.lastSettledFrame = actual
            // Echo suppression runs from write *completion* — stamping only
            // at issue let a slow app's late stash echo through, which then
            // overwrote a float's model frame with off-screen coordinates.
            pendingWrites[id] = (target ?? actual, now)
        }
        // Frame vetoes (§6.4): apps that clamp their windows get floated
        // after two strikes instead of fighting forever — and the rule is
        // learned so next launch floats them immediately.
        for id in result.vetoed {
            // A veto only means something when we tried to place the window
            // *on screen*: stash targets are >99% off-screen by design
            // (`StashPlanner.sliver` is 1 pt), so an app that re-clamps an
            // off-screen origin "vetoes" every hide by hundreds of points —
            // striking on that would float the window out of the tree and
            // persist a permanent `float` rule from an operation that says
            // nothing about whether the app can be tiled. Do not simplify
            // this guard away.
            guard isVisible(id) else { continue }
            guard var mw = windows[id], !mw.floating else { continue }
            mw.vetoStrikes += 1
            windows[id] = mw
            if mw.vetoStrikes >= 2, let ws = model.workspace(containing: id), !ws.isFloating(id) {
                Self.log.info("window \(id.raw) vetoes frames — auto-floating")
                _ = ws.toggleFloat(id, defaultFrame: mw.lastVisibleFrame)
                windows[id]?.floating = true
                applyAll()
                if let bundleID = mw.bundleID {
                    learnFloatRule(pid: mw.pid, bundleID: bundleID)
                }
            }
        }
    }

    /// Persists "this app's windows resist tiling", but only once *every*
    /// managed window of the app has proven it (§6.4 "learn the rule").
    ///
    /// The rule deliberately carries no title. A veto says the app clamps
    /// the frames we write, which is a property of the app, not of the words
    /// in its title bar — and a regex anchored on whatever title happened to
    /// be showing (a browser's unread count, a terminal's progress spinner)
    /// can never match again. Such a rule reads as learned while doing
    /// nothing, which is worse than no rule at all. So a multi-window app
    /// where only one window fights keeps floating that window in-session
    /// and writes nothing to config.
    private func learnFloatRule(pid: pid_t, bundleID: String) {
        let siblings = windows.values.filter { $0.pid == pid && !$0.minimized && !$0.fullscreen }
        guard !siblings.isEmpty, siblings.allSatisfy({ $0.vetoStrikes >= 2 }) else { return }
        onRuleLearned?(bundleID)
    }

    /// Fired when the app layer should persist a learned float rule.
    var onRuleLearned: ((String) -> Void)?

    /// The Mission Control hybrid (§4.4): when every window of an app is a
    /// managed, stashed window, hide the app so nothing lingers in Mission
    /// Control. Hiding is per-app, so a pid with any window we do *not*
    /// manage (title-ignored utility windows) or with a native-fullscreen
    /// window is never hidden — and Zephr never hides itself (the tutorial's
    /// practice windows are managed windows of our own pid).
    private func updateAppHiding() {
        var byPid: [pid_t: (total: Int, visible: Int, exempt: Int)] = [:]
        for mw in windows.values where !mw.minimized {
            var entry = byPid[mw.pid] ?? (0, 0, 0)
            entry.total += 1
            if isVisible(mw.id) { entry.visible += 1 }
            if mw.fullscreen { entry.exempt += 1 }
            byPid[mw.pid] = entry
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selfPid = pid_t(ProcessInfo.processInfo.processIdentifier)
        for (pid, counts) in byPid {
            if counts.total > 0 && counts.visible == 0 && counts.exempt == 0 {
                guard pid != selfPid, pid != frontmost, !hiddenApps.contains(pid),
                      let app = NSRunningApplication(processIdentifier: pid), !app.isHidden
                else { continue }
                maybeHideApp(pid)
            } else if counts.visible > 0 && hiddenApps.contains(pid) {
                NSRunningApplication(processIdentifier: pid)?.unhide()
                hiddenApps.remove(pid)
            }
        }
    }

    /// Confirms with the app's actor that *every* live window of the pid is
    /// one we manage before hiding it (§4.4) — an unmanaged window must stay
    /// visible, and hiding the app would take it too.
    private func maybeHideApp(_ pid: pid_t) {
        guard let conn = connections[pid] else { return }
        // One probe per pid at a time. `updateAppHiding` runs on every
        // re-layout, and each probe is a full AX window listing plus an id
        // lookup per window — without this, a burst of applies stacks
        // several identical round trips on the app's queue (§6.3).
        guard hideProbesInFlight.insert(pid).inserted else { return }
        Task {
            defer { self.hideProbesInFlight.remove(pid) }
            let elements = await conn.listWindows()
            // No evidence (degraded app, empty listing) — don't hide blind.
            guard !elements.isEmpty else { return }
            for element in elements {
                guard let id = await conn.id(for: element), self.windows[id] != nil else { return }
            }
            // Re-check on the main actor: state may have moved during the awaits.
            guard !self.hiddenApps.contains(pid),
                  pid != NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid),
                  !app.isHidden, !app.isTerminated else { return }
            let managed = self.windows.values.filter { $0.pid == pid && !$0.minimized }
            guard !managed.isEmpty,
                  managed.allSatisfy({ !$0.fullscreen && !self.isVisible($0.id) }) else { return }
            app.hide()
            self.hiddenApps.insert(pid)
            // Record the hide now (§6.6): crash recovery unhides only
            // *recorded* apps, and the enclosing apply's persist already
            // ran before this task's awaits finished. A crash before the
            // next incidental persist would otherwise leave the app hidden
            // while its windows tile into the visible workspace — a hole
            // in the layout only `leader w` could fill.
            self.persistSoon()
        }
    }

    private func defaultFloatFrame(on displayID: DisplayID?) -> CGRect {
        let info = displays.first { $0.id == displayID } ?? displays.first
        guard let rect = info?.visibleFrame else { return CGRect(x: 100, y: 100, width: 800, height: 600) }
        return CGRect(
            x: rect.midX - rect.width * 0.3,
            y: rect.midY - rect.height * 0.3,
            width: rect.width * 0.6,
            height: rect.height * 0.6
        )
    }

    // MARK: - Displays

    private func displaysChanged() {
        let fresh = displayService.current()
        guard !fresh.isEmpty else { return }
        displays = fresh

        let fingerprint = ProfileEngine.fingerprint(currentSlots())
        guard profileCaptureEnabled else {
            // Startup hasn't settled yet (§4.5): swap the pending profile
            // for the new arrangement instead of applying mid-adoption —
            // the quiesce task consumes it once apps stop appearing.
            pendingRestore = profile(matching: fingerprint)
            model.syncDisplays(fresh.map(\.id))
            applyAll()
            onEvent?("display_changed", ["displays": "\(fresh.count)"])
            return
        }

        // Known arrangement → restore it exactly; unknown → migrate in
        // stable order and start recording the new profile (§4.5).
        if let profile = profile(matching: fingerprint) {
            applyProfile(profile)
            Self.log.info("display change: restored profile \(fingerprint)")
        } else {
            model.syncDisplays(fresh.map(\.id))
            applyAll()
            Self.log.info("display change: new arrangement \(fingerprint)")
        }
        onEvent?("display_changed", ["displays": "\(fresh.count)"])
    }

    // MARK: - Profiles & session restore (§4.5)

    private func currentSlots() -> [DisplaySlot] {
        displays.map { DisplaySlot(id: $0.id, frame: $0.frame, identity: Self.panelIdentity($0.id)) }
    }

    /// The physical panel behind a display, stable across reboots and hotplug
    /// (§4.5 "identifier"). `CGDirectDisplayID` churns, so it is deliberately
    /// excluded; vendor/model/serial do not. Two same-resolution monitors at
    /// two sites would otherwise share one profile — docking at the second
    /// site restores the first site's layout and then overwrites it.
    /// Profiles saved before panel identity joined the fingerprint are keyed by
    /// geometry alone. Fall back to that key once and re-key the profile, so
    /// upgrading preserves a user's saved layouts instead of silently
    /// resetting every one of them (§4.5).
    private func profile(matching fingerprint: String) -> ModelSnapshot? {
        if let profile = profiles[fingerprint] { return profile }
        let legacyKey = ProfileEngine.fingerprint(
            displays.map { DisplaySlot(id: $0.id, frame: $0.frame) }
        )
        guard legacyKey != fingerprint,
              var migrated = profiles.removeValue(forKey: legacyKey) else { return nil }
        migrated.fingerprint = fingerprint
        profiles[fingerprint] = migrated
        Self.log.info("migrated profile \(legacyKey) → \(fingerprint)")
        persistSoon()
        return migrated
    }

    private static func panelIdentity(_ id: DisplayID) -> String? {
        let display = CGDirectDisplayID(id.raw)
        let vendor = CGDisplayVendorNumber(display)
        let model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        // All-zero means the panel didn't report EDID; fall back to
        // geometry-only rather than collapsing every such display together.
        guard vendor | model | serial != 0 else { return nil }
        return "\(vendor)-\(model)-\(serial)\(CGDisplayIsBuiltin(display) != 0 ? "-b" : "")"
    }

    private func windowFingerprint(_ id: WindowID) -> WindowFingerprint? {
        guard let mw = windows[id], let bundleID = mw.bundleID else { return nil }
        return WindowFingerprint(bundleID: bundleID, title: mw.title)
    }

    /// Live windows eligible for profile matching: minimized and native
    /// fullscreen stay out — the tree must never claim them (§6.4), and a
    /// restore that tiles a fullscreen Safari gets vetoed into a bogus
    /// permanent float rule.
    private func liveFingerprints() -> [WindowID: WindowFingerprint] {
        var live: [WindowID: WindowFingerprint] = [:]
        for (id, mw) in windows where !mw.minimized && !mw.fullscreen {
            // `if let`, deliberately: assigning a nil Optional through a
            // Dictionary subscript *removes* the key, which silently dropped
            // windows without a bundle id from matching (invariant 1).
            if let fp = windowFingerprint(id) { live[id] = fp }
        }
        return live
    }

    private func applyProfile(_ profile: ModelSnapshot) {
        let unplaced = ProfileEngine.apply(
            profile,
            to: model,
            slots: currentSlots(),
            live: liveFingerprints()
        )
        // Everything `apply` didn't place — windows the profile doesn't
        // know, plus any previously managed window it couldn't match —
        // rejoins its display's workspace; dropping one loses it
        // (invariant 1). Minimized/fullscreen windows stay out of the tree
        // (§6.4); their restore paths reinsert them.
        for id in unplaced {
            guard let mw = windows[id], !mw.minimized, !mw.fullscreen else { continue }
            let display = displayContaining(mw.lastVisibleFrame.center)
            let wsID = display.map { model.activeWorkspace(on: $0.id).id }
            model.insertWindow(id, workspace: wsID, floating: mw.floating, frame: mw.lastVisibleFrame)
        }
        applyAll()
        focusModelFallback()
    }

    /// Which workspace the pending profile recorded for a window matching
    /// `fp` — exact (bundleID, title) first, then bundleID-only, mirroring
    /// `ProfileEngine.apply`'s heuristics (§4.5). Only a hint: the quiesce
    /// pass re-applies the full profile with exact trees afterwards.
    private static func profileWorkspace(for fp: WindowFingerprint, in snapshot: ModelSnapshot) -> Int? {
        func contains(_ node: NodeSnapshot, _ index: Int) -> Bool {
            node.window == index || node.children.contains { contains($0, index) }
        }
        guard let index = snapshot.windows.firstIndex(of: fp)
            ?? snapshot.windows.firstIndex(where: { $0.bundleID == fp.bundleID })
        else { return nil }
        return snapshot.workspaces.first { ws in
            ws.floats.contains { $0.window == index }
                || (ws.root.map { contains($0, index) } ?? false)
        }?.id
    }

    /// Settings → Profiles: stored arrangements with their window counts.
    func storedProfiles() -> [(fingerprint: String, windowCount: Int)] {
        profiles
            .map { ($0.key, $0.value.windows.count) }
            .sorted { $0.0 < $1.0 }
    }

    func deleteProfile(_ fingerprint: String) {
        profiles.removeValue(forKey: fingerprint)
        stateStore.save(windows: snapshotRecords(), profiles: profiles, hiddenApps: hiddenAppRecords(), clean: false)
    }

    /// Reassembles the last session's layout for the current arrangement —
    /// covers relaunches, crashes, and reboots alike. Consumes the pending
    /// profile (§4.5): after this, capture may resume.
    private func restoreSession() {
        defer { pendingRestore = nil }
        let fingerprint = ProfileEngine.fingerprint(currentSlots())
        guard let profile = profile(matching: fingerprint) else { return }
        applyProfile(profile)
        Self.log.info("session restored for \(fingerprint)")
    }

    private func displayContaining(_ point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) } ?? displays.first
    }

    // MARK: - Reconciliation audit (§6.4)

    /// Trust readings can flap right after a grant; require several
    /// consecutive misses before treating it as a real revocation.
    private var axFailureStrikes = 0

    private func audit() {
        // Accessibility can be revoked while we run (§6.4: never fail
        // silently) — release the keyboard and ask again.
        if appState.axTrusted && !PermissionGate.isTrusted() {
            axFailureStrikes += 1
            if axFailureStrikes >= 3 {
                Self.log.error("Accessibility permission revoked")
                axFailureStrikes = 0
                appState.axTrusted = false
                setPaused(true)
                AppDelegate.shared?.permissionGate.presentIfNeeded()
            }
            return
        }
        axFailureStrikes = 0

        // Let in-flight writes settle first.
        let now = ContinuousClock.now
        pendingWrites = pendingWrites.filter { now - $0.value.at < .seconds(1) }
        guard pendingWrites.isEmpty else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }

        for (pid, conn) in connections {
            // Missed termination notification (§6.4): a pid that no longer
            // maps to a running application is a dead connection — drop it
            // instead of auditing it forever.
            guard NSRunningApplication(processIdentifier: pid) != nil else {
                detachApp(pid: pid)
                continue
            }
            // One audit in flight per pid (§6.3): a slow-but-not-timing-out
            // app must not pile up queued audits faster than they drain.
            guard !auditsInFlight.contains(pid) else { continue }
            auditsInFlight.insert(pid)
            Task {
                let result = await conn.audit()
                // The pid may have detached — or detached and re-attached —
                // while the audit was in flight; force-quitting a hung app
                // is exactly that path. Discard a stale result wholesale:
                // it would re-insert the pid into `unresponsivePids` after
                // `detachApp` cleared it, and with no connection left to
                // audit, nothing could ever clear it again — silently
                // freezing profile capture (§4.5) for the session.
                guard self.connections[pid] === conn else { return }
                self.auditsInFlight.remove(pid)
                self.handleAudit(pid: pid, result: result)
            }
        }
    }

    private func handleAudit(pid: pid_t, result: AppAXConnection.AuditResult) {
        // §6.3 anti-stall contract: a momentarily busy app reports windows
        // as `unresponsive`, not dead. They keep their model membership and
        // cached geometry — purging them destroys workspace assignments and
        // strands stashed windows off-screen where no rescue can find them
        // (invariant 1) — and none of the reconciliation below may read the
        // *absence* of data about them as a state change.
        if result.unresponsive.isEmpty {
            if unresponsivePids.remove(pid) != nil {
                // Unresponsive → responsive edge (§6.4 convergence): while
                // the pid was busy, `applyFrames` may have aborted a batch
                // mid-way (anti-stall, §6.3), and nothing else re-drives
                // the unwritten frames — the drift check below cannot see
                // them (a window that missed its stash write isn't visible,
                // and a visible one still matches its old
                // `lastAppliedFrame`). Re-apply every display hosting one
                // of the pid's windows; the no-op filter in `applyDisplay`
                // re-issues only frames that never landed.
                var hosts: Set<DisplayID> = []
                for mw in windows.values where mw.pid == pid {
                    if let home = model.workspace(containing: mw.id)?.homeDisplay {
                        hosts.insert(home)
                    }
                }
                for display in hosts { scheduleReapply(display) }
            }
        } else {
            unresponsivePids.insert(pid)
        }

        for id in result.dead where !result.unresponsive.contains(id) {
            removeWindow(id)
        }
        for element in result.unknown {
            Task { await self.adopt(element: element, pid: pid) }
        }

        // Missed miniaturize/deminiaturize notifications (§6.4): drive the
        // same transitions as the handlers, or the window stays excluded
        // from the palette and every apply forever. A window whose
        // attribute did not answer is absent from the map and left alone —
        // guessing "not minimized" would hand it a tile it cannot occupy.
        for (id, mw) in windows where mw.pid == pid && !result.unresponsive.contains(id) {
            // No guard for the other withdrawal reasons is needed: AX
            // reports a ⌘H-hidden or off-Space window as un-minimized, and
            // `restore` simply lifts a reason that was never set, leaving
            // the real one in place.
            guard let observedMinimized = result.minimized[id] else { continue }
            if observedMinimized {
                withdraw(id, reason: .minimized)
            } else {
                restore(id, reason: .minimized)
            }
        }

        // Native fullscreen transitions (§6.4): a window entering fullscreen
        // leaves the tree (never fight the green button); leaving fullscreen
        // re-tiles it into the workspace it came from (§4.4).
        for (id, mw) in windows where mw.pid == pid && !mw.minimized && !result.unresponsive.contains(id) {
            guard let isFullscreen = result.fullscreen[id] else { continue }
            if isFullscreen && !mw.fullscreen {
                windows[id]?.suspendedWorkspace = model.workspace(containing: id)?.id
                windows[id]?.fullscreen = true
                model.removeWindow(id)
                applyAll()
            } else if !isFullscreen && mw.fullscreen {
                windows[id]?.fullscreen = false
                windows[id]?.suspendedWorkspace = nil
                model.insertWindow(id, workspace: mw.suspendedWorkspace, floating: mw.floating, frame: mw.lastVisibleFrame)
                applyAll()
            } else if isFullscreen, model.workspace(containing: id) != nil {
                // A fullscreen window must never sit in the tree — profile
                // restore can re-insert one it matched (§6.4). Drop it from
                // the model; it stays tracked for the palette.
                model.removeWindow(id)
                applyAll()
            }
        }

        // Drift check for visible tiled windows. If most windows moved at
        // once, suspect a Mission Control transition and stand down (§6.4).
        var drifted: Set<DisplayID> = []
        var driftCount = 0
        var eligible = 0
        for (id, actual) in result.frames {
            guard let mw = windows[id], !isFloating(id), !mw.minimized,
                  !result.unresponsive.contains(id),
                  isVisible(id),
                  let expected = mw.lastAppliedFrame
            else { continue }
            eligible += 1
            guard !actual.approximatelyEquals(expected, tolerance: 3),
                  // A snapping app parked where our last write settled is
                  // converged, not drifting (§6.3).
                  !(mw.lastSettledFrame?.approximatelyEquals(actual, tolerance: 3) ?? false)
            else { continue }
            driftCount += 1
            if let home = model.workspace(containing: id)?.homeDisplay {
                drifted.insert(home)
            }
        }
        guard driftCount > 0 else { return }

        // "Most windows moved" has to be judged across every app, not this
        // one. The audit runs per pid, so a single-window app always saw
        // 1 <= max(3, 0) and the suppression could never fire — Mission
        // Control would fight us window by window. Accumulate over a short
        // window so one transition is seen whole.
        let now = ContinuousClock.now
        if driftWindowStart.map({ now - $0 > .milliseconds(750) }) ?? true {
            driftWindowStart = now
            driftWindowSeen = 0
            driftWindowEligible = 0
        }
        driftWindowSeen += driftCount
        driftWindowEligible += eligible
        if driftWindowSeen <= max(3, driftWindowEligible / 2) {
            for display in drifted { scheduleReapply(display) }
        }
    }

    // MARK: - Persistence

    private func snapshotRecords() -> [StateStore.WindowRecord] {
        windows.values.compactMap { mw in
            // Minimized windows sit outside the model but still need a
            // record: crash recovery must know where a stashed-then-minimized
            // window belongs when it resurfaces (§6.6, invariant 1).
            guard !mw.fullscreen else { return nil }
            let ws = model.workspace(containing: mw.id)
            guard ws != nil || mw.minimized else { return nil }
            return StateStore.WindowRecord(
                bundleID: mw.bundleID,
                title: mw.title,
                frame: mw.lastVisibleFrame,
                workspace: ws?.id ?? mw.suspendedWorkspace ?? 1,
                floating: isFloating(mw.id)
            )
        }
    }

    /// The apps Zephr itself currently hides, recorded so crash recovery can
    /// unhide them (§6.6) — by pid within this boot, by bundle id after one.
    private func hiddenAppRecords() -> [StateStore.HiddenApp] {
        hiddenApps.map { StateStore.HiddenApp(pid: $0, bundleID: connections[$0]?.bundleID) }
    }

    private func persistSoon() {
        // Continuous profile recording (§4.5), gated only until the pending
        // launch profile is consumed. Capture reads the model and cached
        // bundle/title metadata, never live AX, so an unresponsive app is
        // no reason to skip it — skipping would strand session restore on a
        // stale profile for as long as one app stays wedged.
        if profileCaptureEnabled, !windows.isEmpty {
            let snapshot = ProfileEngine.capture(
                model: model,
                slots: currentSlots(),
                meta: { self.windowFingerprint($0) }
            )
            profiles[snapshot.fingerprint] = snapshot
        }
        stateStore.save(windows: snapshotRecords(), profiles: profiles, hiddenApps: hiddenAppRecords(), clean: false)
    }

    private func syncAppState() {
        let workspace = model.focusedWorkspace?.id ?? 1
        appState.currentWorkspace = workspace
        appState.managedWindowCount = windows.count
        // Per-display indicator (§4.4): "3·1" with the focused one leading.
        appState.displayWorkspaces = displays.compactMap { model.activeWorkspaceByDisplay[$0.id] }

        // Focus border tracks the focused visible window's target frame.
        if let f = model.focusedWindow, let mw = windows[f], isVisible(f), !mw.minimized {
            focusBorder?.update(frame: mw.lastVisibleFrame)
        } else {
            focusBorder?.update(frame: nil)
        }

        // Gap-resize strips follow the settled layout. Boundaries are an
        // O(n²) pass over every tiled frame and they only move when the
        // layout does, so a focus change — which calls through here on the
        // §6.3 50 ms budget — must not pay for one.
        if gapBoundariesStale, let gapResizer {
            gapBoundariesStale = false
            gapResizer.update(boundaries: gapBoundaries())
        }

        // Workspace-changed callbacks (§4.8): SketchyBar and friends.
        if workspace != lastAnnouncedWorkspace {
            lastAnnouncedWorkspace = workspace
            runWorkspaceCallbacks(workspace)
            onEvent?("workspace_changed", ["workspace": "\(workspace)"])
        }
        if let f = model.focusedWindow, f != lastAnnouncedFocus {
            lastAnnouncedFocus = f
            onEvent?("focus_changed", [
                "window": "\(f.raw)",
                "app": windows[f]?.bundleID ?? "",
                "title": windows[f]?.title ?? "",
            ])
        }
    }

    private var lastAnnouncedFocus: WindowID?

    // MARK: - Config (§4.6)

    /// Applies a (re)loaded config live: layout, rules, callbacks, border,
    /// workspace names and float-by-default flags.
    func applyConfig(_ parsed: ParsedConfig) {
        config = parsed.layout
        rules.userRules = parsed.userRules
        model.defaultContainerLayout = parsed.defaultLayout
        workspaceCallbacks = parsed.onWorkspaceChanged
        focusBorder?.enabled = parsed.focusBorder
        for (n, name) in parsed.workspaceNames {
            model.workspace(n).name = name
        }
        for ws in model.workspaces.values {
            ws.floatByDefault = parsed.floatByDefaultWorkspaces.contains(ws.id)
        }
        for n in parsed.floatByDefaultWorkspaces {
            model.workspace(n).floatByDefault = true
        }
        appState.workspaceNames = parsed.workspaceNames
        if started {
            applyAll()
        }
    }

    private func runWorkspaceCallbacks(_ workspace: Int) {
        for command in workspaceCallbacks {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["ZEPHR_WORKSPACE"] = String(workspace)
            process.environment = env
            do {
                try process.run()
            } catch {
                Self.log.warning("workspace callback failed: \(error.localizedDescription)")
            }
        }
    }
}
