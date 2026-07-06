import AppKit
import Carbon.HIToolbox
import os
import ZephrCore

/// Keyboard front-end: a CGEvent tap for the leader layer and the direct
/// ⌃⌥ chords (§4.2). Never binds bare ⌥ — international typing and Emacs
/// bindings survive. While the layer is open every keystroke is consumed.
@MainActor
final class HotkeyService {

    enum LayerState: Equatable {
        case inactive
        case layer      // leader pressed; command strip visible
        case resize     // leader → r
    }

    var onCommand: ((Command) -> Void)?
    var onLayerChange: ((LayerState) -> Void)?
    var onToggleHelp: (() -> Void)?
    var onTogglePalette: (() -> Void)?
    /// Progressive disclosure (§4.2): after ~10 uses of the same layer
    /// command, a one-time "this has a direct chord" tip for the strip.
    var onHint: ((String) -> Void)?

    private(set) var state: LayerState = .inactive {
        didSet {
            if state != oldValue { onLayerChange?(state) }
            rearmLayerTimeout()
        }
    }

    /// §4.2: one-shot closes the layer after a single command; the idle
    /// timeout (0 = never, the default) closes a forgotten layer.
    private var layerOneShot = false
    private var layerTimeout: TimeInterval = 0
    private var layerTimeoutTask: Task<Void, Never>?

    func configureLayer(oneShot: Bool, timeout: TimeInterval) {
        layerOneShot = oneShot
        layerTimeout = timeout
    }

    private func rearmLayerTimeout() {
        layerTimeoutTask?.cancel()
        guard state != .inactive, layerTimeout > 0 else { return }
        layerTimeoutTask = Task { [weak self, layerTimeout] in
            try? await Task.sleep(for: .seconds(layerTimeout))
            guard !Task.isCancelled else { return }
            self?.state = .inactive
        }
    }

    private func layerCommandIssued() {
        if layerOneShot {
            state = .inactive
        } else {
            rearmLayerTimeout()
        }
    }

    /// Set on the C callback thread == main thread only.
    nonisolated(unsafe) static weak var shared: HotkeyService?

    private var tap: CFMachPort?
    private var swallowedKeyUps: Set<Int64> = []
    private var secureInputPoll: Task<Void, Never>?
    private(set) var secureInputActive = false
    var onSecureInputChange: ((Bool) -> Void)?

    private static let log = Logger(subsystem: "dev.zephr", category: "hotkeys")

    // MARK: Key codes (ANSI layout; rebinding lands with ConfigService in P4)

    private enum Key {
        static let h: Int64 = 4, j: Int64 = 38, k: Int64 = 40, l: Int64 = 37
        static let t: Int64 = 17, m: Int64 = 46, s: Int64 = 1, v: Int64 = 9
        static let r: Int64 = 15, w: Int64 = 13, p: Int64 = 35, q: Int64 = 12
        static let space: Int64 = 49, tab: Int64 = 48, escape: Int64 = 53
        static let equals: Int64 = 24, minus: Int64 = 27, grave: Int64 = 50
        static let slash: Int64 = 44
        static let arrowLeft: Int64 = 123, arrowRight: Int64 = 124
        static let arrowDown: Int64 = 125, arrowUp: Int64 = 126
        static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1–9
    }

    private struct Modifiers: Equatable {
        var control = false, option = false, shift = false, command = false

        init(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false) {
            self.control = control
            self.option = option
            self.shift = shift
            self.command = command
        }

        init(_ flags: CGEventFlags) {
            control = flags.contains(.maskControl)
            option = flags.contains(.maskAlternate)
            shift = flags.contains(.maskShift)
            command = flags.contains(.maskCommand)
        }

        static let ctrlOpt = Modifiers(control: true, option: true)
        static let ctrlOptShift = Modifiers(control: true, option: true, shift: true)
        static let optOnly = Modifiers(option: true)
    }

