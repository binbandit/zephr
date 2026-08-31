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

    /// Every key name the config accepts for the leader chord, mapped to its
    /// virtual key code.
    ///
    /// Core owns this because it is plain data — the `kVK_ANSI_*` constants
    /// are integers, not AppKit — and because the two halves have to agree:
    /// a name the parser accepts but the event tap cannot map would parse
    /// cleanly and then silently leave the old leader bound, the exact
    /// failure §4.6 forbids. One table means they cannot drift.
    public static let keyCodesByName: [String: Int64] = {
        var codes: [String: Int64] = ["space": 49, "tab": 48, "grave": 50, "`": 50]
        let letters: [Int64] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
            45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        ]
        for (offset, scalar) in (UnicodeScalar("a").value...UnicodeScalar("z").value).enumerated() {
            codes[String(UnicodeScalar(scalar)!)] = letters[offset]
        }
        // ANSI digit row, 0 first.
        let digits: [Int64] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (digit, code) in digits.enumerated() {
            codes[String(digit)] = code
        }
        return codes
    }()

    /// Names the config accepts for the leader chord. Anything else gets an
    /// inline warning and the default leader, so an unbindable leader is
    /// never a silent no-op and never rejects the rest of the file (§4.6).
    public static var knownKeyNames: Set<String> { Set(keyCodesByName.keys) }
}

/// Result of parsing a config file. Every field has the shipped default, so
/// an empty file — or no file at all — is a complete, working configuration.
public struct ParsedConfig: Sendable, Equatable {
    public var leader: LeaderBinding = .default
    public var layout: LayoutConfig = .default
    public var focusBorder: FocusBorderStyle = .default
    public var defaultLayout: ContainerLayout = .tiles
    public var keyPreset: String = "default"
    public var userRules: [WindowRule] = []
    /// Key bindings from `[[bind]]`, checked before the preset's defaults so
    /// a user can override any key without redefining the rest.
    public var bindings: [KeyBinding] = []
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
    # Zephr configuration - ~/.config/zephr/config.toml
    # Everything here is optional; these are the defaults. Zephr reloads this
    # file the moment you save it. Errors show in the menu bar, never silently.

    leader = "alt-space"          # e.g. "ctrl-alt-space", "cmd-alt-space"
    menu-bar-icon = true          # the status-bar workspace indicator

    [layout]
    gaps = 8                      # points between windows and screen edges
    accordion-padding = 48        # collapsed sliver width in accordion layout
    focus-border = true           # accent border on the focused window
    default = "tiles"             # tiles | accordion
    # focus-border-color = "#7AA2F7CC"  # hex, alpha optional; "accent" follows macOS
    # focus-border-width = 2            # outline thickness in points
    # focus-border-radius = 19          # outline corner radius; 0 for square corners

    [keys]
    preset = "default"            # default: ⌃⌥ chords · i3: ⌘⌥ · aerospace: bare ⌥ (breaks ⌥-typing!) · vim: leader-only

    # [workspaces]                # optional names and per-workspace behavior
    # 1 = "code"
    # 4 = "chat"
    # float-by-default = [9]      # workspaces where new windows float (junk drawer)

    # Per-app rules - first match wins; checked before Zephr's built-in list.
    # [[rules]]
    # app = "com.example.app"     # bundle identifier
    # title = "^Preferences"      # title regex - case-insensitive, matches anywhere; anchor with ^/$
    # action = "float"            # float | tile | ignore | workspace N

    # Rebind any key. `command` is the same vocabulary zephrctl speaks, so
    # anything you can run from the shell you can bind here.
    # [[bind]]
    # key = "ctrl-alt-b"          # a chord, or "leader b" for the layer
    # command = "balance"         # focus left · workspace 3 · summon 2 · ...

