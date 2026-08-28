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
    /// The line terminator of the file as last read, restored on write. Set by
    /// `splitLines`; every read/modify/write pair below runs to completion on
    /// the MainActor, so it is always current for the matching `write`.
    private var lineEnding = "\n"
    /// Whether `onApply` has fired at least once. The first load must apply
    /// even though it equals the default-constructed `current`.
    private var hasApplied = false
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

    /// Targeted writes — the round-trip guarantee (§4.6): only the changed
    /// key's value is touched; comments (including the changed line's own
    /// trailing comment and its column), ordering, and formatting survive.
    /// The line surgery itself lives in `ConfigEdit` so the test suite can
    /// round-trip it against the parser; this layer is file IO only.
    func setValue(section: String?, key: String, value: String) {
        edit { ConfigEdit.setValue($0, section: section, key: key, value: value) }
    }

    func setLeader(_ value: String) {
        setValue(section: nil, key: "leader", value: ConfigEdit.tomlQuoted(value))
    }

    /// Appends a `[[rules]]` block (user rules run before the shipped list).
    func addRule(app: String, title: String?, action: String) {
        addRules([ConfigEdit.RuleEdit(app: app, title: title, action: action)])
    }

    /// Batch append: one read, one write, one reload. An importer adding 30
    /// rules must not rewrite the file and re-apply the whole config — full
    /// re-layout included — 30 times over (§4.7).
    func addRules(_ rules: [ConfigEdit.RuleEdit]) {
        guard !rules.isEmpty else { return }
        edit { ConfigEdit.addRules($0, rules) }
    }

    /// Removes the `ordinal`-th `[[rules]]` block in file order. Identity is
    /// positional because content cannot distinguish two rules for the same
    /// app that differ only in action — matching on content deleted whichever
    /// one came first.
    func removeRule(at ordinal: Int) {
        edit { ConfigEdit.removeRule($0, at: ordinal) }
    }

    /// Read, transform, write — the one path that mutates the user's file.
    private func edit(_ transform: ([String]) -> [String]) {
        ensureFileExists()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // A swallowed read failure leaves the GUI showing a value the
            // file never received, exactly like a swallowed write failure.
            Self.log.error("config read failed: \(self.url.path)")
            onError?("could not read \(url.lastPathComponent)")
            return
        }
        let lines = splitLines(text)
        let edited = transform(lines)
        guard edited != lines else { return }
        write(edited)
    }

    /// Splits config text into lines, tolerating CRLF. The `\r` is stripped so
    /// the header/key comparisons below (which trim only spaces and tabs) match
    /// on a file that round-tripped through Windows or a syncing editor —
    /// otherwise `"[layout]\r" != "[layout]"`, the section lookup misses, and
    /// every GUI write appends a duplicate table. `lineEnding` remembers the
    /// file's own style so `write` restores it (§4.6: a hand-edited config
    /// survives GUI use untouched except for the keys actually changed).
    private func splitLines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        lineEnding = lines.contains { $0.hasSuffix("\r") } ? "\r\n" : "\n"
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private func write(_ lines: [String]) {
        var text = lines.joined(separator: lineEnding)
        if !text.hasSuffix(lineEnding) { text += lineEnding }
        do {
            try text.write(to: writeURL, atomically: true, encoding: .utf8)
        } catch {
            // A swallowed failure here leaves the GUI showing a value the
            // file never received — surface it like a parse error (§4.6).
            Self.log.error("config save failed: \(error.localizedDescription)")
            onError?("config save failed: \(error.localizedDescription)")
            return
        }
        load()
        watch()
    }

    /// The real file behind `url` — write through a symlink, never over it
    /// (§4.6 courts dotfiles setups that link config.toml into a repo, and
    /// an atomic write renames a temp file over the exact path it is given,
    /// replacing the link itself with a regular file and silently detaching
    /// the repo). `resolvingSymlinksInPath()` leaves a *dangling* link
    /// unresolved, so chase the final component by hand: writing the default
    /// config through a not-yet-materialized link should create its target.
    private var writeURL: URL {
        var resolved = url.resolvingSymlinksInPath()
        var hops = 0
        while hops < 8,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
            resolved = URL(
                fileURLWithPath: destination,
                relativeTo: resolved.deletingLastPathComponent()
            ).absoluteURL.resolvingSymlinksInPath()
            hops += 1
        }
        return resolved
    }

    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let target = writeURL
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (ConfigFile.defaultText + "\n").write(to: target, atomically: true, encoding: .utf8)
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
            // Skip the re-apply when nothing actually changed. Every GUI
            // write reloads once itself and once more from the vnode event
            // its own atomic rename fires, and `onApply` is a full desktop
            // re-layout — so without this each Settings click relaid out
            // the whole desktop twice for one edit.
            let changed = !hasApplied || parsed != current
            current = parsed
            hasApplied = true
            if changed { onApply?(parsed) }
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
