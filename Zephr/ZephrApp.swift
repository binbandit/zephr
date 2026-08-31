import AppKit
import ServiceManagement
import SwiftUI
import ZephrCore

@main
struct ZephrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: Bindable(delegate.appState).showMenuBarIcon) {
            MenuContent(appState: delegate.appState)
        } label: {
            // Quiet indicator (§5): a glyph and the current workspace number;
            // a diamond while the leader layer is open — no invisible modes.
            // §4.4: current workspace per display (e.g. "3·1"); ◆ while the
            // leader layer is open; ⏸ while paused.
            let suffix: String = if delegate.appState.paused {
                "⏸"
            } else if delegate.appState.layerState != .inactive {
                "◆"
            } else if delegate.appState.displayWorkspaces.count > 1 {
                delegate.appState.displayWorkspaces.map(String.init).joined(separator: "·")
            } else {
                "\(delegate.appState.currentWorkspace)"
            }
            Image(systemName: "rectangle.3.group")
            Text(suffix)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

private struct MenuContent: View {
    @Bindable var appState: AppState

    var body: some View {
        if !appState.axTrusted {
            Button("Grant Accessibility Access…") {
                AppDelegate.shared?.permissionGate.presentIfNeeded()
            }
            Divider()
        }
        if appState.secureInputActive {
            Text("⚠︎ Secure Input is active - hotkeys limited")
            Divider()
        }
        if let error = appState.configError {
            Button("⚠︎ \(error)") {
                AppDelegate.shared?.configService.openInEditor()
            }
            Divider()
        }

        if appState.paused {
            Button("▶ Resume Zephr") {
                AppDelegate.shared?.engine.perform(.togglePause)
            }
            Divider()
        }

        // With one display a flat list is right. With more, it is actively
        // misleading: "Workspace 3" gives no clue which screen it will
        // affect, and the answer depending on where that workspace happens
        // to live reads as the menu changing every display at once. Each
        // screen gets its own submenu, and picking there says which.
        if appState.displayRows.count > 1 {
            ForEach(Array(appState.displayRows.enumerated()), id: \.offset) { index, row in
                Menu("Display \(index + 1)\(row.focused ? " (focused)" : "") · Workspace \(row.workspace)") {
                    ForEach(1...9, id: \.self) { n in
                        Button {
                            AppDelegate.shared?.engine.goToWorkspace(n, on: row.id)
                        } label: {
                            let name = appState.workspaceNames[n].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                            let check = n == row.workspace ? "✓ " : ""
                            Text("\(check)Workspace \(n)\(name)")
                        }
                    }
                }
            }
        } else {
            ForEach(1...9, id: \.self) { n in
                Button {
                    AppDelegate.shared?.engine.perform(.goToWorkspace(n))
                } label: {
                    let name = appState.workspaceNames[n].flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                    let check = n == appState.currentWorkspace ? "✓ " : ""
                    Text("\(check)Workspace \(n)\(name)")
                }
                // §4.2: the shortcut hint tracks the active key preset —
                // under vim (leader-only) there is no chord to advertise.
                .keyboardShortcut(ChordHints.menuModifiers.map {
                    KeyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: $0)
                })
            }
        }

        Divider()

        Button("Rescue All Windows Here") {
            AppDelegate.shared?.engine.perform(.rescueWindows)
        }
        Button("Balance Sizes") {
            AppDelegate.shared?.engine.perform(.balance)
        }
        if !appState.paused {
            Button("Pause Zephr (release windows & keys)") {
                AppDelegate.shared?.engine.perform(.togglePause)
            }
            if appState.displayWorkspaces.count > 1 {
                Button("Pause / Resume This Display Only") {
                    AppDelegate.shared?.engine.perform(.togglePauseDisplay)
                }
            }
        }

        Divider()

        Button("Open Config File") {
            AppDelegate.shared?.configService.openInEditor()
        }
        Button("Replay Tutorial") {
            AppDelegate.shared?.onboarding.present(startAt: .tutorial)
        }
        Button("Run Doctor…") {
            AppDelegate.shared?.doctor.present()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button(appState.launchAtLogin ? "✓ Launch at Login" : "Launch at Login") {
            AppDelegate.shared?.toggleLaunchAtLogin()
        }

        Divider()

        Text("\(appState.managedWindowCount) \(appState.managedWindowCount == 1 ? "window" : "windows") managed")

        Divider()

        Button("Quit Zephr") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    nonisolated(unsafe) static var shared: AppDelegate?

    let appState = AppState()
    let permissionGate = PermissionGate()
    let configService = ConfigService()
    let onboarding = OnboardingController()
    private(set) var engine: TilingEngine!
    private(set) var hotkeys: HotkeyService!
    private var strip: CommandStripController!
    private var palette: PaletteController!
    private var ipc: IPCServer?
    let doctor = DoctorController()
    private var sigterm: DispatchSourceSignal?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        takeOverFromOtherInstances()

        let hub = ObserverHub()
        let displayService = DisplayService()
        let stateStore = StateStore()
        engine = TilingEngine(
            hub: hub,
            displayService: displayService,
            stateStore: stateStore,
            appState: appState
        )
        engine.focusBorder = FocusBorderController()
        engine.dropOverlay = DropZoneOverlay()
        let gapResizer = GapResizeController()
        gapResizer.onDrag = { [weak self] id, direction, delta in
            self?.engine.gapDrag(window: id, direction: direction, deltaPixels: delta)
        }
        gapResizer.onDragEnded = { [weak self] in
            // Next-turn hop: this fires from a strip view's own mouseUp —
            // rebuilding immediately would deallocate the window whose view
            // is still mid-dispatch.
            _ = Task { @MainActor in
                guard let engine = self?.engine else { return }
                engine.gapResizer?.update(boundaries: engine.gapBoundaries())
            }
        }
        engine.gapResizer = gapResizer
        hotkeys = HotkeyService()
        strip = CommandStripController()

        hotkeys.onCommand = { [weak self] command in
            self?.engine.perform(command)
        }
        hotkeys.onLayerChange = { [weak self] state in
            self?.appState.layerState = state
            self?.strip.update(state: state)
        }
        hotkeys.onToggleHelp = { [weak self] in
            self?.strip.toggleHelp()
        }
        hotkeys.onHint = { [weak self] text in
            self?.strip.showHint(text)
        }
        hotkeys.onSecureInputChange = { [weak self] active in
            self?.appState.secureInputActive = active
        }
        palette = PaletteController(engine: engine)
        hotkeys.onTogglePalette = { [weak self] in
            self?.palette.toggle()
        }

        // Config exists out of the box (§4.6): defaults written on first run,
        // hot-reloaded on save, applied live to layout, rules, and the leader.
        configService.onApply = { [weak self] parsed in
            self?.engine.applyConfig(parsed)
            self?.hotkeys.setLeader(parsed.leader)
            self?.hotkeys.setPreset(parsed.keyPreset)
            self?.hotkeys.setBindings(parsed.bindings)
            self?.hotkeys.configureLayer(
                oneShot: parsed.layerOneShot,
                timeout: TimeInterval(parsed.layerTimeout)
            )
            // §5: menu-bar app by default; `dock-icon = true` flips it on.
            NSApp.setActivationPolicy(parsed.showDockIcon ? .regular : .accessory)
            self?.appState.showMenuBarIcon = parsed.showMenuBarIcon
        }
        // §6.4: a frame-veto teaches us an app must float — persist the rule.
        engine.onRuleLearned = { [weak self] bundleID in
            guard let config = self?.configService else { return }
            let already = config.current.userRules.contains {
                $0.bundleID == bundleID && $0.action == .float
            }
            if !already {
                config.addRule(app: bundleID, title: nil, action: "float")
            }
        }
        configService.onError = { [weak self] message in
            self?.appState.configError = message
        }
        configService.start()

        appState.launchAtLogin = SMAppService.mainApp.status == .enabled

        // §6.6: restore windows before dying on an uncaught ObjC exception.
        // Synchronously — the default handler terminates the process before
        // the run loop could ever drain an async'd block ("never lose a
        // window"). Off the main thread, hop over with a bounded wait so a
        // wedged main thread can't hang the crash path either (§6.3).
        NSSetUncaughtExceptionHandler { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    AppDelegate.shared?.engine?.shutdownRestore()
                }
            } else {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppDelegate.shared?.engine?.shutdownRestore()
                    }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + .seconds(2))
            }
        }

        // A write to a closed socket must never kill us: the default SIGPIPE
        // disposition terminates the process outright, skipping
        // `applicationWillTerminate` and leaving every stashed window parked
        // off-screen (invariant 1). Set here rather than in `IPCServer`
        // because this runs before the Accessibility grant, and covers any
        // other pipe we ever write to.
        signal(SIGPIPE, SIG_IGN)

        // Restore every window on SIGTERM too, not just clean quits (§6.6).
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppDelegate.shared?.engine.shutdownRestore()
            }
            exit(0)
        }
        source.resume()
        sigterm = source

        // Tutorial steps check themselves off from real usage (§4.1).
        let baseCommand = hotkeys.onCommand
        hotkeys.onCommand = { [weak self] command in
            self?.onboarding.noteCommand(command)
            baseCommand?(command)
        }
        let baseLayer = hotkeys.onLayerChange
        hotkeys.onLayerChange = { [weak self] state in
            if state == .layer { self?.onboarding.noteLayerOpened() }
            baseLayer?(state)
        }
        let basePalette = hotkeys.onTogglePalette
        hotkeys.onTogglePalette = { [weak self] in
            self?.onboarding.notePaletteOpened()
            basePalette?()
        }

        permissionGate.onGranted = { [weak self] in
            self?.startManaging()
        }
        onboarding.onPermissionGranted = { [weak self] in
            self?.startManaging()
        }
        onboarding.onLeaderChosen = { [weak self] leader in
            self?.configService.setLeader(leader)
        }

        if OnboardingController.hasOnboarded {
            permissionGate.presentIfNeeded()
        } else {
            if PermissionGate.isTrusted() { startManaging() }
            onboarding.present()
        }
    }

    private func startManaging() {
        guard PermissionGate.isTrusted(), !appState.axTrusted else { return }
        appState.axTrusted = true
        permissionGate.dismissWindow()
        engine.start()
        hotkeys.start()
        // Idempotent: a re-grant after AX revocation re-enters here — never
        // stack a second server on the same socket (leaked fd, live sources).
        if ipc == nil {
            let server = IPCServer(engine: engine)
            server.start()
            ipc = server
            engine.onEvent = { [weak server] event, payload in
                server?.broadcast(event, payload)
            }
        }
        engine.onPauseChange = { [weak self] paused in
            self?.hotkeys.suspended = paused
        }
        // §6.6: the audit pauses on AX revocation — a re-grant must resume,
        // or every command bails out with no menu-free way back.
        engine.setPaused(false)
        // Two managers fighting over every window is the worst first-run
        // experience possible — check for rivals up front, not just in
        // Doctor. Snapping utilities (Rectangle & co.) only act on their own
        // shortcuts: they coexist, so they never warrant a Doctor window in
        // the user's face at launch.
        Task.detached {
            let rivals = DoctorController.runningRivals()
            if !rivals.fighting.isEmpty {
                await MainActor.run { AppDelegate.shared?.doctor.present() }
            }
        }
        // Stage Manager fights tiling (§6.4): say so plainly, with the fix.
        if DoctorController.stageManagerEnabled() {
            doctor.present()
        }
    }

    /// Only one Zephr may manage windows at a time. The newest launch wins:
    /// older instances get a polite terminate (running their restore path),
    /// then a force-kill if they don't comply within 3 seconds.
    private func takeOverFromOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPid }
        guard !others.isEmpty else { return }
        for old in others {
            old.terminate() // SIGTERM path → old instance restores its windows
        }
        // Give the old instance room to finish `shutdownRestore` before
        // force-killing it: that pass writes two AX calls per window, and a
        // force-kill mid-restore strands the remainder at stash coordinates
        // with no manager left to rescue them (invariant 1). Poll instead of
        // sleeping a fixed interval, so the common case stays fast and a slow
        // app-heavy restore still gets up to 15s.
        Task {
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline,
                  others.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            for old in others where !old.isTerminated {
                old.forceTerminate()
            }
        }
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    /// Idempotent, absolute setter — UI toggles pass the value they show, so
    /// a control can never invert the state it renders.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("launch-at-login toggle failed: \(error.localizedDescription)")
        }
        appState.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipc?.stop()
        engine.shutdownRestore()
    }
}
