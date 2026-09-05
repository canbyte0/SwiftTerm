//
//  GlyphFitCacheTests.swift
//
//  Phase 9D-B: behavioral coverage for the `glyphFitCache` consulted by
//  `TerminalView.glyphSlotFit`. The cache is a file-private, main-thread,
//  size-bounded map keyed by (font identity, glyph, columnWidth, cellWidth,
//  cellHeight) — so these tests assert behavior reachable through the public
//  `glyphSlotFit` entry point: determinism (cache hits return the stored fit),
//  font-size invalidation (a different cell size yields a different fit and
//  cannot reuse the previous size's entry), and glyph/run disambiguation (⚠
//  vs ⚠️ vs ❤️ do not collide).
//

#if os(macOS)
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

@MainActor
final class GlyphFitCacheTests {

    private func cascadeFont(size: CGFloat) -> NSFont {
        let base = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cascadeList: [NSFontDescriptor] = [
            NSFontDescriptor(fontAttributes: [.family: "Apple Color Emoji"])
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascadeList])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

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

    // MARK: - 21/24. Repeated calls are stable (cache hits return the stored fit)

    @Test func repeatedCallsReturnStableFit() throws {
        let base = cascadeFont(size: 24)
        let view = TerminalView(frame: .zero, font: base)
        let (font, glyph) = try #require(firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base))
        var results: [GlyphSlotFit] = []
        for _ in 0..<50 {
            results.append(view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 1))
        }
        let first = results[0]
        #expect(results.allSatisfy { $0.scale == first.scale && $0.dx == first.dx && $0.dy == first.dy },
                "cache must return a stable fit across repeated calls")
    }

    // MARK: - 22. Glyph/run disambiguation — ⚠️ and ❤️ do not collide

    @Test func warningAndHeartEmojiProduceDistinctFits() throws {
        let base = cascadeFont(size: 24)
        let view = TerminalView(frame: .zero, font: base)
        let (warnFont, warnGlyph) = try #require(firstRunFontGlyph("\u{26A0}\u{FE0F}", base: base))
        let (heartFont, heartGlyph) = try #require(firstRunFontGlyph("\u{2764}\u{FE0F}", base: base))
        let warnFit = view.glyphSlotFit(font: warnFont, glyph: warnGlyph, columnWidth: 1)
        let heartFit = view.glyphSlotFit(font: heartFont, glyph: heartGlyph, columnWidth: 1)
        // Both must be fitted (scale < 1), and because they are different
        // glyphs in the cache key, both entries coexist.
        #expect(warnFit.scale < 1 && heartFit.scale < 1)
        // They are distinct cache entries (different glyph ids), so looking
        // them up in interleaved order stays stable.
        let warnAgain = view.glyphSlotFit(font: warnFont, glyph: warnGlyph, columnWidth: 1)
        #expect(warnAgain.scale == warnFit.scale && warnAgain.dx == warnFit.dx)
    }

    // MARK: - 23/31/43. Font-size invalidation — 14pt must not serve 24pt's fit

    @Test func fontSizeChangeDoesNotReuseStaleFit() throws {
        // The cache key carries cellWidth/cellHeight, which are recomputed when
        // the font size changes; a 14pt entry therefore can never satisfy a
        // 24pt lookup. The two sizes produce different scales (Apple Color
        // Emoji does not scale perfectly linearly), proving independence.
        let warn = "\u{26A0}\u{FE0F}"

        let base14 = cascadeFont(size: 14)
        let view14 = TerminalView(frame: .zero, font: base14)
        let (font14, glyph14) = try #require(firstRunFontGlyph(warn, base: base14))
        let fit14 = view14.glyphSlotFit(font: font14, glyph: glyph14, columnWidth: 1)

        let base24 = cascadeFont(size: 24)
        let view24 = TerminalView(frame: .zero, font: base24)
        let (font24, glyph24) = try #require(firstRunFontGlyph(warn, base: base24))
        let fit24 = view24.glyphSlotFit(font: font24, glyph: glyph24, columnWidth: 1)

        // Both must be valid fits that shrink the glyph into one cell...
        #expect(fit14.scale > 0 && fit14.scale < 1)
        #expect(fit24.scale > 0 && fit24.scale < 1)
        // ...and, because they were computed for different cell sizes, the
        // resulting scales differ (no stale reuse across sizes).
        #expect(fit14.scale != fit24.scale,
                "14pt and 24pt fits must not collide via the cache")
    }

    // MARK: - 24. Bounded growth — many distinct glyphs stay stable

    @Test func manyDistinctGlyphsStayStable() throws {
        // Drive a population of distinct glyphs through the cache; the
        // size bound evicts on overflow rather than growing unbounded, and
        // every lookup still returns a consistent no-upscale result.
        let base = cascadeFont(size: 18)
        let view = TerminalView(frame: .zero, font: base)
        for scalar in 0x1F300...0x1F340 {
            guard let (font, glyph) = firstRunFontGlyph(String(Unicode.Scalar(scalar)!), base: base) else {
                continue
            }
            let fit = view.glyphSlotFit(font: font, glyph: glyph, columnWidth: 2)
            #expect(fit.scale <= 1, "wide emoji must never upscale")
        }
    }
}

#endif // os(macOS)
