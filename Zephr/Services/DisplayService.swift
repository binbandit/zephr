import AppKit
import ZephrCore

/// Snapshot of one connected display in global CG (top-left origin)
/// coordinates — the space ZephrCore and the AX API share.
struct DisplayInfo: Equatable {
    var id: DisplayID
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Tracks the display arrangement and debounces the reconfiguration storms
/// macOS fires on dock/undock/wake (§6.4).
@MainActor
final class DisplayService {

    var onChange: (() -> Void)?
    private var debounce: Task<Void, Never>?
    private var observation: Task<Void, Never>?

    init() {
        observation = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            )
            for await _ in changes {
                self?.screenParametersChanged()
            }
        }
    }

    deinit {
        observation?.cancel()
    }

    private func screenParametersChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.onChange?()
        }
    }

    /// Current displays, primary first then left-to-right, in CG coordinates.
    func current() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            return []
        }
        let primaryHeight = primary.frame.height

        var infos: [DisplayInfo] = screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return DisplayInfo(
                id: DisplayID(number.uint32Value),
                frame: cocoaToGlobal(screen.frame, primaryDisplayHeight: primaryHeight),
                visibleFrame: cocoaToGlobal(screen.visibleFrame, primaryDisplayHeight: primaryHeight)
            )
        }
        infos.sort { a, b in
            if a.frame.origin == .zero { return true }
            if b.frame.origin == .zero { return false }
            return a.frame.minX < b.frame.minX
        }
        return infos
    }
}