    [callbacks]
    on-workspace-changed = []     # shell commands; $ZEPHR_WORKSPACE is set
    """

    private enum Section {
        case root, layout, keys, callbacks, workspaces, rule(Int), bind(Int), unknown(String)
    }

    public static func parse(_ text: String) throws -> ParsedConfig {
        var config = ParsedConfig()
        var section = Section.root
        var rules: [PartialRule] = []

        struct PartialBind {
            var key: String?
            var command: String?
            var headerLine: Int
        }
        var binds: [PartialBind] = []

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
                } else if name == "bind" {
                    binds.append(PartialBind(headerLine: lineNumber))
                    section = .bind(binds.count - 1)
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
                // TOML reads `key = #7AA2F7` as an empty value followed by a
                // comment. A hex color is the one value users naturally type
                // with a bare `#`, and "missing value" alone leaves them
                // staring at a line that looks perfectly fine.
                let typed = rawLine.drop { $0 != "=" }.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                let hint = typed.hasPrefix("#")
                    ? " - `#` starts a comment; quote it as \"\(typed)\""
                    : ""
                throw ConfigError(line: lineNumber, message: "missing value for `\(key)`\(hint)")
            }

            let sectionID: String?
            switch section {
            case .root: sectionID = ""
            case .layout: sectionID = "layout"
            case .keys: sectionID = "keys"
            case .callbacks: sectionID = "callbacks"
            case .workspaces: sectionID = "workspaces"
            case .rule(let idx): sectionID = "rules#\(idx)"
            case .bind(let idx): sectionID = "bind#\(idx)"
            case .unknown: sectionID = nil
            }
            if let sectionID {
                let dupKey = "\(sectionID)\u{1}\(key)"
                if let first = firstLineForKey[dupKey] {
                    config.warnings.append("line \(lineNumber): `\(key)` was already set on line \(first) - the last value wins")
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
                        config.warnings.append("line \(lineNumber): \"\(binding.key)\" is not a bindable leader key - use a–z, 0–9, space, tab, or grave; using the default leader \"alt-space\"")
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
                    config.focusBorder.enabled = try bool(rawValue, line: lineNumber)
                // The three appearance keys warn and keep their default
                // rather than throwing. A bad `gaps` changes where every
                // window lands, so holding the whole file back is right; the
                // border only paints, and losing every other edit in the same
                // save over a mistyped color is the worse trade (§4.6, the
                // same call as an unbindable leader key).
                case "focus-border-color":
                    let value = try string(rawValue, line: lineNumber)
                    if value.caseInsensitiveCompare("accent") == .orderedSame {
                        config.focusBorder.color = nil
                    } else if let color = RGBAColor(hex: value) {
                        config.focusBorder.color = color
                    } else {
                        config.focusBorder.color = nil
                        config.warnings.append("line \(lineNumber): \"\(value)\" is not a color - use \"accent\" or a hex like \"#7AA2F7\" or \"#7AA2F7CC\"; using the accent color")
                    }
                case "focus-border-width":
                    if let width = optionalNumber(rawValue, range: 0.5...20) {
                        config.focusBorder.width = width
                    } else {
                        config.warnings.append("line \(lineNumber): `focus-border-width` must be a number from 0.5 to 20, got \(rawValue) - using the default")
                    }
                case "focus-border-radius":
                    if let radius = optionalNumber(rawValue, range: 0...64) {
                        config.focusBorder.cornerRadius = radius
                    } else {
                        config.warnings.append("line \(lineNumber): `focus-border-radius` must be a number from 0 to 64, got \(rawValue) - matching the system window corners")
                    }
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
                        config.warnings.append("line \(lineNumber): unknown key preset \"\(value)\" - using \"default\"")
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

            case .bind(let idx):
                switch key {
                case "key": binds[idx].key = try string(rawValue, line: lineNumber)
                case "command": binds[idx].command = try string(rawValue, line: lineNumber)
                default:
                    config.warnings.append(unknownKey(key, in: "bind", line: lineNumber))
                }

            case .unknown:
                break // already warned at the section header
            }
        }

        // Never strand the user with no visible surface at all.
        if !config.showMenuBarIcon && !config.showDockIcon {
            config.warnings.append("menu-bar-icon and dock-icon are both off - reach Zephr via hotkeys, zephrctl, or by editing this file")
        }

        // Key bindings. A binding that cannot be understood is dropped with
        // a warning rather than throwing: an unknown command name should not
        // cost the user every other setting in the same save, and the same
        // call is already made for an unbindable leader and a bad rule regex.
        for bind in binds {
            guard let raw = bind.key, !raw.isEmpty else {
                config.warnings.append("line \(bind.headerLine): [[bind]] needs a `key` - binding skipped")
                continue
            }
            guard let name = bind.command, !name.isEmpty else {
                config.warnings.append("line \(bind.headerLine): [[bind]] for \(raw) needs a `command` - binding skipped")
                continue
            }
            guard let (trigger, keyName) = KeyBinding.parseTrigger(raw) else {
                config.warnings.append("line \(bind.headerLine): `\(raw)` is not a key - use \"leader b\" or a chord like \"ctrl-alt-b\" - binding skipped")
                continue
            }
            guard LeaderBinding.knownKeyNames.contains(keyName) else {
                config.warnings.append("line \(bind.headerLine): `\(keyName)` is not a bindable key - binding skipped")
                continue
            }
            guard let command = Command.parse(name) else {
                config.warnings.append("line \(bind.headerLine): `\(name)` is not a command - binding skipped")
                continue
            }
            config.bindings.append(KeyBinding(trigger: trigger, key: keyName, command: command))
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
                    config.warnings.append("line \(rule.headerLine): title regex \"\(pattern)\" for \(app) does not compile: \((error as NSError).localizedDescription) - rule skipped")
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
        "layout": [
            "gaps", "inner-gaps", "outer-gaps", "accordion-padding", "default",
            "focus-border", "focus-border-color", "focus-border-width", "focus-border-radius",
        ],
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
            return "line \(line): unknown key `\(key)`\(place) - did you mean `\(best)`?"
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

    /// `number` for keys that warn instead of throwing: nil covers "not a
    /// number", "not finite" and "out of range" alike, because the caller
    /// says the same thing about all three.
    private static func optionalNumber(_ raw: String, range: ClosedRange<Double>) -> CGFloat? {
        guard let value = Double(raw), value.isFinite, range.contains(value) else { return nil }
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
