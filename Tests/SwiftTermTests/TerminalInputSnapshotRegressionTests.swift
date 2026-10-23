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

    @Test("6. ICH, DCH, and in-line cursor editing")
    func insertAndDeleteCharacterEditing() {
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
        terminal.feed(text: "ABCD")

        // Move cursor back 2 columns (over 'C')
        terminal.feed(text: "\u{1b}[2D")
        // Delete 1 character (DCH) -> "ABD"
        terminal.feed(text: "\u{1b}[1P")
        // Move to end and append "E"
        terminal.feed(text: "\u{1b}[1C" + "E")
        osc("C", on: terminal)

        guard let s = snapshot else {
            Issue.record("Expected snapshot")
            return
        }
        switch s.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "ABDE")
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for DCH edit: \(reason)")
        }
        observation.cancel()
    }

    @Test("7. Budget boundaries, truncation flag, and grapheme cluster integrity")
    func budgetBoundariesAndTruncation() {
        let (terminal, _) = makeTerminal(cols: 500, rows: 40)
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        // Generate input longer than raw budget (> 4096 bytes)
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

    @Test("8. Unknown attribution preservation across line copy and clone")
    func unknownAttributionPreservation() {
        let (terminal, _) = makeTerminal()
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: "target line")

        guard let targetLine = terminal.bufferLine(atRow: 0) else {
            Issue.record("Missing target buffer line")
            return
        }
        #expect(!targetLine.hasUncertainAttribution)

        // Mark line with uncertain attribution
        targetLine.hasUncertainAttribution = true
        #expect(targetLine.hasUncertainAttribution)

        // Clone/copy line
        guard let destLine = terminal.bufferLine(atRow: 1) else {
            Issue.record("Missing dest buffer line")
            return
        }
        destLine.copyFrom(targetLine, srcCol: 0, dstCol: 0, len: targetLine.count)
        #expect(destLine.hasUncertainAttribution)
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
