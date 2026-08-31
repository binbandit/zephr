import Foundation
import CoreGraphics

/// AeroSpace migration (§4.7): reads `.aerospace.toml`, maps what has a
/// Zephr equivalent (gaps, per-app float/ignore rules), and produces the
/// plain-language report of what mapped and what didn't.
public enum AeroSpaceImport {

    public struct Result: Sendable, Equatable {
        /// Gap sizes mapped from `[gaps]` `inner.*` / `outer.*` keys — the
        /// first numeric value per side wins (Zephr has one gap per side
        /// class). 0 is meaningful: flush tiling imports as flush tiling.
        public var innerGaps: CGFloat?
        public var outerGaps: CGFloat?
        public var rules: [WindowRule] = []
        public var imported: [String] = []
        public var skipped: [String] = []

        public var report: String {
            var lines: [String] = []
            if !imported.isEmpty {
                lines.append("Imported (\(imported.count)):")
                lines.append(contentsOf: imported.map { "  ✓ \($0)" })
            }
            if !skipped.isEmpty {
                lines.append("Not imported (\(skipped.count)):")
                lines.append(contentsOf: skipped.map { "  – \($0)" })
            }
            if lines.isEmpty { lines.append("Nothing recognizable found.") }
            return lines.joined(separator: "\n")
        }
    }

    /// Well-known config locations, in AeroSpace's own lookup order.
    public static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.aerospace.toml",
            "\(home)/.config/aerospace/aerospace.toml",
        ]
    }

    public static func parse(_ text: String) -> Result {
        var result = Result()
        var bindingCount = 0
        var currentWindowRule: (appID: String?, titleSub: String?, runs: [String])?
        var inBindingSection = false
        var section = ""

        func flushWindowRule() {
            guard let rule = currentWindowRule else { return }
            currentWindowRule = nil
            guard let app = rule.appID, !app.isEmpty else {
                result.skipped.append("an on-window-detected rule without an if.app-id (Zephr matches by bundle id)")
                return
            }
            // A quote or whitespace surviving into the id means the source
            // line didn't parse cleanly — importing it would write a rule
            // that can never match (§4.7: the report stays honest).
            guard !app.contains("\""), !app.contains("'"), !app.contains(where: \.isWhitespace) else {
                result.skipped.append("if.app-id \(app) does not look like a bundle id - fix the AeroSpace config and re-import")
                return
            }
            let runs = rule.runs.joined(separator: "; ")
            let title = rule.titleSub.map { NSRegularExpression.escapedPattern(for: $0) }
            if runs.contains("layout floating") {
                result.rules.append(WindowRule(bundleID: app, titlePattern: title, action: .float))
                result.imported.append("float \(app)\(rule.titleSub.map { " (title ~ \($0))" } ?? "")")
            } else if runs.contains("layout tiling") {
                result.rules.append(WindowRule(bundleID: app, titlePattern: title, action: .tile))
                result.imported.append("tile \(app)")
            } else if runs.contains("move-node-to-workspace") {
                result.skipped.append("\(app): move-to-workspace rules (config support lands with the P4 settings engine - use Zephr's ⇧1–9 for now)")
            } else if runs.isEmpty {
                result.skipped.append("\(app): rule had no run command")
            } else {
                result.skipped.append("\(app): run = \(runs) has no Zephr equivalent")
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") {
                flushWindowRule()
                section = String(line.dropFirst(2).dropLast(2))
                inBindingSection = false
                if section == "on-window-detected" {
                    currentWindowRule = (nil, nil, [])
                }
                continue
            }
            if line.hasPrefix("[") {
                flushWindowRule()
                section = String(line.dropFirst().dropLast())
                inBindingSection = section.hasPrefix("mode.") && section.hasSuffix(".binding")
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if inBindingSection {
                bindingCount += 1
                continue
            }

            if section == "gaps" || section.hasPrefix("gaps.") {
                // Keys arrive as `inner.horizontal = 8` under [gaps] or as
                // `horizontal = 8` under [gaps.inner]; normalize to one form.
                let fullKey = section == "gaps" ? key : "\(section.dropFirst("gaps.".count)).\(key)"
                guard let number = Double(value), number.isFinite else {
                    result.skipped.append("gaps \(fullKey) = \(value): only plain numbers map (per-monitor gap lists have no Zephr equivalent)")
                    continue
                }
                guard (0...100).contains(number) else {
                    result.skipped.append("gaps \(fullKey) = \(value): outside Zephr's 0–100 gap range")
                    continue
                }
                switch fullKey.split(separator: ".").first {
                case "inner":
                    if result.innerGaps == nil {
                        result.innerGaps = CGFloat(number)
                        result.imported.append("inner gaps = \(Int(number))")
                    } else if result.innerGaps != CGFloat(number) {
                        result.skipped.append("gaps \(fullKey) = \(value): Zephr has a single inner gap (keeping \(Int(result.innerGaps!)))")
                    }
                case "outer":
                    if result.outerGaps == nil {
                        result.outerGaps = CGFloat(number)
                        result.imported.append("outer gaps = \(Int(number))")
                    } else if result.outerGaps != CGFloat(number) {
                        result.skipped.append("gaps \(fullKey) = \(value): Zephr has a single outer gap (keeping \(Int(result.outerGaps!)))")
                    }
                default:
                    result.skipped.append("gaps \(fullKey) = \(value): no Zephr equivalent")
                }
                continue
            }

            if currentWindowRule != nil {
                switch key {
                case "if.app-id":
                    currentWindowRule?.appID = unquote(value)
                case "if.window-title-regex-substring":
                    currentWindowRule?.titleSub = unquote(value)
                case "run":
                    currentWindowRule?.runs = parseRuns(value)
                case "check-further-callbacks", "if.during-aerospace-startup", "if.workspace":
                    break
                default:
                    break
                }
                continue
            }
        }
        flushWindowRule()

        if bindingCount > 0 {
            result.skipped.append("\(bindingCount) keybindings - Zephr ships its own scheme; set `preset = \"aerospace\"` in [keys] for ⌥-style chords")
        }
        return result
    }

    /// Removes a `#` comment, tracking TOML quote state — `"` (with `\`
    /// escapes) and literal `'` — so a `#` inside a value survives and a
    /// trailing comment after a quoted value is actually stripped.
    private static func stripComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var skipNext = false
        for index in line.indices {
            guard !skipNext else { skipNext = false; continue }
            let char = line[index]
            if inDouble {
                if char == "\\" { skipNext = true }
                else if char == "\"" { inDouble = false }
            } else if inSingle {
                if char == "'" { inSingle = false }
            } else {
                switch char {
                case "\"": inDouble = true
                case "'": inSingle = true
                case "#": return String(line[..<index])
                default: break
                }
            }
        }
        return line
    }

    private static func unquote(_ raw: String) -> String {
        var s = raw
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func parseRuns(_ raw: String) -> [String] {
        if raw.hasPrefix("[") {
            return raw.dropFirst().dropLast()
                .components(separatedBy: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        return [unquote(raw)]
    }
}
