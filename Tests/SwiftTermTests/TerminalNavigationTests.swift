import Testing
@testable import SwiftTerm

@Suite struct TerminalNavigationTests {
    private func makeTerminal(cols: Int = 32, rows: Int = 5, scrollback: Int = 40) -> Terminal {
        let delegate = TerminalTestDelegate()
        return Terminal(delegate: delegate,
                        options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
    }

    private func osc(_ action: String, on terminal: Terminal) {
        terminal.feed(text: "\u{1b}]133;\(action)\u{07}")
    }

    private func rowText(_ terminal: Terminal, at row: Int) -> String {
        terminal.buffer.lines[row].translateToString(trimRight: true)
    }

    @Test func observersSeeOnlyCompleteValidatedOSCAndCanBeCancelled() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let first = terminal.observeSemanticEvents { events.append($0) }
        let second = terminal.observeSemanticEvents { events.append($0) }

        terminal.feed(text: "\u{1b}]133;A;id=1")
        #expect(events.isEmpty)
        terminal.feed(text: "\u{07}p>")
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.action == .prompt && $0.localToken == "1" })
        #expect(events.allSatisfy { terminal.resolveNavigationAnchor($0.anchor!) != nil })

        first.cancel()
        first.cancel()
        terminal.feed(text: "\u{1b}]133;A;k=invalid\u{07}")
        #expect(events.count == 2)
        osc("B;id=2", on: terminal)
        #expect(events.count == 3)
        #expect(events.last?.action == .inputStarted)
        #expect(events.map(\.sequence) == [1, 1, 2])
        second.cancel()
    }

    @Test func repeatedCommandTextGetsDistinctAnchorsThatFollowReflow() {
        let terminal = makeTerminal(cols: 24, rows: 4, scrollback: 40)
        var promptEvents: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents {
            if $0.action == .prompt { promptEvents.append($0) }
        }

        terminal.feed(text: "\u{1b}]133;A;id=11\u{07}P1> ")
        osc("B;id=11", on: terminal)
        terminal.feed(text: "echo same")
        osc("C;id=11", on: terminal)
        terminal.feed(text: "\r\nOUT1\r\n")
        osc("D;id=11", on: terminal)

        terminal.feed(text: "\u{1b}]133;A;id=12\u{07}P2> ")
        osc("B;id=12", on: terminal)
        terminal.feed(text: "echo same")
        osc("C;id=12", on: terminal)
        terminal.feed(text: "\r\nOUT2\r\n")
        osc("D;id=12", on: terminal)

        #expect(promptEvents.count == 2)
        #expect(promptEvents[0].anchor != promptEvents[1].anchor)
        #expect(promptEvents.map(\.localToken) == ["11", "12"])
        let first = promptEvents[0].anchor!
        let second = promptEvents[1].anchor!

        terminal.resize(cols: 7, rows: 4)
        terminal.resize(cols: 24, rows: 4)

        guard let firstPosition = terminal.resolveNavigationAnchor(first),
              let secondPosition = terminal.resolveNavigationAnchor(second) else {
            Issue.record("reflow must retain both distinct prompt identities")
            return
        }
        #expect(rowText(terminal, at: firstPosition.row).contains("P1>"))
        #expect(rowText(terminal, at: secondPosition.row).contains("P2>"))
        let firstExecutionRows = (firstPosition.row..<secondPosition.row).map { rowText(terminal, at: $0) }
        let secondExecutionRows = (secondPosition.row..<terminal.buffer.lines.count).map { rowText(terminal, at: $0) }
        #expect(firstExecutionRows.joined().contains("OUT1"))
        #expect(!firstExecutionRows.joined().contains("OUT2"))
        #expect(secondExecutionRows.joined().contains("OUT2"))
        observation.cancel()
    }

    @Test func anchorCannotBeResolvedByAnotherTerminal() {
        let firstTerminal = makeTerminal()
        let secondTerminal = makeTerminal()
        var anchor: TerminalNavigationAnchor?
        let observation = firstTerminal.observeSemanticEvents {
            if $0.action == .prompt { anchor = $0.anchor }
        }
        osc("A;id=1", on: firstTerminal)

        #expect(anchor != nil)
        #expect(firstTerminal.resolveNavigationAnchor(anchor!) != nil)
        #expect(secondTerminal.resolveNavigationAnchor(anchor!) == nil)
        observation.cancel()
    }

    @Test func sameBufferRowCopyMovesIdentityAndResetInvalidatesIt() {
        let terminal = makeTerminal(rows: 3)
        var anchor: TerminalNavigationAnchor?
        var invalidations = 0
        let observation = terminal.observeSemanticEvents {
            if $0.action == .prompt { anchor = $0.anchor }
            if $0.action == .navigationAnchorInvalidated { invalidations += 1 }
        }
        osc("A;id=9", on: terminal)
        let identity = anchor!
        let source = terminal.buffer.lines[0]
        let destination = terminal.buffer.lines[1]
        destination.copyFrom(source, srcCol: 0, dstCol: 0, len: source.count)

        #expect(terminal.resolveNavigationAnchor(identity) == Position(col: 0, row: 1))
        terminal.resetNormalBuffer()
        #expect(terminal.resolveNavigationAnchor(identity) == nil)
        #expect(invalidations == 1)
        observation.cancel()
    }

    @Test func onlyOSCStateTransitionsCreateExecutionLifecycleEvents() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("A;id=40", on: terminal)
        let firstAnchor = events[0].anchor
        osc("A;id=40", on: terminal) // prompt redraw reuses its identity
        #expect(events.last?.anchor == firstAnchor)
        osc("B;id=40", on: terminal)
        osc("B;id=40", on: terminal) // duplicate input marker is not another start
        osc("C;id=40", on: terminal)
        osc("C;id=40", on: terminal) // duplicate command marker is not another run
        osc("D;id=40", on: terminal)
        osc("D;id=40", on: terminal)

        #expect(events.map(\.action) == [
            .prompt, .prompt, .inputStarted, .commandStarted, .commandFinished
        ])
        #expect(events.compactMap(\.localToken) == ["40", "40", "40", "40", "40"])

        terminal.feed(text: "\r\n")
        osc("A;id=41", on: terminal)
        osc("B;id=41", on: terminal)
        // Empty submission or cancellation without a shell C marker is not
        // treated as a command execution by the navigation event stream.
        terminal.sendUserInput([0x0d][...])
        #expect(events.filter { $0.action == .commandStarted }.count == 1)
        observation.cancel()
    }

    @Test func localPromptTokenCanStartExecutionWithoutInputMarker() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("P;k=i;id=1", on: terminal)
        let promptAnchor = events.first?.anchor
        terminal.feed(text: "p> echo same")
        terminal.sendUserInput([0x0d][...])
        osc("C;id=1", on: terminal)

        let starts = events.filter { $0.action == .commandStarted }
        #expect(starts.count == 1)
        #expect(starts.first?.localToken == "1")
        #expect(starts.first?.anchor == promptAnchor)
        #expect(promptAnchor.flatMap { terminal.resolveNavigationAnchor($0) } != nil)
        observation.cancel()
    }

    @Test func sshCommandStartAfterDWithoutInputMarkerIsRejected() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("A", on: terminal)
        osc("D", on: terminal)
        osc("C", on: terminal)

        #expect(events.filter { $0.action == .commandStarted }.isEmpty)
        #expect(events.map(\.action) == [.prompt])
        observation.cancel()
    }

    @Test func inputStageEndedByDRejectsLateCommandStart() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("A", on: terminal)
        osc("B", on: terminal)
        osc("D", on: terminal)
        osc("C", on: terminal)

        #expect(events.filter { $0.action == .commandStarted }.isEmpty)
        #expect(events.map(\.action) == [.prompt, .inputStarted])
        observation.cancel()
    }

    @Test func repeatedLocalPromptMarkReusesUnexecutedAnchor() {
        let terminal = makeTerminal()
        var promptEvents: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents {
            if $0.action == .prompt { promptEvents.append($0) }
        }

        osc("P;k=i;id=1", on: terminal)
        osc("P;k=i;id=1", on: terminal)

        #expect(promptEvents.count == 2)
        #expect(promptEvents[0].anchor != nil)
        #expect(promptEvents[1].anchor == promptEvents[0].anchor)
        #expect(promptEvents[0].anchor.flatMap { terminal.resolveNavigationAnchor($0) } != nil)
        observation.cancel()
    }

    @Test func repeatedSSHCommandMarkerWithoutInputMarkerIsRejected() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("A", on: terminal)
        osc("C", on: terminal)
        osc("C", on: terminal)

        #expect(events.filter { $0.action == .commandStarted }.isEmpty)
        #expect(events.map(\.action) == [.prompt])
        observation.cancel()
    }

    @Test func tokenlessSSHMarkersStillProduceAnchoredExecutionEvents() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }

        osc("A", on: terminal)
        osc("B", on: terminal)
        osc("C", on: terminal)
        osc("D", on: terminal)

        #expect(events.map(\.action) == [.prompt, .inputStarted, .commandStarted, .commandFinished])
        #expect(events.allSatisfy { $0.localToken == nil })
        #expect(events[0].anchor != nil)
        #expect(events[1].anchor == events[0].anchor)
        #expect(events[2].anchor == events[0].anchor)
        observation.cancel()

        var malformedTokenEvent: SemanticPromptEvent?
        let malformedObservation = terminal.observeSemanticEvents { malformedTokenEvent = $0 }
        osc("A;id=01", on: terminal)
        #expect(malformedTokenEvent?.action == .prompt)
        #expect(malformedTokenEvent?.localToken == nil)
        #expect(malformedTokenEvent?.anchor != nil)
        malformedObservation.cancel()
    }

    @Test func erasedOriginInvalidatesButPartialOutputRefreshKeepsAnchor() {
        let terminal = makeTerminal()
        var anchor: TerminalNavigationAnchor?
        var invalidations = 0
        let observation = terminal.observeSemanticEvents {
            if $0.action == .prompt { anchor = $0.anchor }
            if $0.action == .navigationAnchorInvalidated { invalidations += 1 }
        }
        terminal.feed(text: "\u{1b}]133;A;id=1\u{07}P> ")
        let original = anchor!
        osc("B;id=1", on: terminal)
        terminal.feed(text: "long-running")
        osc("C;id=1", on: terminal)
        terminal.feed(text: "\r\u{1b}[1;8H\u{1b}[K")
        #expect(terminal.resolveNavigationAnchor(original) != nil)
        #expect(invalidations == 0)

        terminal.feed(text: "\r\u{1b}[K")
        #expect(terminal.resolveNavigationAnchor(original) == nil)
        #expect(invalidations == 1)
        observation.cancel()
    }

    @Test func scrollbackEvictionInvalidatesAnchorInsteadOfRelocatingIt() {
        let terminal = makeTerminal(cols: 12, rows: 2, scrollback: 2)
        var anchor: TerminalNavigationAnchor?
        let observation = terminal.observeSemanticEvents {
            if $0.action == .prompt { anchor = $0.anchor }
        }
        osc("A;id=1", on: terminal)
        let original = anchor!
        terminal.feed(text: "origin\r\n")
        for index in 0..<12 {
            terminal.feed(text: "row\(index)\r\n")
        }

        #expect(terminal.resolveNavigationAnchor(original) == nil)
        observation.cancel()
    }

    @Test func runtimeSwitchKeepsSequenceAndHonorsBothAnchorPolicies() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }
        osc("A;id=1", on: terminal)
        let firstAnchor = events[0].anchor!

        terminal.beginSemanticRuntime(SemanticRuntimeGeneration(rawValue: 1),
                                      preservingExistingAnchors: true)
        #expect(terminal.resolveNavigationAnchor(firstAnchor) != nil)
        terminal.feed(text: "\u{1b}]133;A;id=old\u{07}",
                      runtimeGeneration: SemanticRuntimeGeneration(rawValue: 0))
        #expect(events.count == 1)
        osc("A;id=2", on: terminal)
        #expect(events.last?.runtimeGeneration.rawValue == 1)
        #expect(events.map(\.sequence) == [1, 2])

        let secondAnchor = events[1].anchor!
        terminal.beginSemanticRuntime(SemanticRuntimeGeneration(rawValue: 2),
                                      preservingExistingAnchors: false)
        #expect(terminal.resolveNavigationAnchor(firstAnchor) == nil)
        #expect(terminal.resolveNavigationAnchor(secondAnchor) == nil)
        #expect(events.last?.action == .navigationAnchorInvalidated)
        osc("A;id=3", on: terminal)
        #expect(events.last?.sequence == 5)
        #expect(events.last?.runtimeGeneration.rawValue == 2)
        observation.cancel()
    }

    @Test func alternateBufferPausesEventsAndRetainsPrimaryAnchor() {
        let terminal = makeTerminal()
        var events: [SemanticPromptEvent] = []
        let observation = terminal.observeSemanticEvents { events.append($0) }
        osc("A;id=1", on: terminal)
        let anchor = events[0].anchor!

        terminal.feed(text: "\u{1b}[?1049h")
        osc("A;id=2", on: terminal)
        #expect(events.count == 1)
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(terminal.resolveNavigationAnchor(anchor) != nil)
        observation.cancel()
    }
}
