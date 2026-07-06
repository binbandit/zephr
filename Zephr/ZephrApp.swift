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
            Text("⚠︎ Secure Input is active — hotkeys limited")
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

        ForEach(1...9, id: \.self) { n in
            Button {
                AppDelegate.shared?.engine.perform(.goToWorkspace(n))
            } label: {
                let name = appState.workspaceNames[n].map { " · \($0)" } ?? ""
                let check = n == appState.currentWorkspace ? "✓ " : ""
                Text("\(check)Workspace \(n)\(name)")
            }
            .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.control, .option])
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

        Text("\(appState.managedWindowCount) windows managed")

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
            guard let engine = self?.engine else { return }
            engine.gapResizer?.update(boundaries: engine.gapBoundaries())
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
            self?.hotkeys.configureLayer(
                oneShot: parsed.layerOneShot,
                timeout: TimeInterval(parsed.layerTimeout)
            )
            // §5: menu-bar app by default; `dock-icon = true` flips it on.
            NSApp.setActivationPolicy(parsed.showDockIcon ? .regular : .accessory)
            self?.appState.showMenuBarIcon = parsed.showMenuBarIcon
        }
        // §6.4: a frame-veto teaches us an app must float — persist the rule.
        engine.onRuleLearned = { [weak self] bundleID, title in
            guard let config = self?.configService else { return }
            let escaped = NSRegularExpression.escapedPattern(for: title)
            let already = config.current.userRules.contains {
                $0.bundleID == bundleID && $0.action == .float
            }
            if !already {
                config.addRule(app: bundleID, title: title.isEmpty ? nil : "^\(escaped)$", action: "float")
            }
        }
        configService.onError = { [weak self] message in
            self?.appState.configError = message
        }
        configService.start()

        appState.launchAtLogin = SMAppService.mainApp.status == .enabled

        // §6.6: restore windows before dying on an uncaught ObjC exception.
        NSSetUncaughtExceptionHandler { _ in
            DispatchQueue.main.async {
                AppDelegate.shared?.engine.shutdownRestore()
            }
        }

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
        engine.start()
        hotkeys.start()
        let server = IPCServer(engine: engine)
        server.start()
        ipc = server
        engine.onEvent = { [weak server] event, payload in
            server?.broadcast(event, payload)
        }
        engine.onPauseChange = { [weak self] paused in
            self?.hotkeys.suspended = paused
        }
        // Two managers fighting over every window is the worst first-run
        // experience possible — check for rivals up front, not just in Doctor.
        Task.detached {
            let rivals = DoctorController.runningRivalNames()
            if !rivals.isEmpty {
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
        Task {
            try? await Task.sleep(for: .seconds(3))
            for old in others where !old.isTerminated {
                old.forceTerminate()
            }
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
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
