import Testing
@testable import ZephrCore

@Suite("Command vocabulary")
struct CommandParsingTests {

    @Test(arguments: [
        ("balance", Command.balance),
        ("focus left", .focus(.left)),
        ("move right", .move(.right)),
        ("workspace 3", .goToWorkspace(3)),
        ("send-to-workspace 9", .moveToWorkspace(9)),
        ("summon 2", .summonWorkspace(2)),
        ("toggle-float", .toggleFloat),
        ("monocle", .toggleMonocle),
        ("rescue", .rescueWindows),
        ("close", .closeWindow),
        ("flatten", .flatten),
        ("layout row", .setOrientation(.horizontal)),
        ("layout column", .setOrientation(.vertical)),
        ("layout", .toggleOrientation),
        ("group down", .joinWith(.down)),
        ("split v", .splitPreselect(.vertical)),
        ("pause-display", .togglePauseDisplay),
        ("move-to-display left", .moveWindowToDisplay(.left)),
        ("move-to-display", .moveWindowToDisplay(nil)),
    ])
    func writtenCommandsParse(_ input: String, _ expected: Command) {
        #expect(Command.parse(input) == expected)
    }

    @Test(arguments: ["", "nonsense", "focus sideways", "workspace 0", "workspace 12", "layout diagonal"])
    func nonsenseIsRejected(_ input: String) {
        #expect(Command.parse(input) == nil)
    }

    /// The spelling a user types in their config must be the spelling that
    /// works in the shell, or every binding becomes guesswork.
    @Test func everyVerbInTheVocabularyParses() {
        for verb in Command.vocabulary {
            let sample = switch verb {
            case "focus", "move", "resize", "group": "\(verb) left"
            case "workspace", "send-to-workspace", "summon": "\(verb) 1"
            case "split": "split v"
            default: verb
            }
            #expect(Command.parse(sample) != nil, "\(verb) is advertised but does not parse")
        }
    }
}

@Suite("Key binding triggers")
struct KeyBindingTriggerTests {

    @Test func aChordCarriesItsModifiers() {
        let parsed = KeyBinding.parseTrigger("ctrl-alt-b")
        #expect(parsed?.1 == "b")
        #expect(parsed?.0 == .chord(control: true, option: true, command: false, shift: false))
    }

    @Test func aLeaderBindingIsABareKey() {
        let parsed = KeyBinding.parseTrigger("leader b")
        #expect(parsed?.1 == "b")
        #expect(parsed?.0 == .leader(shift: false))
    }

    @Test func aLeaderBindingCanTakeShift() {
        #expect(KeyBinding.parseTrigger("leader shift-b")?.0 == .leader(shift: true))
    }

    /// Binding a bare letter globally would swallow that key in every app.
    /// A config file must not be able to do that by accident.
    @Test(arguments: ["b", "space", "leader", ""])
    func aChordWithoutModifiersIsRefused(_ input: String) {
        #expect(KeyBinding.parseTrigger(input) == nil)
    }

    @Test func anUnknownModifierIsRefused() {
        #expect(KeyBinding.parseTrigger("hyper-b") == nil)
    }
}

@Suite("Bindings in the config file")
struct ConfigBindingTests {

    @Test func aBindingIsParsed() throws {
        let parsed = try ConfigFile.parse("""
        [[bind]]
        key = "ctrl-alt-b"
        command = "balance"
        """)
        #expect(parsed.bindings.count == 1)
        #expect(parsed.bindings[0].command == .balance)
        #expect(parsed.bindings[0].key == "b")
        #expect(parsed.warnings.isEmpty)
    }

    /// A bad binding must cost the user that binding, not the whole file.
    @Test(arguments: [
        ("key = \"ctrl-alt-b\"\ncommand = \"teleport\"", "not a command"),
        ("key = \"hyper-b\"\ncommand = \"balance\"", "not a key"),
        ("key = \"ctrl-alt-\u{00A5}\"\ncommand = \"balance\"", "not a bindable key"),
        ("command = \"balance\"", "needs a `key`"),
        ("key = \"ctrl-alt-b\"", "needs a `command`"),
    ])
    func abadBindingWarnsAndIsSkipped(_ body: String, _ expected: String) throws {
        let parsed = try ConfigFile.parse("[layout]\ngaps = 12\n\n[[bind]]\n\(body)")
        #expect(parsed.bindings.isEmpty)
        #expect(parsed.warnings.contains { $0.contains(expected) }, "\(parsed.warnings)")
        // The rest of the file still applies.
        #expect(parsed.layout.innerGap == 12)
    }

    @Test func severalBindingsCoexist() throws {
        let parsed = try ConfigFile.parse("""
        [[bind]]
        key = "leader b"
        command = "balance"

        [[bind]]
        key = "cmd-alt-r"
        command = "rescue"
        """)
        #expect(parsed.bindings.count == 2)
        #expect(parsed.bindings[1].command == .rescueWindows)
    }
}
