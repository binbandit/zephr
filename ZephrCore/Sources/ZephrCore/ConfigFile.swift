import Foundation
import CoreGraphics

/// The leader chord, parsed from strings like "alt-space" or "ctrl-alt-space".
public struct LeaderBinding: Sendable, Equatable {
    public var control = false
    public var option = false
    public var command = false
    public var shift = false
    public var key: String = "space"

    public static let `default` = LeaderBinding(option: true, key: "space")

    public init(control: Bool = false, option: Bool = false, command: Bool = false, shift: Bool = false, key: String = "space") {
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
        self.key = key
    }
}

/// Result of parsing a config file. Every field has the shipped default, so
/// an empty file — or no file at all — is a complete, working configuration.
public struct ParsedConfig: Sendable, Equatable {
    public var leader: LeaderBinding = .default
    public var layout: LayoutConfig = .default
    public var focusBorder: Bool = true
    public var defaultLayout: ContainerLayout = .tiles
    public var keyPreset: String = "default"
    public var userRules: [WindowRule] = []
    public var onWorkspaceChanged: [String] = []
    /// Optional workspace names ([workspaces] 4 = "chat").
    public var workspaceNames: [Int: String] = [:]
    /// Workspaces that default new windows to floating (§4.3 junk drawer).
    public var floatByDefaultWorkspaces: [Int] = []
    /// Show a Dock icon (§5: menu-bar app by default, a setting flips it on).
    public var showDockIcon: Bool = false
    /// Show the menu-bar (status bar) item. Default true — it is the app's
    /// primary always-visible surface.
    public var showMenuBarIcon: Bool = true
    /// Close the leader layer after one command (§4.2 one-shot mode).
    public var layerOneShot: Bool = false
    /// Seconds of layer inactivity before it closes; 0 = never (§4.2).
    public var layerTimeout: CGFloat = 0
    /// Non-fatal problems (unknown keys, unsupported presets). Shown, never
    /// silently ignored (§4.6).
    public var warnings: [String] = []

    public init() {}
}

public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// Interim hand-rolled parser for the documented config subset (Appendix B).
/// P4 replaces this with the lossless TOML document engine; the file format
/// is forward-compatible.
public enum ConfigFile {

    /// Written to `~/.config/zephr/config.toml` on first run.
    public static let defaultText = """
    # Zephr configuration — ~/.config/zephr/config.toml
    # Everything here is optional; these are the defaults. Zephr reloads this
    # file the moment you save it. Errors show in the menu bar, never silently.

    leader = "alt-space"          # e.g. "ctrl-alt-space", "cmd-alt-space"
    menu-bar-icon = true          # the status-bar workspace indicator

    [layout]
    gaps = 8                      # points between windows and screen edges
    accordion-padding = 48        # collapsed sliver width in accordion layout
    focus-border = true           # accent border on the focused window
    default = "tiles"             # tiles | accordion

    [keys]
    preset = "default"            # default: ⌃⌥ chords · i3: ⌘⌥ · aerospace: bare ⌥ (breaks ⌥-typing!) · vim: leader-only

    # [workspaces]                # optional names and per-workspace behavior
    # 1 = "code"
    # 4 = "chat"
    # float-by-default = [9]      # workspaces where new windows float (junk drawer)

    # Per-app rules — first match wins; checked before Zephr's built-in list.
    # [[rules]]
    # app = "com.example.app"     # bundle identifier
    # title = "^Preferences"      # optional regex on the window title
    # action = "float"            # float | tile | ignore | workspace N

    [callbacks]
    on-workspace-changed = []     # shell commands; $ZEPHR_WORKSPACE is set
    """

    private enum Section {
        case root, layout, keys, callbacks, workspaces, rule(Int), unknown(String)
    }

