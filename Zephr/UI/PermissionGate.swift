import AppKit
import ApplicationServices
import SwiftUI

/// Reusable `NSWindowDelegate` for controllers that aren't NSObjects: routes
/// close / resign-key back to the owner so no window can be stranded with
/// state (polls, practice windows) the close button never cleans up (§4.1).
/// NSWindow holds its delegate weakly — owners must retain this object.
final class CallbackWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onResignKey: (() -> Void)?

    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidResignKey(_ notification: Notification) { onResignKey?() }
}

/// Accessibility permission flow (§4.1): one screen, one sentence of why,
/// automatic detection the moment the grant lands. "Remind me later" leaves
/// the app dormant in the menu bar instead of broken.
@MainActor
final class PermissionGate {

    nonisolated(unsafe) static weak var shared: PermissionGate?

    var onGranted: (() -> Void)?
    private var window: NSWindow?
    private let windowDelegate = CallbackWindowDelegate()
    private var poll: Task<Void, Never>?

    init() {
        Self.shared = self
        // macOS posts this the moment any AX trust changes — instant
        // detection instead of waiting on the poll.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // TCC needs a beat before AXIsProcessTrusted reflects it.
                _ = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    PermissionGate.shared?.checkNow()
                }
            }
        }
    }

    private func checkNow() {
        // No `window != nil` condition: after "Remind me later" the gate was
        // never presented, yet a grant made in System Settings must still
        // start managing — "Zephr notices the grant instantly" (§4.1).
        if Self.isTrusted() {
            granted()
        }
    }

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// macOS ties the Accessibility grant to the app's code signature. After
    /// re-signing (updates, dev builds), System Settings still shows the old
    /// checkmark but the running binary is refused — the check "looks
    /// broken". Resetting drops the stale record so a fresh grant sticks.
    static func resetStaleGrant() async {
        // tccutil blocks for a beat — never on the main actor (§6.3). And a
        // failed spawn must not reach `waitUntilExit` on an unlaunched
        // Process: that raises NSInvalidArgumentException and kills the app.
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "dev.zephr.Zephr"]
            do { try process.run() } catch { return }
            process.waitUntilExit()
        }.value
    }

    func presentIfNeeded() {
        guard !Self.isTrusted() else {
            onGranted?()
            return
        }

        // One gate window for the life of the process: a second call (menu +
        // Doctor) re-fronts it — never stacks an unreachable copy.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = PermissionView(
            openSettings: { [weak self] in self?.requestAndOpenSettings() },
            resetStale: { [weak self] in
                _ = Task {
                    await PermissionGate.resetStaleGrant()
                    self?.requestAndOpenSettings()
                }
            },
            later: { [weak self] in self?.dismiss() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        windowDelegate.onClose = { [weak self] in self?.dismiss() }
        window.delegate = windowDelegate
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Self.isTrusted() {
                    self?.granted()
                    return
                }
            }
        }
    }

    /// Belt and braces: anything that confirms trust can close the window.
    func dismissWindow() {
        dismiss()
    }

    private func requestAndOpenSettings() {
        // kAXTrustedCheckOptionPrompt imports as a mutable global (not
        // concurrency-safe to reference); its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func granted() {
        dismiss()
        onGranted?()
    }

    private func dismiss() {
        poll?.cancel()
        window?.orderOut(nil)
        window = nil
    }
}

private struct PermissionView: View {
    let openSettings: () -> Void
    let resetStale: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 28)

            Text("Zephr needs Accessibility access")
                .font(.title2.weight(.semibold))

            Text("Moving and tiling windows requires the Accessibility permission - that's true of every window manager on macOS. Zephr detects the grant automatically; nothing to restart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button("Remind me later", action: later)
                Button("Open System Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }

            Divider().padding(.horizontal, 60)

            Text("Already checked in System Settings but this window won't go away? macOS bound that grant to an older build. Reset it, then check the box again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Reset Stale Permission…", action: resetStale)
                .controlSize(.small)
                .padding(.bottom, 24)
        }
        .frame(width: 460)
    }
}
