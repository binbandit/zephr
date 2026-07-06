import AppKit
import os
import ZephrCore

/// Owns `~/.config/zephr/config.toml` (§4.6): writes the commented defaults
/// on first run, hot-reloads on every save, and surfaces parse errors in the
/// menu bar — never silently. Interim parser; the lossless TOML engine with
/// the GUI round-trip guarantee lands in P4.
@MainActor
final class ConfigService {

    let url: URL
    var onApply: ((ParsedConfig) -> Void)?
    var onError: ((String?) -> Void)?
    /// Last successfully parsed config (what the Settings GUI reads).
    private(set) var current = ParsedConfig()

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var reloadDebounce: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.zephr", category: "config")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        url = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zephr", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    func start() {
        ensureFileExists()
        load()
        watch()
    }

    func openInEditor() {
        ensureFileExists()
        if !NSWorkspace.shared.open(url) {
            // No .toml handler registered: fall back to the default text editor.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-t", url.path]
            try? process.run()
        }
    }

    func setLeader(_ value: String) {
        setValue(section: nil, key: "leader", value: "\"\(value)\"")
    }

    /// Targeted writes — the round-trip guarantee (§4.6): only the changed
    /// key's value is touched; comments (including the changed line's own
    /// trailing comment), ordering, and formatting survive.
    func setValue(section: String?, key: String, value: String) {
        ensureFileExists()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")

        func isHeader(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
        func matchesKey(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { return false }
            let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("=")
        }
        func trailingComment(_ line: String) -> String? {
            var inString = false
            for (i, char) in line.enumerated() {
                if char == "\"" { inString.toggle() }
                if char == "#" && !inString {
                    return String(line.suffix(line.count - i))
                }
            }
            return nil
        }

        // Locate the section's line range.
        var start = 0
        var end = lines.count
        if let section {
            guard let headerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "[\(section)]"
            }) else {
                lines.append(contentsOf: ["", "[\(section)]", "\(key) = \(value)"])
                write(lines)
                return
            }
            start = headerIndex + 1
            end = lines[start...].firstIndex(where: isHeader) ?? lines.count
        } else {
            end = lines.firstIndex(where: isHeader) ?? lines.count
        }

        if let idx = lines[start..<end].firstIndex(where: matchesKey) {
            let comment = trailingComment(lines[idx])
            lines[idx] = "\(key) = \(value)" + (comment.map { "  \($0)" } ?? "")
        } else {
            var insertAt = end
            while insertAt > start, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert("\(key) = \(value)", at: insertAt)
        }
        write(lines)
    }

    /// Appends a `[[rules]]` block (user rules run before the shipped list).
    func addRule(app: String, title: String?, action: String) {
        ensureFileExists()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append(contentsOf: ["", "[[rules]]", "app = \"\(app)\""])
        if let title, !title.isEmpty {
            lines.append("title = \"\(title)\"")
        }
        lines.append("action = \"\(action)\"")
        write(lines)
    }

    /// Removes the first `[[rules]]` block matching app (+ title if given).
    func removeRule(app: String, title: String?) {
        ensureFileExists()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")

        var blockStart: Int?
        var blockApp: String?
        var blockTitle: String?
        func value(of line: String, key: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key),
                  let eq = trimmed.firstIndex(of: "=") else { return nil }
            let raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2
                ? String(raw.dropFirst().dropLast()) : raw
        }

        for index in 0...lines.count {
            let isEnd = index == lines.count
            let trimmed = isEnd ? "[" : lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") || isEnd {
                if let start = blockStart, blockApp == app, (title == nil || blockTitle == title) {
                    var removeFrom = start
                    if removeFrom > 0, lines[removeFrom - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                        removeFrom -= 1
                    }
                    lines.removeSubrange(removeFrom..<index)
                    write(lines)
                    return
                }
                blockStart = trimmed == "[[rules]]" ? index : nil
                blockApp = nil
                blockTitle = nil
            } else if blockStart != nil {
                if let v = value(of: lines[index], key: "app") { blockApp = v }
                if let v = value(of: lines[index], key: "title") { blockTitle = v }
            }
        }
    }

    private func write(_ lines: [String]) {
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        load()
        watch()
    }

    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (ConfigFile.defaultText + "\n").write(to: url, atomically: true, encoding: .utf8)
            Self.log.info("wrote default config to \(self.url.path)")
        } catch {
            Self.log.error("could not create config: \(error.localizedDescription)")
        }
    }

    private func load() {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            onError?("config unreadable: \(error.localizedDescription)")
            return
        }
        do {
            let parsed = try ConfigFile.parse(text)
            for warning in parsed.warnings {
                Self.log.warning("config \(warning)")
            }
            onError?(parsed.warnings.first)
            current = parsed
            onApply?(parsed)
        } catch let error as ConfigError {
            Self.log.error("config \(error.description)")
            onError?("config.toml \(error.description)")
            // Keep running on the previous (or default) config — a typo must
            // never take window management down.
        } catch {
            onError?("config parse failed: \(error.localizedDescription)")
        }
    }

    /// Watches the file's vnode. Editors save atomically (write + rename),
    /// which kills the watched node — on delete/rename we re-arm on the new
    /// file after the reload.
    private func watch() {
        cancelWatch()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                ConfigServiceBox.shared?.fileChanged()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        ConfigServiceBox.shared = self
    }

    private func cancelWatch() {
        watcher?.cancel()
        watcher = nil
    }

    fileprivate func fileChanged() {
        reloadDebounce?.cancel()
        reloadDebounce = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.ensureFileExists()
            self.load()
            self.watch() // re-arm: the saved file may be a new vnode
        }
    }
}

/// Static hop for the dispatch-source handler (main queue → MainActor).
@MainActor
private enum ConfigServiceBox {
    static weak var shared: ConfigService?
}
