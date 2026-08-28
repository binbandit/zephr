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

    /// An app Zephr itself hid for the stash (§4.4). Crash recovery (§6.6)
    /// matches by pid within a boot and falls back to the bundle id across
    /// reboots, where pids get recycled.
    nonisolated struct HiddenApp: Codable, Sendable {
        var pid: pid_t
        var bundleID: String?
    }

    nonisolated struct Snapshot: Codable, Sendable {
        var version = 2
        var cleanShutdown: Bool
        var windows: [WindowRecord]
        /// Display profiles keyed by arrangement fingerprint (§4.5).
        var profiles: [String: ModelSnapshot]? = [:]
        /// Apps hidden by Zephr at snapshot time — crash recovery unhides
        /// them (§6.6). Optional so older snapshots still decode.
        var hiddenApps: [HiddenApp]? = []
    }

    private let url: URL
    private var pending: Task<Void, Never>?
    /// Monotonic stamp for each requested snapshot. Cancellation alone
    /// cannot order the writes: a detached task already past its
    /// cancellation check would land *after* `saveNow`'s clean-shutdown
    /// write and replace it with a stale `cleanShutdown: false` snapshot —
    /// the next launch would then run crash recovery (§6.6) after a
    /// perfectly clean quit, yanking windows the user parked at screen
    /// edges. Every write funnels through `writeQueue` and re-checks its
    /// stamp there, so a superseded write drops itself.
    private var generation: UInt64 = 0
    /// Serializes all snapshot writes. `lastWrittenGeneration` is guarded
    /// by this queue — it is only ever read or written on it.
    private nonisolated let writeQueue = DispatchQueue(label: "dev.zephr.state-write", qos: .utility)
    private nonisolated(unsafe) var lastWrittenGeneration: UInt64 = 0
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
    func save(
        windows: [WindowRecord],
        profiles: [String: ModelSnapshot],
        hiddenApps: [HiddenApp] = [],
        clean: Bool = false
    ) {
        pending?.cancel()
        generation += 1
        let snapshot = Snapshot(cleanShutdown: clean, windows: windows, profiles: profiles, hiddenApps: hiddenApps)
        // Detached: a `Task {}` here would inherit MainActor isolation and
        // put the JSON encode + file write on the main thread (§6.3). The
        // snapshot is Sendable, so hop off entirely.
        pending = Task.detached(priority: .utility) { [generation] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.write(snapshot, generation: generation)
        }
    }

    /// Synchronous write for shutdown paths — waits until the snapshot is
    /// on disk (and any in-flight debounced write has drained first).
    func saveNow(
        windows: [WindowRecord],
        profiles: [String: ModelSnapshot],
        hiddenApps: [HiddenApp] = [],
        clean: Bool
    ) {
        pending?.cancel()
        generation += 1
        let snapshot = Snapshot(cleanShutdown: clean, windows: windows, profiles: profiles, hiddenApps: hiddenApps)
        write(snapshot, generation: generation, andWait: true)
    }

    /// All writes land here, on `writeQueue`, in generation order: a
    /// snapshot older than the last one written is superseded and drops
    /// itself (see `generation`). The debounced path stays off the
    /// MainActor for the encode; the shutdown path blocks until done.
    private nonisolated func write(_ snapshot: Snapshot, generation: UInt64, andWait: Bool = false) {
        let work: @Sendable () -> Void = { [url] in
            guard generation > self.lastWrittenGeneration else { return }
            self.lastWrittenGeneration = generation
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Self.log.error("state write failed: \(error.localizedDescription)")
            }
        }
        if andWait {
            writeQueue.sync(execute: work)
        } else {
            writeQueue.async(execute: work)
        }
    }
}