    // MARK: - Leader configuration (§4.6)

    private var leaderKeyCode: Int64 = Key.space
    private var leaderMods: Modifiers = .optOnly

    /// Chord preset (§4.2/§4.7): which modifiers the direct chords use.
    /// nil = chords disabled (vim preset: leader-only).
    private var chordMods: Modifiers? = .ctrlOpt
    private var chordMoveMods: Modifiers? = .ctrlOptShift

    func setPreset(_ preset: String) {
        switch preset {
        case "i3":
            chordMods = Modifiers(option: true, command: true)
            chordMoveMods = Modifiers(option: true, shift: true, command: true)
        case "aerospace":
            // AeroSpace muscle memory: bare ⌥ — documented as hostile to
            // ⌥-typing (§2 failure mode 3), but the choice is the user's.
            chordMods = Modifiers(option: true)
            chordMoveMods = Modifiers(option: true, shift: true)
        case "vim":
            chordMods = nil
            chordMoveMods = nil
        default:
            chordMods = .ctrlOpt
            chordMoveMods = .ctrlOptShift
        }
    }

    private static let keyCodesByName: [String: Int64] = [
        "space": Key.space, "tab": Key.tab, "grave": Key.grave, "`": Key.grave,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
    ]

    /// Applies a leader binding from config. Returns false (keeping the
    /// current leader) when the key name is unknown.
    @discardableResult
    func setLeader(_ binding: LeaderBinding) -> Bool {
        guard let code = Self.keyCodesByName[binding.key] else {
            Self.log.warning("unknown leader key \"\(binding.key)\" — keeping current leader")
            return false
        }
        leaderKeyCode = code
        leaderMods = Modifiers(
            control: binding.control,
            option: binding.option,
            shift: binding.shift,
            command: binding.command
        )
        return true
    }

    // MARK: - Lifecycle

