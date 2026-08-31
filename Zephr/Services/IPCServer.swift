import AppKit
import Darwin
import os
import ZephrCore

/// The `zephrctl` endpoint (§4.8): a Unix socket speaking line-delimited
/// text. Nothing requires it — hotkeys and the palette cover everything —
/// but it makes SketchyBar integrations and scripting one-liners.
///
/// Protocol: one request per line, one JSON reply per line. The verb table
/// is `commands` below - it is the only description of this surface, and
/// `zephrctl --help` renders it rather than keeping a copy.
@MainActor
final class IPCServer {

    /// Wire-format version, reported by `version`. §4.8 promises stable JSON
    /// schemas; this is what a script can actually test before trusting
    /// them. It rises only when a documented field changes meaning or
    /// disappears - new fields and new verbs are additive and do not bump it.
    static let protocolVersion = 1

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
            let args = Self.tokenize(line)
            if args.first == "subscribe" {
                subscribers.insert(fd)
                // The protocol version rides along on the hello: a long-lived
                // subscriber can check the schemas it is about to parse
                // without opening a second connection to ask.
                send(#"{"ok":true,"subscribed":true,"protocol":\#(Self.protocolVersion)}"#, to: fd)
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
            if let reply = handle(args, from: fd) { send(reply, to: fd) }
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

    /// The whole verb table, served by `help` and rendered by
    /// `zephrctl --help`. The CLI keeps no list of its own, so this is the
    /// only place a command can be described - every case `handle` accepts
    /// belongs here, and one that is missing is a command nobody can find.
    private static let commands: [(usage: String, summary: String)] = [
        ("focus left|down|up|right", "Move focus in that direction"),
        ("move left|down|up|right", "Move the focused window"),
        ("resize left|down|up|right [--fine]", "Resize by 5% (1% with --fine)"),
        ("shrink | grow | balance", "Adjust shares in the container"),
        ("workspace N", "Go to workspace 1-9 (re-request = back-and-forth)"),
        ("send-to-workspace N", "Send the focused window to workspace N"),
        ("summon N", "Bring workspace N to the focused display"),
        ("toggle-float", "Float or re-tile the focused window"),
        ("float-mode", "Toggle float-by-default on this workspace"),
        ("monocle", "Toggle monocle on this workspace"),
        ("cycle-layout", "Tiles <-> accordion"),
        ("layout [row|column]", "Lay the container out along that axis; no argument flips it"),
        ("split-h | split-v", "Pre-select the next split's direction"),
        ("group [left|down|up|right]", "Group the focused window with that neighbour"),
        ("flatten", "Reparent every window onto the root - the layout reset"),
        ("close", "Close the focused window"),
        ("focus-window <id>", "Focus a window by id, from list-windows"),
        ("next-display", "Focus the next display"),
        ("move-to-display [dir]", "Send the focused window to that display"),
        ("move-workspace-to-display [dir]", "Send the whole workspace to that display"),
        ("toggle-pause-display", "Suspend tiling here only (alias: pause-display, resume-display)"),
        ("pause | resume", "Release or retake every window and the keyboard"),
        ("rescue", "Bring every window to the current workspace"),
        ("list-windows [--focused] [--workspace N] [--display ID] [--app BUNDLE] [--count]",
         "Managed windows as JSON, or a count with --count"),
        ("list-workspaces [--count]", "Workspaces as JSON: id, name, windows, display, visible"),
        ("list-displays [--count]", "Displays as JSON: id, frame, workspace, focused, paused"),
        ("list-apps [--count]", "Managed apps as JSON: app, app-name, pid, windows"),
        ("doctor", "Health checks as JSON: title, status, detail"),
        ("version", "App version, build, and IPC protocol version"),
        ("subscribe", "Stream events as JSON until disconnected"),
        ("help", "This table, as JSON"),
    ]

    /// Splits a request line into arguments. Bare tokens split on spaces the
    /// way they always have, so `printf 'workspace 3\n' | nc …` keeps
    /// working, but a double-quoted run is one argument - without that, a
    /// value containing a space simply could not reach the server. `zephrctl`
    /// quotes every argument it forwards; inside quotes a backslash escapes
    /// the next character.
    private static func tokenize(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        // An argument can be legitimately empty (`""`), which is not the same
        // as the run of spaces between two arguments.
        var started = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if quoted, ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted, ch == " " || ch == "\t" {
                if started { args.append(current) }
                current = ""
                started = false
            } else {
                current.append(ch)
                started = true
            }
        }
        if started { args.append(current) }
        return args
    }

    /// Returns the reply, or nil when the command replies asynchronously.
    private func handle(_ parts: [String], from fd: Int32) -> String? {
        guard let engine else { return #"{"ok":false,"error":"engine down"}"# }
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
        case "pause-display", "resume-display", "toggle-pause-display":
            engine.perform(.togglePauseDisplay); return ok
        case "move-to-display":
            let dir = parts.dropFirst().first.flatMap(Direction.init(rawValue:))
            engine.perform(.moveWindowToDisplay(dir)); return ok
        case "summon":
            guard let n = parts.dropFirst().first.flatMap(Int.init), (1...9).contains(n) else {
                return bad("summon needs a workspace 1-9")
            }
            engine.perform(.summonWorkspace(n)); return ok
        case "move-workspace-to-display":
            let dir = parts.dropFirst().first.flatMap(Direction.init(rawValue:))
            engine.perform(.moveWorkspaceToDisplay(dir)); return ok
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
            return listWindows(engine, parts.dropFirst())
        case "list-workspaces":
            guard let count = countOnlyFlag(parts.dropFirst()) else {
                return bad("list-workspaces takes --count only")
            }
            // `display` and `visible` are what make a multi-monitor layout
            // debuggable at all: which screen a workspace belongs to, and
            // whether it is the one that screen is currently showing.
            let workspaces = engine.model.workspaces.values.sorted { $0.id < $1.id }
            if count { return "\(workspaces.count)" }
            let items = workspaces.map { ws -> String in
                let display = ws.homeDisplay.map { "\($0.raw)" } ?? ""
                let visible = ws.homeDisplay.map { engine.model.activeWorkspaceByDisplay[$0] == ws.id } ?? false
                return #"{"id":\#(ws.id),"name":\#(jsonString(ws.name ?? "")),"windows":\#(ws.allWindows.count),"display":\#(jsonString(display)),"visible":\#(visible),"focused":\#(engine.model.focusedWorkspace?.id == ws.id)}"#
            }
            return "[\(items.joined(separator: ","))]"

        case "list-displays":
            guard let count = countOnlyFlag(parts.dropFirst()) else {
                return bad("list-displays takes --count only")
            }
            if count { return "\(engine.displays.count)" }
            let focused = engine.model.focusedDisplay
            let items = engine.displays.map { info -> String in
                let active = engine.model.activeWorkspaceByDisplay[info.id].map(String.init) ?? "null"
                let f = info.frame
                return #"{"id":\#(jsonString("\(info.id.raw)")),"frame":[\#(Int(f.minX)),\#(Int(f.minY)),\#(Int(f.width)),\#(Int(f.height))],"workspace":\#(active),"focused":\#(info.id == focused),"paused":\#(engine.isPaused(display: info.id))}"#
            }
            return "[\(items.joined(separator: ","))]"

        case "list-apps":
            guard let count = countOnlyFlag(parts.dropFirst()) else {
                return bad("list-apps takes --count only")
            }
            // Aggregated from exactly the window set `list-windows` reports,
            // so a count here and `list-windows --app X --count` can never
            // disagree - a status bar showing both would look broken.
            var byBundle: [String: (name: String, pid: pid_t, windows: Int)] = [:]
            for window in engine.paletteWindows() {
                if var entry = byBundle[window.bundleID] {
                    entry.windows += 1
                    byBundle[window.bundleID] = entry
                } else {
                    byBundle[window.bundleID] = (window.app, engine.windows[window.id]?.pid ?? 0, 1)
                }
            }
            if count { return "\(byBundle.count)" }
            let apps = byBundle.sorted { $0.key < $1.key }.map { bundle, entry in
                #"{"app":\#(jsonString(bundle)),"app-name":\#(jsonString(entry.name)),"pid":\#(entry.pid),"windows":\#(entry.windows)}"#
            }
            return "[\(apps.joined(separator: ","))]"

        case "version":
            let info = Bundle.main.infoDictionary
            let short = info?["CFBundleShortVersionString"] as? String ?? "0"
            let build = info?["CFBundleVersion"] as? String ?? "0"
            return #"{"ok":true,"version":\#(jsonString(short)),"build":\#(jsonString(build)),"protocol":\#(Self.protocolVersion)}"#

        case "help":
            let items = Self.commands.map {
                #"{"command":\#(jsonString($0.usage)),"summary":\#(jsonString($0.summary))}"#
            }
            return "[\(items.joined(separator: ","))]"
        default:
            return bad("unknown command; see zephrctl --help")
        }
    }

    /// `list-windows`, filtered. A status bar re-runs this several times a
    /// second: answering the narrow question here is the difference between
    /// one round trip and a round trip plus a `jq` fork per tick.
    private func listWindows(_ engine: TilingEngine, _ args: ArraySlice<String>) -> String {
        var onlyFocused = false
        var count = false
        var workspace: Int?
        var display: UInt32?
        var bundleID: String?
        var flags = args.makeIterator()
        while let flag = flags.next() {
            switch flag {
            case "--focused": onlyFocused = true
            case "--count": count = true
            case "--workspace":
                guard let value = flags.next(), let n = Int(value) else {
                    return bad("--workspace needs a number")
                }
                workspace = n
            case "--display":
                guard let value = flags.next(), let n = UInt32(value) else {
                    return bad("--display needs an id from list-displays")
                }
                display = n
            case "--app":
                guard let value = flags.next() else {
                    return bad("--app needs a bundle id from list-apps")
                }
                bundleID = value
            default:
                return bad("list-windows: unknown option \(flag)")
            }
        }

        let focused = engine.model.focusedWindow
        let matches = engine.paletteWindows().filter { window in
            if onlyFocused, window.id != focused { return false }
            if let workspace, window.workspace != workspace { return false }
            // Bundle ids are case-insensitively unique on macOS, and no one
            // types `com.googlecode.iterm2` from memory with the capitals right.
            if let bundleID, window.bundleID.caseInsensitiveCompare(bundleID) != .orderedSame { return false }
            if let display {
                // A window's display is its workspace's home. One that has no
                // workspace (native fullscreen, or parked on another Space)
                // has no display either, so it never matches.
                let home = window.workspace.flatMap { engine.model.workspaces[$0]?.homeDisplay }
                if home?.raw != display { return false }
            }
            return true
        }
        if count { return "\(matches.count)" }

        let items = matches.map {
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
    }

    /// `--count` is the only flag the unfiltered list verbs take. Returns nil
    /// on anything else, so a typo is an error rather than a filter that
    /// silently did nothing.
    private func countOnlyFlag(_ args: ArraySlice<String>) -> Bool? {
        var count = false
        for arg in args {
            guard arg == "--count" else { return nil }
            count = true
        }
        return count
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