    public static func parse(_ text: String) throws -> ParsedConfig {
        var config = ParsedConfig()
        var section = Section.root
        var rules: [PartialRule] = []

        struct PartialRule {
            var app: String?
            var title: String?
            var action: String?
            var headerLine: Int
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if name == "rules" {
                    rules.append(PartialRule(headerLine: lineNumber))
                    section = .rule(rules.count - 1)
                } else {
                    config.warnings.append("line \(lineNumber): unknown table [[\(name)]]")
                    section = .unknown(name)
                }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                switch name {
                case "layout": section = .layout
                case "keys": section = .keys
                case "callbacks": section = .callbacks
                case "workspaces": section = .workspaces
                default:
                    config.warnings.append("line \(lineNumber): unknown section [\(name)]")
                    section = .unknown(name)
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError(line: lineNumber, message: "expected `key = value`")
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ConfigError(line: lineNumber, message: "missing key before `=`")
            }
            guard !rawValue.isEmpty else {
                throw ConfigError(line: lineNumber, message: "missing value for `\(key)`")
            }

            switch section {
            case .root:
                switch key {
                case "leader":
                    config.leader = try parseLeader(try string(rawValue, line: lineNumber), line: lineNumber)
                case "dock-icon":
                    config.showDockIcon = try bool(rawValue, line: lineNumber)
                case "menu-bar-icon":
                    config.showMenuBarIcon = try bool(rawValue, line: lineNumber)
                default:
                    config.warnings.append(unknownKey(key, in: nil, line: lineNumber))
                }

            case .layout:
                switch key {
                case "gaps":
                    let gaps = try number(rawValue, line: lineNumber, range: 0...100)
                    config.layout.innerGap = gaps
                    config.layout.outerGap = gaps
                case "inner-gaps":
                    config.layout.innerGap = try number(rawValue, line: lineNumber, range: 0...100)
                case "outer-gaps":
                    config.layout.outerGap = try number(rawValue, line: lineNumber, range: 0...100)
                case "accordion-padding":
                    config.layout.accordionPadding = try number(rawValue, line: lineNumber, range: 2...400)
                case "focus-border":
                    config.focusBorder = try bool(rawValue, line: lineNumber)
                case "default":
                    let value = try string(rawValue, line: lineNumber)
                    guard let layout = ContainerLayout(rawValue: value) else {
                        throw ConfigError(line: lineNumber, message: "`default` must be \"tiles\" or \"accordion\", got \"\(value)\"")
                    }
                    config.defaultLayout = layout
                default:
                    config.warnings.append(unknownKey(key, in: "layout", line: lineNumber))
                }

            case .keys:
                switch key {
                case "preset":
                    let value = try string(rawValue, line: lineNumber)
                    if ["default", "i3", "aerospace", "vim"].contains(value) {
                        config.keyPreset = value
                    } else {
                        config.warnings.append("line \(lineNumber): unknown key preset \"\(value)\" — using \"default\"")
                    }
                case "one-shot":
                    config.layerOneShot = try bool(rawValue, line: lineNumber)
                case "layer-timeout":
                    config.layerTimeout = try number(rawValue, line: lineNumber, range: 0...300)
                default:
                    config.warnings.append(unknownKey(key, in: "keys", line: lineNumber))
                }

            case .callbacks:
                switch key {
                case "on-workspace-changed":
                    config.onWorkspaceChanged = try stringArray(rawValue, line: lineNumber)
                default:
                    config.warnings.append(unknownKey(key, in: "callbacks", line: lineNumber))
                }

            case .workspaces:
                if let n = Int(key), (1...9).contains(n) {
                    config.workspaceNames[n] = try string(rawValue, line: lineNumber)
                } else if key == "float-by-default" {
                    config.floatByDefaultWorkspaces = try intArray(rawValue, line: lineNumber, range: 1...9)
                } else {
                    config.warnings.append(unknownKey(key, in: "workspaces", line: lineNumber))
                }

            case .rule(let idx):
                switch key {
                case "app": rules[idx].app = try string(rawValue, line: lineNumber)
                case "title": rules[idx].title = try string(rawValue, line: lineNumber)
                case "action": rules[idx].action = try string(rawValue, line: lineNumber)
                default:
                    config.warnings.append(unknownKey(key, in: "rules", line: lineNumber))
                }

            case .unknown:
                break // already warned at the section header
            }
        }

        // Never strand the user with no visible surface at all.
        if !config.showMenuBarIcon && !config.showDockIcon {
            config.warnings.append("menu-bar-icon and dock-icon are both off — reach Zephr via hotkeys, zephrctl, or by editing this file")
        }

        for rule in rules {
            guard let app = rule.app, !app.isEmpty else {
                throw ConfigError(line: rule.headerLine, message: "[[rules]] needs an `app` (bundle identifier)")
            }
            guard let actionName = rule.action else {
                throw ConfigError(line: rule.headerLine, message: "[[rules]] for \(app) needs an `action`")
            }
            let action: WindowRule.Action
            switch actionName {
            case "float": action = .float
            case "tile": action = .tile
            case "ignore": action = .ignore
            default:
                // "workspace N": this app's windows always open on workspace N.
                let parts = actionName.split(separator: " ")
                if parts.count == 2, parts[0] == "workspace", let n = Int(parts[1]), (1...9).contains(n) {
                    action = .workspace(n)
                } else {
                    throw ConfigError(line: rule.headerLine, message: "action must be \"float\", \"tile\", \"ignore\", or \"workspace N\", got \"\(actionName)\"")
                }
            }
            config.userRules.append(WindowRule(bundleID: app, titlePattern: rule.title, action: action))
        }

        return config
    }

