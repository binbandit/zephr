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
        /// Native fullscreen: unmanaged but palette-listed (§6.4).
        var fullscreen: Bool = false
        var lastAppliedFrame: CGRect?
        var lastVisibleFrame: CGRect
        var vetoStrikes: Int = 0
    }

    private(set) var windows: [WindowID: ManagedWindow] = [:]
    private(set) var connections: [pid_t: AppAXConnection] = [:]
    /// Apps *we* hid for the stash — never touch apps the user hid (⌘H).
    private var hiddenApps: Set<pid_t> = []
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

        displays = displayService.current()
        model.syncDisplays(displays.map(\.id))
        displayService.onChange = { [weak self] in self?.displaysChanged() }

        hub.onEvent = { [weak self] event in self?.handle(event) }

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
            }
        }

        // Session restore (§4.5): load saved profiles, then — after the
        // adoption sweep settles — reassemble the layout for the current
        // display arrangement. Capture is gated until then so a half-adopted
        // startup can't overwrite a good profile.
        profiles = stateStore.load()?.profiles ?? [:]
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.restoreSession()
            self.profileCaptureEnabled = true
            self.persistSoon()
        }
    }

    /// Orderly shutdown: every window back on screen, apps unhidden,
    /// snapshot marked clean. Synchronous AX on purpose — we're exiting.
    func shutdownRestore() {
        for pid in hiddenApps {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        hiddenApps.removeAll()
        for mw in windows.values where !isVisible(mw.id) {
            mw.element.set(kAXPositionAttribute, point: mw.lastVisibleFrame.origin)
            mw.element.set(kAXSizeAttribute, size: mw.lastVisibleFrame.size)
        }
        stateStore.saveNow(windows: snapshotRecords(), profiles: profiles, clean: true)
    }

    // MARK: - App attach/detach

    private func attachApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
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
        }
    }

    private func detachApp(pid: pid_t) {
        guard connections.removeValue(forKey: pid) != nil else { return }
        hub.unwatchApp(pid: pid)
        hiddenApps.remove(pid)
        let ids = windows.values.filter { $0.pid == pid }.map(\.id)
        for id in ids {
            windows.removeValue(forKey: id)
            model.removeWindow(id)
        }
        if !ids.isEmpty { applyAll() }
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
            windows[id] = ManagedWindow(
                id: id, pid: pid, bundleID: conn.bundleID, element: element,
                title: snap.title, floating: false, fullscreen: true,
                lastVisibleFrame: snap.frame
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
        if workspaceID == nil {
            workspaceID = displayContaining(snap.frame.center).map {
                model.activeWorkspace(on: $0.id).id
            }
        }

        windows[id] = ManagedWindow(
            id: id, pid: pid, bundleID: conn.bundleID, element: element,
            title: snap.title, floating: floats, minimized: snap.minimized,
            fullscreen: false, lastVisibleFrame: snap.frame
        )
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
            guard windows[id] != nil else { return }
            windows[id]?.minimized = true
            model.removeWindow(id)
            applyAll()
            focusModelFallback()

        case .windowDeminiaturized(let id):
            guard let mw = windows[id], mw.minimized else { return }
            windows[id]?.minimized = false
            model.insertWindow(id, floating: mw.floating, frame: mw.lastVisibleFrame)
            applyAll()
        }
    }

    private func removeWindow(_ id: WindowID) {
        guard let mw = windows.removeValue(forKey: id) else { return }
        let wasFocused = model.focusedWindow == id
        model.removeWindow(id)
        pendingWrites.removeValue(forKey: id)
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

        guard isVisible(id) else { return }

        if NSEvent.pressedMouseButtons & 1 != 0 {
            // Title-bar drag on a tiled window: float it for the drag and
            // offer drop targets to re-tile (§4.3).
            guard let conn = connections[mw.pid] else { return }
            Task {
                guard let snap = await conn.snapshot(of: id) else { return }
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

    private func beginDragSession(_ id: WindowID) {
        guard dragSession == nil else { return }
        // The mouse may already be up if the drag was a flick; stay floating.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        var monitors: [Any] = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { _ in
            MainActor.assumeIsolated { TilingEngine.shared?.dragMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { _ in
            MainActor.assumeIsolated { TilingEngine.shared?.dragEnded() }
        }) { monitors.append(m) }
        dragSession = (id, monitors, nil)
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
            for pid in hiddenApps {
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
            for (pid, batch) in perApp {
                guard let conn = connections[pid] else { continue }
                Task { _ = await conn.applyFrames(batch) }
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
                        .activate(options: [.activateIgnoringOtherApps])
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
        syncAppState()
    }

    private func focusWindow(_ id: WindowID) {
        guard let mw = windows[id], let conn = connections[mw.pid] else { return }
        model.noteFocused(id)
        syncAppState()
        Task {
            await conn.raise(id)
            NSRunningApplication(processIdentifier: mw.pid)?
                .activate(options: [.activateIgnoringOtherApps])
        }
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

    private func isVisible(_ id: WindowID) -> Bool {
        guard let ws = model.workspace(containing: id),
              let home = ws.homeDisplay else { return false }
        return model.activeWorkspaceByDisplay[home] == ws.id
    }

    func applyAll() {
        for display in displays { applyDisplay(display.id) }
        syncAppState()
    }

    private func applyDisplay(_ displayID: DisplayID) {
        guard !paused else { return }
        guard let info = displays.first(where: { $0.id == displayID }) else { return }
        let active = model.activeWorkspace(on: displayID)
        let solved = Solver.solve(workspace: active, in: info.visibleFrame, config: config)

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
            let now = ContinuousClock.now
            for (id, frame) in work { pendingWrites[id] = (frame, now) }
            Task {
                let result = await conn.applyFrames(work)
                for id in raiseList { await conn.raise(id) }
                self.noteWriteResults(result)
            }
        }

        updateAppHiding()
        persistSoon()
    }

    private func noteWriteResults(_ result: AppAXConnection.WriteResult) {
        for (id, frame) in result.applied {
            windows[id]?.lastAppliedFrame = frame
        }
        // Frame vetoes (§6.4): apps that clamp their windows get floated
        // after two strikes instead of fighting forever — and the rule is
        // learned so next launch floats them immediately.
        for id in result.vetoed {
            guard var mw = windows[id], !mw.floating else { continue }
            mw.vetoStrikes += 1
            windows[id] = mw
            if mw.vetoStrikes >= 2, let ws = model.workspace(containing: id), !ws.isFloating(id) {
                Self.log.info("window \(id.raw) vetoes frames — auto-floating")
                _ = ws.toggleFloat(id, defaultFrame: mw.lastVisibleFrame)
                windows[id]?.floating = true
                applyAll()
                if let bundleID = mw.bundleID {
                    onRuleLearned?(bundleID, mw.title)
                }
            }
        }
    }

    /// Fired when a veto teaches us an app needs to float (§6.4 "learn the
    /// rule") — the app layer persists it to config.
    var onRuleLearned: ((String, String) -> Void)?

    /// The Mission Control hybrid (§4.4): when every managed window of an app
    /// is stashed, hide the app so nothing lingers in Mission Control.
    private func updateAppHiding() {
        var byPid: [pid_t: (total: Int, visible: Int)] = [:]
        for mw in windows.values where !mw.minimized {
            var entry = byPid[mw.pid] ?? (0, 0)
            entry.total += 1
            if isVisible(mw.id) { entry.visible += 1 }
            byPid[mw.pid] = entry
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (pid, counts) in byPid {
            if counts.total > 0 && counts.visible == 0 {
                if !hiddenApps.contains(pid), pid != frontmost,
                   let app = NSRunningApplication(processIdentifier: pid), !app.isHidden {
                    app.hide()
                    hiddenApps.insert(pid)
                }
            } else if counts.visible > 0 && hiddenApps.contains(pid) {
                NSRunningApplication(processIdentifier: pid)?.unhide()
                hiddenApps.remove(pid)
            }
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

        // Known arrangement → restore it exactly; unknown → migrate in
        // stable order and start recording the new profile (§4.5).
        let fingerprint = ProfileEngine.fingerprint(currentSlots())
        if let profile = profiles[fingerprint] {
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
        displays.map { DisplaySlot(id: $0.id, frame: $0.frame) }
    }

    private func windowFingerprint(_ id: WindowID) -> WindowFingerprint? {
        guard let mw = windows[id], let bundleID = mw.bundleID else { return nil }
        return WindowFingerprint(bundleID: bundleID, title: mw.title)
    }

    private func liveFingerprints() -> [WindowID: WindowFingerprint] {
        var live: [WindowID: WindowFingerprint] = [:]
        for id in windows.keys where !(windows[id]?.minimized ?? true) {
            live[id] = windowFingerprint(id)
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
        // Windows the profile doesn't know join their display's workspace.
        for id in unplaced {
            guard let mw = windows[id] else { continue }
            let display = displayContaining(mw.lastVisibleFrame.center)
            let wsID = display.map { model.activeWorkspace(on: $0.id).id }
            model.insertWindow(id, workspace: wsID, floating: mw.floating, frame: mw.lastVisibleFrame)
        }
        applyAll()
        focusModelFallback()
    }

    /// Settings → Profiles: stored arrangements with their window counts.
    func storedProfiles() -> [(fingerprint: String, windowCount: Int)] {
        profiles
            .map { ($0.key, $0.value.windows.count) }
            .sorted { $0.0 < $1.0 }
    }

    func deleteProfile(_ fingerprint: String) {
        profiles.removeValue(forKey: fingerprint)
        stateStore.save(windows: snapshotRecords(), profiles: profiles, clean: false)
    }

    /// Reassembles the last session's layout for the current arrangement —
    /// covers relaunches, crashes, and reboots alike.
    private func restoreSession() {
        let fingerprint = ProfileEngine.fingerprint(currentSlots())
        guard let profile = profiles[fingerprint] else { return }
        applyProfile(profile)
        Self.log.info("session restored for \(fingerprint)")
    }

    private func displayContaining(_ point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) } ?? displays.first
    }

    // MARK: - Reconciliation audit (§6.4)

    private func audit() {
        // Accessibility can be revoked while we run (§6.4: never fail
        // silently) — release the keyboard and ask again.
        if appState.axTrusted && !PermissionGate.isTrusted() {
            Self.log.error("Accessibility permission revoked")
            appState.axTrusted = false
            setPaused(true)
            AppDelegate.shared?.permissionGate.presentIfNeeded()
            return
        }

        // Let in-flight writes settle first.
        let now = ContinuousClock.now
        pendingWrites = pendingWrites.filter { now - $0.value.at < .seconds(1) }
        guard pendingWrites.isEmpty else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }

        for (pid, conn) in connections {
            Task {
                let result = await conn.audit()
                self.handleAudit(pid: pid, result: result)
            }
        }
    }

    private func handleAudit(pid: pid_t, result: AppAXConnection.AuditResult) {
        for id in result.dead {
            removeWindow(id)
        }
        for element in result.unknown {
            Task { await self.adopt(element: element, pid: pid) }
        }

        // Native fullscreen transitions (§6.4): a window entering fullscreen
        // leaves the tree (never fight the green button); leaving fullscreen
        // re-tiles it.
        for (id, mw) in windows where mw.pid == pid && !mw.minimized {
            let isFullscreen = result.fullscreen.contains(id)
            if isFullscreen && !mw.fullscreen {
                windows[id]?.fullscreen = true
                model.removeWindow(id)
                applyAll()
            } else if !isFullscreen && mw.fullscreen {
                windows[id]?.fullscreen = false
                model.insertWindow(id, floating: mw.floating, frame: mw.lastVisibleFrame)
                applyAll()
            }
        }

        // Drift check for visible tiled windows. If most windows moved at
        // once, suspect a Mission Control transition and stand down (§6.4).
        var drifted: Set<DisplayID> = []
        var driftCount = 0
        for (id, actual) in result.frames {
            guard let mw = windows[id], !mw.floating, !mw.minimized,
                  isVisible(id),
                  let expected = mw.lastAppliedFrame,
                  !actual.approximatelyEquals(expected, tolerance: 3) else { continue }
            driftCount += 1
            if let home = model.workspace(containing: id)?.homeDisplay {
                drifted.insert(home)
            }
        }
        if driftCount > 0 && driftCount <= max(3, result.frames.count / 2) {
            for display in drifted { scheduleReapply(display) }
        }
    }

    // MARK: - Persistence

    private func snapshotRecords() -> [StateStore.WindowRecord] {
        windows.values.compactMap { mw in
            guard let ws = model.workspace(containing: mw.id) else { return nil }
            return StateStore.WindowRecord(
                bundleID: mw.bundleID,
                title: mw.title,
                frame: mw.lastVisibleFrame,
                workspace: ws.id,
                floating: ws.isFloating(mw.id)
            )
        }
    }

    private func persistSoon() {
        // Continuous profile recording (§4.5), gated until session restore
        // has run so a half-adopted startup can't clobber a good profile.
        if profileCaptureEnabled, !windows.isEmpty {
            let snapshot = ProfileEngine.capture(
                model: model,
                slots: currentSlots(),
                meta: { self.windowFingerprint($0) }
            )
            profiles[snapshot.fingerprint] = snapshot
        }
        stateStore.save(windows: snapshotRecords(), profiles: profiles, clean: false)
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

        // Gap-resize strips follow the settled layout.
        gapResizer?.update(boundaries: gapBoundaries())

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
