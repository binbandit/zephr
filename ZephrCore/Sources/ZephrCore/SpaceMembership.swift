import Foundation
import CoreGraphics

/// Deciding which managed windows sit on the native Space the user is
/// currently looking at (§6.4).
///
/// macOS offers no public API to enumerate Spaces or ask which one a window
/// is on — the tools that do it disable SIP, which Zephr never will (§6.1).
/// What *is* public is `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)`,
/// which lists only the windows on the active Space. A window we expect to
/// be on screen and cannot find in that list is therefore on another Space,
/// and must leave the layout until it comes back — otherwise its tile holds
/// space for something nobody can see.
///
/// Matching is on pid and bounds, never on title: `kCGWindowName` requires
/// the Screen Recording permission, and needing that would break the
/// "never require reduced security" invariant for a cosmetic gain.
public enum SpaceMembership {

    /// A managed window that *should* be visible right now.
    ///
    /// Only windows the model places on a display's active workspace belong
    /// here. Stashed windows are parked off-display on purpose and may be
    /// absent from the on-screen list for that reason alone — judging them
    /// would empty every inactive workspace.
    public struct Candidate: Equatable, Sendable {
        public var id: WindowID
        public var pid: pid_t
        public var frame: CGRect

        public init(id: WindowID, pid: pid_t, frame: CGRect) {
            self.id = id
            self.pid = pid
            self.frame = frame
        }
    }

    /// Candidates with no counterpart in the current Space's window list.
    ///
    /// The per-app *count* is the primary signal and the frames only break
    /// ties. An app showing at least as many windows as we expect cannot
    /// have any of them on another Space, whatever the frames say — which
    /// matters because our cached frame for a window the user just dragged
    /// is briefly stale, and reading that as "moved to another Space" would
    /// tear a window out of the layout for no reason.
    ///
    /// When an app *is* short, frame matching picks which windows to blame,
    /// each live rect satisfying at most one candidate. The result is capped
    /// at the shortfall so drift can never implicate more windows than are
    /// actually missing, and candidates are walked in id order so the answer
    /// does not vary with `Dictionary` seeding — a verdict that flipped
    /// between runs would add and remove tiles at random.
    public static func absent(
        candidates: [Candidate],
        onScreenByPID: [pid_t: [CGRect]],
        tolerance: CGFloat = 6
    ) -> Set<WindowID> {
        // Everything gone is not a migration, it is a Space *switch*: the
        // user is looking at a Space none of these windows live on, and the
        // workspace they belong to is simply not visible. Withdrawing them
        // all would tear the whole layout out of the tree and rebuild a
        // different one on the way back — insertion splits near the focused
        // window and halves ratios, so the tree that returns is not the tree
        // that left. Entering native fullscreen looks exactly like this too,
        // because macOS gives the fullscreen window its own Space.
        //
        // Withdrawal is only meaningful when *some* windows left while
        // others stayed, which is what a window dragged to another Space
        // actually looks like.
        guard !candidates.isEmpty else { return [] }
        let anyPresent = candidates.contains { candidate in
            (onScreenByPID[candidate.pid] ?? []).contains {
                $0.approximatelyEquals(candidate.frame, tolerance: tolerance)
            }
        }
        guard anyPresent else { return [] }

        var missing: Set<WindowID> = []
        for (pid, group) in Dictionary(grouping: candidates, by: \.pid) {
            let live = onScreenByPID[pid] ?? []
            let shortfall = group.count - live.count
            guard shortfall > 0 else { continue }

            var rects = live
            var unmatched: [WindowID] = []
            for candidate in group.sorted(by: { $0.id.raw < $1.id.raw }) {
                if let hit = rects.firstIndex(where: {
                    $0.approximatelyEquals(candidate.frame, tolerance: tolerance)
                }) {
                    rects.remove(at: hit)
                } else {
                    unmatched.append(candidate.id)
                }
            }
            missing.formUnion(unmatched.prefix(shortfall))
        }
        return missing
    }
}
