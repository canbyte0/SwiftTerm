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

    @Test("2. Q1 prompt seek and Q2 command span boundaries (S2A/S2B)")
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

        // S2A: Q1 short overwrite of stale tail isolates new input without stale residue
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)
        let (termS2A, _) = makeTerminal()
        let obsS2A = termS2A.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }
        osc("A", on: termS2A)
        termS2A.feed(text: "$ ")
        osc("B", on: termS2A)
        termS2A.feed(text: "oldcommand")
        osc("C", on: termS2A)
        osc("D;0", on: termS2A)
        // Reposition cursor to row 1 col 1, write new prompt and short input "new", submit with C
        termS2A.feed(text: "\u{1b}[1;1H")
        osc("A", on: termS2A)
        termS2A.feed(text: "$ ")
        osc("B", on: termS2A)
        termS2A.feed(text: "new")
        osc("C", on: termS2A)

        guard let s2a = snapshot else {
            Issue.record("Expected snapshot for S2A")
            return
        }
        switch s2a.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "new")
            #expect(content.summary == "new")
            #expect(!content.summary.contains("command"))
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for S2A: \(reason)")
        }
        obsS2A.cancel()

        // S2B: Q2 Continuation residue from previous multiline command filtered
        snapshot = nil
        let (termS2B, _) = makeTerminal()
        let obsS2B = termS2B.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }
        osc("A", on: termS2B)
        termS2B.feed(text: "$ ")
        osc("B", on: termS2B)
        termS2B.feed(text: "multiline-cmd\r\n")
        osc("P;k=s", on: termS2B)
        termS2B.feed(text: "> ")
        osc("B", on: termS2B)
        termS2B.feed(text: "line2")
        osc("C", on: termS2B)
        osc("D;0", on: termS2B)
        // Reposition cursor to row 1 col 1, write single line command "new"
        termS2B.feed(text: "\u{1b}[1;1H")
        osc("A", on: termS2B)
        termS2B.feed(text: "$ ")
        osc("B", on: termS2B)
        termS2B.feed(text: "new")
        osc("C", on: termS2B)

        guard let s2b = snapshot else {
            Issue.record("Expected snapshot for S2B")
            return
        }
        switch s2b.result {
        case .success(let content):
            #expect(content.rawInputPrefix == "new")
            #expect(content.summary == "new")
            #expect(!content.summary.contains("line2"))
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for S2B: \(reason)")
        }
        obsS2B.cancel()

        observation.cancel()
    }

    @Test("3. Normal, wide (CJK), combining character, and multi-byte emoji handling")
    func normalWideAndCombiningCharacters() {
        let (terminal, _) = makeTerminal(cols: 80, rows: 24)
        var snapshot: TerminalInputSnapshot?
        let observation = terminal.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }

        // CJK wide characters + combining accent sequence
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
            #expect(content.rawInputPrefix == mixedCommand)
            #expect(content.summary == mixedCommand)
            #expect(content.rawInputPrefix.contains(wideText))
            #expect(content.rawInputPrefix.contains(combiningText))
            #expect(content.rawInputPrefix.contains("done"))
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for wide/combining input: \(reason)")
        }

        // S5B: Combining family emoji preserved as atomic grapheme cluster
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)
        let familyEmoji = "👨‍👩‍👧‍👦"
        let familyCmd = "echo \(familyEmoji)"
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: familyCmd)
        osc("C", on: terminal)

        guard let s5b = snapshot else {
            Issue.record("Expected snapshot for family emoji")
            return
        }
        switch s5b.result {
        case .success(let content):
            #expect(content.rawInputPrefix == familyCmd)
            #expect(content.summary == familyCmd)
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for family emoji: \(reason)")
        }

        // S5D: Legitimate literal U+FFFD preserved without error
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)
        let fffdCmd = "echo \"literal_\u{FFFD}_char\""
        osc("A", on: terminal)
        terminal.feed(text: "$ ")
        osc("B", on: terminal)
        terminal.feed(text: fffdCmd)
        osc("C", on: terminal)

        guard let s5d = snapshot else {
            Issue.record("Expected snapshot for literal U+FFFD")
            return
        }
        switch s5d.result {
        case .success(let content):
            #expect(content.rawInputPrefix == fffdCmd)
            #expect(content.summary == fffdCmd)
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for literal U+FFFD: \(reason)")
        }

        // S5C: Dual-budget multi-byte emoji stream truncated strictly on Character boundary
        snapshot = nil
        terminal.feed(text: "\r\n")
        osc("D;0", on: terminal)
        let (wideTerm, _) = makeTerminal(cols: 500, rows: 40)
        let wideObs = wideTerm.observeSemanticEvents { event in
            if event.action == .commandStarted {
                snapshot = event.inputSnapshot
            }
        }
        let hugeEmojiInput = "x" + String(repeating: familyEmoji, count: 200)
        osc("A", on: wideTerm)
        wideTerm.feed(text: "$ ")
        osc("B", on: wideTerm)
        wideTerm.feed(text: hugeEmojiInput)
        osc("C", on: wideTerm)

        guard let s5c = snapshot else {
            Issue.record("Expected snapshot for long emoji stream")
            return
        }
        switch s5c.result {
        case .success(let content):
            #expect(content.isTruncated == true)
            #expect(content.rawInputPrefix.utf8.count <= 4096)
            #expect(content.summary.utf8.count <= 1024)
            #expect(content.summary.count <= 160)
            #expect(!content.rawInputPrefix.contains("\u{FFFD}"))
            #expect(!content.summary.contains("\u{FFFD}"))
            #expect(!content.rawInputPrefix.isEmpty)
            #expect(hugeEmojiInput.hasPrefix(content.rawInputPrefix))
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for long emoji stream: \(reason)")
        }
        wideObs.cancel()

        observation.cancel()
    }

    @Test("4. Soft wrap and secondary PS2 continuation lines (S3B)")
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
            #expect(content.summary == "abcdefghijklmnopqrstuvwxyz1234")
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for soft wrap: \(reason)")
        }

        // S3B: Secondary prompt continuation (PS2) with empty lines preserved in raw and folded in summary
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
        wideTerminal.feed(text: "def foo():\r\n")
        osc("P;k=s", on: wideTerminal)
        wideTerminal.feed(text: "> ")
        osc("B", on: wideTerminal)
        wideTerminal.feed(text: "\r\n")
        osc("P;k=s", on: wideTerminal)
        wideTerminal.feed(text: "> ")
        osc("B", on: wideTerminal)
        wideTerminal.feed(text: "    return 42")
        osc("C", on: wideTerminal)

        guard let s2 = snapshot else {
            Issue.record("Expected snapshot for PS2 continuation")
            return
        }
        let expectedRaw = "def foo():\n\n    return 42"
        let expectedSummary = "def foo(): return 42"
        switch s2.result {
        case .success(let content):
            #expect(content.rawInputPrefix == expectedRaw)
            #expect(content.summary == expectedSummary)
            #expect(!content.isTruncated)
        case .unavailable(let reason):
            Issue.record("Unexpected unavailable for PS2 continuation: \(reason)")
        }
        obs2.cancel()
        observation.cancel()
    }

    @Test("5. Anchor identity, reflow preservation, and runtime generation mismatch (N1a/N1b/B6)")
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
        observation.cancel()

        // N1a: Same-generation normal buffer reset triggers navigationAnchorInvalidated
        do {
            let (termN1a, _) = makeTerminal(cols: 80, rows: 24)
            var originalAnchor: TerminalNavigationAnchor?
            var invalidatedAnchors: [TerminalNavigationAnchor] = []
            let obsN1a = termN1a.observeSemanticEvents { e in
                if e.action == .commandStarted {
                    originalAnchor = e.anchor
                }
                if e.action == .navigationAnchorInvalidated, let a = e.anchor {
                    invalidatedAnchors.append(a)
                }
            }
            osc("A", on: termN1a)
            termN1a.feed(text: "$ ")
            osc("B", on: termN1a)
            termN1a.feed(text: "echo x")
            osc("C", on: termN1a)
            osc("D;0", on: termN1a)

            #expect(originalAnchor != nil)
            #expect(termN1a.resolveNavigationAnchor(originalAnchor!) != nil)

            termN1a.resetNormalBuffer()
            obsN1a.cancel()

            #expect(invalidatedAnchors.count == 1)
            if let orig = originalAnchor, let inval = invalidatedAnchors.first {
                #expect(inval == orig)
                #expect(Set([orig]).subtracting(Set(invalidatedAnchors)).isEmpty)
                #expect(termN1a.resolveNavigationAnchor(orig) == nil)
            }
        }

        // N1b: Generation change without anchor preservation triggers navigationAnchorInvalidated
        do {
            let (termN1b, _) = makeTerminal(cols: 80, rows: 24)
            var originalAnchor: TerminalNavigationAnchor?
            var invalidatedAnchors: [TerminalNavigationAnchor] = []
            let obsN1b = termN1b.observeSemanticEvents { e in
                if e.action == .commandStarted {
                    originalAnchor = e.anchor
                }
                if e.action == .navigationAnchorInvalidated, let a = e.anchor {
                    invalidatedAnchors.append(a)
                }
            }
            osc("A", on: termN1b)
            termN1b.feed(text: "$ ")
            osc("B", on: termN1b)
            termN1b.feed(text: "echo x")
            osc("C", on: termN1b)
            osc("D;0", on: termN1b)

            #expect(originalAnchor != nil)
            #expect(termN1b.resolveNavigationAnchor(originalAnchor!) != nil)

            termN1b.beginSemanticRuntime(SemanticRuntimeGeneration(rawValue: 2), preservingExistingAnchors: false)
            obsN1b.cancel()

            #expect(invalidatedAnchors.count == 1)
            if let orig = originalAnchor, let inval = invalidatedAnchors.first {
                #expect(inval == orig)
                #expect(Set([orig]).subtracting(Set(invalidatedAnchors)).isEmpty)
                #expect(termN1b.resolveNavigationAnchor(orig) == nil)
            }
        }

        // B6: Preserved old navigation anchor from previous generation rejected for active capture but remains valid for navigation
        do {
            let (termB6, _) = makeTerminal(cols: 80, rows: 24)
            let g1 = SemanticRuntimeGeneration(rawValue: 1)
            let g2 = SemanticRuntimeGeneration(rawValue: 2)
            termB6.beginSemanticRuntime(g1, preservingExistingAnchors: false)
            var oldAnchor: TerminalNavigationAnchor?
            let obsB6 = termB6.observeSemanticEvents { e in
                if e.action == .commandStarted {
                    oldAnchor = e.anchor
                }
            }
            osc("A", on: termB6)
            termB6.feed(text: "$ ")
            osc("B", on: termB6)
            termB6.feed(text: "old-runtime-command")
            osc("C", on: termB6)
            osc("D;0", on: termB6)
            termB6.feed(text: "\r\n")
            obsB6.cancel()

            #expect(oldAnchor != nil)
            #expect(termB6.resolveNavigationAnchor(oldAnchor!) != nil)

            // Switch generation while preserving existing anchors for navigation
            termB6.beginSemanticRuntime(g2, preservingExistingAnchors: true)
            osc("A", on: termB6)
            termB6.feed(text: "$ ")
            osc("B", on: termB6)
            termB6.feed(text: "new-runtime-input")

            // Active capture using the old anchor must be explicitly rejected
            let oldSnapshot = oldAnchor.map { termB6.captureInputSnapshot(anchor: $0) }
            #expect(oldSnapshot != nil)
            if let snap = oldSnapshot {
                switch snap.result {
                case .unavailable:
                    #expect(true)
                case .success:
                    Issue.record("Preserved old anchor must be rejected for active capture")
                }
            }

            // Old anchor remains resolvable for navigation
            #expect(termB6.resolveNavigationAnchor(oldAnchor!) != nil)
        }
    }
}
