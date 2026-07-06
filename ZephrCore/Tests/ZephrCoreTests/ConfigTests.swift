import Testing
import CoreGraphics
@testable import ZephrCore

@Suite("Config file")
struct ConfigTests {

    @Test func defaultTextParsesToDefaults() throws {
        let parsed = try ConfigFile.parse(ConfigFile.defaultText)
        #expect(parsed == ParsedConfig())
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.leader == .default)
        #expect(parsed.layout == .default)
    }

    @Test func emptyFileIsACompleteConfig() throws {
        let parsed = try ConfigFile.parse("")
        #expect(parsed == ParsedConfig())
    }

    @Test func customValuesApply() throws {
        let parsed = try ConfigFile.parse("""
        leader = "ctrl-alt-space"

        [layout]
        gaps = 12
        outer-gaps = 4
        focus-border = false
        default = "accordion"

        [callbacks]
        on-workspace-changed = ["echo one", "echo two"]
        """)
        #expect(parsed.leader == LeaderBinding(control: true, option: true, key: "space"))
        #expect(parsed.layout.innerGap == 12)
        #expect(parsed.layout.outerGap == 4)
        #expect(parsed.focusBorder == false)
        #expect(parsed.defaultLayout == .accordion)
        #expect(parsed.onWorkspaceChanged == ["echo one", "echo two"])
    }

    @Test func rulesParse() throws {
        let parsed = try ConfigFile.parse("""
        [[rules]]
        app = "us.zoom.xos"
        title = "^zoom floating"
        action = "float"

        [[rules]]
        app = "com.example.tool"
        action = "ignore"
        """)
        #expect(parsed.userRules == [
            WindowRule(bundleID: "us.zoom.xos", titlePattern: "^zoom floating", action: .float),
            WindowRule(bundleID: "com.example.tool", action: .ignore),
        ])
    }

    @Test func errorsCarryLineNumbers() {
        #expect(throws: ConfigError(line: 2, message: "expected true or false, got maybe")) {
            _ = try ConfigFile.parse("[layout]\nfocus-border = maybe")
        }
        #expect(throws: ConfigError(line: 1, message: "expected `key = value`")) {
            _ = try ConfigFile.parse("what is this")
        }
    }

    @Test func ruleWithoutActionFails() {
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("[[rules]]\napp = \"com.example\"")
        }
    }

    @Test func badLeaderFails() {
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("leader = \"space\"")
        }
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("leader = \"shift-space\"") // no ctrl/alt/cmd
        }
    }

    @Test func workspaceSectionParses() throws {
        let parsed = try ConfigFile.parse("""
        [workspaces]
        1 = "code"
        4 = "chat"
        float-by-default = [9]
        """)
        #expect(parsed.workspaceNames == [1: "code", 4: "chat"])
        #expect(parsed.floatByDefaultWorkspaces == [9])
    }

    @Test func workspaceRuleActionParses() throws {
        let parsed = try ConfigFile.parse("""
        [[rules]]
        app = "com.tinyspeck.slackmacgap"
        action = "workspace 4"
        """)
        #expect(parsed.userRules == [
            WindowRule(bundleID: "com.tinyspeck.slackmacgap", action: .workspace(4))
        ])
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("[[rules]]\napp = \"x\"\naction = \"workspace 12\"")
        }
    }

    @Test func unknownKeysWarnWithSuggestion() throws {
        let parsed = try ConfigFile.parse("""
        [layout]
        gapz = 8
        """)
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("did you mean `gaps`"))
        #expect(parsed.layout == .default)
    }

    @Test func layerAndAppOptionsParse() throws {
        let parsed = try ConfigFile.parse("""
        dock-icon = true

        [keys]
        one-shot = true
        layer-timeout = 5
        """)
        #expect(parsed.showDockIcon)
        #expect(parsed.layerOneShot)
        #expect(parsed.layerTimeout == 5)
    }

    @Test func menuBarIconDefaultsOnAndWarnsWhenAllSurfacesOff() throws {
        #expect(try ConfigFile.parse("").showMenuBarIcon)
        let off = try ConfigFile.parse("menu-bar-icon = false")
        #expect(!off.showMenuBarIcon)
        // No menu bar item AND no Dock icon: warn, never strand silently.
        #expect(off.warnings.contains { $0.contains("both off") })
        let dockOnly = try ConfigFile.parse("menu-bar-icon = false\ndock-icon = true")
        #expect(dockOnly.warnings.isEmpty)
    }

    @Test func commentsAndGapsRangeEnforced() throws {
        let parsed = try ConfigFile.parse("""
        [layout]
        gaps = 0   # flush tiling, no ricing
        """)
        #expect(parsed.layout.innerGap == 0)
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("[layout]\ngaps = 5000")
        }
    }
}
