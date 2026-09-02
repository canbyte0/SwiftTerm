//
//  TerminalOptions.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 2/29/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

/// Configuration option for the desired cursor style, this style can also be overwritten by the application
/// inside the terminal, and the UI control can choose to honor this request.
public enum CursorStyle: CaseIterable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    // Beyond CaseIterable, the declaration deliberately gains no protocol
    // conformances (Codable, CustomStringConvertible...): clients may have
    // added those retroactively, and a library-provided conformance would
    // collide with theirs. Only members are added below.

    /// A stable, machine-readable name for the style, suitable for persisting
    /// settings; the inverse of ``init(tagName:)``
    public var tagName: String {
        switch self {
        case .blinkBlock: return "blinkBlock"
        case .steadyBlock: return "steadyBlock"
        case .blinkUnderline: return "blinkUnderline"
        case .steadyUnderline: return "steadyUnderline"
        case .blinkBar: return "blinkBar"
        case .steadyBar: return "steadyBar"
        }
    }

    /// A human-readable name for the style, for use in user interfaces
    public var displayName: String {
        switch self {
        case .blinkBlock: return "Blinking Block"
        case .steadyBlock: return "Steady Block"
        case .blinkUnderline: return "Blinking Underline"
        case .steadyUnderline: return "Steady Underline"
        case .blinkBar: return "Blinking Bar"
        case .steadyBar: return "Steady Bar"
        }
    }

    /// Creates a cursor style from the stable name returned by ``tagName``
    public init? (tagName: String) {
        guard let match = CursorStyle.allCases.first (where: { $0.tagName == tagName }) else {
            return nil
        }
        self = match
    }

    public static func from (string: String) -> CursorStyle? {
        return CursorStyle (tagName: string)
    }
}

/// Policy controlling how U+FE0F (Variation Selector-16 / "emoji presentation
/// selector") affects the column width of a preceding base character.
///
/// Some base characters (for example U+26A0 ⚠ or U+2764 ❤) have a Unicode default
/// width of 1 but are widened to 2 columns when followed by VS16, to match the
/// width an emoji-presentation glyph occupies. Several host shells and
/// terminal multiplexers (notably macOS `zsh` using the system `wcwidth()`)
/// instead report width 1 for these base characters and width 0 for VS16
/// itself, so they never widen. When SwiftTerm and the shell disagree on the
/// width, bracketed-paste redraws and command-line cursor motion diverge and
/// the displayed line drifts (for example `echo '⚠️'` rendering as `eecho ...`).
///
/// This option lets a client opt into the host's narrow base-character width
/// without changing the default emoji semantics, and without removing VS16 from
/// the stored grapheme cluster (emoji presentation is preserved for shaping).
public enum VariationSelector16WidthPolicy: Sendable {
    /// Widen a width-1 emoji-VS16 base character to 2 columns when followed by
    /// U+FE0F. This is the historical SwiftTerm behavior and the default.
    case widenToEmojiWidth
    /// Keep the base character's original width when followed by U+FE0F. The
    /// VS16 scalar remains part of the stored grapheme cluster (so renderers
    /// still pick emoji presentation), only the cell width is not widened. Use
    /// this for local shells whose `wcwidth()` does not widen these bases.
    case preserveBaseWidth
}

/// Width to assign to individual (unpaired) Regional Indicator symbols (U+1F1E6–U+1F1FF).
/// Combined flag pairs (e.g. 🇺🇸) are always rendered as width 2 regardless of this setting.
public enum RegionalIndicatorWidth: Sendable {
    /// Width 2: matches kitty, Ghostty, iTerm2, and the Python wcwidth >= 0.5.2 library.
    /// This is the default and preserves SwiftTerm's existing behavior.
    case wide
    /// Width 1: matches system wcwidth() on macOS/Linux, Alacritty, WezTerm, Windows Terminal,
    /// and the Unicode East Asian Width property (Neutral). Use this when running inside tmux
    /// or other multiplexers that use wcwidth() for cursor positioning.
    case narrow
}

