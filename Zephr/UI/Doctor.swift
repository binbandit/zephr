import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// `zephr doctor` as a window (§4.6): permission, Secure Input, Stage
/// Manager, conflicting window managers, display/window counts, config
/// status — with plain language and one-click fixes where macOS allows one.
@MainActor
final class DoctorController {

    struct Check: Identifiable {
        enum Status { case pass, warn, fail }
        let id = UUID()
        var status: Status
        var title: String
        var detail: String
        var actionLabel: String?
        var action: (() -> Void)?
    }

    private var window: NSWindow?
    private let windowDelegate = CallbackWindowDelegate()

    /// Stage Manager is incompatible by nature (§6.4): say so plainly.
    static func stageManagerEnabled() -> Bool {
        CFPreferencesCopyAppValue(
            "GloballyEnabled" as CFString,
            "com.apple.WindowManager" as CFString
        ) as? Bool ?? false
    }

    /// Tiling managers that enforce their own layout: two of these really
    /// will fight over every window.
    private nonisolated static let fightingRivals = ["yabai", "AeroSpace", "Amethyst", "Rift"]
    /// Snapping utilities that only move windows on their own explicit
    /// shortcuts — they coexist with Zephr and are a heads-up, not a failure.
    private nonisolated static let snappingUtilities = ["Rectangle", "Magnet", "Loop"]

    /// Blocking (forks one pgrep) — call off the main actor (§6.3).
    nonisolated static func runningRivals() -> (fighting: [String], snapping: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-lx", (fightingRivals + snappingUtilities).joined(separator: "|")]
        let pipe = Pipe()
        p.standardOutput = pipe
        // A failed spawn must never reach `waitUntilExit` on an unlaunched
        // Process — that raises NSInvalidArgumentException (§6.6).
        do { try p.run() } catch { return ([], []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let names = Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { $0.split(separator: " ", maxSplits: 1).last.map(String.init) }
        )
        return (fightingRivals.filter(names.contains), snappingUtilities.filter(names.contains))
    }

    /// Scans for rivals off the main actor, then builds the checks. The scan
    /// forks a process, which §6.3 forbids on the main actor — callers that
    /// can await (the Doctor window, `zephrctl doctor`) go through here.
    func runChecksOffActor() async -> [Check] {
        let rivals = await Task.detached { Self.runningRivals() }.value
        return runChecks(rivals: rivals)
    }

    func runChecks(rivals: (fighting: [String], snapping: [String])) -> [Check] {
        var checks: [Check] = []
        guard let delegate = AppDelegate.shared else { return checks }

        let trusted = AXIsProcessTrusted()
        checks.append(Check(
            status: trusted ? .pass : .fail,
            title: "Accessibility permission",
            detail: trusted
                ? "Granted — window control is active."
                : "Not granted. Zephr cannot move windows without it.",
            actionLabel: trusted ? nil : "Open System Settings",
            action: trusted ? nil : { delegate.permissionGate.presentIfNeeded() }
        ))

        let secure = IsSecureEventInputEnabled()
        checks.append(Check(
            status: secure ? .warn : .pass,
            title: "Secure Input",
            detail: secure
                ? "Active — a password field or security tool is holding keyboard events; hotkeys resume when it ends."
                : "Inactive — hotkeys fully available."
        ))

        let stage = Self.stageManagerEnabled()
        checks.append(Check(
            status: stage ? .fail : .pass,
            title: "Stage Manager",
            detail: stage
                ? "Enabled. Stage Manager rearranges windows on its own and is incompatible with tiling — turn it off in Desktop & Dock."
                : "Off.",
            actionLabel: stage ? "Open Desktop & Dock" : nil,
            action: stage ? {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } : nil
        ))

        var rivalStatus = Check.Status.pass
        var rivalParts: [String] = []
        if !rivals.fighting.isEmpty {
            rivalStatus = .fail
            rivalParts.append("\(rivals.fighting.joined(separator: ", ")) running — another tiling manager; two will fight over every window. Quit it before tiling with Zephr.")
        }
        if !rivals.snapping.isEmpty {
            if rivalStatus == .pass { rivalStatus = .warn }
            rivalParts.append("\(rivals.snapping.joined(separator: ", ")) running — a snapping utility that only acts on its own shortcuts. It coexists with Zephr; just mind overlapping hotkeys.")
        }
        checks.append(Check(
            status: rivalStatus,
            title: "Other window managers",
            detail: rivalParts.isEmpty ? "None running." : rivalParts.joined(separator: " ")
        ))

        checks.append(Check(
            status: delegate.appState.configError == nil ? .pass : .warn,
            title: "Configuration",
            detail: delegate.appState.configError
                ?? "config.toml parsed cleanly. Hot reload is on.",
            actionLabel: "Open Config",
            action: { delegate.configService.openInEditor() }
        ))

        let windowCount = delegate.appState.managedWindowCount
        let displayCount = NSScreen.screens.count
        checks.append(Check(
            status: .pass,
            title: "Engine",
            detail: "\(windowCount) \(windowCount == 1 ? "window" : "windows") managed across \(displayCount) \(displayCount == 1 ? "display" : "displays")."
        ))

        return checks
    }

    func present() {
        // §6.3 anti-stall: the rival scan forks pgrep — run it off the main
        // actor, then present with the results.
        _ = Task { [weak self] in
            let rivals = await Task.detached { Self.runningRivals() }.value
            self?.presentNow(rivals: rivals)
        }
    }

    private func presentNow(rivals: (fighting: [String], snapping: [String])) {
        let checks = runChecks(rivals: rivals)
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Zephr Doctor"
            w.isReleasedWhenClosed = false
            windowDelegate.onClose = { [weak self] in self?.window = nil }
            w.delegate = windowDelegate
            window = w
        }
        window?.contentView = NSHostingView(rootView: DoctorView(checks: checks, controller: self))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DoctorView: View {
    let checks: [DoctorController.Check]
    let controller: DoctorController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(check.status))
                            .foregroundStyle(color(check.status))
                            .font(.system(size: 16))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.headline)
                            Text(check.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let label = check.actionLabel, let action = check.action {
                                Button(label, action: action)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Run Again") { controller.present() }
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 420)
    }

    private func icon(_ status: DoctorController.Check.Status) -> String {
        switch status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func color(_ status: DoctorController.Check.Status) -> Color {
        switch status {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        }
    }
}
