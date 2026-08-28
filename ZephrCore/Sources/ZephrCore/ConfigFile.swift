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

    /// Every key name the config accepts for the leader chord. The app's
    /// HotkeyService key table must map each of these — anything else gets
    /// an inline warning and the default leader, so an unbindable leader is
    /// never a silent no-op and never rejects the rest of the file (§4.6).
    public static let knownKeyNames: Set<String> = {
        var names: Set<String> = ["space", "tab", "grave", "`"]
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            names.insert(String(UnicodeScalar(scalar)!))
        }
        for digit in 0...9 {
            names.insert(String(digit))
        }
        return names
    }()
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
    # title = "^Preferences"      # title regex — case-insensitive, matches anywhere; anchor with ^/$
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

        // CRLF files: normalize up front so reported line numbers match
        // what the user's editor shows (§4.6) and no stray \r survives
        // into values or writeback comparisons.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        // Duplicate `key =` lines in one table silently last-win otherwise;
        // TOML calls redefinition an error, we warn naming both lines (§4.6).
        var firstLineForKey: [String: Int] = [:]
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

            let sectionID: String?
            switch section {
            case .root: sectionID = ""
            case .layout: sectionID = "layout"
            case .keys: sectionID = "keys"
            case .callbacks: sectionID = "callbacks"
            case .workspaces: sectionID = "workspaces"
            case .rule(let idx): sectionID = "rules#\(idx)"
            case .unknown: sectionID = nil
            }
            if let sectionID {
                let dupKey = "\(sectionID)\u{1}\(key)"
                if let first = firstLineForKey[dupKey] {
                    config.warnings.append("line \(lineNumber): `\(key)` was already set on line \(first) — the last value wins")
                } else {
                    firstLineForKey[dupKey] = lineNumber
                }
            }

            switch section {
            case .root:
                switch key {
                case "leader":
                    let binding = try parseLeader(try string(rawValue, line: lineNumber), line: lineNumber)
                    // Only keys HotkeyService can bind are accepted — anything
                    // else would parse fine and then silently never open the
                    // layer. Warn and fall back to the default leader; one bad
                    // key must not revert the whole file (§4.6: a broken file
                    // never takes window management down).
                    if LeaderBinding.knownKeyNames.contains(binding.key) {
                        config.leader = binding
                    } else {
                        config.leader = .default
                        config.warnings.append("line \(lineNumber): \"\(binding.key)\" is not a bindable leader key — use a–z, 0–9, space, tab, or grave; using the default leader \"alt-space\"")
                    }
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

        for (ordinal, rule) in rules.enumerated() {
            guard let app = rule.app, !app.isEmpty else {
                throw ConfigError(line: rule.headerLine, message: "[[rules]] needs an `app` (bundle identifier)")
            }
            guard let actionName = rule.action else {
                throw ConfigError(line: rule.headerLine, message: "[[rules]] for \(app) needs an `action`")
            }
            if let pattern = rule.title {
                do {
                    try WindowRule.validateTitlePattern(pattern)
                } catch {
                    // A rule that can never fire is worse than silence (§4.6),
                    // but one dead rule must not reject the whole file either.
                    // Warn with the line number and drop just this rule.
                    config.warnings.append("line \(rule.headerLine): title regex \"\(pattern)\" for \(app) does not compile: \((error as NSError).localizedDescription) — rule skipped")
                    continue
                }
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
            config.userRules.append(WindowRule(bundleID: app, titlePattern: rule.title, action: action, sourceOrdinal: ordinal))
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
        var skipNext = false
        for index in line.indices {
            guard !skipNext else { skipNext = false; continue }
            let char = line[index]
            if inString {
                if char == "\\" { skipNext = true } // \" does not close the string
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func string(_ raw: String, line: Int) throws -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            throw ConfigError(line: line, message: "expected a quoted string, got \(raw)")
        }
        return decodeEscapes(String(raw.dropFirst().dropLast()))
    }

    /// TOML basic-string escapes. Unknown sequences (`\d`, `\s`, …) pass
    /// through untouched — title regexes lean on them and the interim
    /// parser stays lenient; P4's TOML engine tightens this.
    private static func decodeEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let char = s[i]
            i = s.index(after: i)
            guard char == "\\", i < s.endIndex else {
                out.append(char)
                continue
            }
            switch s[i] {
            case "\"": out.append("\""); i = s.index(after: i)
            case "\\": out.append("\\"); i = s.index(after: i)
            case "n": out.append("\n"); i = s.index(after: i)
            case "t": out.append("\t"); i = s.index(after: i)
            case "r": out.append("\r"); i = s.index(after: i)
            case "u", "U":
                let digits = s[i] == "u" ? 4 : 8
                let start = s.index(after: i)
                if let end = s.index(start, offsetBy: digits, limitedBy: s.endIndex),
                   let code = UInt32(s[start..<end], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    out.append(Character(scalar))
                    i = end
                } else {
                    out.append("\\") // malformed \uXXXX: keep it literally
                }
            default:
                out.append("\\") // unknown escape: keep it literally
            }
        }
        return out
    }

    private static func bool(_ raw: String, line: Int) throws -> Bool {
        switch raw {
        case "true": return true
        case "false": return false
        default: throw ConfigError(line: line, message: "expected true or false, got \(raw)")
        }
    }

    private static func number(_ raw: String, line: Int, range: ClosedRange<Double>) throws -> CGFloat {
        // `Double(raw)` happily parses "nan"/"inf"; formatting those (or
        // anything huge) through Int(value) traps. Reject non-finite up
        // front and format errors from the raw token — a config typo must
        // never be able to crash the app (invariant 1: a trap here strands
        // every stashed window off-screen).
        guard let value = Double(raw), value.isFinite else {
            throw ConfigError(line: line, message: "expected a number, got \(raw)")
        }
        guard range.contains(value) else {
            throw ConfigError(line: line, message: "\(raw) is outside \(Int(range.lowerBound))–\(Int(range.upperBound))")
        }
        return CGFloat(value)
    }

    private static func intArray(_ raw: String, line: Int, range: ClosedRange<Int>) throws -> [Int] {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else {
            throw ConfigError(line: line, message: "expected an array like [7, 8]")
        }
        let inner = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return try splitArrayBody(inner).map {
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
        return try splitArrayBody(inner).map {
            try string($0.trimmingCharacters(in: .whitespaces), line: line)
        }
    }

    /// Splits an array body on commas that sit outside quoted strings, so
    /// a comma inside a command (`"sketchybar --set a b=1,2"`) survives.
    /// A trailing comma is tolerated.
    private static func splitArrayBody(_ inner: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var inString = false
        var skipNext = false
        for char in inner {
            if skipNext {
                current.append(char)
                skipNext = false
            } else if inString {
                current.append(char)
                if char == "\\" { skipNext = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
                current.append(char)
            } else if char == "," {
                elements.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        elements.append(current)
        if let last = elements.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            elements.removeLast()
        }
        return elements
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
        // Whether the key is one HotkeyService can bind is checked at the
        // call site: an unbindable key is a warning plus the default leader,
        // not a parse failure (§4.6).
        return binding
    }
}
