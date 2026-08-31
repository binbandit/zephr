import CoreGraphics
import Foundation
import ZephrCore

/// Reads the window list for the native Space the user is currently looking
/// at (§6.4 Space-awareness), and the window *level* of each entry.
///
/// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` is the only public
/// API that distinguishes Spaces: it reports the windows on the active Space
/// and omits everything on the others. It is also the only public source of
/// `kCGWindowLevel`, which is the single strongest signal for telling a real
/// window from an overlay — screen-share bars, screenshot tools, reminder
/// popups and picture-in-picture all sit above the normal layer while
/// looking like ordinary windows to the Accessibility API.
///
/// Neither use needs `kCGWindowName`, which requires Screen Recording, and
/// it is deliberately never read here (§6.1, never require reduced
/// security). Correlating by pid and bounds is the approach `docs/DESIGN.md`
/// already sanctions for CGWindow lookups.
enum SpaceProbe {

    /// The normal window layer. Everything a user thinks of as "a window"
    /// lives here; anything above it is chrome of some kind.
    static let normalLevel = 0

    /// Every window on the active Space, keyed by owning pid.
    ///
    /// An empty result means the API told us nothing — not that the screen
    /// is empty — and callers must treat it as "no information" rather than
    /// concluding every window has moved away.
    static func onScreenWindows() -> [pid_t: [WindowProbe.Entry]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else { return [:] }

        var byPID: [pid_t: [WindowProbe.Entry]] = [:]
        for entry in entries {
            guard let level = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String],
                  CFGetTypeID(bounds as CFTypeRef) == CFDictionaryGetTypeID(),
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
            else { continue }
            byPID[pid, default: []].append(.init(frame: rect, level: level))
        }
        return byPID
    }

    /// Bounds of the ordinary windows on the active Space, for Space
    /// membership. Chrome at other levels is not something the layout ever
    /// tracks, so counting it would only skew the comparison.
    static func onScreenWindowsByPID() -> [pid_t: [CGRect]] {
        onScreenWindows().compactMapValues { entries -> [CGRect]? in
            let normal = entries.filter { $0.level == normalLevel }.map(\.frame)
            return normal.isEmpty ? nil : normal
        }
    }
}
