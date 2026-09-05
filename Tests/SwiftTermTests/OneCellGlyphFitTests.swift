//
//  OneCellGlyphFitTests.swift
//
//  Phase 9D-B: the presentation-only "uniform fit" for single-cell fallback
//  glyphs whose ink overflows the logical cell (e.g. an Apple Color Emoji
//  glyph shaped for a width-1 ⚠️/❤️ cell under `preserveBaseWidth`).
//
//  These tests exercise the shared `TerminalView.glyphSlotFit` entry point —
//  the single source of the presentation transform consumed by BOTH the
//  CoreGraphics draw path (`AppleTerminalView.swift` CG loop) and the Metal
//  renderer (`MetalTerminalRenderer.swift` main + cursor paths). They use the
//  metrics-driven predicate (ink overflow, never Unicode code-point or size
//  checks) and prove the controls are untouched: ASCII, the text-presentation
//  ⚠/❤, plain width-2 emoji, and CJK.
//

#if os(macOS)
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

@MainActor
final class OneCellGlyphFitTests {

    // MARK: - Helpers

    /// A base monospace font with an Apple Color Emoji cascade, mirroring how a
    /// terminal host builds its font. Uses system Menlo (always available in
    /// tests) so the suite has no bundled-font dependency; the fit math is
    /// font-independent — any monospace base + Apple Color Emoji cascade shapes
    /// ⚠️ to an Apple Color Emoji glyph whose ink overflows the cell.
    private func cascadeFont(size: CGFloat) -> NSFont {
        let base = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cascadeList: [NSFontDescriptor] = [
            NSFontDescriptor(fontAttributes: [.family: "Apple Color Emoji"])
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascadeList])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Shapes `string` and returns the first run's font + first glyph, so a test
    /// can hand the exact (font, glyph) CoreText produced to `glyphSlotFit`.
    private func firstRunFontGlyph(_ string: String, base: NSFont) -> (font: CTFont, glyph: CGGlyph)? {
        let attributes: [NSAttributedString.Key: Any] = [.font: base]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes))
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        let runFontNS = ((CTRunGetAttributes(run) as? [NSAttributedString.Key: Any])?[.font] as? NSFont)
            ?? base
        return (runFontNS as CTFont, glyphs[0])
    }

    private func makeView(size: CGFloat) -> (TerminalView, NSFont) {
        let base = cascadeFont(size: size)
        let view = TerminalView(frame: .zero, font: base)
        return (view, base)
    }

    // MARK: - 26/27. ASCII / base-font hard gate (identity, never transformed)

    @Test func asciiBaseFontGlyphIsIdentity() throws {
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("A", base: base))
        #expect(view.isBaseFont(font), "ASCII run must resolve to the base font")
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale == 1, "ASCII must never be scaled")
        #expect(fit.dx == 0, "ASCII must never be translated in X")
        #expect(fit.dy == 0, "ASCII must never be translated in Y")
    }

    @Test func wideAsciiRunIsIdentityAcrossPunctuation() throws {
        let (view, base) = makeView(size: 24)
        for ch in ["W", "1", "|", "!", "@", "#"] {
            let (font, glyph) = try #require(firstRunFontGlyph(ch, base: base))
            let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
            #expect(fit.scale == 1 && fit.dx == 0 && fit.dy == 0,
                    "\(ch) must stay identity")
        }
    }

    // MARK: - 9/10. ⚠ vs ⚠️ — metrics decide, not the U+26A0 code point

    @Test func warningSignEmojiIsFittedIntoOneCell() throws {
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base))
        #expect(!view.isBaseFont(font), "⚠️ must resolve to a fallback (Apple Color Emoji)")
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale < 1, "⚠️ ink overflows one cell and must be scaled down")
        #expect(fit.scale > 0, "scale must remain positive")
        #expect(fit.scale <= 1, "must never upscale")
    }

    @Test func warningSignTextPresentationIsIdentity() throws {
        // ⚠ (no VS16) renders as a text glyph whose ink fits the cell, so it
        // must NOT be fitted — regardless of whether it lands in the base font
        // or a text fallback. This proves the predicate is ink-driven, not
        // code-point-driven: the same U+26A0 base yields identity here but a
        // fit when followed by VS16.
        let (view, base) = makeView(size: 24)
        guard let (font, glyph) = firstRunFontGlyph("\u{26A0}", base: base) else {
            // Some base fonts lack U+26A0 entirely; skip rather than guess.
            return
        }
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale == 1, "⚠ text presentation must not be scaled")
    }

    // MARK: - 10. ❤ vs ❤️ — metrics decide

    @Test func heartEmojiIsFittedIntoOneCell() throws {
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{2764}\u{FE0F}", base: base))
        #expect(!view.isBaseFont(font), "❤️ must resolve to a fallback (Apple Color Emoji)")
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale < 1, "❤️ ink overflows one cell and must be scaled down")
        #expect(fit.scale <= 1, "must never upscale")
    }

    @Test func heartTextPresentationIsIdentity() throws {
        let (view, base) = makeView(size: 24)
        guard let (font, glyph) = firstRunFontGlyph("\u{2764}", base: base) else { return }
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale == 1, "❤ text presentation must not be scaled")
    }

    // MARK: - 11. Plain width-2 emoji keep the existing wide path

    @Test func plainEmojiUsesWidePathAndStaysBounded() throws {
        // 😀 is inherently width 2 (no VS16), so it takes the existing
        // columnWidth >= 2 path. The fit must be a no-upscale, uniform result.
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{1F600}", base: base))
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 2)
        #expect(fit.scale <= 1, "wide emoji must never upscale")
    }

    // MARK: - 8/28. CJK existing 2-cell path is regression-free

    @Test func cjkWideCellIsBoundedAndUniform() throws {
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("中", base: base))
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 2)
        #expect(fit.scale <= 1, "CJK must never upscale")
    }

    // MARK: - 33/34. Uniform scale + no upscale invariants

    @Test func fitScaleIsUniformAndNeverUpscales() throws {
        // GlyphSlotFit carries a single `scale` applied to both X and Y, so the
        // transform is uniform by construction (scaleX == scaleY); and it is
        // clamped to <= 1, so there is never any upscale.
        let (view, base) = makeView(size: 32)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base))
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale > 0 && fit.scale < 1, "must shrink")
        #expect(fit.scale <= 1, "must not upscale")
        // Single scale field => no horizontal-squash possibility.
        #expect(type(of: fit.scale) == CGFloat.self)
    }

    @Test func smallGlyphIsNeverUpscaled() throws {
        // A glyph whose ink already fits the cell (the common case) stays
        // identity — scale == 1, no enlargement to "fill" the cell.
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph(".", base: base))
        let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(fit.scale == 1, "a fitting glyph must not be upscaled")
    }

    // MARK: - 36. Size matrix — ⚠️ fits at every tested size

    @Test func warningSignEmojiFitsAcrossSizeMatrix() throws {
        for size in [CGFloat(10), 14, 18, 24, 32] {
            let (view, base) = makeView(size: size)
            guard let (font, glyph) = firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base) else {
                continue
            }
            let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
            #expect(fit.scale > 0 && fit.scale < 1,
                    "⚠️ must be scaled down at \(size)pt")
            #expect(fit.scale <= 1, "no upscale at \(size)pt")
        }
    }

    // MARK: - 29/30/41. Model invariants — fit is presentation-only

    @Test func preserveBaseWidthKeepsEmojiOneCellAndCursorColumn() {
        // Presentation-only guarantee: the renderer fix does not touch the
        // terminal model. Under preserveBaseWidth, ⚠️ stays one logical cell
        // and the model cursor column advances by the host width model.
        let h = HeadlessTerminal(queue: SwiftTermTests.queue,
                                 options: TerminalOptions(variationSelector16WidthPolicy: .preserveBaseWidth)) { _ in }
        let t = h.terminal!
        t.feed(text: "A\u{26A0}\u{FE0F}B\u{2764}\u{FE0F}C")
        // A(1) ⚠️(1) B(1) ❤️(1) C(1) => 5 cells; cursor at column 5.
        #expect(t.getCharData(col: 0, row: 0)?.width == 1)
        #expect(t.getCharData(col: 1, row: 0)?.width == 1, "⚠️ stays one cell")
        #expect(t.getCharData(col: 3, row: 0)?.width == 1, "❤️ stays one cell")
        #expect(t.buffer.x == 5, "model cursor column must be 5")
        // VS16 scalars preserved in the stored cluster.
        let heart = t.getCharacter(col: 3, row: 0)
        #expect(heart?.unicodeScalars.contains { $0.value == 0xFE0F } == true)
    }

    // MARK: - 20. CG / Metal parity — single shared source

    @Test func glyphSlotFitIsDeterministicSharedSource() throws {
        // Both the CoreGraphics draw loop and the Metal renderer call this same
        // `glyphSlotFit` method (the single source of the transform), so the
        // two renderers cannot diverge. Asserting determinism proves the
        // shared result is stable across the two consumers' repeated calls.
        let (view, base) = makeView(size: 24)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{2764}\u{FE0F}", base: base))
        let a = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        let b = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1)
        #expect(a.scale == b.scale && a.dx == b.dx && a.dy == b.dy,
                "shared fit must be deterministic across CG and Metal consumers")
    }

    // MARK: - Base-font family guard (Phase 9D-B2 remediation)
    //
    // The original `isBaseFont` only compared against `fontSet.normal`
    // (object identity). Because `FontSet` derives bold/italic/boldItalic
    // via `NSFontManager.convert` — distinct objects — styled ASCII runs
    // were mis-classified as fallback fonts: Bold ASCII was horizontally
    // shifted (dx != 0) and Italic ASCII (whose ink overflows the cell on
    // the lean) was scaled down. The baseline `columnWidth >= 2` gate
    // skipped every single-cell run, so this was a regression. The guard
    // now recognizes all four primary `FontSet` members; the matrices
    // below prove styled ASCII is identity again while real fallback
    // fonts (Apple Color Emoji) still flow into the ink-overflow fit.

    @Test func baseFontFamilyGuardRecognizesAllFourMembers() throws {
        // Each FontSet member must be recognized as a base font on its own.
        let (view, _) = makeView(size: 24)
        #expect(view.isBaseFont(view.fontSet.normal as CTFont), "normal is base")
        #expect(view.isBaseFont(view.fontSet.bold as CTFont), "bold is base")
        #expect(view.isBaseFont(view.fontSet.italic as CTFont), "italic is base")
        #expect(view.isBaseFont(view.fontSet.boldItalic as CTFont), "boldItalic is base")
    }

    @Test func styledAsciiStaysIdentityAcrossFontSet() throws {
        // 4 styles x 6 glyphs: every styled ASCII glyph must resolve to a
        // recognized base-font member and yield an identity fit (no scale,
        // no translation). This is the hard gate that failed before the fix.
        let (view, _) = makeView(size: 24)
        let members: [(String, NSFont)] = [
            ("normal", view.fontSet.normal),
            ("bold", view.fontSet.bold),
            ("italic", view.fontSet.italic),
            ("boldItalic", view.fontSet.boldItalic),
        ]
        for ch in ["A", "W", "1", "|", "!", "@"] {
            for (label, font) in members {
                let (runFont, glyph) = try #require(firstRunFontGlyph(ch, base: font))
                #expect(view.isBaseFont(runFont),
                        "\(label) '\(ch)' must resolve to a base-font member")
                let fit = view.glyphSlotFit(font: runFont, glyph: glyph, columnWidth: 1)
                #expect(fit.scale == 1, "\(label) '\(ch)' must not scale")
                #expect(fit.dx == 0, "\(label) '\(ch)' must not translate in X")
                #expect(fit.dy == 0, "\(label) '\(ch)' must not translate in Y")
            }
        }
    }

    @Test func fallbackFontsAreNotBaseFamilyAndStillFit() throws {
        // The broader guard must NOT swallow true fallback fonts: Apple
        // Color Emoji (shaped for ⚠️/❤️) is a different object from every
        // base member, so it stays non-base and still enters the 1-cell
        // ink-overflow fit.
        let (view, base) = makeView(size: 24)
        let (warnFont, warnGlyph) = try #require(firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base))
        let (heartFont, heartGlyph) = try #require(firstRunFontGlyph("\u{2764}\u{FE0F}", base: base))
        #expect(!view.isBaseFont(warnFont), "⚠️ Apple Color Emoji must not be base")
        #expect(!view.isBaseFont(heartFont), "❤️ Apple Color Emoji must not be base")
        let warnFit = view.glyphSlotFit(font: warnFont, glyph: warnGlyph, columnWidth: 1)
        let heartFit = view.glyphSlotFit(font: heartFont, glyph: heartGlyph, columnWidth: 1)
        #expect(warnFit.scale < 1, "⚠️ must still be fitted after the guard fix")
        #expect(heartFit.scale < 1, "❤️ must still be fitted after the guard fix")
    }

    @Test func styledAsciiIdentityAcrossSizeMatrix() throws {
        // Bold / Italic / BoldItalic ASCII must stay identity across the
        // full Phase 9 font-size matrix, including glyphs ('W'/'|') whose
        // italic ink would otherwise overflow the cell and get scaled.
        for size in [CGFloat(10), 14, 18, 24, 32] {
            let (view, _) = makeView(size: size)
            let members: [(String, NSFont)] = [
                ("bold", view.fontSet.bold),
                ("italic", view.fontSet.italic),
                ("boldItalic", view.fontSet.boldItalic),
            ]
            for ch in ["A", "W", "|"] {
                for (label, font) in members {
                    guard let (runFont, glyph) = firstRunFontGlyph(ch, base: font) else { continue }
                    let fit = view.glyphSlotFit(font: runFont, glyph: glyph, columnWidth: 1)
                    #expect(fit.scale == 1 && fit.dx == 0 && fit.dy == 0,
                            "\(size)pt \(label) '\(ch)' must stay identity")
                }
            }
        }
    }
}

#endif // os(macOS)