    // MARK: - "Did you mean" (§4.6)

    private static let knownKeys: [String?: [String]] = [
        nil: ["leader", "dock-icon", "menu-bar-icon"],
        "layout": ["gaps", "inner-gaps", "outer-gaps", "accordion-padding", "focus-border", "default"],
        "keys": ["preset", "one-shot", "layer-timeout"],
        "callbacks": ["on-workspace-changed"],
        "workspaces": ["float-by-default"],
        "rules": ["app", "title", "action"],
    ]

    private static func unknownKey(_ key: String, in section: String?, line: Int) -> String {
        let place = section.map { " in [\($0)]" } ?? ""
        let candidates = knownKeys[section] ?? []
        if let best = candidates.min(by: { editDistance(key, $0) < editDistance(key, $1) }),
           editDistance(key, best) <= max(1, key.count / 3) {
            return "line \(line): unknown key `\(key)`\(place) — did you mean `\(best)`?"
        }
        return "line \(line): unknown key `\(key)`\(place)"
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = old
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    // MARK: - Value parsing

    private static func stripComment(_ line: String) -> String {
        var inString = false
        for (i, char) in line.enumerated() {
            if char == "\"" { inString.toggle() }
            if char == "#" && !inString {
                return String(line.prefix(i))
            }
        }
        return line
    }

    private static func string(_ raw: String, line: Int) throws -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            throw ConfigError(line: line, message: "expected a quoted string, got \(raw)")
        }
        return String(raw.dropFirst().dropLast())
    }

    private static func bool(_ raw: String, line: Int) throws -> Bool {
        switch raw {
        case "true": return true
        case "false": return false
        default: throw ConfigError(line: line, message: "expected true or false, got \(raw)")
        }
    }

    private static func number(_ raw: String, line: Int, range: ClosedRange<Double>) throws -> CGFloat {
        guard let value = Double(raw) else {
            throw ConfigError(line: line, message: "expected a number, got \(raw)")
        }
        guard range.contains(value) else {
            throw ConfigError(line: line, message: "\(Int(value)) is outside \(Int(range.lowerBound))–\(Int(range.upperBound))")
        }
        return CGFloat(value)
    }

    private static func intArray(_ raw: String, line: Int, range: ClosedRange<Int>) throws -> [Int] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            throw ConfigError(line: line, message: "expected an array like [7, 8]")
        }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return try inner.components(separatedBy: ",").map {
            let token = $0.trimmingCharacters(in: .whitespaces)
            guard let n = Int(token), range.contains(n) else {
                throw ConfigError(line: line, message: "expected numbers \(range.lowerBound)–\(range.upperBound), got \(token)")
            }
            return n
        }
    }

    private static func stringArray(_ raw: String, line: Int) throws -> [String] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            throw ConfigError(line: line, message: "expected an array like [\"…\"]")
        }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return try inner.components(separatedBy: ",").map {
            try string($0.trimmingCharacters(in: .whitespaces), line: line)
        }
    }

    private static func parseLeader(_ raw: String, line: Int) throws -> LeaderBinding {
        let parts = raw.lowercased().components(separatedBy: "-")
        guard parts.count >= 2 else {
            throw ConfigError(line: line, message: "leader needs modifiers, e.g. \"alt-space\"")
        }
        var binding = LeaderBinding(key: parts.last!)
        for modifier in parts.dropLast() {
            switch modifier {
            case "ctrl", "control": binding.control = true
            case "alt", "opt", "option": binding.option = true
            case "cmd", "command": binding.command = true
            case "shift": binding.shift = true
            default:
                throw ConfigError(line: line, message: "unknown modifier \"\(modifier)\" in leader")
            }
        }
        guard binding.control || binding.option || binding.command else {
            throw ConfigError(line: line, message: "leader needs at least one of ctrl/alt/cmd")
        }
        guard !binding.key.isEmpty else {
            throw ConfigError(line: line, message: "leader is missing its key")
        }
        return binding
    }
}
