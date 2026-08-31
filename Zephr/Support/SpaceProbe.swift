import CoreGraphics
import Foundation

/// Reads the window list for the native Space the user is currently looking
/// at (§6.4 Space-awareness).
///
/// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)` is the only public
/// API that distinguishes Spaces: it reports the windows on the active Space
/// and omits everything on the others. That is enough to keep a tile from
/// standing empty while the window it belongs to sits on a Space nobody is
/// looking at, and it needs no extra permission — unlike `kCGWindowName`,
/// which requires Screen Recording and is deliberately never read here
/// (§6.1, never require reduced security).
enum SpaceProbe {

    /// Bounds of every ordinary window on the active Space, keyed by owning
    /// pid. Bounds arrive in the same global, y-down coordinate space the
    /// rest of the engine uses, so they need no conversion.
    ///
    /// An empty result means the API told us nothing — not that the screen
    /// is empty — and callers must treat it as "no information" rather than
    /// concluding every window has moved away.
    static func onScreenWindowsByPID() -> [pid_t: [CGRect]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else { return [:] }

        var byPID: [pid_t: [CGRect]] = [:]
        for entry in entries {
            // Layer 0 is the ordinary window layer. Anything else is chrome
            // the engine never manages — the Dock, the menu bar, overlays,
            // and Zephr's own panels.
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String],
                  CFGetTypeID(bounds as CFTypeRef) == CFDictionaryGetTypeID(),
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
            else { continue }
            byPID[pid, default: []].append(rect)
        }
        return byPID
    }
}
