import Testing
@testable import ZephrCore

/// `ConfigEdit` is the only code that rewrites the user's real config file,
/// so every test here round-trips through `ConfigFile.parse` rather than
/// asserting on strings alone: an edit that produces text the parser rejects
/// (or silently reads differently) is a data-loss bug, not a formatting one.
@Suite("Config file edits")
struct ConfigEditTests {

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
    private func text(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    /// Uncomments the shipped `# [[rules]]` example the way a user would.
    private func uncommentRulesExample(_ lines: [String]) -> [String] {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# "),
                  trimmed.contains("[[rules]]") || trimmed.hasPrefix("# app =")
                    || trimmed.hasPrefix("# title =") || trimmed.hasPrefix("# action =")
            else { return line }
            return String(trimmed.dropFirst(2))
        }
    }

    // MARK: - Section boundaries

    /// A key written into a section must not be parked past the commented
    /// example block that follows it. It parses fine either way — until the
    /// user accepts the file's own invitation to uncomment the example, at
    /// which point the stranded key is captured by `[[rules]]` and either
    /// vanishes or breaks the whole file.
    @Test func aKeyNeverLandsInsideACommentedExampleBlock() throws {
        var l = lines(ConfigFile.defaultText)
        l = ConfigEdit.setValue(l, section: "workspaces", key: "1", value: "\"code\"")

        let named = try ConfigFile.parse(text(l))
        #expect(named.workspaceNames[1] == "code")

        // The user uncomments the shipped [[rules]] example.
        let after = try ConfigFile.parse(text(uncommentRulesExample(l)))
        #expect(after.workspaceNames[1] == "code", "workspace name was swallowed by [[rules]]")
        #expect(after.userRules.count == 1)
        #expect(after.userRules.first?.bundleID == "com.example.app")
    }

    @Test func commentedHeadersBoundASectionForAnExistingTable() throws {
        // [keys] is followed by the commented [workspaces] example, so a new
        // key in [keys] must stop short of it.
        var l = lines(ConfigFile.defaultText)
        l = ConfigEdit.setValue(l, section: "keys", key: "one-shot", value: "true")

        let keysIndex = l.firstIndex { ConfigEdit.header($0) == "[keys]" }!
        let exampleIndex = l.firstIndex { ConfigEdit.commentedHeader($0) == "[workspaces]" }!
        let keyIndex = l.firstIndex { ConfigEdit.declaresKey($0, key: "one-shot") }!
        #expect(keyIndex > keysIndex && keyIndex < exampleIndex)
        #expect(try ConfigFile.parse(text(l)).layerOneShot == true)
    }

    @Test func aMissingSectionReusesTheCommentedHeader() throws {
        var l = lines(ConfigFile.defaultText)
        l = ConfigEdit.setValue(l, section: "workspaces", key: "4", value: "\"chat\"")
        // Reused, not duplicated.
        #expect(l.filter { ConfigEdit.header($0) == "[workspaces]" }.count == 1)
        #expect(try ConfigFile.parse(text(l)).workspaceNames[4] == "chat")
    }

    @Test func anAbsentSectionIsAppended() throws {
        let l = ConfigEdit.setValue(["leader = \"alt-space\""], section: "layout", key: "gaps", value: "4")
        #expect(try ConfigFile.parse(text(l)).layout.innerGap == 4)
    }

    // MARK: - Rule identity

    /// Two rules for one app differing only in action are identical to a
    /// content match, so deleting the second used to delete the first.
    @Test func removingARuleDeletesTheBlockAtThatPosition() throws {
        let source = """
        [[rules]]
        app = "com.slack"
        action = "workspace 4"

        [[rules]]
        app = "com.slack"
        action = "float"
        """
        let parsed = try ConfigFile.parse(source)
        #expect(parsed.userRules.count == 2)

        let floatRule = parsed.userRules[1]
        #expect(floatRule.action == .float)
        let edited = ConfigEdit.removeRule(lines(source), at: floatRule.sourceOrdinal!)

        let after = try ConfigFile.parse(text(edited))
        #expect(after.userRules.count == 1)
        #expect(after.userRules.first?.action == .workspace(4))
    }

