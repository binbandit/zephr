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

    /// Stage Manager is incompatible by nature (§6.4): say so plainly.
    static func stageManagerEnabled() -> Bool {
        CFPreferencesCopyAppValue(
            "GloballyEnabled" as CFString,
            "com.apple.WindowManager" as CFString
        ) as? Bool ?? false
    }

    private nonisolated static let rivalProcesses = ["yabai", "AeroSpace", "Amethyst", "Rift", "Rectangle", "Magnet", "Loop"]

    /// Callable off the main actor for the launch-time check.
    nonisolated static func runningRivalNames() -> [String] {
        runningRivals()
    }

    private nonisolated static func runningRivals() -> [String] {
        var found: [String] = []
        for name in rivalProcesses {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-xq", name]
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { found.append(name) }
        }
        return found
    }

    func runChecks() -> [Check] {
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

        let rivals = Self.runningRivals()
        checks.append(Check(
            status: rivals.isEmpty ? .pass : .fail,
            title: "Other window managers",
            detail: rivals.isEmpty
                ? "None running."
                : "\(rivals.joined(separator: ", ")) running — two managers will fight over every window. Quit them."
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
        checks.append(Check(
            status: .pass,
            title: "Engine",
            detail: "\(windowCount) windows managed across \(NSScreen.screens.count) display(s)."
        ))

        return checks
    }

    func present() {
        let checks = runChecks()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Zephr Doctor"
            w.isReleasedWhenClosed = false
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