    init() {
        Self.shared = self
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: nil
        ) else {
            Self.log.error("event tap creation failed — is Accessibility granted?")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Secure Input detection (§6.4): never fail silently — and fall back
        // to Carbon hotkeys, which keep working while taps are muted.
        secureInputPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(2))
                guard let self else { return }
                let active = IsSecureEventInputEnabled()
                if active != self.secureInputActive {
                    self.secureInputActive = active
                    self.onSecureInputChange?(active)
                    if active {
                        self.closeLayer()
                        self.registerCarbonFallback()
                    } else {
                        self.unregisterCarbonFallback()
                    }
                }
            }
        }
    }

    // MARK: - Carbon fallback (§6.4): chords survive Secure Input

    private var carbonHotkeys: [EventHotKeyRef] = []
    private var carbonHandler: EventHandlerRef?
    /// Commands reachable while Secure Input is active, indexed by hotkey id.
    private var carbonCommands: [Command] = []

    private func carbonModifiers(_ mods: Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if mods.control { flags |= UInt32(controlKey) }
        if mods.option { flags |= UInt32(optionKey) }
        if mods.shift { flags |= UInt32(shiftKey) }
        if mods.command { flags |= UInt32(cmdKey) }
        return flags
    }

    private func registerCarbonFallback() {
        guard carbonHandler == nil, let chordMods, let chordMoveMods else { return }

        var bindings: [(Int64, Modifiers, Command)] = []
        for (code, dir) in [(Key.h, Direction.left), (Key.j, .down), (Key.k, .up), (Key.l, .right)] {
            bindings.append((code, chordMods, .focus(dir)))
            bindings.append((code, chordMoveMods, .move(dir)))
        }
        for (index, code) in Key.digits.enumerated() {
            bindings.append((code, chordMods, .goToWorkspace(index + 1)))
            bindings.append((code, chordMoveMods, .moveToWorkspace(index + 1)))
        }
        bindings.append((Key.t, chordMods, .toggleFloat))
        bindings.append((Key.m, chordMods, .toggleMonocle))
        bindings.append((Key.grave, chordMods, .focusNextDisplay))

        var handlerSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyHandler, 1, &handlerSpec, nil, &carbonHandler)

        carbonCommands = bindings.map(\.2)
        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5A504852) /* "ZPHR" */, id: UInt32(index))
            RegisterEventHotKey(
                UInt32(binding.0),
                carbonModifiers(binding.1),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if let ref { carbonHotkeys.append(ref) }
        }
        Self.log.info("Secure Input active — Carbon fallback registered (\(self.carbonHotkeys.count) chords)")
    }

    private func unregisterCarbonFallback() {
        for ref in carbonHotkeys { UnregisterEventHotKey(ref) }
        carbonHotkeys.removeAll()
        carbonCommands.removeAll()
        if let handler = carbonHandler {
            RemoveEventHandler(handler)
            carbonHandler = nil
        }
    }

    fileprivate func carbonHotkeyFired(id: UInt32) {
        guard carbonCommands.indices.contains(Int(id)) else { return }
        onCommand?(carbonCommands[Int(id)])
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        secureInputPoll?.cancel()
    }

    func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func closeLayer() {
        state = .inactive
    }

    // MARK: - Event handling (main thread, via the tap callback)

    /// While paused, the keyboard belongs entirely to the user again.
    var suspended = false {
        didSet { if suspended { closeLayer() } }
    }

    /// Returns true when the event must be consumed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap()
            return false
        }
        guard !suspended else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            if swallowedKeyUps.remove(keyCode) != nil { return true }
            return state != .inactive
        }
        guard type == .keyDown else { return false }

        let mods = Modifiers(event.flags)
        let consumed = handleKeyDown(keyCode: keyCode, mods: mods)
        if consumed { swallowedKeyUps.insert(keyCode) }
        return consumed
    }

    private func handleKeyDown(keyCode: Int64, mods: Modifiers) -> Bool {
        // The leader (default ⌥Space) toggles the layer from any state.
        if keyCode == leaderKeyCode && mods == leaderMods {
            state = state == .inactive ? .layer : .inactive
            return true
        }

        switch state {
        case .inactive:
            return handleChord(keyCode: keyCode, mods: mods)
        case .layer:
            handleLayerKey(keyCode: keyCode, mods: mods)
            return true // the layer consumes everything (§4.2)
        case .resize:
            handleResizeKey(keyCode: keyCode, mods: mods)
            return true
        }
    }

    private func direction(for keyCode: Int64) -> Direction? {
        switch keyCode {
        case Key.h, Key.arrowLeft: .left
        case Key.j, Key.arrowDown: .down
        case Key.k, Key.arrowUp: .up
        case Key.l, Key.arrowRight: .right
        default: nil
        }
    }

    private func workspaceNumber(for keyCode: Int64) -> Int? {
        Key.digits.firstIndex(of: keyCode).map { $0 + 1 }
    }

    /// Direct chords: ⌃⌥ and ⌃⌥⇧ by default; presets remap (§4.2).
    private func handleChord(keyCode: Int64, mods: Modifiers) -> Bool {
        if mods == chordMods {
            if let dir = direction(for: keyCode) { onCommand?(.focus(dir)); return true }
            if let n = workspaceNumber(for: keyCode) { onCommand?(.goToWorkspace(n)); return true }
            switch keyCode {
            case Key.t: onCommand?(.toggleFloat); return true
            case Key.m: onCommand?(.toggleMonocle); return true
            case Key.minus: onCommand?(.shrink); return true
            case Key.equals: onCommand?(.grow); return true
            case Key.grave: onCommand?(.focusNextDisplay); return true
            case Key.p: onTogglePalette?(); return true
            case Key.q: onCommand?(.closeWindow); return true
            default: return false
            }
        }
        if mods == chordMoveMods {
            if let dir = direction(for: keyCode) { onCommand?(.move(dir)); return true }
            if let n = workspaceNumber(for: keyCode) { onCommand?(.moveToWorkspace(n)); return true }
            return false
        }
        return false
    }

    private var layerUsage: [String: Int] =
        UserDefaults.standard.dictionary(forKey: "dev.zephr.layerUsage") as? [String: Int] ?? [:]

    /// One-time inline tip once a layer command becomes muscle memory.
    private func noteLayerUsage(_ command: Command, chordKey: String) {
        guard let mods = chordMods else { return } // vim preset: no chords
        let key = command.label
        let count = (layerUsage[key] ?? 0) + 1
        layerUsage[key] = count
        UserDefaults.standard.set(layerUsage, forKey: "dev.zephr.layerUsage")
        if count == 10 {
            var prefix = ""
            if mods.control { prefix += "⌃" }
            if mods.option { prefix += "⌥" }
            if mods.command { prefix += "⌘" }
            let shifted = command.isMoveVariant ? "⇧" : ""
            onHint?("Tip: \(prefix)\(shifted)\(chordKey) does this without the leader")
        }
    }

    /// Leader-layer keys. Sticky: the layer stays open so `h h ⇧L 3` flows.
    private func handleLayerKey(keyCode: Int64, mods: Modifiers) {
        if keyCode == Key.escape { state = .inactive; return }
        guard !mods.command, !mods.control else { return }

        if let dir = direction(for: keyCode) {
            let command: Command = mods.shift ? .move(dir) : .focus(dir)
            noteLayerUsage(command, chordKey: ["left": "H", "down": "J", "up": "K", "right": "L"][dir.rawValue] ?? "")
            onCommand?(command)
            layerCommandIssued()
            return
        }
        if let n = workspaceNumber(for: keyCode) {
            let command: Command = mods.shift ? .moveToWorkspace(n) : .goToWorkspace(n)
            noteLayerUsage(command, chordKey: "\(n)")
            onCommand?(command)
            layerCommandIssued()
            return
        }
        switch keyCode {
        case Key.t: onCommand?(.toggleFloat); layerCommandIssued()
        case Key.m: onCommand?(.toggleMonocle); layerCommandIssued()
        case Key.s: onCommand?(.splitPreselect(.horizontal)); layerCommandIssued()
        case Key.v: onCommand?(.splitPreselect(.vertical)); layerCommandIssued()
        case Key.space: onCommand?(.cycleLayout); layerCommandIssued()
        case Key.equals: onCommand?(.balance); layerCommandIssued()
        case Key.r: state = .resize
        case Key.p:
            state = .inactive // palette takes over the keyboard
            onTogglePalette?()
        case Key.w: onCommand?(.rescueWindows); layerCommandIssued()
        case Key.q: onCommand?(.closeWindow); layerCommandIssued()
        case Key.tab: onCommand?(.focusNextDisplay); layerCommandIssued()
        case Key.slash where mods.shift: onToggleHelp?()
        default: rearmLayerTimeout() // unknown keys are consumed and ignored
        }
    }

    private func handleResizeKey(keyCode: Int64, mods: Modifiers) {
        if keyCode == Key.escape || keyCode == Key.r {
            state = .layer
            return
        }
        if let dir = direction(for: keyCode) {
            onCommand?(.resize(dir, fine: mods.shift))
        }
    }
}

/// Carbon hot-key callback (Secure Input fallback) — delivered on the main
/// thread via the application event target.
private nonisolated func carbonHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotkeyService.shared?.carbonHotkeyFired(id: id)
    }
    return noErr
}

/// Tap callback — runs on the main thread (the tap source lives on the main
/// run loop), so hopping onto the MainActor is safe.
private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The tap source lives on the main run loop; this is the main thread.
    nonisolated(unsafe) let unsafeEvent = event
    let consumed = MainActor.assumeIsolated {
        HotkeyService.shared?.handle(type: type, event: unsafeEvent) ?? false
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