/// Configuration options for the terminal at startup, these values are only read at startup
public struct TerminalOptions {
    /// Desired number of columns at startup (default 80)
    public var cols: Int
    /// Desired number of rows at startup (default 25)
    public var rows: Int
    /// Controls whether a Line-Feed character will also behave like a carriage return (true) or not (false).  defaults to false)
    public var convertEol: Bool
    /// Desired value for the terminal name, defaults to xterm-color
    public var termName: String
    /// The desired startup cursor style, this merely sets an internal variable, it is the view job to render it
    public var cursorStyle: CursorStyle
    /// Deprecated?   The new accessibility work will make this useless
    public var screenReaderMode: Bool
    /// Size of the scrollback buffer, defaults to 500 lines
    public var scrollback: Int
    /// Default size of the tabs, defaults to 8
    public var tabStopWidth: Int
    /// Whether to report that sixel support is present
    public var enableSixelReported:Bool
    /// Maximum total bytes to keep for kitty image data; defaults to 320MB and is clamped to 4GB.
    public var kittyImageCacheLimitBytes: Int
    /// Strategy used to derive the 256-color palette from the base 16 colors.
    public var ansi256PaletteStrategy: Ansi256PaletteStrategy
    /// Width for individual Regional Indicator symbols. `.wide` (default) preserves existing
    /// behavior. `.narrow` matches system wcwidth() and avoids cursor divergence with tmux.
    public var regionalIndicatorWidth: RegionalIndicatorWidth
    /// Policy for how U+FE0F (VS16) affects the width of a preceding narrow emoji base.
    /// `.widenToEmojiWidth` (default) preserves existing behavior; `.preserveBaseWidth` keeps
    /// the base character's original width for compatibility with shells that use a `wcwidth()`
    /// which does not widen these bases (e.g. macOS `zsh`). The VS16 scalar is never stripped.
    public var variationSelector16WidthPolicy: VariationSelector16WidthPolicy
    /// BiDi state for new paragraphs after startup or reset.
    public var initialBidiState: BidiPresentationState
    /// Maximum rows that the renderer processes as one BiDi paragraph.
    public var maximumBidiParagraphRows: Int
    /// Initial state for terminal-wg left and right arrow swapping. The default
    /// is false, so the host or terminal application must opt in.
    public var initialBidiArrowKeySwap: Bool

    /// Default options
    public static let `default` = TerminalOptions.init(cols: 80,
                                                       rows: 25,
                                                       convertEol: false,
                                                       termName: "xterm-256color",
                                                       cursorStyle: .blinkBlock,
                                                       screenReaderMode: false,
                                                       scrollback: 500,
                                                       tabStopWidth: 8,
                                                       enableSixelReported: true,
                                                       kittyImageCacheLimitBytes: 320 * 1024 * 1024,
                                                       ansi256PaletteStrategy: .base16Lab,
                                                       regionalIndicatorWidth: .wide,
                                                       variationSelector16WidthPolicy: .widenToEmojiWidth,
                                                       initialBidiState: .default,
                                                       maximumBidiParagraphRows: 500,
                                                       initialBidiArrowKeySwap: false)

  public init(cols: Int = Self.default.cols, rows: Int = Self.default.rows, convertEol: Bool = Self.default.convertEol, termName: String = Self.default.termName, cursorStyle: CursorStyle = Self.default.cursorStyle, screenReaderMode: Bool = Self.default.screenReaderMode, scrollback: Int = Self.default.scrollback, tabStopWidth: Int = Self.default.tabStopWidth,
              enableSixelReported: Bool = Self.default.enableSixelReported, kittyImageCacheLimitBytes: Int = Self.default.kittyImageCacheLimitBytes, ansi256PaletteStrategy: Ansi256PaletteStrategy = Self.default.ansi256PaletteStrategy,
              regionalIndicatorWidth: RegionalIndicatorWidth = Self.default.regionalIndicatorWidth,
              variationSelector16WidthPolicy: VariationSelector16WidthPolicy = Self.default.variationSelector16WidthPolicy,
              initialBidiState: BidiPresentationState = Self.default.initialBidiState,
              maximumBidiParagraphRows: Int = Self.default.maximumBidiParagraphRows,
              initialBidiArrowKeySwap: Bool = Self.default.initialBidiArrowKeySwap) {
        self.cols = cols
        self.rows = rows
        self.convertEol = convertEol
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.screenReaderMode = screenReaderMode
        self.scrollback = scrollback
        self.tabStopWidth = tabStopWidth
        self.enableSixelReported = enableSixelReported
        self.kittyImageCacheLimitBytes = kittyImageCacheLimitBytes
        self.ansi256PaletteStrategy = ansi256PaletteStrategy
        self.regionalIndicatorWidth = regionalIndicatorWidth
        self.variationSelector16WidthPolicy = variationSelector16WidthPolicy
        self.initialBidiState = initialBidiState
        self.maximumBidiParagraphRows = max(1, maximumBidiParagraphRows)
        self.initialBidiArrowKeySwap = initialBidiArrowKeySwap
    }
}
