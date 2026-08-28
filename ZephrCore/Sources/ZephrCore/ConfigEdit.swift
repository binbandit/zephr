import Foundation

/// Line-targeted edits to `config.toml`, kept pure (`[String] -> [String]`)
/// so the whole read/modify/write round trip can be tested against
/// `ConfigFile.parse`. The app layer owns file IO, hot reload and error
/// surfacing; every decision about *where a character goes* lives here.
///
/// The contract is §4.6's round-trip guarantee: a hand-edited config survives
/// GUI use untouched except for the keys actually changed — comments,
/// ordering, blank lines and comment columns all preserved.
public enum ConfigEdit {

    public struct RuleEdit: Equatable, Sendable {
        public var app: String
        public var title: String?
        public var action: String

        public init(app: String, title: String? = nil, action: String) {
            self.app = app
            self.title = title
            self.action = action
        }
    }

    // MARK: - Lexical helpers

    /// Splits a line into its body and any trailing comment, respecting
    /// quoted strings and backslash escapes.
    ///
    /// The single authority on where a comment starts. Four separate
    /// implementations of this used to disagree — one of them escape-blind,
    /// one absent entirely — which is how `removeRule` came to silently
    /// no-op on any rule carrying a trailing comment.
    public static func splitComment(_ line: String) -> (body: String, comment: String?) {
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
                return (String(line[..<index]), String(line[index...]))
            }
        }
        return (line, nil)
    }

    /// The table name a line declares, `[[rules]]` included, or nil.
    public static func header(_ line: String) -> String? {
        let body = splitComment(line).body.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        return body
    }

    /// The table name a *commented-out* line declares, or nil. The shipped
    /// defaults comment out `[workspaces]` and `[[rules]]` as examples, so
    /// these lines bound a section just as firmly as a live header: a key
    /// written past one lands inside an example block the user is invited to
    /// uncomment, and uncommenting then captures or invalidates it.
    public static func commentedHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return header(String(trimmed.dropFirst()))
    }

    /// Where a section ends: the next header, live or commented.
    static func isSectionBoundary(_ line: String) -> Bool {
        header(line) != nil || commentedHeader(line) != nil
    }

    /// The raw (still TOML-encoded) value of `key` on this line, or nil.
    static func value(of line: String, key: String) -> String? {
        let body = splitComment(line).body.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix(key) else { return nil }
        let rest = body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        let raw = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2
            ? String(raw.dropFirst().dropLast())
            : raw
    }

    static func declaresKey(_ line: String, key: String) -> Bool {
        let body = splitComment(line).body.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix(key) else { return false }
        return body.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    /// `value` as a TOML basic string — quoted, with `\`, `"`, and control
    /// characters escaped. Every GUI-originated string must pass through
    /// this: the veto-float learner writes real window titles, and a title
    /// like `Say "hi"` interpolated verbatim yields a config that no longer
    /// parses — the user's edits then silently stop applying.
    public static func tomlQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            // NB: no `\b`/`\f` shorthand. The parser deliberately passes
            // unknown escapes through literally so a `title` regex keeps its
            // `\b` word boundary and `\d`; decoding `\b` as backspace would
            // break far more configs than it fixes. Emitting the `\uXXXX`
            // form instead keeps writer and parser exact inverses.
            case let c where c.value < 0x20 || c.value == 0x7F:
                out += String(format: "\\u%04X", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Edits

    /// Sets `key` in `section` (nil = the root table), rewriting only that
    /// line. Creates the section if it is missing, reusing a commented-out
    /// header rather than appending a look-alike duplicate.
    public static func setValue(
        _ lines: [String], section: String?, key: String, value: String
    ) -> [String] {
        var lines = lines
        let assignment = "\(key) = \(value)"

        var start = 0
        var end = lines.count

        if let section {
            let wanted = "[\(section)]"
            if let headerIndex = lines.firstIndex(where: { header($0) == wanted }) {
                start = headerIndex + 1
                end = lines[start...].firstIndex(where: isSectionBoundary) ?? lines.count
            } else if let commented = lines.firstIndex(where: { commentedHeader($0) == wanted }) {
                // Uncomment the shipped example header and open the section
                // right there. Inserting immediately after it keeps the key
                // clear of the commented example keys that follow, which the
                // user may uncomment later.
                lines[commented] = uncommented(lines[commented])
                lines.insert(assignment, at: commented + 1)
                return lines
            } else {
                while lines.last?.isEmpty == true { lines.removeLast() }
                lines.append(contentsOf: ["", wanted, assignment])
                return lines
            }
        } else {
            end = lines.firstIndex(where: isSectionBoundary) ?? lines.count
        }

        if let idx = lines[start..<end].firstIndex(where: { declaresKey($0, key: key) }) {
            lines[idx] = rewriting(lines[idx], as: assignment)
        } else {
            var insertAt = end
            while insertAt > start, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(assignment, at: insertAt)
        }
        return lines
    }

    /// Appends `[[rules]]` blocks. User rules run before the shipped list,
    /// and duplicates are skipped so a re-import cannot stack identical
    /// blocks that the Settings list then cannot tell apart.
    public static func addRules(_ lines: [String], _ rules: [RuleEdit]) -> [String] {
        var lines = lines
        var present = self.rules(in: lines).map(\.rule)
        var appended = false
        for rule in rules where !present.contains(rule) {
            if !appended {
                while lines.last?.isEmpty == true { lines.removeLast() }
                appended = true
            }
            present.append(rule)
            lines.append(contentsOf: ["", "[[rules]]", "app = \(tomlQuoted(rule.app))"])
            if let title = rule.title, !title.isEmpty {
                lines.append("title = \(tomlQuoted(title))")
            }
            lines.append("action = \(tomlQuoted(rule.action))")
        }
        return lines
    }

    /// Every `[[rules]]` block in file order, with the line range it spans.
    /// Order is the only reliable identity: two rules for the same app
    /// differing only in action are indistinguishable by content, and
    /// matching on content deleted whichever came first.
    public static func rules(in lines: [String]) -> [(rule: RuleEdit, range: Range<Int>)] {
        var found: [(rule: RuleEdit, range: Range<Int>)] = []
        var start: Int?
        var app: String?
        var title: String?
        var action: String?

        func close(at index: Int) {
            if let start, let app {
                found.append((RuleEdit(app: app, title: title, action: action ?? "float"), start..<index))
            }
            start = nil; app = nil; title = nil; action = nil
        }

        for index in lines.indices {
            if isSectionBoundary(lines[index]) {
                close(at: index)
                if header(lines[index]) == "[[rules]]" { start = index }
            } else if start != nil {
                if let v = value(of: lines[index], key: "app") { app = v }
                if let v = value(of: lines[index], key: "title") { title = v }
                if let v = value(of: lines[index], key: "action") { action = v }
            }
        }
        close(at: lines.count)
        return found
    }

    /// Removes the `ordinal`-th `[[rules]]` block in file order.
    public static func removeRule(_ lines: [String], at ordinal: Int) -> [String] {
        let blocks = rules(in: lines)
        guard blocks.indices.contains(ordinal) else { return lines }
        var lines = lines
        let range = blocks[ordinal].range

        // Take exactly one separating blank line with the block — the
        // trailing one when the range already ends in it, else the leading
        // one. Eating both would collapse a hand-formatted file's spacing a
        // little further on every add/remove cycle.
        var from = range.lowerBound
        let hasTrailingBlank = range.upperBound > range.lowerBound
            && lines[range.upperBound - 1].trimmingCharacters(in: .whitespaces).isEmpty
        if !hasTrailingBlank, from > 0,
           lines[from - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            from -= 1
        }
        lines.removeSubrange(from..<range.upperBound)
        return lines
    }

    // MARK: - Line rendering

    /// Replaces a line's assignment while keeping its trailing comment at
    /// the column it already occupied, so editing `gaps` does not reflow the
    /// aligned comment block the shipped defaults ship with.
    private static func rewriting(_ line: String, as assignment: String) -> String {
        let (body, comment) = splitComment(line)
        guard let comment else { return assignment }
        let column = body.count
        let padding = max(2, column - assignment.count)
        return assignment + String(repeating: " ", count: padding) + comment
    }

    /// Drops the leading `#` (and one following space) from a commented line.
    private static func uncommented(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        var rest = line[line.index(after: hash)...]
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return String(line[..<hash]) + rest
    }
}
