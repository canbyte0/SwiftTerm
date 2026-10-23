import Testing
import Foundation
@testable import SwiftTerm

@Suite("TerminalInputSnapshotTests - Formal Core Contracts")
struct TerminalInputSnapshotTests {
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

    @Test("1. Synchronous freeze at OSC 133 C moment and immutability")
    func synchronousFreezeAtCMoment() {
        let (terminal, _) = makeTerminal()
        var capturedEvents: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                capturedEvents.append(event)
            }
        }

        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: "echo test_synchronous_freeze")
        osc("C", on: terminal)

        #expect(capturedEvents.count == 1)
        guard let snapshot = capturedEvents.first?.inputSnapshot else {
            Issue.record("Expected inputSnapshot in commandStarted event")
            return
        }

        switch snapshot.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "echo test_synchronous_freeze")
            #expect(content.summary == "echo test_synchronous_freeze")
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Expected successful snapshot, got unavailable(\(reason))")
        }

        // Subsequent output and command termination do not mutate the recorded snapshot
        terminal.feed(text: "\r\noutput text\r\n")
        osc("D;0", on: terminal)

        // Snapshot remains immutable
        switch snapshot.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "echo test_synchronous_freeze")
            #expect(!content.isTruncated)
        case .unavailable:
            Issue.record("Snapshot mutated unexpectedly")
        }
        observation.cancel()
    }

    @Test("2. Q1 prompt seek and Q2 command span boundaries")
    func promptSeekAndCommandSpanBoundaries() {
        let (terminal, _) = makeTerminal()
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        // Multiline prompt before input mark
        osc("A", on: terminal)
        terminal.feed(text: "line1\r\nline2> ")
        osc("B", on: terminal)
        terminal.feed(text: "cargo build --release")
        osc("C", on: terminal)

        guard let s = snapshot else {
            Issue.record("Expected snapshot")
            return
        }
        switch s.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "cargo build --release")
            #expect(content.summary == "cargo build --release")
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable: \(reason)")
        }

        // Empty input yields noInputFound
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        osc("C", on: terminal)

        guard let emptySnapshot = snapshot else {
            Issue.record("Expected snapshot for empty input")
            return
        }
        switch emptySnapshot.result {
        case .unavailable(let reason):
            #expect(reason == .noInputFound)
        case .success:
            Issue.record("Expected noInputFound for empty command input")
        }
        observation.cancel()
    }

    @Test("3. Normal, wide (CJK), and combining character handling")
    func normalWideAndCombiningCharacters() {
        let (terminal, _) = makeTerminal(cols: 80, rows: 24)
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        // CJK wide characters + combining accent
        let combiningText = "e\u{0301}" // é as combining sequence
        let wideText = "测试输入"
        let mixedCommand = "echo \(wideText) \(combiningText) done"

        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: mixedCommand)
        osc("C", on: terminal)

        guard let s = snapshot else {
            Issue.record("Expected snapshot")
            return
        }
        switch s.result {
        case .success(let content):
            #expect(content.rawInputPrefix.contains(wideText))
            #expect(content.rawInputPrefix.contains("done"))
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for wide/combining input: \(reason)")
        }
        observation.cancel()
    }

    @Test("4. Soft wrap and secondary PS2 continuation lines")
    func softWrapAndSecondaryContinuation() {
        let (terminal, _) = makeTerminal(cols: 16, rows: 10)
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        // Soft wrap: 30 chars in 16 cols wraps automatically
        osc("A", on: terminal)
        terminal.feed(text: "> ")
        osc("B", on: terminal)
        terminal.feed(text: "abcdefghijklmnopqrstuvwxyz1234")
        osc("C", on: terminal)

        guard let s1 = snapshot else {
            Issue.record("Expected snapshot for soft wrapped command")
            return
        }
        switch s1.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "abcdefghijklmnopqrstuvwxyz1234")
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for soft wrap: \(reason)")
        }

        // Secondary prompt continuation (PS2) with multiple lines
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)

        let (wideTerminal, _) = makeTerminal(cols: 80, rows: 10)
        let obs2 = wideTerminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }
        osc("A", on: wideTerminal)
        wideTerminal.feed(text: "$ ")
        osc("B", on: wideTerminal)
        wideTerminal.feed(text: "first line \\\r\n")
        osc("P;k=s", on: wideTerminal)
        wideTerminal.feed(text: "> ")
        osc("B", on: wideTerminal)
        wideTerminal.feed(text: "second line")
        osc("C", on: wideTerminal)

        guard let s2 = snapshot else {
            Issue.record("Expected snapshot for PS2 continuation")
            return
        }
        switch s2.result {
        case .success(let content):
            #expect(content.rawInputPrefix.contains("first line"))
            #expect(content.rawInputPrefix.contains("second line"))
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for PS2 continuation: \(reason)")
        }
        obs2.cancel()
        observation.cancel()
    }

    @Test("5. Anchor identity, reflow preservation, and runtime generation mismatch")
    func anchorIdentityAndGenerationMismatch() {
        let (terminal, _) = makeTerminal(cols: 40, rows: 10)
        var lastAnchor: TerminalNavigationAnchor?
        var lastSnapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .prompt {
                lastAnchor = event.anchor
            }
            if event.action == .commandStarted {
                lastSnapshot = event.inputSnapshot
            }
        }

        osc("A;id=101", on: terminal)
        terminal.feed(text: "$ ")
        osc("B;id=101", on: terminal)
        terminal.feed(text: "ls -la")

        #expect(lastAnchor != nil)
        #expect(terminal.resolveNavigationAnchor(lastAnchor!) != nil)

        // Reflow terminal
        terminal.resize(cols: 30, rows: 10)
        // Reflow after armed input marks snapshot unavailable (conservative safety)
        osc("C;id=101", on: terminal)

        guard let reflowSnapshot = lastSnapshot else {
            Issue.record("Expected snapshot after reflow")
            return
        }
        switch reflowSnapshot.result {
        case .unavailable(let reason):
            #expect(reason == .ambiguousInput)
        case .success:
            Issue.record("Expected ambiguousInput after reflow since armed input")
        }

        // New runtime generation isolates previous anchors
        terminal.beginSemanticRuntime(SemanticRuntimeGeneration(rawValue: 2), preservingExistingAnchors: false)
        #expect(terminal.resolveNavigationAnchor(lastAnchor!) == nil)

        observation.cancel()
    }
}
