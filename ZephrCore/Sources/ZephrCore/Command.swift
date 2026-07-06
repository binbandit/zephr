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
    case resize(Direction, fine: Bool)
    case shrink
    case grow
    case balance
    case rescueWindows
    case focusNextDisplay
    case closeWindow
    case toggleWorkspaceFloatMode
    case togglePause

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
        case .resize: "Resize"
        case .shrink: "Shrink"
        case .grow: "Grow"
        case .balance: "Balance"
        case .rescueWindows: "Rescue windows"
        case .focusNextDisplay: "Next display"
        case .closeWindow: "Close window"
        case .toggleWorkspaceFloatMode: "Workspace float mode"
        case .togglePause: "Pause / resume Zephr"
        }
    }
}
