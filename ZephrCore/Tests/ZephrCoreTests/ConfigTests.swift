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
        #expect(parsed.focusBorder.enabled == false)
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

    @Test func focusBorderAppearanceParses() throws {
        let parsed = try ConfigFile.parse("""
        [layout]
        focus-border-color = "#7AA2F7CC"
        focus-border-width = 3
        focus-border-radius = 0
        """)
        #expect(parsed.focusBorder.enabled) // untouched by the appearance keys
        #expect(parsed.focusBorder.color == RGBAColor(hex: "#7AA2F7CC"))
        #expect(parsed.focusBorder.width == 3)
        #expect(parsed.focusBorder.cornerRadius == 0)
    }

    @Test func accentKeywordMeansUnset() throws {
        // "unset" has to stay distinguishable from "set to a color": the
        // accent is a live system setting, so no hex can stand in for it.
        #expect(try ConfigFile.parse("[layout]\nfocus-border-color = \"accent\"").focusBorder.color == nil)
        #expect(try ConfigFile.parse("[layout]\nfocus-border-color = \"ACCENT\"").focusBorder.color == nil)
        #expect(try ConfigFile.parse("[layout]\nfocus-border-color = \"accent\"").warnings.isEmpty)
        #expect(try ConfigFile.parse("[layout]\nfocus-border = false").focusBorder == FocusBorderStyle(enabled: false))
    }

    @Test func badBorderAppearanceWarnsAndKeepsTheRestOfTheFile() throws {
        // Cosmetic keys warn and fall back; a typo in one must not cost the
        // user every other edit in the same save (§4.6).
        let parsed = try ConfigFile.parse("""
        [layout]
        gaps = 12
        focus-border-color = "burnt sienna"
        focus-border-width = 900
        focus-border-radius = nan
        """)
        #expect(parsed.focusBorder == .default)
        #expect(parsed.layout.innerGap == 12)
        #expect(parsed.warnings.count == 3)
        #expect(parsed.warnings[0].contains("line 3") && parsed.warnings[0].contains("is not a color"))
        #expect(parsed.warnings[1].contains("line 4") && parsed.warnings[1].contains("0.5 to 20"))
        #expect(parsed.warnings[2].contains("line 5") && parsed.warnings[2].contains("0 to 64"))
    }

    @Test func bareHashColorNamesTheRealProblem() {
        // `#` opens a comment, so this line parses as a value-less key. The
        // bare message ("missing value") points at a line that looks fine.
        #expect(throws: ConfigError(
            line: 2,
            message: "missing value for `focus-border-color` - `#` starts a comment; quote it as \"#7AA2F7\""
        )) {
            _ = try ConfigFile.parse("[layout]\nfocus-border-color = #7AA2F7")
        }
    }

    @Test func focusBorderTypoGetsASuggestion() throws {
        let parsed = try ConfigFile.parse("[layout]\nfocus-border-colour = \"#fff\"")
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings[0].contains("did you mean `focus-border-color`"))
    }
}

@Suite("Hex colors")
struct HexColorTests {

    @Test func acceptedForms() throws {
        let blue = RGBAColor(red: 0x7A / 255, green: 0xA2 / 255, blue: 0xF7 / 255)
        #expect(RGBAColor(hex: "#7AA2F7") == blue)
        #expect(RGBAColor(hex: "7aa2f7") == blue)          // no #, lowercase
        #expect(RGBAColor(hex: "  #7AA2F7  ") == blue)     // surrounding space
        #expect(RGBAColor(hex: "#000") == RGBAColor(red: 0, green: 0, blue: 0))
        // #RGB doubles each nibble, so "f" is 255 and not 15.
        #expect(RGBAColor(hex: "#fff") == RGBAColor(red: 1, green: 1, blue: 1))
        #expect(RGBAColor(hex: "#FF000080")?.alpha == 128.0 / 255)
        #expect(RGBAColor(hex: "#FF0000FF") == RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
    }

    @Test func garbageIsRejectedRatherThanGuessed() {
        // Every one of these has to come back nil so the parser can warn with
        // a line number instead of painting an arbitrary color.
        for bad in ["", "#", "#12", "#12345", "#1234567", "#123456789",
                    "burnt sienna", "#GGHHII", "0x7AA2F7", "#-12345", "#+00FF00",
                    "rgb(1,2,3)", "＃ＦＦＦ"] {
            #expect(RGBAColor(hex: bad) == nil, "\(bad) should not parse")
        }
    }

    @Test func hexStringRoundTrips() throws {
        // What the Settings color well writes must be re-readable by hand.
        for hex in ["#000000", "#FFFFFF", "#7AA2F7", "#7AA2F7CC", "#12345678"] {
            let color = try #require(RGBAColor(hex: hex))
            #expect(color.hexString == hex)
            #expect(RGBAColor(hex: color.hexString) == color)
        }
        // Opaque colors drop the redundant alpha pair.
        #expect(RGBAColor(hex: "#7AA2F7FF")?.hexString == "#7AA2F7")
        // Out-of-gamut components clamp instead of overflowing the format.
        #expect(RGBAColor(red: -1, green: 2, blue: 0.5).hexString == "#00FF80")
    }
}

@Suite("Leader key table")
struct LeaderKeyTableTests {

    /// These are the ANSI virtual key codes the event tap compares against.
    /// A wrong number here binds the leader to the wrong physical key, which
    /// no other test would catch.
    @Test func knownCodesAreCorrect() {
        let codes = LeaderBinding.keyCodesByName
        #expect(codes["space"] == 49)
        #expect(codes["tab"] == 48)
        #expect(codes["grave"] == 50)
        #expect(codes["`"] == codes["grave"])
        #expect(codes["a"] == 0)
        #expect(codes["h"] == 4)
        #expect(codes["j"] == 38)
        #expect(codes["k"] == 40)
        #expect(codes["l"] == 37)
        #expect(codes["z"] == 6)
        #expect(codes["0"] == 29)
        #expect(codes["1"] == 18)
        #expect(codes["9"] == 25)
    }

    /// Every accepted name must map, or a config the parser blesses leaves
    /// the old leader silently bound (§4.6).
    @Test func everyAcceptedNameMaps() {
        for name in LeaderBinding.knownKeyNames {
            #expect(LeaderBinding.keyCodesByName[name] != nil, "\(name) has no key code")
        }
        #expect(LeaderBinding.knownKeyNames.count == 26 + 10 + 4)
    }
}
