import AppKit
import CoreGraphics
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

    /// §6.1 names the CG reconfiguration callback as the display source:
    /// wake/undock storms can reach it before (or without) AppKit's screen-
    /// parameters notification. Both feed the same debouncer. Stored so
    /// deinit can unregister the identical function pointer. No captures —
    /// context goes through `DisplayServiceBox` (C convention).
    private nonisolated let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
        // Each change arrives as a begin/end pair; only react to the end.
        guard !flags.contains(.beginConfigurationFlag) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DisplayServiceBox.shared?.displayConfigurationChanged()
            }
        }
    }

    init() {
        observation = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            )
            for await _ in changes {
                self?.displayConfigurationChanged()
            }
        }
        DisplayServiceBox.shared = self
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)
    }

    deinit {
        observation?.cancel()
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
    }

    fileprivate func displayConfigurationChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // §6.4: debounce + stability check — on wake with an external
            // display, a parameters change can post while visibleFrame is
            // still transitional, and fingerprinting that transient
            // arrangement records a bogus profile. Only fire once two
            // consecutive samples agree; bounded, so a flapping display
            // cannot postpone reconciliation forever (never stall).
            var sample = self.current()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let next = self.current()
                if next == sample { break }
                sample = next
            }
            self.onChange?()
        }
    }

    /// Current displays, primary first then left-to-right, in CG coordinates.
    /// The `NSScreen` backing a display id.
    ///
    /// Overlays place themselves in Cocoa coordinates, so they need the
    /// screen object rather than the engine's global-CG rects.
    static func screen(for id: DisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id.raw
        }
    }

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

/// Static hop for the C reconfiguration callback (main queue → MainActor).
@MainActor
private enum DisplayServiceBox {
    static weak var shared: DisplayService?
}
