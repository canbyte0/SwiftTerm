//
//  TerminalHighlightProvider.swift
//  SwiftTerm
//
//  Presentation-only cell background decoration hook, consumed by
//  TerminalView.buildAttributedString — the single attributed-string
//  construction path shared by the CoreGraphics and Metal renderers.
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

/// A presentation-only background decoration for a range of terminal cells.
///
/// Ranges are expressed in terminal cell columns of a single buffer row.
/// They never alter cell contents, parser input, copied text, or any
/// renderer state.
public struct TerminalCellHighlight {
    /// First decorated column (inclusive).
    public let startColumn: Int
    /// Column one past the last decorated cell (exclusive).
    public let endColumn: Int
    /// Background decoration color.
    public let color: TTColor

    public init (startColumn: Int, endColumn: Int, color: TTColor) {
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.color = color
    }
}

/// Supplies presentation-only background decorations while terminal rows are
/// rendered.
///
/// Conformance requirements:
/// - Methods are called on the main actor, once per visible row, from
///   `TerminalView.buildAttributedString`.
/// - The provider is a pure presentation lookup: it must not mutate the
///   terminal buffer, the parser input, the pasteboard, or renderer state.
/// - Decorations are painted below the selection and cursor layers and never
///   replace a cell's foreground color.
///
/// Ownership: `TerminalView` stores the provider weakly, so the client owns
/// the provider instance and must keep it alive for as long as its views
/// should display decorations.
@MainActor
public protocol TerminalHighlightProvider: AnyObject {
    /// Returns the cell background decorations for `row` of `terminal`, or
    /// nil when the row carries no decorations.
    ///
    /// - Parameter terminal: the terminal currently being rendered.
    /// - Parameter row: buffer row index (0 = oldest scrollback line held by
    ///   the buffer) — the same coordinate `buildAttributedString` uses for
    ///   its `row` parameter.
    func cellHighlights (in terminal: Terminal, row: Int) -> [TerminalCellHighlight]?
}
#endif
