import Foundation
import CoreGraphics

/// AeroSpace migration (§4.7): reads `.aerospace.toml`, maps what has a
/// Zephr equivalent (gaps, per-app float/ignore rules), and produces the
/// plain-language report of what mapped and what didn't.
public enum AeroSpaceImport {

    public struct Result: Sendable, Equatable {
        public var gaps: CGFloat?
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
            guard let app = rule.appID else {
                result.skipped.append("an on-window-detected rule without if.app-id (Zephr matches by bundle id)")
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
                result.skipped.append("\(app): move-to-workspace rules (config support lands with the P4 settings engine — use Zephr's ⇧1–9 for now)")
            } else if runs.isEmpty {
                result.skipped.append("\(app): rule had no run command")
            } else {
                result.skipped.append("\(app): run = \(runs) has no Zephr equivalent")
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#"), !line.contains("\"") || hash == line.startIndex {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
            }
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
                if let number = Double(value), result.gaps == nil, number > 0 {
                    result.gaps = CGFloat(number)
                    result.imported.append("gaps = \(Int(number))")
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
            result.skipped.append("\(bindingCount) keybindings — Zephr ships its own scheme; set `preset = \"aerospace\"` in [keys] for ⌥-style chords")
        }
        return result
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
