//
//  PasteTextTests.swift
//  SwiftTerm
//
//  Tests for the public `pasteText(_:)` API added by the Phase 7 fork patch.
//  `pasteText` is the programmatic equivalent of `paste(_:)` but accepts an
//  arbitrary string instead of reading the system pasteboard. It reuses the
//  internal `insertText(_:replacementRange:isPaste:)` path so that:
//    - bracketed paste (DECSET 2004) is handled by SwiftTerm's single source
//      of truth (start / text / end, exactly once, no double wrapping);
//    - in-progress IME marked-text state is cleared first;
//    - bytes flow through the same `TerminalViewDelegate.send(source:data:)`
//      delegate the keyboard uses;
//    - no trailing Return is sent.
//

#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

@MainActor
final class PasteTextTests {

    // MARK: - Capture delegate

    /// Minimal `TerminalViewDelegate` that records every `send(source:data:)`
    /// slice. The remaining protocol requirements use the default extensions
    /// provided by SwiftTerm on macOS (`bell`, `requestOpenLink`, `iTermContent`,
    /// `clipboardCopy`, `clipboardRead`).
    final class CaptureDelegate: TerminalViewDelegate {
        private(set) var sentSlices: [[UInt8]] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sentSlices.append(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clear() { sentSlices.removeAll() }

        /// All bytes across every slice, in send order.
        var allBytes: [UInt8] { sentSlices.flatMap { $0 } }
    }

    // MARK: - Harness

    private func makeView() -> (view: TerminalView, delegate: CaptureDelegate) {
        let delegate = CaptureDelegate()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.terminalDelegate = delegate
        return (view, delegate)
    }

    /// Enable bracketed paste mode (DECSET 2004) by feeding the host sequence.
    private func enableBracketedPaste(_ view: TerminalView) {
        view.getTerminal().feed(text: "\u{1b}[?2004h")
    }

    // MARK: - Plain mode (bracketed paste off)

    @Test("pasteText in plain mode sends exact UTF-8 text with no bracketed markers")
    func plainModeSendsExactText() {
        let (view, delegate) = makeView()
        view.pasteText("git status")
        #expect(delegate.allBytes == Array("git status".utf8))
        #expect(!delegate.sentSlices.contains(EscapeSequences.bracketedPasteStart))
        #expect(!delegate.sentSlices.contains(EscapeSequences.bracketedPasteEnd))
    }

    @Test("pasteText sends no Return (CR or LF)")
    func sendsNoReturn() {
        let (view, delegate) = makeView()
        view.pasteText("git status")
        #expect(!delegate.allBytes.contains(0x0d)) // CR
        #expect(!delegate.allBytes.contains(0x0a)) // LF
    }

    // MARK: - Bracketed mode

    @Test("pasteText in bracketed mode wraps start + text + end exactly once")
    func bracketedModeWrapsExactlyOnce() {
        let (view, delegate) = makeView()
        enableBracketedPaste(view)
        #expect(view.getTerminal().bracketedPasteMode == true)
        delegate.clear()

        view.pasteText("git status")

        let start = EscapeSequences.bracketedPasteStart
        let end = EscapeSequences.bracketedPasteEnd

        // Exactly one start marker and one end marker.
        #expect(delegate.sentSlices.filter { $0 == start }.count == 1)
        #expect(delegate.sentSlices.filter { $0 == end }.count == 1)

        // First slice is the start marker, last is the end marker.
        #expect(delegate.sentSlices.first == start)
        #expect(delegate.sentSlices.last == end)

        // The text payload sits between them, byte-for-byte.
        #expect(delegate.allBytes == start + Array("git status".utf8) + end)

        // Still no Return.
        #expect(!delegate.allBytes.contains(0x0d))
    }

    // MARK: - UTF-8 preservation

    @Test("pasteText preserves UTF-8 Chinese")
    func preservesChinese() {
        let (view, delegate) = makeView()
        view.pasteText("echo '中文'")
        #expect(delegate.allBytes == Array("echo '中文'".utf8))
    }

    @Test("pasteText preserves Emoji")
    func preservesEmoji() {
        let (view, delegate) = makeView()
        view.pasteText("echo '😀'")
        #expect(delegate.allBytes == Array("echo '😀'".utf8))
    }

    // MARK: - Quote preservation

    @Test("pasteText preserves quotes byte-for-byte (no escaping/normalization)")
    func preservesQuotes() {
        let (view, delegate) = makeView()
        let cmd = "printf '%s\\n' \"$HOME test\""
        view.pasteText(cmd)
        #expect(delegate.allBytes == Array(cmd.utf8))
    }

    @Test("pasteText preserves single quotes and $ literally")
    func preservesSingleQuotes() {
        let (view, delegate) = makeView()
        let cmd = "echo '$PATH'"
        view.pasteText(cmd)
        #expect(delegate.allBytes == Array(cmd.utf8))
    }

    // MARK: - Empty text

    @Test("pasteText with empty string in plain mode sends no markers and no Return")
    func emptyPlainText() {
        let (view, delegate) = makeView()
        view.pasteText("")
        // No bracketed markers in plain mode.
        #expect(!delegate.sentSlices.contains(EscapeSequences.bracketedPasteStart))
        #expect(!delegate.sentSlices.contains(EscapeSequences.bracketedPasteEnd))
        // No Return.
        #expect(!delegate.allBytes.contains(0x0d))
    }

    @Test("pasteText with empty string in bracketed mode still wraps start/end")
    func emptyBracketedText() {
        let (view, delegate) = makeView()
        enableBracketedPaste(view)
        delegate.clear()
        view.pasteText("")
        let start = EscapeSequences.bracketedPasteStart
        let end = EscapeSequences.bracketedPasteEnd
        // An empty paste in bracketed mode still emits start + (empty) + end.
        #expect(delegate.sentSlices.filter { $0 == start }.count == 1)
        #expect(delegate.sentSlices.filter { $0 == end }.count == 1)
        #expect(!delegate.allBytes.contains(0x0d))
    }

    // MARK: - IME / marked-text state

    @Test("pasteText clears in-progress IME marked text before sending")
    func clearsMarkedText() {
        let (view, delegate) = makeView()
        view.setMarkedText("あ",
                          selectedRange: NSRange(location: 0, length: 1),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == true)

        view.pasteText("git status")

        // insertText(isPaste:true) nils markedTextStorage at the top.
        #expect(view.hasMarkedText() == false)
        // And the paste text still reached the delegate.
        #expect(delegate.allBytes == Array("git status".utf8))
    }

    // MARK: - Delegate path parity

    @Test("pasteText routes bytes through the same send delegate as keyboard input")
    func routesThroughSendDelegate() {
        let (view, delegate) = makeView()
        view.pasteText("ls -la")
        // pasteText → insertText(isPaste:true) → send(txt:) → send(data:) → delegate.send
        #expect(delegate.allBytes == Array("ls -la".utf8))
    }

    // MARK: - Return path unchanged

    @Test("EscapeSequences.cmdRet remains the stable Return byte contract")
    func returnByteContractUnchanged() {
        #expect(EscapeSequences.cmdRet == [13]) // 0x0D, CR
    }
}
#endif
