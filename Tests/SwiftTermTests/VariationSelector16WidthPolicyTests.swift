//
//  VariationSelector16WidthPolicyTests.swift
//
//  Tests for the opt-in `variationSelector16WidthPolicy` option.
//
//  Default policy (`widenToEmojiWidth`) preserves the historical SwiftTerm
//  behavior: a width-1 emoji-VS16 base (e.g. U+26A0 ⚠, U+2764 ❤) is widened to
//  2 columns when followed by U+FE0F.
//
//  Compatibility policy (`preserveBaseWidth`) keeps the base character's
//  original width (1) when followed by U+FE0F. The VS16 scalar is never stripped
//  from the stored grapheme cluster — only the cell column width is not widened.
//  This matches host shells (e.g. macOS `zsh` using the system `wcwidth()`) that
//  report width 1 for these bases and 0 for VS16, eliminating the cursor-column
//  divergence that corrupts bracketed-paste redraws (the `eecho ...` defect).
//

#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

@Suite(.serialized)
final class VariationSelector16WidthPolicyTests {

    // MARK: - Helpers

    private func makeTerminal(policy: VariationSelector16WidthPolicy) -> Terminal {
        let h = HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(variationSelector16WidthPolicy: policy)) { _ in }
        return h.terminal!
    }

    private func makeDefaultTerminal() -> Terminal {
        makeTerminal(policy: .widenToEmojiWidth)
    }

    private func makeCompatTerminal() -> Terminal {
        makeTerminal(policy: .preserveBaseWidth)
    }

    /// Translates the given buffer line to a string, dropping any residual NUL
    /// placeholder cells so the result reads as the visible text.
    private func lineString(_ t: Terminal, row: Int) -> String {
        t.buffer.translateBufferLineToString(
            lineIndex: row,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: { t.getCharacter(for: $0) }
        ).replacingOccurrences(of: "\u{0}", with: "")
    }

    // MARK: - 12. Default vs compatibility width for ⚠️ and ❤️

    @Test func testDefaultPolicyWidensWarningSign() {
        let t = makeDefaultTerminal()
        t.feed(text: "\u{26A0}\u{FE0F}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    @Test func testDefaultPolicyWidensHeart() {
        let t = makeDefaultTerminal()
        t.feed(text: "\u{2764}\u{FE0F}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    @Test func testPreserveBaseWidthKeepsWarningSignNarrow() {
        let t = makeCompatTerminal()
        t.feed(text: "\u{26A0}\u{FE0F}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        // No width-0 continuation cell is inserted; the next glyph lands at col 1.
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    @Test func testPreserveBaseWidthKeepsHeartNarrow() {
        let t = makeCompatTerminal()
        t.feed(text: "\u{2764}\u{FE0F}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    // MARK: - 13. VS15 (text presentation) is not affected by the new policy

    @Test func testVS15ForcesNarrowUnderDefaultPolicy() {
        let t = makeDefaultTerminal()
        t.feed(text: "\u{26A0}\u{FE0E}x")
        // VS15 always forces width 1 regardless of policy.
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    @Test func testVS15ForcesNarrowUnderPreservePolicy() {
        let t = makeCompatTerminal()
        t.feed(text: "\u{2764}\u{FE0E}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    // MARK: - 14. Plain wide emoji are unaffected by preserveBaseWidth

    @Test func testPlainEmojiKeepWidthTwoUnderPreservePolicy() {
        let t = makeCompatTerminal()
        // 😀 U+1F600, 🚀 U+1F680, 👍 U+1F44D are inherently width 2 (East Asian Wide /
        // emoji presentation) and carry no VS16 in this sequence.
        t.feed(text: "\u{1F600}\u{1F680}\u{1F44D}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharData(col: 2, row: 0)?.width == 2)
        #expect(t.getCharData(col: 4, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 6, row: 0) == "x")
    }

    // MARK: - 15. CJK characters are unaffected

    @Test func testCJKKeepsWidthTwoUnderBothPolicies() {
        for policy in [VariationSelector16WidthPolicy.widenToEmojiWidth,
                       VariationSelector16WidthPolicy.preserveBaseWidth] {
            let t = makeTerminal(policy: policy)
            t.feed(text: "中文")
            #expect(t.getCharData(col: 0, row: 0)?.width == 2)
            #expect(t.getCharData(col: 2, row: 0)?.width == 2)
            #expect(t.getCharacter(col: 0, row: 0) == "中")
            #expect(t.getCharacter(col: 2, row: 0) == "文")
        }
    }

    // MARK: - 16. Regional indicator behavior is not disturbed by the new policy

    @Test func testRegionalIndicatorDefaultWideUnaffectedByPreservePolicy() {
        // Default regionalIndicatorWidth is .wide; preserveBaseWidth must not
        // change individual RI width or flag combining.
        let t = makeCompatTerminal()
        t.feed(text: "\u{1F1FA}\u{1F1F8}x") // 🇺🇸
        let flag = t.getCharacter(col: 0, row: 0)
        #expect(flag == "\u{1F1FA}\u{1F1F8}")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    // MARK: - 17. Keycap sequences (base + VS16 + combining enclosing keycap)

    @Test func testKeycapDefaultWideUnderDefaultPolicy() {
        // 1️⃣ = U+0031 + U+FE0F + U+20E3. The digit base is an emoji-VS16 base, so
        // under the default policy the VS16 widens it to 2 before the keycap combines.
        let t = makeDefaultTerminal()
        t.feed(text: "1\u{FE0F}\u{20E3}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 0, row: 0) == "1\u{FE0F}\u{20E3}")
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    @Test func testKeycapNarrowUnderPreservePolicy() {
        // Under preserveBaseWidth the VS16 does not widen the digit base; the
        // keycap combines at the base width. This matches a host wcwidth() that
        // reports the digit as 1 and VS16/U+20E3 as 0 — the documented, intended
        // compatibility behavior, not a regression.
        let t = makeCompatTerminal()
        t.feed(text: "1\u{FE0F}\u{20E3}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharacter(col: 0, row: 0) == "1\u{FE0F}\u{20E3}")
        #expect(t.getCharacter(col: 1, row: 0) == "x")
    }

    // MARK: - 18. Skin tone modifiers are not disturbed by the VS16 policy

    @Test func testSkinToneModifierUnaffectedUnderPreservePolicy() {
        // 👍🏻 = U+1F44D + U+1F3FB. The modifier is an Emoji_Modifier, not a VS16;
        // the new policy must not change how the modifier combines or the width.
        let t = makeCompatTerminal()
        t.feed(text: "\u{1F44D}\u{1F3FB}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 0, row: 0) == "\u{1F44D}\u{1F3FB}")
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    // MARK: - 19. ZWJ sequences are not directly broken by the VS16 policy

    @Test func testZWJFamilyUnaffectedUnderPreservePolicy() {
        // 👨‍👩‍👧‍👦 is a ZWJ sequence (no standalone VS16 widening step); the policy
        // must not change its handling.
        let t = makeCompatTerminal()
        t.feed(text: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}x")
        let family = t.getCharacter(col: 0, row: 0)
        #expect(family == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }

    // MARK: - 23/25. VS16 scalar is preserved in the stored cluster (not stripped)

    @Test func testVS16ScalarPreservedInClusterUnderPreservePolicy() throws {
        let t = makeCompatTerminal()
        t.feed(text: "\u{26A0}\u{FE0F}")
        let ch = try #require(t.getCharacter(col: 0, row: 0))
        #expect(ch.unicodeScalars.contains { $0.value == 0xFE0F })
        #expect(ch.unicodeScalars.contains { $0.value == 0x26A0 })
    }

    @Test func testVS16ScalarPreservedInClusterUnderDefaultPolicy() throws {
        let t = makeDefaultTerminal()
        t.feed(text: "\u{2764}\u{FE0F}")
        let ch = try #require(t.getCharacter(col: 0, row: 0))
        #expect(ch.unicodeScalars.contains { $0.value == 0xFE0F })
        #expect(ch.unicodeScalars.contains { $0.value == 0x2764 })
    }

    // MARK: - 20/21. Redraw + copy regression for `echo '⚠️ ❤️'`

    /// `echo '⚠️ ❤️'` is 10 cells under preserveBaseWidth
    /// (e c h o SP ' ⚠️ SP ❤️ ').
    private static let redrawCommand = "echo '\u{26A0}\u{FE0F} \u{2764}\u{FE0F}'"

    @Test func testBracketedPasteRedrawStaysCleanUnderPreservePolicy() {
        let t = makeCompatTerminal()
        t.feed(text: Self.redrawCommand)
        // Cursor advanced by 10 (the host wcwidth model) to column 10.
        #expect(t.buffer.x == 10)

        // Simulate the host bracketed-paste redraw: move back by the host-model
        // width (10) and reprint the same command.
        t.feed(text: "\u{1b}[10D")
        #expect(t.buffer.x == 0)
        t.feed(text: Self.redrawCommand)

        // The model line must remain the clean command — no `ececho ...` drift.
        #expect(lineString(t, row: 0) == Self.redrawCommand)
    }

    @Test func testBracketedPasteRedrawDivergesUnderDefaultPolicy() {
        // Under the default policy the widths disagree with a host that uses
        // wcwidth(): the command is 12 cells here (⚠️ and ❤️ are width 2), but
        // the host redraws as if it were 10. The reprint therefore lands at the
        // wrong column and corrupts the line — this is the defect the opt-in
        // policy fixes. Asserting divergence proves the regression is real.
        let t = makeDefaultTerminal()
        t.feed(text: Self.redrawCommand)
        #expect(t.buffer.x == 12)

        t.feed(text: "\u{1b}[10D")
        t.feed(text: Self.redrawCommand)

        #expect(lineString(t, row: 0) != Self.redrawCommand)
    }

    @Test func testCopyLineExtractionMatchesVisibleTextUnderPreservePolicy() {
        let t = makeCompatTerminal()
        t.feed(text: Self.redrawCommand)
        // Direct copy of the rendered line must reproduce the command verbatim.
        #expect(lineString(t, row: 0) == Self.redrawCommand)
    }

    // MARK: - 22. Inverse attribute regression (no residual inverse after redraw)

    @Test func testNoResidualInverseAfterRedrawUnderPreservePolicy() {
        let t = makeCompatTerminal()
        t.feed(text: Self.redrawCommand)

        // Simulate a host that briefly highlights the pasted region (SGR 7),
        // repositions by its width model, reprints, then clears the highlight
        // (SGR 27) and reprints normally. Under preserveBaseWidth the widths
        // match the host, so the final non-inverse reprint fully overwrites the
        // highlight — no residual inverse at the command start.
        let highlightAndRedraw = "\u{1b}[7m\u{1b}[10D" + Self.redrawCommand
            + "\u{1b}[27m\u{1b}[10D" + Self.redrawCommand
        t.feed(text: highlightAndRedraw)

        // Every cell of the command must be free of the inverse attribute.
        for col in 0..<Self.redrawCommand.count {
            let cd = t.getCharData(col: col, row: 0)
            #expect(cd?.attribute.style.contains(.inverse) == false,
                    "residual inverse at col \(col)")
        }
        #expect(lineString(t, row: 0) == Self.redrawCommand)
    }

    // MARK: - Default-policy parity with existing upstream behavior

    @Test func testDefaultPolicyMatchesUpstreamVS16Widening() {
        // Mirrors the existing upstream `testVS16MakesNarrowCharWide` to prove
        // the patch is backward compatible by default.
        let t = makeDefaultTerminal()
        t.feed(text: "\u{2764}\u{FE0F}x")
        #expect(t.getCharData(col: 0, row: 0)?.width == 2)
        #expect(t.getCharacter(col: 2, row: 0) == "x")
    }
}

#endif // os(macOS)
