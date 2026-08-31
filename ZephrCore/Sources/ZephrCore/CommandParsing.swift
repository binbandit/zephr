import Foundation

/// Turning a written command into a `Command`.
///
/// One vocabulary, shared by the config file's key bindings and by
/// `zephrctl`. Keeping them the same is the point: a user who has learned
/// `zephrctl focus left` should be able to bind that exact string, and a
/// binding that works should be testable from the shell without guessing at
/// a second spelling.
extension Command {

    /// Parses `focus left`, `workspace 3`, `balance`, and so on. Returns nil
    /// for anything unrecognised so the caller can report the line.
    public static func parse(_ input: String) -> Command? {
        let parts = input.split(separator: " ").map { String($0).lowercased() }
        guard let verb = parts.first else { return nil }
        let argument = parts.dropFirst().first

        func direction() -> Direction? { argument.flatMap(Direction.init(rawValue:)) }
        func workspace() -> Int? {
            guard let n = argument.flatMap(Int.init), (1...9).contains(n) else { return nil }
            return n
        }

        switch verb {
        case "focus":
            guard let d = direction() else { return nil }
            return .focus(d)
        case "move":
            guard let d = direction() else { return nil }
            return .move(d)
        case "workspace":
            guard let n = workspace() else { return nil }
            return .goToWorkspace(n)
        case "send-to-workspace":
            guard let n = workspace() else { return nil }
            return .moveToWorkspace(n)
        case "summon":
            guard let n = workspace() else { return nil }
            return .summonWorkspace(n)
        case "toggle-float": return .toggleFloat
        case "monocle": return .toggleMonocle
        case "balance": return .balance
        case "rescue": return .rescueWindows
        case "close": return .closeWindow
        case "cycle-layout": return .cycleLayout
        case "flatten": return .flatten
        case "float-mode": return .toggleWorkspaceFloatMode
        case "pause": return .togglePause
        case "pause-display": return .togglePauseDisplay
        case "next-display": return .focusNextDisplay
        case "shrink": return .shrink
        case "grow": return .grow
        case "group":
            return .joinWith(direction() ?? .right)
        case "layout":
            switch argument {
            case "row", "horizontal": return .setOrientation(.horizontal)
            case "column", "vertical": return .setOrientation(.vertical)
            case nil: return .toggleOrientation
            default: return nil
            }
        case "split":
            switch argument {
            case "h", "horizontal": return .splitPreselect(.horizontal)
            case "v", "vertical": return .splitPreselect(.vertical)
            default: return nil
            }
        case "resize":
            guard let d = direction() else { return nil }
            return .resize(d, fine: parts.contains("fine"))
        case "move-to-display":
            return .moveWindowToDisplay(direction())
        case "move-workspace-to-display":
            return .moveWorkspaceToDisplay(direction())
        default:
            return nil
        }
    }

    /// Every verb `parse` accepts, for error messages and completion.
    public static let vocabulary: [String] = [
        "focus", "move", "workspace", "send-to-workspace", "summon",
        "toggle-float", "monocle", "balance", "rescue", "close",
        "cycle-layout", "flatten", "float-mode", "pause", "pause-display",
        "next-display", "shrink", "grow", "group", "layout", "split",
        "resize", "move-to-display", "move-workspace-to-display",
    ]
}

/// A key the user has bound to a command.
///
/// Two shapes, because Zephr has two ways to reach the same command and a
/// binding has to be able to say which: a direct chord carries modifiers and
/// fires from anywhere, while a leader binding is a bare key that only means
/// something while the layer is open.
public struct KeyBinding: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        /// Held modifiers plus a key, e.g. `ctrl-alt-b`.
        case chord(control: Bool, option: Bool, command: Bool, shift: Bool)
        /// Pressed after the leader, e.g. `leader b`.
        case leader(shift: Bool)
    }

    public var trigger: Trigger
    public var key: String
    public var command: Command

    public init(trigger: Trigger, key: String, command: Command) {
        self.trigger = trigger
        self.key = key
        self.command = command
    }

    /// Parses `ctrl-alt-b`, `leader b`, `leader shift-b`.
    ///
    /// A chord with no modifier is rejected outright: binding a bare letter
    /// globally would swallow that key everywhere, in every app, which is
    /// not something a config file should be able to do by accident.
    public static func parseTrigger(_ raw: String) -> (Trigger, String)? {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("leader ") {
            let rest = String(lowered.dropFirst("leader ".count))
                .trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: "-")
            let shift = parts.count > 1 && parts.dropLast().contains("shift")
            guard let key = parts.last, !key.isEmpty else { return nil }
            return (.leader(shift: shift), key)
        }
        let parts = lowered.components(separatedBy: "-")
        guard parts.count >= 2, let key = parts.last, !key.isEmpty else { return nil }
        var control = false, option = false, command = false, shift = false
        for modifier in parts.dropLast() {
            switch modifier {
            case "ctrl", "control": control = true
            case "alt", "opt", "option": option = true
            case "cmd", "command": command = true
            case "shift": shift = true
            default: return nil
            }
        }
        guard control || option || command else { return nil }
        return (.chord(control: control, option: option, command: command, shift: shift), key)
    }
}
