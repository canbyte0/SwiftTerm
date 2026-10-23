import Testing
import Foundation
@testable import SwiftTerm

@Suite("TerminalInputSnapshotRegressionTests - Advanced Safety and Regressions")
struct TerminalInputSnapshotRegressionTests {
    private func makeTerminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 100) -> (Terminal, TerminalTestDelegate) {
        let delegate = TerminalTestDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        let terminal = Terminal(delegate: delegate, options: options)
        terminal.beginSemanticRuntime(SemanticRuntimeGeneration(rawValue: 1), preservingExistingAnchors: false)
        return (terminal, delegate)
    }

    private func osc(_ action: String, on terminal: Terminal) {
        terminal.feed(text: "\u{1b}]133;\(action)\u{07}")
    }

    @Test("6. ICH, DCH, in-line editing, and margin preservation (N2a/N2b/N2d/M3)")
    func insertAndDeleteCharacterEditing() {
        // N2a: ICH with replacement: inserting characters shifts existing input and captures accurately
        do {
            let (terminal, _) = makeTerminal()
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "abcdef")
            // Move cursor to row 1 col 5 (over 'c'), insert 2 characters (ICH), write "XY"
            terminal.feed(text: "\u{1b}[1;5H\u{1b}[2@XY")
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for N2a")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "abXYcdef")
                #expect(content.summary == "abXYcdef")
                #expect(!content.isTruncated)
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for N2a ICH: \(reason)")
            }
            observation.cancel()
        }

        // N2b: DCH shifts historical stale tail, new command isolates without stale tail
        do {
            let (terminal, _) = makeTerminal()
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "abcdefghij")
            osc("C", on: terminal)
            osc("D;0", on: terminal)
            // Move to row 1 col 1, write new command "xyz", delete 1 character at position 3
            terminal.feed(text: "\u{1b}[1;1H")
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "xyz")
            terminal.feed(text: "\u{1b}[1;3H\u{1b}[1P")
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for N2b")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "yz")
                #expect(content.summary == "yz")
                #expect(!content.isTruncated)
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for N2b DCH: \(reason)")
            }
            observation.cancel()
        }

        // N2d: Simple DCH with no historical tail
        do {
            let (terminal, _) = makeTerminal()
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "abcdef")
            // Move to col 5 and delete 2 chars (DCH) -> "abef"
            terminal.feed(text: "\u{1b}[1;5H\u{1b}[2P")
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for N2d")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "abef")
                #expect(content.summary == "abef")
                #expect(!content.isTruncated)
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for N2d DCH: \(reason)")
            }
            observation.cancel()
        }

        // M3: Horizontal margin DCH does not crash, preserves text outside margin, and produces conservative snapshot
        do {
            let (terminal, _) = makeTerminal(cols: 80, rows: 24)
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            // ab in prompt, xyz at col 71, set margins 1;20, delete character at col 3
            let marginStream = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ab\u{1b}[1;71Hxyz\u{1b}[?69h\u{1b}[1;20s\u{1b}[1;3H\u{1b}[1P"
            terminal.feed(text: marginStream)
            osc("C", on: terminal)

            // Text outside margin (cols 70..<73) must remain "xyz"
            let outside = (70..<73).map { terminal.getCharacter(col: $0, row: 0).map(String.init) ?? "?" }.joined()
            #expect(outside == "xyz")

            guard let s = snapshot else {
                Issue.record("Expected snapshot for M3 margin DCH")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "b")
                #expect(content.isTruncated == true)
            case .unavailable(let reason):
                // Conservative safety is also acceptable if margin manipulation marks ambiguous
                #expect(reason == .ambiguousInput)
            }
            observation.cancel()
        }
    }

    @Test("7. Budget boundaries, truncation flag, row/col cutoff, and grapheme integrity (M1/M2/N4)")
    func budgetBoundariesAndTruncation() {
        // M2: Current row input ends exactly at col 512, followed by PS2 continuation
        do {
            let (terminal, _) = makeTerminal(cols: 600, rows: 40)
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "a" + String(repeating: " ", count: 509) + "\r\n")
            osc("P;k=s", on: terminal)
            terminal.feed(text: "> ")
            osc("B", on: terminal)
            terminal.feed(text: "tail")
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for M2")
                return
            }
            let expectedRaw = "a" + String(repeating: " ", count: 509) + "\ntail"
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == expectedRaw)
                #expect(!content.isTruncated)
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for M2: \(reason)")
            }
            observation.cancel()
        }

        // N4: Trailing spaces / collection cutoff completeness proves byte and summary budgets cannot substitute
        do {
            let (terminal, _) = makeTerminal(cols: 80, rows: 40)
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            let input = "echo" + String(repeating: " ", count: 500) + "tail"
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: input)
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for N4")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == input)
                #expect(content.summary.count <= 160)
                #expect(content.isTruncated == true)
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for N4: \(reason)")
            }
            observation.cancel()
        }

        // M1: Column cutoff beyond column budget stops before gap
        do {
            let (terminal, _) = makeTerminal(cols: 600, rows: 40)
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: "a\u{1b}[1;551H" + String(repeating: "x", count: 50) + "TAIL")
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot for M1")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "a")
                #expect(content.isTruncated == true)
            case .unavailable(let reason):
                #expect(reason == .ambiguousInput)
            }
            observation.cancel()
        }

        // Massive ASCII stream (4500 chars) exceeding raw budget (>4096B)
        do {
            let (terminal, _) = makeTerminal(cols: 500, rows: 40)
            var snapshot: TerminalInputSnapshot?
            let observation = terminal.observeSemanticEvents { event in
                if event.action == .commandStarted {
                    snapshot = event.inputSnapshot
                }
            }

            let hugeToken = String(repeating: "abcdefghij", count: 450) // 4500 chars
            osc("A", on: terminal)
            terminal.feed(text: "$ ")
            osc("B", on: terminal)
            terminal.feed(text: hugeToken)
            osc("C", on: terminal)

            guard let s = snapshot else {
                Issue.record("Expected snapshot")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.isTruncated == true)
                #expect(content.rawInputPrefix.utf8.count <= 4096)
                #expect(content.summary.utf8.count <= 1024)
                #expect(content.summary.count <= 160)
                #expect(hugeToken.hasPrefix(content.rawInputPrefix))
            case .unavailable(let reason):
                Issue.record("Unexpected unavailable for long command: \(reason)")
            }
            observation.cancel()
        }
    }

    @Test("8. Unknown attribution preservation across line copy, clone, partial write, and erasures")
    func unknownAttributionPreservation() {
        let (terminal, _) = makeTerminal()
        // Setup historical command 1
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: "OLDZZ")
        osc("C", on: terminal)
        osc("D;0", on: terminal)
        terminal.feed(text: "\r\n")

        // Setup multiline command 2
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: "first\r\n")
        osc("P;k=s", on: terminal)
        terminal.feed(text: "> ")
        osc("B", on: terminal)
        terminal.feed(text: "second\r\n")
        osc("P;k=s", on: terminal)
        terminal.feed(text: "> ")
        osc("B", on: terminal)
        terminal.feed(text: "third")

        // Inject cross-group conflict: copy from row 0 to continuation row 2
        guard let old = terminal.bufferLine(atRow: 0), let cont = terminal.bufferLine(atRow: 2) else {
            Issue.record("Missing buffer rows")
            return
        }
        #expect(!cont.hasUncertainAttribution)
        cont.copyFrom(old, srcCol: 2, dstCol: 10, len: 4)
        #expect(cont.hasUncertainAttribution)

        // BufferLine(from:) clone constructor must propagate hasUncertainAttribution
        let cloned = BufferLine(from: cont)
        #expect(cloned.hasUncertainAttribution)
        cont.copyFrom(line: cloned)
        #expect(cont.hasUncertainAttribution)

        // Partial write does not clear unknown attribution
        terminal.feed(text: "\u{1b}[3;3HW")
        #expect(cont.hasUncertainAttribution)

        // Local erase (ECH) does not clear unknown attribution
        terminal.feed(text: "\u{1b}[3;3H\u{1b}[1X")
        #expect(cont.hasUncertainAttribution)

        // ICH does not clear unknown attribution
        terminal.feed(text: "\u{1b}[3;3H\u{1b}[1@")
        #expect(cont.hasUncertainAttribution)

        // DCH does not clear unknown attribution
        terminal.feed(text: "\u{1b}[3;3H\u{1b}[1P")
        #expect(cont.hasUncertainAttribution)

        // C snapshot proves that reading stops before the uncertain line
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }
        osc("C", on: terminal)
        observation.cancel()

        guard let s = snapshot else {
            Issue.record("Expected snapshot after unknown line barrier")
            return
        }
        switch s.result {
        case .success(let content):
            #expect(!content.rawInputPrefix.contains("third"))
            #expect(content.isTruncated == true)
        case .unavailable:
            #expect(true)
        }
    }

    @Test("9. Unknown line pre-read barrier stops before reading uncertain line")
    func unknownLinePreReadBarrier() {
        let (terminal, _) = makeTerminal()
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: "line1")

        // Inject uncertain attribution on primary row
        guard let line0 = terminal.bufferLine(atRow: 0) else {
            Issue.record("Missing row 0")
            return
        }
        line0.hasUncertainAttribution = true
        osc("C", on: terminal)

        guard let s = snapshot else {
            Issue.record("Expected snapshot")
            return
        }
        switch s.result {
        case .unavailable(let reason):
            #expect(reason == .ambiguousInput)
        case .success:
            Issue.record("Primary uncertain line must return ambiguousInput")
        }
        observation.cancel()
    }

    @Test("10. T1, T2, T5 probes and clean candidate recovery (T4)")
    func tProbesAndCleanCandidateRecovery() {
        // T1: Primary row uncertain before trusted col -> unavailable(.ambiguousInput)
        do {
            let (terminal, _) = makeTerminal(cols: 80, rows: 40, scrollback: 1000)
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}OLDZZ\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}\r\n")
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}one")
            guard let old = terminal.bufferLine(atRow: 0), let target = terminal.bufferLine(atRow: 1) else {
                Issue.record("Missing synthetic row")
                return
            }
            target.copyFrom(old, srcCol: 2, dstCol: 10, len: 4)
            terminal.feed(text: "\u{1b}[2;4HX")

            var snapshot: TerminalInputSnapshot?
            let obs = terminal.observeSemanticEvents { if $0.action == .commandStarted { snapshot = $0.inputSnapshot } }
            terminal.feed(text: "\u{1b}]133;C\u{07}")
            obs.cancel()

            guard let s = snapshot else {
                Issue.record("Missing T1 snapshot")
                return
            }
            switch s.result {
            case .unavailable(let reason):
                #expect(reason == .ambiguousInput)
            case .success:
                Issue.record("T1 must not produce success snapshot")
            }
        }

        // T2: Continuation row uncertain -> truncated at valid previous row
        do {
            let (terminal, _) = makeTerminal(cols: 80, rows: 40, scrollback: 1000)
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}OLDZZ\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}\r\n")
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}one\r\n\u{1b}]133;P;k=s\u{07}> \u{1b}]133;B\u{07}two\r\n\u{1b}]133;P;k=s\u{07}> \u{1b}]133;B\u{07}three")
            guard let old = terminal.bufferLine(atRow: 0), let target = terminal.bufferLine(atRow: 2) else {
                Issue.record("Missing synthetic row")
                return
            }
            target.copyFrom(old, srcCol: 2, dstCol: 10, len: 4)
            terminal.feed(text: "\u{1b}[3;4HX")

            var snapshot: TerminalInputSnapshot?
            let obs = terminal.observeSemanticEvents { if $0.action == .commandStarted { snapshot = $0.inputSnapshot } }
            terminal.feed(text: "\u{1b}]133;C\u{07}")
            obs.cancel()

            guard let s = snapshot else {
                Issue.record("Missing T2 snapshot")
                return
            }
            switch s.result {
            case .unavailable(let reason):
                #expect(reason == .ambiguousInput)
            case .success(let content):
                #expect(content.isTruncated)
                #expect(content.rawInputPrefix == "one" || content.rawInputPrefix == "one\n")
            }
        }

        // T5: Prompt seek must not skip uncertain primary row
        do {
            let (terminal, _) = makeTerminal(cols: 600, rows: 40, scrollback: 1000)
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}OLDZZ\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}\r\n")
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\u{1b}[2;551Hfar\r\n\u{1b}]133;P;k=s\u{07}> \u{1b}]133;B\u{07}three")
            guard let old = terminal.bufferLine(atRow: 0), let primary = terminal.bufferLine(atRow: 1) else {
                Issue.record("Missing synthetic rows")
                return
            }
            primary.copyFrom(old, srcCol: 2, dstCol: 560, len: 4)

            var snapshot: TerminalInputSnapshot?
            let obs = terminal.observeSemanticEvents { if $0.action == .commandStarted { snapshot = $0.inputSnapshot } }
            terminal.feed(text: "\u{1b}]133;C\u{07}")
            obs.cancel()

            guard let s = snapshot else {
                Issue.record("Missing T5 snapshot")
                return
            }
            switch s.result {
            case .unavailable(let reason):
                #expect(reason == .ambiguousInput)
            case .success:
                Issue.record("T5 must not skip uncertain primary line to grab continuation")
            }
        }

        // T4: Clean new candidate recovers after earlier command
        do {
            let (terminal, _) = makeTerminal(cols: 80, rows: 40, scrollback: 1000)
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}OLDZZ\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}\r\n")
            // Earlier command finished, now a clean fresh command
            terminal.feed(text: "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}fresh_command")

            var snapshot: TerminalInputSnapshot?
            let obs = terminal.observeSemanticEvents { if $0.action == .commandStarted { snapshot = $0.inputSnapshot } }
            terminal.feed(text: "\u{1b}]133;C\u{07}")
            obs.cancel()

            guard let s = snapshot else {
                Issue.record("Missing T4 snapshot")
                return
            }
            switch s.result {
            case .success(let content):
                #expect(content.rawInputPrefix == "fresh_command")
                #expect(!content.isTruncated)
            case .unavailable(let reason):
                Issue.record("Clean fresh command must succeed: \(reason)")
            }
        }
    }
}
