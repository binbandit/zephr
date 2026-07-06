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

    private var listener: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private var subscribers: Set<Int32> = []
    private weak var engine: TilingEngine?
    private static let log = Logger(subsystem: "dev.zephr", category: "ipc")

    init(engine: TilingEngine) {
        self.engine = engine
    }

    func start() {
        let path = Self.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
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
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { IPCBox.shared?.acceptClient() }
        }
        source.resume()
        listener = source
        IPCBox.shared = self
        Self.log.info("zephrctl listening at \(path)")
    }

    func stop() {
        listener?.cancel()
        if listenFD >= 0 { close(listenFD) }
        for (fd, source) in clients {
            source.cancel()
            close(fd)
        }
        clients.removeAll()
        unlink(Self.socketPath)
    }

    fileprivate func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { IPCBox.shared?.readClient(fd) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        clients[fd] = source
        buffers[fd] = Data()
    }

    private func readClient(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else {
            clients.removeValue(forKey: fd)?.cancel()
            buffers.removeValue(forKey: fd)
            subscribers.remove(fd)
            return
        }
        buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
        while let newline = buffers[fd]?.firstIndex(of: 0x0A) {
            let lineData = buffers[fd]!.subdata(in: buffers[fd]!.startIndex..<newline)
            buffers[fd]!.removeSubrange(buffers[fd]!.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "subscribe" {
                subscribers.insert(fd)
                send(#"{"ok":true,"subscribed":true}"#, to: fd)
                continue
            }
            send(handle(line), to: fd)
        }
    }

    private func send(_ message: String, to fd: Int32) {
        (message + "\n").withCString { _ = write(fd, $0, strlen($0)) }
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

    private func handle(_ line: String) -> String {
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
        case "next-display": engine.perform(.focusNextDisplay); return ok
        case "float-mode": engine.perform(.toggleWorkspaceFloatMode); return ok
        case "doctor":
            let checks = (AppDelegate.shared?.doctor.runChecks() ?? []).map {
                #"{"title":\#(jsonString($0.title)),"status":\#(jsonString(String(describing: $0.status))),"detail":\#(jsonString($0.detail))}"#
            }
            return "[\(checks.joined(separator: ","))]"
        case "focus-window":
            guard let raw = parts.dropFirst().first.flatMap(UInt64.init) else { return bad("focus-window needs an id from list-windows") }
            engine.focusManagedWindow(WindowID(raw)); return ok
        case "list-windows":
            let items = engine.paletteWindows().map {
                #"{"id":\#($0.id.raw),"app":\#(jsonString($0.app)),"title":\#(jsonString($0.title)),"workspace":\#($0.workspace)}"#
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

private func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

@MainActor
private enum IPCBox {
    static weak var shared: IPCServer?
}
