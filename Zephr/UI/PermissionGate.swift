import AppKit
import ApplicationServices
import SwiftUI

/// Accessibility permission flow (§4.1): one screen, one sentence of why,
/// automatic detection the moment the grant lands. "Remind me later" leaves
/// the app dormant in the menu bar instead of broken.
@MainActor
final class PermissionGate {

    var onGranted: (() -> Void)?
    private var window: NSWindow?
    private var poll: Task<Void, Never>?

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func presentIfNeeded() {
        guard !Self.isTrusted() else {
            onGranted?()
            return
        }

        let content = PermissionView(
            openSettings: { [weak self] in self?.requestAndOpenSettings() },
            later: { [weak self] in self?.dismiss() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Self.isTrusted() {
                    self?.granted()
                    return
                }
            }
        }
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
    let later: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 28)

            Text("Zephr needs Accessibility access")
                .font(.title2.weight(.semibold))

            Text("Moving and tiling windows requires the Accessibility permission — that's true of every window manager on macOS. Zephr detects the grant automatically; nothing to restart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button("Remind me later", action: later)
                Button("Open System Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 460)
    }
}
