//
//  TerminalHighlightProviderTests.swift
//  SwiftTerm
//
//  Renderer-level tests for the presentation-only highlight provider hook:
//  nil-provider default parity, decoration application through the shared
//  buildAttributedString path (consumed by both the CoreGraphics and Metal
//  renderers), selection precedence, ANSI foreground preservation, ANSI
//  background layering, copy/model invariance, weak provider lifecycle, and
//  wide-character / VS16 column painting.
//
//  Providers are always held in local strong references: `highlightProvider`
//  is weak storage, so assigning a temporary would release it immediately
//  (that release behavior is itself asserted in
//  `providerReleasedRestoresDefaultRendering`).
//

#if os(macOS)
import Foundation
import AppKit
import Testing

@testable import SwiftTerm

@MainActor
final class TerminalHighlightProviderTests {

    // MARK: - Fixtures

    /// Provider stub returning the same ranges for every row.
    final class StubProvider: TerminalHighlightProvider {
        let highlights: [TerminalCellHighlight]

        init(highlights: [TerminalCellHighlight]) {
            self.highlights = highlights
        }

        func cellHighlights(in terminal: Terminal, row: Int) -> [TerminalCellHighlight]? {
            highlights
        }
    }

    private static let testRed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private static let testBlue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    private func makeView(feed text: String) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        view.getTerminal().feed(text: text)
        return view
    }

    private func makeView(feed text: String, options: TerminalOptions) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 200),
                                options: options)
        view.getTerminal().feed(text: text)
        return view
    }

    // MARK: - Attribute inspection

    /// Attributes per terminal column for one row, built through the exact
    /// path both renderers use (`buildAttributedString`). A segment can hold
    /// several attribute runs, so runs are enumerated and mapped back to
    /// columns via the segment's cell-ordinal table (a wide cell covers all
    /// of its columns).
    private func rowAttributeMap(_ view: TerminalView, row: Int) -> [Int: [NSAttributedString.Key: Any]] {
        let terminal = view.getTerminal()
        let info = view.buildAttributedString(row: row, line: terminal.buffer.lines[row],
                                              cols: terminal.cols)
        var map: [Int: [NSAttributedString.Key: Any]] = [:]
        for segment in info.segments {
            let string = segment.attributedString
            guard string.length > 0 else { continue }
            let full = NSRange(location: 0, length: string.length)
            var location = 0
            while location < string.length {
                var runRange = NSRange()
                let attrs = string.attributes(at: location, longestEffectiveRange: &runRange, in: full)
                for utf16 in runRange.lowerBound..<runRange.upperBound {
                    let baseColumn = segment.column + segment.cellOrdinal(forUTF16: utf16) * segment.columnWidth
                    for column in baseColumn..<(baseColumn + segment.columnWidth) {
                        map[column] = attrs
                    }
                }
                location = NSMaxRange(runRange)
            }
        }
        return map
    }

    /// Color equality resolved in device RGB (catalog and resolved instances
    /// of the same color must compare equal).
    private func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            let l = lhs.usingColorSpace(.deviceRGB) ?? lhs
            let r = rhs.usingColorSpace(.deviceRGB) ?? rhs
            return l == r
        default:
            return false
        }
    }

    private func selectionBackground(of view: TerminalView, row: Int, column: Int) -> NSColor? {
        rowAttributeMap(view, row: row)[column]?[.selectionBackgroundColor] as? NSColor
    }

    private func foreground(of view: TerminalView, row: Int, column: Int) -> NSColor? {
        rowAttributeMap(view, row: row)[column]?[.foregroundColor] as? NSColor
    }

    /// The background a renderer would paint for the column: the selection /
    /// highlight channel first, then a non-default ANSI background (mirrors
    /// the CoreGraphics PreparedRun resolution and the Metal renderer's quad
    /// decision, where the default background emits no quad).
    private func paintedBackground(of view: TerminalView, row: Int, column: Int) -> NSColor? {
        guard let attrs = rowAttributeMap(view, row: row)[column] else { return nil }
        if let selection = attrs[.selectionBackgroundColor] as? NSColor {
            return selection
        }
        if let background = attrs[.backgroundColor] as? NSColor,
           !sameColor(background, view.effectiveNativeBackgroundColor) {
            return background
        }
        return nil
    }

    // MARK: - Default parity (provider == nil)

    /// Without a provider, no cell carries the decoration channel, and the
    /// attributes are exactly the pre-patch ones: no `.selectionBackgroundColor`
    /// outside of real selections.
    @Test func nilProviderLeavesPlainCellsUndecorated() {
        let view = makeView(feed: "abc ERROR xyz")
        for column in 0..<13 {
            #expect(selectionBackground(of: view, row: 0, column: column) == nil,
                    "column \(column) must not carry a decoration with no provider")
        }
    }

    /// Without a provider, selection still paints through the selection
    /// background channel with the selection foreground on top.
    @Test func nilProviderKeepsSelectionWorking() {
        let view = makeView(feed: "ERROR")
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: 5, row: 0))
        for column in 0..<5 {
            #expect(sameColor(selectionBackground(of: view, row: 0, column: column),
                              view.selectedTextBackgroundColor),
                    "column \(column) must paint the selection background")
            #expect(sameColor(foreground(of: view, row: 0, column: column),
                              view.selectedTextForegroundColor),
                    "column \(column) must paint the selection foreground")
        }
    }

    // MARK: - Decoration application

    /// Provider ranges turn into `.selectionBackgroundColor` attributes on
    /// exactly the requested columns — the attribute channel both the
    /// CoreGraphics and the Metal renderers already resolve for painting.
    @Test func providerAppliesBackgroundToExactRange() {
        let view = makeView(feed: "abc ERROR xyz")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 4, endColumn: 9, color: Self.testRed)
        ])
        view.highlightProvider = provider

        #expect(!sameColor(paintedBackground(of: view, row: 0, column: 3), Self.testRed))
        for column in 4..<9 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column), Self.testRed),
                    "column \(column) must be decorated")
        }
        #expect(!sameColor(paintedBackground(of: view, row: 0, column: 9), Self.testRed))
    }

    /// The decoration uses the shared "SwiftTerm_selectionBackgroundColor"
    /// attribute key — the literal channel `MetalTerminalRenderer` reads when
    /// it builds its background quads, so the Metal path consumes the same
    /// output without any Metal-specific code.
    @Test func decorationRidesSharedSelectionBackgroundKey() {
        let view = makeView(feed: "ERROR")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 0, endColumn: 5, color: Self.testBlue)
        ])
        view.highlightProvider = provider

        let key = NSAttributedString.Key("SwiftTerm_selectionBackgroundColor")
        let color = rowAttributeMap(view, row: 0)[0]?[key] as? NSColor
        #expect(sameColor(color, Self.testBlue))
    }

    // MARK: - Precedence

    /// A selection covering decorated cells wins: selection background and
    /// selection foreground replace the decoration entirely.
    @Test func selectionOverridesHighlight() {
        let view = makeView(feed: "ERROR")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 0, endColumn: 5, color: Self.testRed)
        ])
        view.highlightProvider = provider
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: 5, row: 0))

        for column in 0..<5 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column),
                              view.selectedTextBackgroundColor),
                    "selection must beat the highlight at column \(column)")
            #expect(sameColor(foreground(of: view, row: 0, column: column),
                              view.selectedTextForegroundColor))
            #expect(!sameColor(paintedBackground(of: view, row: 0, column: column), Self.testRed))
        }
    }

    /// Decorations never touch the foreground color: an ANSI red foreground
    /// stays identical with and without a provider.
    @Test func ansiForegroundPreservedUnderHighlight() {
        let plain = makeView(feed: "\u{1b}[31mERROR\u{1b}[0m tail")
        let decorated = makeView(feed: "\u{1b}[31mERROR\u{1b}[0m tail")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 0, endColumn: 5, color: Self.testBlue)
        ])
        decorated.highlightProvider = provider

        for column in 0..<10 {
            #expect(sameColor(foreground(of: plain, row: 0, column: column),
                              foreground(of: decorated, row: 0, column: column)),
                    "foreground must not change at column \(column)")
        }
        #expect(sameColor(paintedBackground(of: decorated, row: 0, column: 0), Self.testBlue))
        #expect(foreground(of: decorated, row: 0, column: 0) != nil)
    }

    /// Decorations paint above an ANSI background: the renderer resolves the
    /// decoration channel before the ANSI background.
    @Test func highlightSitsAboveAnsiBackground() {
        let view = makeView(feed: "\u{1b}[41mERROR\u{1b}[0m tail")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 0, endColumn: 5, color: Self.testBlue)
        ])
        view.highlightProvider = provider

        for column in 0..<5 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column), Self.testBlue),
                    "highlight must cover the ANSI background at column \(column)")
        }
        // After the SGR reset the ANSI background is gone and no decoration
        // applies: nothing is painted.
        #expect(paintedBackground(of: view, row: 0, column: 6) == nil)
    }

    // MARK: - Model / copy invariance

    /// A provider never changes the buffer or the text the copy path reads.
    @Test func modelAndCopyUnchangedWithProvider() {
        let view = makeView(feed: "abc ERROR xyz")
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 4, endColumn: 9, color: Self.testRed)
        ])
        view.highlightProvider = provider

        let terminal = view.getTerminal()
        #expect(terminal.getText(start: Position(col: 0, row: 0),
                                 end: Position(col: 13, row: 0)) == "abc ERROR xyz")
        #expect(terminal.getText(start: Position(col: 4, row: 0),
                                 end: Position(col: 9, row: 0)) == "ERROR")
    }

    // MARK: - Provider lifecycle

    /// The view does not retain the provider (weak storage): releasing the
    /// provider restores upstream rendering without any bookkeeping.
    @Test func providerReleasedRestoresDefaultRendering() {
        let view = makeView(feed: "abc ERROR xyz")
        var provider: StubProvider? = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 4, endColumn: 9, color: Self.testRed)
        ])
        view.highlightProvider = provider
        #expect(sameColor(paintedBackground(of: view, row: 0, column: 4), Self.testRed))

        provider = nil
        #expect(view.highlightProvider == nil, "weak storage must drop the released provider")
        for column in 0..<13 {
            #expect(selectionBackground(of: view, row: 0, column: column) == nil)
        }
    }

    /// Assigning a provider must not change the provider's retain count
    /// (weak, not strong storage).
    @Test func viewDoesNotRetainProvider() {
        let view = makeView(feed: "ERROR")
        let provider = StubProvider(highlights: [])
        let countBefore = CFGetRetainCount(provider)
        view.highlightProvider = provider
        #expect(CFGetRetainCount(provider) == countBefore,
                "highlightProvider storage must be weak")
        view.highlightProvider = nil
    }

    // MARK: - Column geometry

    /// A wide CJK character occupies two cells; a decoration spanning its
    /// columns paints both cells of the glyph.
    @Test func wideCharacterColumnsBothPainted() {
        let view = makeView(feed: "中文x")
        // 中 occupies columns 0-1, 文 occupies 2-3, x occupies 4.
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 0, endColumn: 2, color: Self.testRed)
        ])
        view.highlightProvider = provider

        for column in 0..<2 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column), Self.testRed),
                    "both cells of the wide glyph must be decorated")
        }
        #expect(!sameColor(paintedBackground(of: view, row: 0, column: 2), Self.testRed))
    }

    /// Under the default VS16 policy (widen), ⚠️ takes two cells, so ERROR
    /// starts at column 3; decorations addressed at model columns paint the
    /// right cells.
    @Test func vs16WidenPolicyColumnPainting() {
        let view = makeView(feed: "⚠️ ERROR",
                            options: TerminalOptions(cols: 40, rows: 5, scrollback: 100))
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 3, endColumn: 8, color: Self.testRed)
        ])
        view.highlightProvider = provider

        for column in 3..<8 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column), Self.testRed),
                    "column \(column) must be decorated under widen policy")
        }
        #expect(!sameColor(paintedBackground(of: view, row: 0, column: 1), Self.testRed))
    }

    /// Under `.preserveBaseWidth`, ⚠️ takes a single cell and ERROR starts at
    /// column 2 — the hook paints whatever model columns the host computed.
    @Test func vs16PreservePolicyColumnPainting() {
        let view = makeView(feed: "⚠️ ERROR",
                            options: TerminalOptions(cols: 40, rows: 5, scrollback: 100,
                                                     variationSelector16WidthPolicy: .preserveBaseWidth))
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 2, endColumn: 7, color: Self.testRed)
        ])
        view.highlightProvider = provider

        for column in 2..<7 {
            #expect(sameColor(paintedBackground(of: view, row: 0, column: column), Self.testRed),
                    "column \(column) must be decorated under preserve policy")
        }
        #expect(!sameColor(paintedBackground(of: view, row: 0, column: 0), Self.testRed))
    }
}
#endif
