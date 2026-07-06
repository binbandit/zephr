import AppKit
import ServiceManagement
import SwiftUI
import ZephrCore

/// The Settings window (§4.6): every control reads from and writes to
/// config.toml through the targeted editor, so hand-edits and the GUI never
/// fight. "Fully usable without ever opening Settings, and fully
/// configurable without ever opening Settings" (§5) — this is the second half.
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
    @State private var floatDefaults: Set<Int> = []

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
                        .onSubmit { commitName(n) }
                    Toggle("Float", isOn: floatBinding(for: n))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(20)
        .onAppear {
            guard let current = config?.current else { return }
            names = current.workspaceNames
            floatDefaults = Set(current.floatByDefaultWorkspaces)
        }
    }

    private func binding(for n: Int) -> Binding<String> {
        Binding(get: { names[n] ?? "" }, set: { names[n] = $0 })
    }

    private func commitName(_ n: Int) {
        let name = (names[n] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        config?.setValue(section: "workspaces", key: "\(n)", value: "\"\(name)\"")
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

    private var config: ConfigService? { AppDelegate.shared?.configService }

    var body: some View {
        Form {
            Picker("Leader key:", selection: $leader) {
                Text("⌥ Space").tag("alt-space")
                Text("⌃⌥ Space").tag("ctrl-alt-space")
                Text("⌘⌥ Space").tag("cmd-alt-space")
            }
            .onChange(of: leader) { _, new in config?.setLeader(new) }

            Picker("Key preset:", selection: $preset) {
                Text("Default (⌃⌥ chords)").tag("default")
                Text("i3 (⌘⌥ chords)").tag("i3")
                Text("AeroSpace (bare ⌥ — breaks ⌥-typing)").tag("aerospace")
                Text("Vim (leader only, no chords)").tag("vim")
            }
            .onChange(of: preset) { _, new in
                config?.setValue(section: "keys", key: "preset", value: "\"\(new)\"")
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, _ in
                    AppDelegate.shared?.toggleLaunchAtLogin()
                }

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
            leader = [l.control ? "ctrl" : nil, l.option ? "alt" : nil, l.command ? "cmd" : nil, l.key]
                .compactMap { $0 }.joined(separator: "-")
            preset = current.keyPreset
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
            Slider(value: $gaps, in: 0...32, step: 1) {
                Text("Gaps: \(Int(gaps)) pt")
            }
            .onChange(of: gaps) { _, new in
                config?.setValue(section: "layout", key: "gaps", value: "\(Int(new))")
            }

            Slider(value: $accordionPadding, in: 16...96, step: 4) {
                Text("Accordion sliver: \(Int(accordionPadding)) pt")
            }
            .onChange(of: accordionPadding) { _, new in
                config?.setValue(section: "layout", key: "accordion-padding", value: "\(Int(new))")
            }

            Toggle("Focused-window border", isOn: $focusBorder)
                .onChange(of: focusBorder) { _, new in
                    config?.setValue(section: "layout", key: "focus-border", value: new ? "true" : "false")
                }

            Picker("New workspaces start as:", selection: $defaultLayout) {
                Text("Tiles").tag("tiles")
                Text("Accordion").tag("accordion")
            }
            .onChange(of: defaultLayout) { _, new in
                config?.setValue(section: "layout", key: "default", value: "\"\(new)\"")
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
                            config?.removeRule(app: rule.bundleID, title: rule.titlePattern)
                            refresh()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
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
                Button("Add") {
                    guard !newApp.isEmpty else { return }
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
        // Give the hot reload a beat to re-parse after a write.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            userRules = config?.current.userRules ?? []
        }
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