    /// The parser drops a rule whose title regex will not compile, so a
    /// position in `userRules` is not a position in the file.
    @Test func sourceOrdinalSurvivesADroppedRule() throws {
        let source = """
        [[rules]]
        app = "com.first"
        title = "^(unclosed"
        action = "float"

        [[rules]]
        app = "com.second"
        action = "float"
        """
        let parsed = try ConfigFile.parse(source)
        #expect(parsed.userRules.count == 1)
        #expect(parsed.warnings.count == 1)

        let survivor = parsed.userRules[0]
        #expect(survivor.bundleID == "com.second")
        #expect(survivor.sourceOrdinal == 1, "ordinal must index the file, not the parsed array")

        let edited = ConfigEdit.removeRule(lines(source), at: survivor.sourceOrdinal!)
        #expect(text(edited).contains("com.first"))
        #expect(!text(edited).contains("com.second"))
    }

    /// `removeRule` used to compare a raw line against a quoted literal, so
    /// any rule carrying a trailing comment silently refused to delete.
    @Test func aTrailingCommentDoesNotBlockRemoval() throws {
        let source = """
        [[rules]]   # my chat app
        app = "com.slack"   # the bundle id
        action = "float"
        """
        let parsed = try ConfigFile.parse(source)
        #expect(parsed.userRules.count == 1)
        let edited = ConfigEdit.removeRule(lines(source), at: parsed.userRules[0].sourceOrdinal!)
        #expect(try ConfigFile.parse(text(edited)).userRules.isEmpty)
    }

    @Test func addingARuleThatAlreadyExistsIsANoOp() throws {
        let rule = ConfigEdit.RuleEdit(app: "com.slack", action: "float")
        let once = ConfigEdit.addRules(lines(ConfigFile.defaultText), [rule])
        let twice = ConfigEdit.addRules(once, [rule, rule])
        #expect(once == twice)
        #expect(try ConfigFile.parse(text(twice)).userRules.count == 1)
    }

    // MARK: - Round-trip fidelity (§4.6)

    @Test func editingAValueKeepsItsCommentColumn() {
        let l = ConfigEdit.setValue(
            ["gaps = 8                      # points between windows and screen edges"],
            section: nil, key: "gaps", value: "12")
        #expect(l[0].hasSuffix("# points between windows and screen edges"))
        #expect(l[0].firstIndex(of: "#") == l[0].index(l[0].startIndex, offsetBy: 30))
    }

    @Test func repeatedAddRemoveCyclesLeaveTheFileByteIdentical() {
        let original = lines(ConfigFile.defaultText)
        var l = original
        for i in 0..<50 {
            l = ConfigEdit.addRules(l, [ConfigEdit.RuleEdit(app: "com.app\(i)", action: "float")])
            l = ConfigEdit.removeRule(l, at: 0)
        }
        #expect(l == original)
    }

    @Test func repeatedValueWritesDoNotGrowTheFile() {
        let original = lines(ConfigFile.defaultText)
        var l = original
        for value in 0..<40 {
            l = ConfigEdit.setValue(l, section: "layout", key: "gaps", value: "\(value)")
        }
        #expect(l.count == original.count)
        l = ConfigEdit.setValue(l, section: "layout", key: "gaps", value: "8")
        #expect(l == original)
    }

    /// The writer and the parser must be exact inverses, or a window title
    /// containing a quote produces a config that no longer parses and the
    /// user's edits silently stop applying.
    @Test(arguments: [
        #"Say "hi""#,
        #"back\slash"#,
        "hash # not a comment",
        "^\\(43\\) YouTube$",
        "tab\there",
    ])
    func awkwardStringsSurviveTheWriteParseRoundTrip(_ raw: String) throws {
        let l = ConfigEdit.addRules(
            lines(ConfigFile.defaultText),
            [ConfigEdit.RuleEdit(app: "com.example", title: raw, action: "float")])
        let parsed = try ConfigFile.parse(text(l))
        #expect(parsed.userRules.last?.titlePattern == raw)
    }

    /// A `#` inside a quoted value is not a comment, and the four
    /// implementations of this that used to exist did not agree.
    @Test func commentSplittingRespectsStringsAndEscapes() {
        #expect(ConfigEdit.splitComment(#"a = "x # y"  # real"#).body == #"a = "x # y"  "#)
        #expect(ConfigEdit.splitComment(#"a = "x \" # y""#).comment == nil)
        #expect(ConfigEdit.splitComment("plain = 1").comment == nil)
    }

    /// Every shipped default must parse without a single warning — the file
    /// the user is handed on first run is also the file they learn from.
    @Test func theShippedDefaultsParseCleanly() throws {
        let parsed = try ConfigFile.parse(ConfigFile.defaultText)
        #expect(parsed.warnings.isEmpty, "\(parsed.warnings)")
    }
}
