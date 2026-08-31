import Foundation
import CoreGraphics

/// Correlating an Accessibility window with the CoreGraphics window list.
///
/// The AX API describes what a window *is*; the CG list describes where it
/// sits in the window server, including its level. Only the latter can tell
/// a screen-share bar, a screenshot overlay, a reminder popup or a
/// picture-in-picture panel from an ordinary window — every one of those
/// reports `AXStandardWindow` with a close button and looks perfectly
/// tileable through AX alone.
///
/// The two are joined on pid and bounds, because the exact identifier that
/// would join them precisely is a private API (§6.1). That makes the join a
/// heuristic, so the rule here is deliberately strict: answer only when
/// exactly one candidate matches. An ambiguous answer must leave the caller
/// exactly where it was rather than guess, since guessing wrong means
/// refusing to manage a window the user expects to be tiled.
public enum WindowProbe {

    public struct Entry: Equatable, Sendable {
        public var frame: CGRect
        public var level: Int

        public init(frame: CGRect, level: Int) {
            self.frame = frame
            self.level = level
        }
    }

    /// The window level for `frame` among `candidates`, or nil when no
    /// single candidate matches.
    ///
    /// The tolerance is generous because an app may have settled a point or
    /// two off the frame AX reports, and because being wrong in the
    /// permissive direction (no answer) is free while being wrong in the
    /// other direction drops a real window from management.
    public static func level(
        of frame: CGRect,
        among candidates: [Entry],
        tolerance: CGFloat = 4
    ) -> Int? {
        let matches = candidates.filter {
            $0.frame.approximatelyEquals(frame, tolerance: tolerance)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].level
    }
}
