import Foundation
import os
import ZephrCore

/// Crash-safe window snapshots (§6.5): the last visible frame and workspace
/// of every managed window, written atomically and debounced. If the previous
/// run didn't shut down cleanly, the next launch restores from this.
@MainActor
final class StateStore {

    nonisolated struct WindowRecord: Codable, Sendable {
        var bundleID: String?
        var title: String
        var frame: CGRect
        var workspace: Int
        var floating: Bool
    }

    nonisolated struct Snapshot: Codable, Sendable {
        var version = 2
        var cleanShutdown: Bool
        var windows: [WindowRecord]
        /// Display profiles keyed by arrangement fingerprint (§4.5).
        var profiles: [String: ModelSnapshot]? = [:]
    }

    private let url: URL
    private var pending: Task<Void, Never>?
    private nonisolated static let log = Logger(subsystem: "dev.zephr", category: "state")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Zephr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Debounced (300 ms) atomic write; `clean` false while running.
    func save(windows: [WindowRecord], profiles: [String: ModelSnapshot], clean: Bool = false) {
        pending?.cancel()
        let snapshot = Snapshot(cleanShutdown: clean, windows: windows, profiles: profiles)
        pending = Task { [url] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: url)
        }
    }

    /// Synchronous write for shutdown paths.
    func saveNow(windows: [WindowRecord], profiles: [String: ModelSnapshot], clean: Bool) {
        pending?.cancel()
        Self.write(Snapshot(cleanShutdown: clean, windows: windows, profiles: profiles), to: url)
    }

    private nonisolated static func write(_ snapshot: Snapshot, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            log.error("state write failed: \(error.localizedDescription)")
        }
    }
}
