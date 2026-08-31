import AppKit
import Darwin
import os
import ZephrCore

/// The `zephrctl` endpoint (§4.8): a Unix socket speaking line-delimited
/// text. Nothing requires it — hotkeys and the palette cover everything —
/// but it makes SketchyBar integrations and scripting one-liners.
///
/// Protocol: one request per line, one JSON reply per line.
///   focus left|down|up|right     move left|down|up|right
///   workspace N                  send-to-workspace N
///   toggle-float | monocle | balance | rescue
///   list-windows | list-workspaces
@MainActor
final class IPCServer {

    static var socketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Zephr/zephr.sock").path
    }

    /// Per-connection state. Replies queue in `outbound` and the write
    /// source drains them as the socket allows, so a consumer that stops
    /// reading can never block the main thread — and with it the event
    /// tap, i.e. all keyboard input (§6.3: never stall).
    private final class Client {
        let reader: DispatchSourceRead
        let writer: DispatchSourceWrite
        var inbound = Data()
        var outbound = Data()
        /// Half-close the write side once `outbound` drains. Set for
        /// request/reply clients so the peer sees EOF and exits; never for
        /// subscribers, whose whole point is to stay open.
        var closeWhenDrained = false
        var writerActive = false  // true iff `writer` is resumed

        init(reader: DispatchSourceRead, writer: DispatchSourceWrite) {
            self.reader = reader
            self.writer = writer
        }
    }

    /// Past this many clients, new connections are closed at accept —
    /// otherwise fd exhaustion makes `accept` fail silently for everyone.
    private static let maxClients = 16
    /// Longest tolerated request line; a "line" that never ends is a
    /// runaway peer, not a command, and must not grow without bound.
    private static let maxInbound = 64 * 1024
    /// Un-drained replies/events; past this the consumer is dead or wedged
    /// and gets dropped rather than buffered forever.
    private static let maxOutbound = 256 * 1024

    private var listener: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var clients: [Int32: Client] = [:]
    private var subscribers: Set<Int32> = []
    /// Sources still watching each fd; the last cancel handler to retire
    /// closes it (`sourceRetired`).
    private var pendingCloses: [Int32: Int] = [:]
    private weak var engine: TilingEngine?
    private static let log = Logger(subsystem: "dev.zephr", category: "ipc")

    init(engine: TilingEngine) {
        self.engine = engine
    }

    func start() {
        // NB: SIGPIPE is ignored process-wide in the app delegate, which
        // runs before the Accessibility grant and so covers more than this
        // server. Every fd here still gets SO_NOSIGPIPE as belt and braces.
        let path = Self.socketPath
        // Same-user peers are trusted by design (§4.8 — zephrctl is a
        // local tool for the logged-in user; peer WMs' sockets behave the
        // same). The 0700 directory / 0600 socket below keep *other*
        // users out: defense in depth, not authentication.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { src in
                buffer.copyBytes(from: src.prefix(buffer.count - 1))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            Self.log.error("ipc bind failed at \(path)")
            return
        }
        chmod(path, 0o600)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { IPCBox.shared?.acceptClient() }
        }
        // The source owns the fd: cancellation is asynchronous, so closing
        // it anywhere else could close a recycled descriptor.
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        IPCBox.shared = self
        Self.log.info("zephrctl listening at \(path)")
    }

    func stop() {
        // Never close an fd a dispatch source still watches: cancellation
        // is asynchronous, and an early close() can hit a recycled
        // descriptor — e.g. shutdownRestore's state.json write in the same
        // main-queue turn taking the freed number. Cancel handlers do all
        // the closing.
        listener?.cancel()
        listener = nil
        listenFD = -1
        for fd in Array(clients.keys) { disconnect(fd) }
        subscribers.removeAll()
        unlink(Self.socketPath)
    }

    fileprivate func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        guard clients.count < Self.maxClients else {
            // Say so rather than closing mute: a silent empty reply looks
            // to zephrctl exactly like a command that succeeded (§4.8).
            _ = #"{"ok":false,"error":"too many clients"}"#.withCString {
                write(fd, $0, strlen($0))
            }
            _ = "\n".withCString { write(fd, $0, 1) }
            close(fd)  // no source watches it yet; safe to close inline
            Self.log.error("ipc client refused: \(Self.maxClients) already connected")
            return
        }
        // Non-blocking + NOSIGPIPE: a slow or dead peer must never block
        // the main thread (§6.3) or signal us.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler {
            MainActor.assumeIsolated { IPCBox.shared?.readClient(fd) }
        }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        writer.setEventHandler {
            MainActor.assumeIsolated { IPCBox.shared?.flush(fd) }
        }
        // Two sources watch this fd; the last cancel handler to run closes
        // it (see pendingCloses).
        reader.setCancelHandler {
            MainActor.assumeIsolated { IPCBox.shared?.sourceRetired(fd) }
        }
        writer.setCancelHandler {
            MainActor.assumeIsolated { IPCBox.shared?.sourceRetired(fd) }
        }
        pendingCloses[fd] = 2
        reader.resume()
        // `writer` stays suspended until there is something to drain.
        clients[fd] = Client(reader: reader, writer: writer)
    }

    /// Cancels both sources and forgets the client. The fd itself closes
    /// in `sourceRetired` once neither source watches it any more.
    private func disconnect(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        subscribers.remove(fd)
        // A suspended source can never finish cancelling; resume it first.
        if !client.writerActive { client.writer.resume() }
        client.reader.cancel()
        client.writer.cancel()
    }

    private func sourceRetired(_ fd: Int32) {
        guard let remaining = pendingCloses[fd] else { return }
        if remaining > 1 {
            pendingCloses[fd] = remaining - 1
        } else {
            pendingCloses.removeValue(forKey: fd)
            close(fd)
        }
    }

    private func readClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else {
            disconnect(fd)  // EOF or hard error
            return
        }
        client.inbound.append(contentsOf: chunk[0..<n])
        guard client.inbound.count <= Self.maxInbound else {
            Self.log.error("ipc client dropped: request line exceeded \(Self.maxInbound) bytes")
            disconnect(fd)
            return
        }
        // `send` can disconnect mid-loop (dead peer, full backlog); the
        // identity check stops us resurrecting a dropped fd.
        while clients[fd] === client, let newline = client.inbound.firstIndex(of: 0x0A) {
            let lineData = client.inbound.subdata(in: client.inbound.startIndex..<newline)
            client.inbound.removeSubrange(client.inbound.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "subscribe" {
                subscribers.insert(fd)
                send(#"{"ok":true,"subscribed":true}"#, to: fd)
                // Replay the current state before any change arrives. A
                // status bar started at login otherwise renders blank and
                // stays blank until the user happens to switch workspace,
                // and the obvious workaround — query first, then subscribe —
                // races across two connections (§4.8).
                let workspace = engine?.model.focusedWorkspace?.id ?? 1
                let wsField = jsonString("\(workspace)")
                send(#"{"event":"workspace_changed","initial":true,"workspace":\#(wsField)}"#, to: fd)
                if let focused = engine?.model.focusedWindow {
                    let winField = jsonString("\(focused.raw)")
                    send(#"{"event":"focus_changed","initial":true,"window":\#(winField)}"#, to: fd)
                }
                continue
            }
            // A nil reply means the command answers asynchronously and will
            // send its own response (see `doctor`).
            if let reply = handle(line, from: fd) { send(reply, to: fd) }
        }
    }

    /// Queues a reply and drains what the socket will take right now.
    /// Never blocks — the fd is non-blocking and leftovers wait for the
    /// write source — because a wedged consumer must not stall the main
    /// thread and with it all keyboard input (§6.3).
    private func send(_ message: String, to fd: Int32) {
        guard let client = clients[fd] else { return }
        // A request/reply client is done once this drains. Without the
        // half-close it waits forever for output that never comes — and
        // every wedged invocation holds a slot until `maxClients` is
        // reached, after which the CLI silently stops working entirely.
        if !subscribers.contains(fd) { client.closeWhenDrained = true }
        client.outbound.append(contentsOf: (message + "\n").utf8)
        guard client.outbound.count <= Self.maxOutbound else {
            Self.log.error("ipc client dropped: \(Self.maxOutbound)-byte backlog not draining")
            disconnect(fd)
            return
        }
        flush(fd)
    }

    /// Writes as much of `outbound` as the socket accepts; arms the write
    /// source for the remainder, disarms it once drained.
    private func flush(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        while !client.outbound.isEmpty {
            let n = client.outbound.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                client.outbound.removeFirst(n)
            } else if n == -1, errno == EINTR {
                continue
            } else if n == -1, errno == EAGAIN {
                break
            } else {
                disconnect(fd)  // EPIPE and friends: the peer is gone
                return
            }
        }
        setWriterActive(fd, active: !client.outbound.isEmpty)
        if client.outbound.isEmpty, client.closeWhenDrained {
            // Write side only: the peer's own close still arrives as EOF in
            // `readClient`, which is what frees the slot.
            shutdown(fd, SHUT_WR)
        }
    }

    private func setWriterActive(_ fd: Int32, active: Bool) {
        guard let client = clients[fd], client.writerActive != active else { return }
        client.writerActive = active
        if active { client.writer.resume() } else { client.writer.suspend() }
    }

    /// Event stream for `zephrctl subscribe` (§4.8): one JSON object per
    /// line, e.g. {"event":"workspace_changed","workspace":"3"}.
    func broadcast(_ event: String, _ payload: [String: String] = [:]) {
        guard !subscribers.isEmpty else { return }
        var fields = [#""event":\#(jsonString(event))"#]
        for (key, value) in payload.sorted(by: { $0.key < $1.key }) {
            fields.append("\(jsonString(key)):\(jsonString(value))")
        }
        let line = "{\(fields.joined(separator: ","))}"
        for fd in subscribers { send(line, to: fd) }
    }

    /// Returns the reply, or nil when the command replies asynchronously.
    private func handle(_ line: String, from fd: Int32) -> String? {
        guard let engine else { return #"{"ok":false,"error":"engine down"}"# }
        let parts = line.split(separator: " ").map(String.init)
        let ok = #"{"ok":true}"#

        func direction(_ s: String?) -> Direction? {
            s.flatMap { Direction(rawValue: $0) }
        }

        switch parts.first {
        case "focus":
            guard let d = direction(parts.dropFirst().first) else { return bad("focus needs left|down|up|right") }
            engine.perform(.focus(d)); return ok
        case "move":
            guard let d = direction(parts.dropFirst().first) else { return bad("move needs left|down|up|right") }
            engine.perform(.move(d)); return ok
        case "workspace":
            guard let n = parts.dropFirst().first.flatMap(Int.init), (1...9).contains(n) else { return bad("workspace needs 1–9") }
            engine.perform(.goToWorkspace(n)); return ok
        case "send-to-workspace":
            guard let n = parts.dropFirst().first.flatMap(Int.init), (1...9).contains(n) else { return bad("send-to-workspace needs 1–9") }
            engine.perform(.moveToWorkspace(n)); return ok
        case "toggle-float": engine.perform(.toggleFloat); return ok
        case "monocle": engine.perform(.toggleMonocle); return ok
        case "balance": engine.perform(.balance); return ok
        case "rescue": engine.perform(.rescueWindows); return ok
        case "close": engine.perform(.closeWindow); return ok
        case "pause": engine.setPaused(true); return ok
        case "resume": engine.setPaused(false); return ok
        case "resize":
            guard let d = direction(parts.dropFirst().first) else { return bad("resize needs left|down|up|right") }
            engine.perform(.resize(d, fine: parts.contains("--fine"))); return ok
        case "shrink": engine.perform(.shrink); return ok
        case "grow": engine.perform(.grow); return ok
        case "split-h": engine.perform(.splitPreselect(.horizontal)); return ok
        case "split-v": engine.perform(.splitPreselect(.vertical)); return ok
        case "cycle-layout": engine.perform(.cycleLayout); return ok
        case "group":
            let dir = parts.dropFirst().first.flatMap(Direction.init(rawValue:)) ?? .right
            engine.perform(.joinWith(dir)); return ok
        case "flatten": engine.perform(.flatten); return ok
        case "layout":
            switch parts.dropFirst().first {
            case "row", "horizontal": engine.perform(.setOrientation(.horizontal)); return ok
            case "column", "vertical": engine.perform(.setOrientation(.vertical)); return ok
            case nil: engine.perform(.toggleOrientation); return ok
            default: return bad("layout takes row|column, or nothing to flip")
            }
        case "next-display": engine.perform(.focusNextDisplay); return ok
        case "float-mode": engine.perform(.toggleWorkspaceFloatMode); return ok
        case "doctor":
            // Rival detection forks a process, which must not happen on the
            // main actor (§6.3). Scan off-actor and reply when it returns —
            // the client's outbound queue makes a deferred reply safe.
            // Capture the client identity, not just the descriptor: if this
            // client disconnects while the scan runs, the fd number can be
            // recycled onto a new connection, and the reply would land in a
            // stranger's stream.
            let requester = clients[fd]
            Task { [weak self] in
                guard let self else { return }
                let checks = await AppDelegate.shared?.doctor.runChecksOffActor() ?? []
                guard let requester, self.clients[fd] === requester else { return }
                let items = checks.map {
                    #"{"title":\#(jsonString($0.title)),"status":\#(jsonString(String(describing: $0.status))),"detail":\#(jsonString($0.detail))}"#
                }
                self.send("[\(items.joined(separator: ","))]", to: fd)
            }
            return nil
        case "focus-window":
            guard let raw = parts.dropFirst().first.flatMap(UInt64.init) else { return bad("focus-window needs an id from list-windows") }
            engine.focusManagedWindow(WindowID(raw)); return ok
        case "list-windows":
            let items = engine.paletteWindows().map {
                // `workspace` is optional (nil = native fullscreen). Interpolating
                // it directly emits `Optional(1)` / `nil`, neither of which is
                // JSON — §4.8 promises stable, parseable schemas.
                // `id` is a string and `app` a bundle id, matching the
                // event stream exactly — they used to disagree on both, so
                // any `jq` join between a subscription and this query
                // silently matched nothing. `app-name` carries the
                // localized display name the palette shows.
                #"{"id":\#(jsonString("\($0.id.raw)")),"app":\#(jsonString($0.bundleID)),"app-name":\#(jsonString($0.app)),"title":\#(jsonString($0.title)),"workspace":\#($0.workspace.map(String.init) ?? "null")}"#
            }
            return "[\(items.joined(separator: ","))]"
        case "list-workspaces":
            let items = engine.model.workspaces.values.sorted { $0.id < $1.id }.map {
                #"{"id":\#($0.id),"name":\#(jsonString($0.name ?? "")),"windows":\#($0.allWindows.count),"focused":\#(engine.model.focusedWorkspace?.id == $0.id)}"#
            }
            return "[\(items.joined(separator: ","))]"
        default:
            return bad("unknown command; see zephrctl --help")
        }
    }

    private func bad(_ message: String) -> String {
        #"{"ok":false,"error":\#(jsonString(message))}"#
    }
}

/// RFC 8259 escaping: every control scalar below 0x20 must be escaped or a
/// tab in a window title breaks `list-windows | jq`, violating §4.8's
/// stable-JSON-schema promise.
private func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

@MainActor
private enum IPCBox {
    static weak var shared: IPCServer?
}
