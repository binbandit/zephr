import AppKit
import ApplicationServices
import SwiftUI
import ZephrCore

/// First-run flow (§4.1): welcome → Accessibility (auto-detected) → leader
/// selection with a conflict scan → an interactive tutorial that checks
/// itself off as the user performs the real actions. Replayable from the
/// menu bar.
@MainActor
final class OnboardingController {

    enum Page: Int {
        case welcome, permission, leader, tutorial, done
    }

    enum TutorialStep: Int, CaseIterable, Identifiable {
        case openLayer, focusWindow, moveWindow, switchWorkspace, sendToWorkspace, toggleFloat, openPalette
        var id: Int { rawValue }

        var label: String {
            switch self {
            case .openLayer: "Press the leader key — the command strip appears"
            case .focusWindow: "Focus another window: leader, then h or l"
            case .moveWindow: "Move a window: ⇧L (or any ⇧-direction)"
            case .switchWorkspace: "Jump to workspace 2: leader, then 2"
            case .sendToWorkspace: "Send a window along: ⇧2"
            case .toggleFloat: "Float the focused window: t"
            case .openPalette: "Open the palette: p — fuzzy-find anything"
            }
        }
    }

    @Observable
    final class Model {
        var page: Page = .welcome
        var permissionGranted = false
        var raycastDetected = false
        var chosenLeader = "alt-space"
        var steps: [TutorialStep: Bool] = Dictionary(
            uniqueKeysWithValues: TutorialStep.allCases.map { ($0, false) }
        )
        var launchAtLogin = false
        var allStepsDone: Bool { steps.values.allSatisfy { $0 } }
    }

    static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: "dev.zephr.onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.zephr.onboarded") }
    }

    let model = Model()
    var onPermissionGranted: (() -> Void)?
    var onLeaderChosen: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private var window: NSWindow?
    private var permissionPoll: Task<Void, Never>?
    private var practiceWindows: [NSWindow] = []

    /// §4.1: the tutorial drives real windows — if the desktop is empty,
    /// Zephr opens two harmless ones of its own and tiles them.
    private func openPracticeWindowsIfNeeded() {
        guard practiceWindows.isEmpty,
              let engine = AppDelegate.shared?.engine,
              engine.windows.count < 2 else { return }
        engine.enablePracticeWindows()
        for n in 1...2 {
            let w = NSWindow(
                contentRect: NSRect(x: 200 + n * 60, y: 200 + n * 40, width: 620, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "\(TilingEngine.practiceWindowPrefix) \(n)"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView:
                VStack(spacing: 10) {
                    Image(systemName: "hand.wave")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Practice window \(n)")
                        .font(.title3.weight(.medium))
                    Text("Try the tutorial steps on me — I'm disposable.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            w.makeKeyAndOrderFront(nil)
            practiceWindows.append(w)
        }
    }

    private func closePracticeWindows() {
        for w in practiceWindows { w.close() }
        practiceWindows.removeAll()
        AppDelegate.shared?.engine.disablePracticeWindows()
    }

    func present(startAt page: Page = .welcome) {
        model.page = page
        model.permissionGranted = AXIsProcessTrusted()
        model.raycastDetected = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.raycast.macos").isEmpty
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos") != nil

        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: model, controller: self))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPermissionPollIfNeeded()
        if page == .tutorial { openPracticeWindowsIfNeeded() }
    }

    // MARK: - Flow

    func advance() {
        switch model.page {
        case .welcome:
            model.page = model.permissionGranted ? .leader : .permission
            startPermissionPollIfNeeded()
        case .permission:
            model.page = .leader
        case .leader:
            onLeaderChosen?(model.chosenLeader)
            model.page = .tutorial
            openPracticeWindowsIfNeeded()
        case .tutorial:
            model.page = .done
            closePracticeWindows()
        case .done:
            finish()
        }
    }

    func skipTutorial() {
        model.page = .done
        closePracticeWindows()
    }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func remindLater() {
        // Dormant in the menu bar, never broken (§4.1).
        finish()
    }

    private func startPermissionPollIfNeeded() {
        guard !model.permissionGranted, permissionPoll == nil else { return }
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.model.permissionGranted = true
                    self.onPermissionGranted?()
                    if self.model.page == .permission { self.model.page = .leader }
                    self.permissionPoll = nil
                    return
                }
            }
        }
    }

    private func finish() {
        Self.hasOnboarded = true
        permissionPoll?.cancel()
        permissionPoll = nil
        closePracticeWindows()
        window?.orderOut(nil)
        onFinished?()
    }

    // MARK: - Tutorial observation (real actions, not a video)

    func noteLayerOpened() {
        markStep(.openLayer)
    }

    func noteCommand(_ command: Command) {
        switch command {
        case .focus: markStep(.focusWindow)
        case .move: markStep(.moveWindow)
        case .goToWorkspace(2): markStep(.switchWorkspace)
        case .moveToWorkspace(2): markStep(.sendToWorkspace)
        case .toggleFloat: markStep(.toggleFloat)
        default: break
        }
    }

    func notePaletteOpened() {
        markStep(.openPalette)
    }

    private func markStep(_ step: TutorialStep) {
        guard model.page == .tutorial, model.steps[step] == false else { return }
        model.steps[step] = true
    }
}

