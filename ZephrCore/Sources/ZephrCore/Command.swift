import Foundation
import CoreGraphics

/// Every user-facing command in Zephr. Hotkeys, the leader layer, the menu
/// bar, and (later) the palette and zephrctl all speak this vocabulary.
public enum Command: Sendable, Equatable {
    case focus(Direction)
    case move(Direction)
    case goToWorkspace(Int)
    case moveToWorkspace(Int)
    case toggleFloat
    case toggleMonocle
    case splitPreselect(Orientation)
    case cycleLayout
    /// Group the focused window with its neighbour in a new container.
    case joinWith(Direction)
    /// Reparent every window onto the root — the layout reset.
    case flatten
    /// Lay the focused window's container out along this axis.
    case setOrientation(Orientation)
    /// Flip the focused window's container between a row and a column. The
    /// keyboard wants one reversible key; the CLI wants to say which.
    case toggleOrientation
    case resize(Direction, fine: Bool)
    case shrink
    case grow
    case balance
    case rescueWindows
    case focusNextDisplay
    /// Send the focused window to another display. `nil` = the next one.
    case moveWindowToDisplay(Direction?)
    /// Send the whole current workspace to another display.
    case moveWorkspaceToDisplay(Direction?)
    case closeWindow
    case toggleWorkspaceFloatMode
    case togglePause
    /// Suspend or resume tiling on the focused display only.
    case togglePauseDisplay

    /// Whether the command's direct chord adds ⇧ (move variants).
    public var isMoveVariant: Bool {
        switch self {
        case .move, .moveToWorkspace: true
        default: false
        }
    }

    /// Short label shown on the command strip keycaps.
    public var label: String {
        switch self {
        case .focus(let d): "Focus \(d.rawValue)"
        case .move(let d): "Move \(d.rawValue)"
        case .goToWorkspace(let n): "Workspace \(n)"
        case .moveToWorkspace(let n): "Send to \(n)"
        case .toggleFloat: "Toggle float"
        case .toggleMonocle: "Monocle"
        case .splitPreselect(let o): o == .horizontal ? "Split right" : "Split down"
        case .cycleLayout: "Cycle layout"
        case .joinWith(let d): "Group with \(d.rawValue)"
        case .flatten: "Flatten layout"
        case .setOrientation(let o): o == .horizontal ? "Lay out in a row" : "Lay out in a column"
        case .toggleOrientation: "Row ↔ column"
        case .resize: "Resize"
        case .shrink: "Shrink"
        case .grow: "Grow"
        case .balance: "Balance"
        case .rescueWindows: "Rescue windows"
        case .focusNextDisplay: "Next display"
        case .moveWindowToDisplay(let d): d.map { "Send window \($0.rawValue)" } ?? "Send window to next display"
        case .moveWorkspaceToDisplay(let d): d.map { "Send workspace \($0.rawValue)" } ?? "Send workspace to next display"
        case .closeWindow: "Close window"
        case .toggleWorkspaceFloatMode: "Workspace float mode"
        case .togglePause: "Pause / resume Zephr"
        case .togglePauseDisplay: "Pause / resume this display"
        }
    }
}
