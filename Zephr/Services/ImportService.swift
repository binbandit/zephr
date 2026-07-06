import AppKit
import ZephrCore

/// Migration as a feature (§4.7): pulls settings out of AeroSpace and
/// Amethyst into config.toml, with a plain-language report.
@MainActor
enum ImportService {

    struct Outcome {
        var report: String
        var rulesAdded: Int
    }

    static func aerospaceConfigPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AeroSpaceImport.candidatePaths(home: home)
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func amethystFloatList() -> [String] {
        guard let value = CFPreferencesCopyAppValue(
            "floating" as CFString,
            "com.amethyst.Amethyst" as CFString
        ) else { return [] }
        if let ids = value as? [String] { return ids }
        if let dicts = value as? [[String: Any]] {
            return dicts.compactMap { $0["id"] as? String }
        }
        return []
    }

    static var anythingToImport: Bool {
        aerospaceConfigPath() != nil || !amethystFloatList().isEmpty
    }

    /// Runs the import, writing into config.toml via the targeted editor
    /// (hot reload applies everything immediately).
    static func run(config: ConfigService) -> Outcome {
        var sections: [String] = []
        var rulesAdded = 0
        let existing = config.current.userRules

        if let path = aerospaceConfigPath(),
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let result = AeroSpaceImport.parse(text)
            if let gaps = result.gaps {
                config.setValue(section: "layout", key: "gaps", value: "\(Int(gaps))")
            }
            for rule in result.rules where !existing.contains(rule) {
                let action: String = switch rule.action {
                case .float: "float"
                case .tile: "tile"
                case .ignore: "ignore"
                case .workspace: "float"
                }
                config.addRule(app: rule.bundleID, title: rule.titlePattern, action: action)
                rulesAdded += 1
            }
            sections.append("AeroSpace (\((path as NSString).abbreviatingWithTildeInPath)):\n\(result.report)")
        } else {
            sections.append("AeroSpace: no config found.")
        }

        let amethyst = amethystFloatList()
        if !amethyst.isEmpty {
            var added = 0
            for bundleID in amethyst where !existing.contains(where: { $0.bundleID == bundleID && $0.action == .float }) {
                config.addRule(app: bundleID, title: nil, action: "float")
                added += 1
                rulesAdded += 1
            }
            sections.append("Amethyst: imported \(added) float rule(s).")
        }

        sections.append("Rectangle: nothing to import — its snapping shortcuts are superseded by tiling itself.")
        return Outcome(report: sections.joined(separator: "\n\n"), rulesAdded: rulesAdded)
    }

    static func runAndShowReport(config: ConfigService) {
        let outcome = run(config: config)
        let alert = NSAlert()
        alert.messageText = "Import complete — \(outcome.rulesAdded) rule(s) added"
        alert.informativeText = outcome.report
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open Config")
        if alert.runModal() == .alertSecondButtonReturn {
            config.openInEditor()
        }
    }
}