// MARK: - SwiftUI content

private struct OnboardingView: View {
    @Bindable var model: OnboardingController.Model
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
        }
        .frame(width: 520, height: 440)
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .welcome: welcome
        case .permission: permission
        case .leader: leader
        case .tutorial: tutorial
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Zephr").font(.largeTitle.weight(.semibold))
            Text("Your windows arrange themselves. Your hands stay on the keyboard.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Get Started") { controller.advance() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var permission: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hand.raised.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("One permission").font(.title2.weight(.semibold))
            Text("Moving windows requires Accessibility access — true of every window manager on macOS. Zephr notices the grant instantly; nothing to restart.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.permissionGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer()
            HStack {
                Button("Remind me later") { controller.remindLater() }
                Button("Open System Settings") { controller.requestPermission() }
                    .keyboardShortcut(.defaultAction)
            }
            if !model.permissionGranted {
                Button("Checked the box already? Reset the stale grant…") {
                    PermissionGate.resetStaleGrant()
                    controller.requestPermission()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var leader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick your leader key").font(.title2.weight(.semibold))
            Text("The leader opens Zephr's command layer. Every command also has a direct ⌃⌥ chord — the leader is the on-ramp, not a cage.")
                .foregroundStyle(.secondary)
            if model.raycastDetected {
                Label("Raycast detected — it often claims ⌥ Space, so ⌃⌥ Space is preselected.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .onAppear {
                        if model.chosenLeader == "alt-space" { model.chosenLeader = "ctrl-alt-space" }
                    }
            }
            Picker("", selection: $model.chosenLeader) {
                Text("⌥ Space").tag("alt-space")
                Text("⌃⌥ Space").tag("ctrl-alt-space")
                Text("⌘⌥ Space").tag("cmd-alt-space")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Change it anytime in ~/.config/zephr/config.toml — Zephr reloads on save.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { controller.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ninety seconds, your real windows").font(.title2.weight(.semibold))
            Text("Open a couple of app windows, then do each of these. Zephr checks them off as they happen.")
                .foregroundStyle(.secondary)
            ForEach(OnboardingController.TutorialStep.allCases) { step in
                Label {
                    Text(step.label)
                        .strikethrough(model.steps[step] == true)
                        .foregroundStyle(model.steps[step] == true ? .secondary : .primary)
                } icon: {
                    Image(systemName: model.steps[step] == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.steps[step] == true ? .green : .secondary)
                }
            }
            Spacer()
            HStack {
                Button("Skip") { controller.skipTutorial() }
                Spacer()
                Button(model.allStepsDone ? "Finish" : "Done for now") { controller.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.green)
            Text("You know 80% of it.").font(.title2.weight(.semibold))
            Text("Press your leader, then ? — the full cheat sheet is always one keystroke away. Replay this tour from the menu bar anytime.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if ImportService.anythingToImport {
                Button("Import AeroSpace / Amethyst settings…") {
                    if let config = AppDelegate.shared?.configService {
                        ImportService.runAndShowReport(config: config)
                    }
                }
            }
            Toggle("Start Zephr at login", isOn: Bindable(model).launchAtLogin)
                .onChange(of: model.launchAtLogin) { _, _ in
                    AppDelegate.shared?.toggleLaunchAtLogin()
                }
            Spacer()
            Button("Start tiling") { controller.advance() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}
