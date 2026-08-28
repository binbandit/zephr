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

    @Test func nonFiniteAndAstronomicalNumbersThrowInsteadOfTrapping() {
        // `Double("nan")` parses happily and `Int(1e100)` traps: an errant
        // config value used to crash the app on every launch (invariant 1: a
        // trap here strands every stashed window off-screen). All of these
        // must be inline parse errors, never traps.
        for value in ["1e100", "nan", "inf", "-inf", "-1e300"] {
            #expect(throws: ConfigError.self, "gaps = \(value)") {
                _ = try ConfigFile.parse("[layout]\ngaps = \(value)")
            }
        }
        #expect(throws: ConfigError.self) {
            _ = try ConfigFile.parse("[keys]\nlayer-timeout = nan")
        }
    }

    @Test func crlfFilesReportCorrectLineNumbers() {
        // CRLF files must report the line numbers the user's editor shows —
        // off-by-N errors point at the wrong line (§4.6).
        #expect(throws: ConfigError(line: 3, message: "expected a number, got nan")) {
            _ = try ConfigFile.parse("leader = \"alt-space\"\r\n[layout]\r\ngaps = nan")
        }
        #expect(throws: ConfigError(line: 2, message: "expected true or false, got maybe")) {
            _ = try ConfigFile.parse("[layout]\r\nfocus-border = maybe")
        }
    }

    @Test func commaInsideQuotedArrayElementSurvives() throws {
        let parsed = try ConfigFile.parse("""
        [callbacks]
        on-workspace-changed = ["a,b", "sketchybar --set spaces label=1,2,3"]
        """)
        #expect(parsed.onWorkspaceChanged == ["a,b", "sketchybar --set spaces label=1,2,3"])
    }

    @Test func invalidTitleRegexWarnsAndDropsOnlyThatRule() throws {
        // A rule that can never fire is worse than silence (§4.6) — but one
        // dead rule must not reject the file: everything else still applies.
        let parsed = try ConfigFile.parse("""
        leader = "ctrl-alt-space"

        [[rules]]
        app = "com.example.app"
        title = "(unclosed"
        action = "float"

        [[rules]]
        app = "com.example.tool"
        action = "ignore"
        """)
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("line 3")) // the [[rules]] header line
        #expect(parsed.warnings[0].contains("(unclosed"))
        #expect(parsed.warnings[0].contains("does not compile"))
        // Only the broken rule is dropped; the valid one survives …
        #expect(parsed.userRules == [
            WindowRule(bundleID: "com.example.tool", action: .ignore)
        ])
        // … and the rest of the config still applied.
        #expect(parsed.leader == LeaderBinding(control: true, option: true, key: "space"))
    }

    @Test func unmappableLeaderKeyWarnsAndKeepsTheDefaultLeader() throws {
        // A leader key HotkeyService can't bind would parse fine and then
        // silently never open the layer (§4.6: never silent) — but one bad
        // key must not revert the whole file to defaults either.
        let parsed = try ConfigFile.parse("""
        leader = "alt-f13"

        [layout]
        gaps = 12
        """)
        #expect(parsed.leader == .default)
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("line 1"))
        #expect(parsed.warnings[0].contains("\"f13\""))
        #expect(parsed.warnings[0].contains("a–z, 0–9, space, tab, or grave"))
        // The rest of the config still applied.
        #expect(parsed.layout.innerGap == 12)
        #expect(try ConfigFile.parse("leader = \"ctrl-alt-escape\"").leader == .default)
        // The boundary cases that must keep working, warning-free.
        #expect(try ConfigFile.parse("leader = \"alt-grave\"").leader.key == "grave")
        #expect(try ConfigFile.parse("leader = \"ctrl-alt-9\"").leader.key == "9")
        #expect(try ConfigFile.parse("leader = \"alt-grave\"").warnings.isEmpty)
    }

    @Test func invalidRuleStillAppliesLayoutAndKeys() throws {
        // The §4.6 promise this pins: one broken [[rules]] entry costs that
        // rule, never the user's layout, keys, or workspaces.
        let parsed = try ConfigFile.parse("""
        [layout]
        gaps = 12
        default = "accordion"

        [keys]
        preset = "i3"

        [workspaces]
        4 = "chat"

        [[rules]]
        app = "com.example.app"
        title = "(unclosed"
        action = "float"
        """)
        #expect(parsed.layout.innerGap == 12)
        #expect(parsed.layout.outerGap == 12)
        #expect(parsed.defaultLayout == .accordion)
        #expect(parsed.keyPreset == "i3")
        #expect(parsed.workspaceNames == [4: "chat"])
        #expect(parsed.userRules.isEmpty)
        #expect(parsed.warnings.count == 1)
    }

    @Test func duplicateKeysWarnNamingBothLines() throws {
        let parsed = try ConfigFile.parse("""
        [layout]
        gaps = 8
        gaps = 9
        """)
        #expect(parsed.layout.innerGap == 9) // last wins, as warned
        #expect(parsed.warnings.contains { $0.contains("line 3") && $0.contains("line 2") && $0.contains("gaps") })
        // Same key in different sections is not a duplicate.
        let clean = try ConfigFile.parse("menu-bar-icon = true\n[layout]\ngaps = 4")
        #expect(clean.warnings.isEmpty)
    }

    @Test func escapedQuotesAndHashesInsideStringsSurvive() throws {
        let parsed = try ConfigFile.parse(#"""
        [workspaces]
        1 = "a \"b\" # not a comment"

        [[rules]]
        app = "com.example.app"
        title = "Save \"draft\" #1"
        action = "float"
        """#)
        #expect(parsed.workspaceNames[1] == #"a "b" # not a comment"#)
        #expect(parsed.userRules.count == 1)
        #expect(parsed.userRules[0].titlePattern == #"Save "draft" #1"#)
    }
}
