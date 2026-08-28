import AppKit
import ServiceManagement
import SwiftUI
import ZephrCore

/// The Settings window (§4.6): every control reads from and writes to
/// config.toml through the targeted editor, so hand-edits and the GUI never
/// fight. "Fully usable without ever opening Settings, and fully
/// configurable without ever opening Settings" (§5) — this is the second half.
/// A binding that persists only on user edits: `onAppear` seeding assigns the
/// `@State` directly and never reaches the setter, so merely opening Settings
/// can't rewrite the config or flip real state — §4.6's round-trip guarantee
/// ("except the keys actually changed"). `onChange` cannot make that
/// distinction: it fires for programmatic seeding too.
private func writeThrough<T>(_ state: Binding<T>, _ write: @escaping (T) -> Void) -> Binding<T> {
    Binding(
        get: { state.wrappedValue },
        set: { state.wrappedValue = $0; write($0) }
    )
}

/// A slider that previews live and writes once, on release.
///
/// Writing per step rewrites, re-parses and re-applies the whole config —
/// a full desktop re-layout — on every one of the ~30 stops in a single
/// drag. That is a main-thread stall §6.3 forbids outright, and a long
/// enough one gets the event tap killed with `kCGEventTapDisabledByTimeout`,
/// taking the keyboard with it. Binding straight to `@State` also means
/// `onAppear` seeding cannot write, the same guarantee `writeThrough` gives.
private struct CommittingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String
    let commit: (Double) -> Void

    var body: some View {
        Slider(value: $value, in: range, step: step) {
            Text(label(value))
        } onEditingChanged: { editing in
            if !editing { commit(value) }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            LayoutSettings()
                .tabItem { Label("Layout", systemImage: "rectangle.split.3x1") }
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            WorkspacesSettings()
                .tabItem { Label("Workspaces", systemImage: "square.grid.3x3") }
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "display.2") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct WorkspacesSettings: View {
    @State private var names: [Int: String] = [:]
    @State private var savedNames: [Int: String] = [:]
    @State private var floatDefaults: Set<Int> = []
    @FocusState private var focusedRow: Int?

    private var config: ConfigService? { AppDelegate.shared?.configService }

    var body: some View {
        Form {
            Text("Names show in the menu bar, palette, and zephrctl. Float-by-default makes a workspace a junk drawer: new windows float.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(1...9, id: \.self) { n in
                HStack {
                    Text("\(n)").monospacedDigit().frame(width: 18)
                    TextField("name", text: binding(for: n))
                        .focused($focusedRow, equals: n)
                        .onSubmit { commitName(n) }
                    Toggle("Float", isOn: floatBinding(for: n))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(20)
        // Enter-only commits lose edits — commit on focus loss too (§4.6).
        .onChange(of: focusedRow) { old, _ in
            if let old { commitName(old) }
        }
        .onAppear {
            guard let current = config?.current else { return }
            names = current.workspaceNames
            savedNames = current.workspaceNames
            floatDefaults = Set(current.floatByDefaultWorkspaces)
        }
    }

    private func binding(for n: Int) -> Binding<String> {
        Binding(get: { names[n] ?? "" }, set: { names[n] = $0 })
    }

    private func commitName(_ n: Int) {
        let name = (names[n] ?? "").trimmingCharacters(in: .whitespaces)
        // Only write what actually changed (§4.6); empty clears the name.
        // (True key removal needs a ConfigService `removeValue`; an empty
        // string parses cleanly and the UI treats it as unnamed.)
        guard name != (savedNames[n] ?? "") else { return }
        savedNames[n] = name
        config?.setValue(section: "workspaces", key: "\(n)", value: ConfigEdit.tomlQuoted(name))
    }

    private func floatBinding(for n: Int) -> Binding<Bool> {
        Binding(
            get: { floatDefaults.contains(n) },
            set: { on in
                if on { floatDefaults.insert(n) } else { floatDefaults.remove(n) }
                let list = floatDefaults.sorted().map(String.init).joined(separator: ", ")
                config?.setValue(section: "workspaces", key: "float-by-default", value: "[\(list)]")
            }
        )
    }
}

private struct ProfilesSettings: View {
    @State private var profiles: [(fingerprint: String, windowCount: Int)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zephr records a layout profile per display arrangement and restores it exactly on redock or relaunch. Delete one to forget it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(profiles, id: \.fingerprint) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.fingerprint)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(profile.windowCount) windows recorded")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            AppDelegate.shared?.engine.deleteProfile(profile.fingerprint)
                            refresh()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete profile \(profile.fingerprint)")
                    }
                }
                if profiles.isEmpty {
                    Text("No profiles recorded yet.").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .onAppear { refresh() }
    }

    private func refresh() {
        profiles = AppDelegate.shared?.engine.storedProfiles() ?? []
    }
}

private struct GeneralSettings: View {
    @State private var leader = "alt-space"
    @State private var preset = "default"
    @State private var launchAtLogin = false
    @State private var menuBarIcon = true
    @State private var dockIcon = false

    private var config: ConfigService? { AppDelegate.shared?.configService }

    var body: some View {
        Form {
            Picker("Leader key:", selection: writeThrough($leader) { config?.setLeader($0) }) {
                Text("⌥ Space").tag("alt-space")
                Text("⌃⌥ Space").tag("ctrl-alt-space")
                Text("⌘⌥ Space").tag("cmd-alt-space")
            }

            Picker("Key preset:", selection: writeThrough($preset) {
                config?.setValue(section: "keys", key: "preset", value: "\"\($0)\"")
            }) {
                Text("Default (⌃⌥ chords)").tag("default")
                Text("i3 (⌘⌥ chords)").tag("i3")
                Text("AeroSpace (bare ⌥ — breaks ⌥-typing)").tag("aerospace")
                Text("Vim (leader only, no chords)").tag("vim")
            }

            Toggle("Launch at login", isOn: writeThrough($launchAtLogin) {
                AppDelegate.shared?.setLaunchAtLogin($0)
            })

            Toggle("Show menu bar icon", isOn: Binding(
                get: { menuBarIcon },
                set: { on in
                    menuBarIcon = on
                    if !on && !dockIcon {
                        // §5: never let the GUI hide every surface at once —
                        // an LSUIElement app with no status item, no Dock
                        // icon, and no window is unreachable.
                        dockIcon = true
                        config?.setValue(section: nil, key: "dock-icon", value: "true")
                    }
                    config?.setValue(section: nil, key: "menu-bar-icon", value: on ? "true" : "false")
                }
            ))
            if !menuBarIcon {
                Text("With the icon hidden, the Dock icon stays on so Zephr remains reachable. Bring the icon back anytime with menu-bar-icon = true in ~/.config/zephr/config.toml.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Show Dock icon", isOn: Binding(
                get: { dockIcon },
                set: { on in
                    dockIcon = on
                    if !on && !menuBarIcon {
                        menuBarIcon = true
                        config?.setValue(section: nil, key: "menu-bar-icon", value: "true")
                    }
                    config?.setValue(section: nil, key: "dock-icon", value: on ? "true" : "false")
                }
            ))

            LabeledContent("Config file:") {
                Button("Open in Editor") { config?.openInEditor() }
            }
            LabeledContent("Diagnostics:") {
                Button("Run Doctor") { AppDelegate.shared?.doctor.present() }
            }
            LabeledContent("Tutorial:") {
                Button("Replay") { AppDelegate.shared?.onboarding.present(startAt: .tutorial) }
            }
            if ImportService.anythingToImport {
                LabeledContent("Migration:") {
                    Button("Import from AeroSpace / Amethyst…") {
                        guard let config else { return }
                        ImportService.runAndShowReport(config: config)
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            guard let current = config?.current else { return }
            let l = current.leader
            // Canonical modifier order, matching the Picker tags: a fixed
            // ctrl/alt/cmd order rendered ⌘⌥ Space as "alt-cmd-space" — no
            // tag matched, the Picker went blank, and the mismatch rewrote
            // the config with the malformed string.
            leader = [l.control ? "ctrl" : nil, l.command ? "cmd" : nil, l.option ? "alt" : nil, l.key]
                .compactMap { $0 }.joined(separator: "-")
            preset = current.keyPreset
            launchAtLogin = SMAppService.mainApp.status == .enabled
            menuBarIcon = current.showMenuBarIcon
            dockIcon = current.showDockIcon
        }
    }
}

private struct LayoutSettings: View {
    @State private var gaps: Double = 8
    @State private var accordionPadding: Double = 48
    @State private var focusBorder = true
    @State private var defaultLayout = "tiles"

    private var config: ConfigService? { AppDelegate.shared?.configService }

    var body: some View {
        Form {
            CommittingSlider(
                value: $gaps, range: 0...32, step: 1,
                label: { "Gaps: \(Int($0)) pt" },
                commit: { config?.setValue(section: "layout", key: "gaps", value: "\(Int($0))") }
            )

            CommittingSlider(
                value: $accordionPadding, range: 16...96, step: 4,
                label: { "Accordion sliver: \(Int($0)) pt" },
                commit: { config?.setValue(section: "layout", key: "accordion-padding", value: "\(Int($0))") }
            )

            Toggle("Focused-window border", isOn: writeThrough($focusBorder) {
                config?.setValue(section: "layout", key: "focus-border", value: $0 ? "true" : "false")
            })

            Picker("New workspaces start as:", selection: writeThrough($defaultLayout) {
                config?.setValue(section: "layout", key: "default", value: "\"\($0)\"")
            }) {
                Text("Tiles").tag("tiles")
                Text("Accordion").tag("accordion")
            }
        }
        .padding(20)
        .onAppear {
            guard let current = config?.current else { return }
            gaps = Double(current.layout.innerGap)
            accordionPadding = Double(current.layout.accordionPadding)
            focusBorder = current.focusBorder
            defaultLayout = current.defaultLayout.rawValue
        }
    }
}

private struct RulesSettings: View {
    @State private var userRules: [WindowRule] = []
    @State private var newApp = ""
    @State private var newTitle = ""
    @State private var newAction = "float"

    private var config: ConfigService? { AppDelegate.shared?.configService }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your rules run before Zephr's built-in list; first match wins.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(userRules.enumerated()), id: \.offset) { _, rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.bundleID).font(.system(.body, design: .monospaced))
                            if let title = rule.titlePattern {
                                Text("title ~ \(title)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(label(rule.action)).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            // Delete by the block's own position in the file:
                            // two rules for one app differing only in action
                            // are identical to a content match.
                            if let ordinal = rule.sourceOrdinal {
                                config?.removeRule(at: ordinal)
                            }
                            refresh()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete rule for \(rule.bundleID)")
                    }
                }
                if userRules.isEmpty {
                    Text("No custom rules yet.").foregroundStyle(.tertiary)
                }
            }

            HStack {
                TextField("Bundle id (com.example.app)", text: $newApp)
                TextField("Title regex (optional)", text: $newTitle)
                Picker("", selection: $newAction) {
                    Text("Float").tag("float")
                    Text("Tile").tag("tile")
                    Text("Ignore").tag("ignore")
                }
                .frame(width: 90)
                .accessibilityLabel("Rule action")
                Button("Add") {
                    guard !newApp.isEmpty else { return }
                    // Raw strings: addRule TOML-escapes internally (§4.6).
                    config?.addRule(app: newApp, title: newTitle.isEmpty ? nil : newTitle, action: newAction)
                    newApp = ""; newTitle = ""
                    refresh()
                }
            }
            Button("Add Rule for Focused Window…") {
                guard let info = AppDelegate.shared?.engine.focusedWindowInfo() else { return }
                newApp = info.bundleID
                newTitle = ""
            }
            .controlSize(.small)
        }
        .padding(20)
        .onAppear { refresh() }
    }

    private func refresh() {
        // `ConfigService.write` reloads and reparses before it returns, so
        // `current` is already the post-write state — no need to race the
        // file watcher's debounced reload for it.
        userRules = config?.current.userRules ?? []
    }

    private func label(_ action: WindowRule.Action) -> String {
        switch action {
        case .float: "float"
        case .tile: "tile"
        case .ignore: "ignore"
        case .workspace(let n): "workspace \(n)"
        }
    }
}
