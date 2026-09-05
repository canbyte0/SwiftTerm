//
//  RasterContainmentTests.swift
//  SwiftTerm
//
//  Phase 9D-D: real-pixel hard gates for the CoreGraphics renderer's
//  single-cell overflowing fallback glyph fit (an Apple Color Emoji glyph
//  shaped for a width-1 ⚠️/❤️ cell under `preserveBaseWidth`).
//
//  Why these tests exist (do not "optimize" back to a scaled CTFont):
//  Phase 9D-C real-pixel investigation proved that
//  `CTFontCreateCopyWithAttributes(appleColorEmoji, size × fit.scale, ...)`
//  RE-SELECTS an sbix bitmap strike whose declared ink/size ratio is
//  piecewise-constant per strike (1.250 / 1.250 / 1.167 / 1.000 / 1.000 at
//  10/14/18/24/32pt), NOT linear in point size. The fit math's linear
//  prediction `ink(S) × scale` then underestimates the real raster ink by
//  up to ~25% and the glyph still overflowed its logical cell by up to
//  +3.0pt at 24pt — while every metric-based unit test passed. Only real
//  rendered pixels can gate this: helper/theoretical bounds are fast
//  predicates, never the final correctness source.
//
//  The production draw path (AppleTerminalView scaledFits branch) therefore
//  draws the ORIGINAL CTFont under a local uniform CGContext transform
//  (translate to the glyph origin, scale by fit.scale, draw, restore).
//  These tests render the REAL TerminalView draw path into a bitmap with
//  the REAL font stack and assert containment on the final pixels:
//  left/right/top/bottom overflow <= 0.5pt @2x (1.0pt @1x — one device px).
//

#if os(macOS)
import AppKit
import CoreText
import Testing

@testable import SwiftTerm

@MainActor
final class RasterContainmentTests {

    // MARK: - Raster harness

    /// Bitmap surface the real renderer draws into. Y-up CG coordinates in
    /// points (matching the unflipped TerminalView); pixels addressed from
    /// the top for measurement.
    private final class RasterCanvas {
        let scale: CGFloat
        let ptW: CGFloat, ptH: CGFloat
        let wPx: Int, hPx: Int
        let bytesPerRow: Int
        let ptr: UnsafeMutablePointer<UInt8>
        let ctx: CGContext

        init(pointWidth: CGFloat, pointHeight: CGFloat, scale: CGFloat) {
            self.scale = scale
            ptW = pointWidth
            ptH = pointHeight
            wPx = max(1, Int((ptW * scale).rounded()))
            hPx = max(1, Int((ptH * scale).rounded()))
            bytesPerRow = wPx * 4
            ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * hPx)
            ptr.initialize(repeating: 0, count: bytesPerRow * hPx)
            ctx = CGContext(data: ptr, width: wPx, height: hPx, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: scale, y: scale)
        }

        deinit { ptr.deallocate() }

        @inline(__always) func pixel(x: Int, yFromTop: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let off = yFromTop * bytesPerRow + x * 4
            return (Int(ptr[off]), Int(ptr[off + 1]), Int(ptr[off + 2]), Int(ptr[off + 3]))
        }
    }

    /// Runs the REAL CG draw path (`TerminalView.draw` → `drawTerminalContents`)
    /// into a fresh bitmap at `scale`. Ink = alpha > 16 pixels (the renderer
    /// clears to transparent; the host's layer paints the background in a real
    /// GUI, so any drawn pixel is content ink).
    private func render(_ view: TerminalView, scale: CGFloat) -> RasterCanvas {
        let canvas = RasterCanvas(pointWidth: view.bounds.width,
                                  pointHeight: view.bounds.height, scale: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas.ctx, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    private func isChromatic(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        p.a > 16 && (max(p.r, max(p.g, p.b)) - min(p.r, min(p.g, p.b))) > 24
    }

    private func hasInk(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.a > 16 }

    /// X-clustered chromatic bounding boxes within a row band, in points
    /// (y-up). Adjacent emoji are separated by achromatic cells, so each
    /// cluster maps to exactly one emoji.
    private func chromaticClusters(_ c: RasterCanvas,
                                   rowTopYpt: CGFloat, rowBottomYpt: CGFloat,
                                   xMinPt: CGFloat, xMaxPt: CGFloat,
                                   gapLimitPx: Int)
        -> [(minX: Double, maxX: Double, minY: Double, maxY: Double)]
    {
        let yTopPx = c.hPx - Int((rowTopYpt * c.scale).rounded())
        let yBotPx = c.hPx - Int((rowBottomYpt * c.scale).rounded())
        let xMin = max(0, Int((xMinPt * c.scale).rounded()))
        let xMax = min(c.wPx - 1, Int((xMaxPt * c.scale).rounded()))
        let yLo = max(0, min(yTopPx, yBotPx) + 1)
        let yHi = min(c.hPx - 1, max(yTopPx, yBotPx) - 1)
        guard yLo <= yHi, xMin <= xMax else { return [] }
        var hits: [(x: Int, yLo: Int, yHi: Int)] = []
        for x in xMin...xMax {
            var colLo = Int.max, colHi = Int.min
            for y in yLo...yHi where isChromatic(c.pixel(x: x, yFromTop: y)) {
                if y < colLo { colLo = y }
                if y > colHi { colHi = y }
            }
            if colLo != Int.max { hits.append((x, colLo, colHi)) }
        }
        guard !hits.isEmpty else { return [] }
        var clusters: [(minX: Double, maxX: Double, minY: Double, maxY: Double)] = []
        var start = hits[0].x, prev = hits[0].x
        var lo = hits[0].yLo, hi = hits[0].yHi
        func finishCluster() {
            clusters.append((Double(start) / Double(c.scale),
                             Double(prev) / Double(c.scale),
                             Double(c.hPx - 1 - hi) / Double(c.scale),
                             Double(c.hPx - 1 - lo) / Double(c.scale)))
        }
        for h in hits.dropFirst() {
            if h.x - prev > gapLimitPx { finishCluster(); start = h.x; lo = h.yLo; hi = h.yHi }
            prev = h.x
            lo = min(lo, h.yLo); hi = max(hi, h.yHi)
        }
        finishCluster()
        return clusters
    }

    /// Full ink (any drawn pixel) bbox within a window, in points (y-up).
    private func inkBBox(_ c: RasterCanvas,
                         rowTopYpt: CGFloat, rowBottomYpt: CGFloat,
                         xMinPt: CGFloat, xMaxPt: CGFloat,
                         match: ((r: Int, g: Int, b: Int, a: Int)) -> Bool)
        -> (minX: Double, maxX: Double, minY: Double, maxY: Double)?
    {
        let yTopPx = c.hPx - Int((rowTopYpt * c.scale).rounded())
        let yBotPx = c.hPx - Int((rowBottomYpt * c.scale).rounded())
        let xMin = max(0, Int((xMinPt * c.scale).rounded()))
        let xMax = min(c.wPx - 1, Int((xMaxPt * c.scale).rounded()))
        let yLo = max(0, min(yTopPx, yBotPx) + 1)
        let yHi = min(c.hPx - 1, max(yTopPx, yBotPx) - 1)
        guard yLo <= yHi, xMin <= xMax else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in yLo...yHi {
            for x in xMin...xMax where match(c.pixel(x: x, yFromTop: y)) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX != Int.max else { return nil }
        return (Double(minX) / Double(c.scale), Double(maxX) / Double(c.scale),
                Double(c.hPx - 1 - maxY) / Double(c.scale),
                Double(c.hPx - 1 - minY) / Double(c.scale))
    }

    // MARK: - Fixtures

    /// Base monospace + Apple Color Emoji cascade (same construction the
    /// OneCellGlyphFitTests use): system Menlo keeps the suite free of any
    /// bundled-font dependency; the strike behavior under test lives in
    /// Apple Color Emoji, not the base font.
    private func cascadeFont(size: CGFloat) -> NSFont {
        let base = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let cascadeList: [NSFontDescriptor] = [
            NSFontDescriptor(fontAttributes: [.family: "Apple Color Emoji"])
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascadeList])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private let s1 = "A\u{26A0}\u{FE0F}B\u{2764}\u{FE0F}C"                                  // emoji cols 1, 3
    private let s2 = "|\u{26A0}\u{FE0F}|\u{2764}\u{FE0F}|\u{26A0}\u{FE0F}|\u{2764}\u{FE0F}|" // emoji 1,3,5,7 / sep 0,2,4,6,8

    /// Keeps the offscreen windows backing the test views alive for the
    /// duration of the process (a view's caret/scroller lifecycle is
    /// window-driven; without a window the caret never re-attaches).
    private static var retainedWindows: [NSWindow] = []

    private func makeView(size: CGFloat, cols: Int = 24, rows: Int = 6)
        -> (view: TerminalView, cellW: CGFloat, cellH: CGFloat, scale: CGFloat)
    {
        let options = TerminalOptions(cols: cols, rows: rows, termName: "xterm-256color",
                                      scrollback: 50,
                                      variationSelector16WidthPolicy: .preserveBaseWidth)
        let view = TerminalView(frame: .zero, font: nil, options: options)
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = .black
        // Never ordered front; intersects the main screen so the view gets a
        // real backing scale and a real window-driven caret lifecycle,
        // matching the GUI environment the gate protects.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        Self.retainedWindows.append(window)
        view.font = cascadeFont(size: size)
        let cellW = view.cellDimension.width
        let cellH = view.cellDimension.height
        view.frame = NSRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH)
        return (view, view.cellDimension.width, view.cellDimension.height, view.backingScaleFactor())
    }

    private func tolerance(scale: CGFloat) -> Double { scale >= 2 ? 0.5 : 1.0 }

    private func feedStandardContent(_ view: TerminalView) {
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        term.feed(text: s1)                              // row 0
        term.feed(text: "\r\n" + s2)                     // row 1
        term.feed(text: "\r\n" + "  \u{26A0}\u{FE0F}  ") // row 2: isolated ⚠️ col 2
        term.feed(text: "\r\n" + "  \u{2764}\u{FE0F}  ") // row 3: isolated ❤️ col 2
        term.feed(text: "\u{1b}[?25l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// Asserts one emoji cluster stays inside its logical cell on all four
    /// sides (final bitmap pixels, y-up points).
    private func expectContained(_ cluster: (minX: Double, maxX: Double, minY: Double, maxY: Double),
                                 cellLeft: CGFloat, cellRight: CGFloat,
                                 rowTop: CGFloat, rowBottom: CGFloat,
                                 tol: Double, label: String) {
        #expect(cluster.minX >= Double(cellLeft) - tol,
                "\(label): left intrusion \(Double(cellLeft) - cluster.minX)pt > \(tol)pt")
        #expect(cluster.maxX <= Double(cellRight) + tol,
                "\(label): right intrusion \(cluster.maxX - Double(cellRight))pt > \(tol)pt")
        #expect(cluster.maxY <= Double(rowTop) + tol,
                "\(label): top intrusion \(cluster.maxY - Double(rowTop))pt > \(tol)pt")
        #expect(cluster.minY >= Double(rowBottom) - tol,
                "\(label): bottom intrusion \(Double(rowBottom) - cluster.minY)pt > \(tol)pt")
    }

    // MARK: - §15/§17/§18/§19/§23: per-size raster containment hard gate

    @Test(arguments: [CGFloat(10), CGFloat(14), CGFloat(18), CGFloat(24), CGFloat(32)])
    func singleCellEmojiRasterContained(size: CGFloat) throws {
        let (view, cellW, cellH, scale) = makeView(size: size)
        feedStandardContent(view)
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let gap = Int(0.5 * cellW * scale)

        func rowBand(_ r: Int) -> (top: CGFloat, bottom: CGFloat) {
            (H - CGFloat(r) * cellH, H - CGFloat(r + 1) * cellH)
        }
        func check(row: Int, col: Int, label: String) {
            let band = rowBand(row)
            let cellL = CGFloat(col) * cellW, cellR = cellL + cellW
            let clusters = chromaticClusters(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                                             xMinPt: cellL - 1.5 * cellW, xMaxPt: cellR + 1.5 * cellW,
                                             gapLimitPx: gap)
            guard let cluster = clusters.min(by: {
                abs(($0.minX + $0.maxX) / 2 - Double((cellL + cellR) / 2)) <
                abs(($1.minX + $1.maxX) / 2 - Double((cellL + cellR) / 2))
            }) else {
                Issue.record("\(label): no emoji ink found")
                return
            }
            expectContained(cluster, cellLeft: cellL, cellRight: cellR,
                            rowTop: band.top, rowBottom: band.bottom, tol: tol, label: label)
        }

        for (i, col) in [1, 3].enumerated() { check(row: 0, col: col, label: "s1 emoji \(i) @\(Int(size))pt") }
        for (i, col) in [1, 3, 5, 7].enumerated() { check(row: 1, col: col, label: "s2 emoji \(i) @\(Int(size))pt") }
        check(row: 2, col: 2, label: "isolated ⚠️ @\(Int(size))pt")
        check(row: 3, col: 2, label: "isolated ❤️ @\(Int(size))pt")
    }

    // MARK: - §20: separator hard gate

    @Test(arguments: [CGFloat(10), CGFloat(14), CGFloat(18), CGFloat(24), CGFloat(32)])
    func separatorsNotCoveredByEmojiInk(size: CGFloat) throws {
        let (view, cellW, cellH, scale) = makeView(size: size)
        feedStandardContent(view)
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H - cellH, bottom: H - 2 * cellH) // row 1 = s2

        for sepCol in [0, 2, 4, 6, 8] {
            let sepL = CGFloat(sepCol) * cellW, sepR = sepL + cellW
            // (a) emoji ink may cover the separator by at most tol (0.5pt@2x):
            // scan the separator cell's interior, excluding the allowed
            // tol-wide fringe on each side (pixel columns fully inside the
            // fringes never count as a violation).
            let yTopPx = canvas.hPx - Int((band.top * canvas.scale).rounded())
            let yBotPx = canvas.hPx - Int((band.bottom * canvas.scale).rounded())
            let yLo = max(0, min(yTopPx, yBotPx) + 1)
            let yHi = min(canvas.hPx - 1, max(yTopPx, yBotPx) - 1)
            let xLo = Int(((sepL + CGFloat(tol)) * canvas.scale).rounded(.up))
            let xHi = Int(((sepR - CGFloat(tol)) * canvas.scale).rounded(.down)) - 1
            var violation = false
            if yLo <= yHi && xLo <= xHi {
                outer: for y in yLo...yHi {
                    for x in xLo...xHi where isChromatic(canvas.pixel(x: x, yFromTop: y)) {
                        violation = true
                        break outer
                    }
                }
            }
            #expect(!violation,
                    "separator col \(sepCol) @\(Int(size))pt covered by emoji ink deeper than \(tol)pt")
            // (b) the separator glyph itself is drawn (ink present in its cell)
            let pipe = inkBBox(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                               xMinPt: sepL, xMaxPt: sepR, match: hasInk)
            #expect(pipe != nil, "separator col \(sepCol) @\(Int(size))pt glyph missing")
        }
    }

    // MARK: - §21: cursor hard gate (renderer transform must not move the caret)

    @Test(arguments: [CGFloat(14), CGFloat(24), CGFloat(32)])
    func cursorStaysOnLogicalGrid(size: CGFloat) throws {
        let (view, cellW, _, _) = makeView(size: size)
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        term.feed(text: s1)
        // Model-level hard gate: preserveBaseWidth keeps the cursor at the
        // exact logical column (⚠️/❤️ are width 1).
        #expect(term.buffer.x == 5, "model cursor column must be 5, got \(term.buffer.x)")
        // Presentation-level hard gate: the caret positioner itself
        // (production `updateCursorPosition`, cellW × caretCol) must place the
        // caret on the logical grid — the CGContext transform branch must
        // never move it. Called synchronously (the async display-coalescing
        // path is GUI-timing, not the invariant under test).
        view.updateCursorPosition()
        let caret = view.caretFrame
        #expect(abs(caret.origin.x - 5 * cellW) < 0.01,
                "caret x \(caret.origin.x) != 5 × cellW \(5 * cellW)")
        #expect(abs(caret.width - cellW) < 0.01, "caret width must equal cellW")
        term.feed(text: "\r\n" + s2)
        #expect(term.buffer.x == 9, "model cursor column after s2 must be 9")
        view.updateCursorPosition()
        #expect(abs(view.caretFrame.origin.x - 9 * cellW) < 0.01,
                "caret x after s2 must be 9 × cellW")
    }

    // MARK: - §29: text presentation (no VS16) is not transformed

    /// Resolves the font+glyph CoreText picks for `string` under the cascade
    /// (same shaping the renderer uses).
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

    /// Reference raster of one glyph drawn directly with CTFontDrawGlyphs
    /// (no renderer, no transform) — the "natural" pixel footprint.
    private func referenceRasterBBox(font: CTFont, glyph: CGGlyph, scale: CGFloat)
        -> (width: Double, height: Double)
    {
        let wPx = Int(200 * scale), hPx = Int(120 * scale)
        let ctx = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        var g = glyph
        var p = CGPoint(x: 100, y: 60)
        CTFontDrawGlyphs(font, &g, &p, 1, ctx)
        guard let data = ctx.data else { return (0, 0) }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<hPx {
            for x in 0..<wPx where ptr[y * bpr + x * 4 + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX != Int.max else { return (0, 0) }
        return (Double(maxX - minX) / Double(scale), Double(maxY - minY) / Double(scale))
    }

    @Test func textPresentationBaselineUntouched() throws {
        let (view, cellW, cellH, scale) = makeView(size: 24)
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        term.feed(text: "  \u{26A0} \u{2764}  ") // ⚠ col 2, ❤ col 4, no VS16
        term.feed(text: "\u{1b}[?25l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H, bottom: H - cellH)
        let base = cascadeFont(size: 24)
        for (col, scalar) in [(2, "\u{26A0}"), (4, "\u{2764}")] {
            let cellL = CGFloat(col) * cellW, cellR = cellL + cellW
            // Exact-cell window: a no-transform comparison must not blend the
            // neighbor cell's ink into the bbox.
            let ink = inkBBox(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                              xMinPt: cellL, xMaxPt: cellR, match: hasInk)
            let bbox = try #require(ink, "⚠/❤ text glyph must be drawn")
            let (font, glyph) = try #require(firstRunFontGlyph(scalar, base: base))
            if view.isBaseFont(font) {
                // Base-font glyphs are NEVER transformed or clipped (identity
                // fast path, by design): the renderer's raster must match a
                // direct untransformed reference render of the same glyph
                // (raster-vs-raster — immune to declared-bounds quirks).
                let reference = referenceRasterBBox(font: font, glyph: glyph, scale: scale)
                let rasterWidth = bbox.maxX - bbox.minX
                let rasterHeight = bbox.maxY - bbox.minY
                #expect(abs(rasterWidth - reference.width) <= 1.5,
                        "text col \(col): raster width \(rasterWidth)pt vs reference \(reference.width)pt — unexpected transform")
                #expect(abs(rasterHeight - reference.height) <= 1.5,
                        "text col \(col): raster height \(rasterHeight)pt vs reference \(reference.height)pt — unexpected transform")
            } else {
                // Fallback resolution (e.g. Apple Color Emoji): legitimately
                // fitted — then it must be contained by the same gate.
                #expect(bbox.maxX <= Double(cellR) + tol,
                        "text-presentation col \(col) right intrusion \(bbox.maxX - Double(cellR))pt")
                #expect(bbox.minX >= Double(cellL) - tol,
                        "text-presentation col \(col) left intrusion \(Double(cellL) - bbox.minX)pt")
            }
        }
    }

    // MARK: - §30: normal (width-2) emoji baseline — wide path untouched

    @Test(arguments: [CGFloat(10), CGFloat(14), CGFloat(18), CGFloat(24), CGFloat(32)])
    func normalWideEmojiBaselineContained(size: CGFloat) throws {
        let (view, cellW, cellH, scale) = makeView(size: size)
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        term.feed(text: "  \u{1F600}  ") // 😀 occupies cols 2-3
        term.feed(text: "\u{1b}[?25l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H, bottom: H - cellH)
        let slotL = 2 * cellW, slotR = slotL + 2 * cellW
        let gap = Int(0.5 * cellW * scale)
        let clusters = chromaticClusters(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                                         xMinPt: slotL - cellW, xMaxPt: slotR + cellW, gapLimitPx: gap)
        let cluster = try #require(clusters.first, "😀 ink must be present")
        #expect(cluster.minX >= Double(slotL) - tol,
                "😀 left intrusion \(Double(slotL) - cluster.minX)pt")
        #expect(cluster.maxX <= Double(slotR) + tol,
                "😀 right intrusion \(cluster.maxX - Double(slotR))pt")
    }

    // MARK: - §26: styled ASCII runs do not break containment

    @Test(arguments: [CGFloat(14), CGFloat(24), CGFloat(32)])
    func styledAsciiRunsKeepContainment(size: CGFloat) throws {
        let (view, cellW, cellH, scale) = makeView(size: size)
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        // Bold A, ⚠️, Italic B, ❤️, BoldItalic C — styled runs adjacent to emoji.
        term.feed(text: "\u{1b}[1mA\u{1b}[22m\u{26A0}\u{FE0F}\u{1b}[3mB\u{1b}[23m\u{2764}\u{FE0F}\u{1b}[1;3mC\u{1b}[0m")
        term.feed(text: "\u{1b}[?25l")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H, bottom: H - cellH)
        let gap = Int(0.5 * cellW * scale)
        for (i, col) in [1, 3].enumerated() {
            let cellL = CGFloat(col) * cellW, cellR = cellL + cellW
            let clusters = chromaticClusters(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                                             xMinPt: cellL - 1.5 * cellW, xMaxPt: cellR + 1.5 * cellW,
                                             gapLimitPx: gap)
            guard let cluster = clusters.min(by: {
                abs(($0.minX + $0.maxX) / 2 - Double((cellL + cellR) / 2)) <
                abs(($1.minX + $1.maxX) / 2 - Double((cellL + cellR) / 2))
            }) else {
                Issue.record("styled emoji \(i) @\(Int(size))pt: no ink")
                return
            }
            expectContained(cluster, cellLeft: cellL, cellRight: cellR,
                            rowTop: band.top, rowBottom: band.bottom, tol: tol,
                            label: "styled emoji \(i) @\(Int(size))pt")
        }
    }

    // MARK: - §16: 1x smoke (mechanism is not Retina-specific)

    @Test(arguments: [CGFloat(14), CGFloat(24), CGFloat(32)])
    func oneXRenderSmoke(size: CGFloat) throws {
        let (view, cellW, cellH, _) = makeView(size: size)
        feedStandardContent(view)
        let canvas = render(view, scale: 1)
        let tol = 1.0 // one device pixel at 1x
        let H = view.bounds.height
        let gap = Int(0.5 * cellW)
        let band = (top: H, bottom: H - cellH)
        for (i, col) in [1, 3].enumerated() {
            let cellL = CGFloat(col) * cellW, cellR = cellL + cellW
            let clusters = chromaticClusters(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                                             xMinPt: cellL - 1.5 * cellW, xMaxPt: cellR + 1.5 * cellW,
                                             gapLimitPx: gap)
            guard let cluster = clusters.min(by: {
                abs(($0.minX + $0.maxX) / 2 - Double((cellL + cellR) / 2)) <
                abs(($1.minX + $1.maxX) / 2 - Double((cellL + cellR) / 2))
            }) else {
                Issue.record("1x emoji \(i) @\(Int(size))pt: no ink")
                return
            }
            #expect(cluster.minX >= Double(cellL) - tol, "1x left intrusion @\(Int(size))pt")
            #expect(cluster.maxX <= Double(cellR) + tol, "1x right intrusion @\(Int(size))pt")
        }
    }

    // MARK: - §39: highlight background stays cell-aligned

    final class StubProvider: TerminalHighlightProvider {
        let highlights: [TerminalCellHighlight]
        init(highlights: [TerminalCellHighlight]) { self.highlights = highlights }
        func cellHighlights(in terminal: Terminal, row: Int) -> [TerminalCellHighlight]? { highlights }
    }

    @Test func highlightRectStaysCellAligned() throws {
        let (view, cellW, cellH, scale) = makeView(size: 24)
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        // Highlight a CONTENT cell whose glyph ink is narrow (col 4 = "C"):
        // the red rect stays visible out to both cell edges, while the SAME
        // row carries fitted emoji at cols 1/3 whose CGContext transforms
        // must stay confined to their glyph draws and never leak into the
        // background pass. (Trailing blank cells carry no runs, so a blank
        // cell would prove nothing.) The provider storage is WEAK — keep a
        // strong reference across the render.
        let provider = StubProvider(highlights: [
            TerminalCellHighlight(startColumn: 4, endColumn: 5, color: red)
        ])
        view.highlightProvider = provider
        feedStandardContent(view)
        let canvas = render(view, scale: scale)
        withExtendedLifetime(provider) {}
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H, bottom: H - cellH)
        let cellL = 4 * cellW, cellR = 5 * cellW
        // Strict pure-red matcher: the ❤️ emoji body (~255,59,48) and its
        // darker shadow edge must NOT match; only the (255,0,0) highlight
        // counts. Window is the cell ± tol so the fitted ❤️ at col 3 (whose
        // ink ends just left of cellL) can never contaminate the sample.
        let redBBox = inkBBox(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                              xMinPt: cellL - CGFloat(tol), xMaxPt: cellR + CGFloat(tol),
                              match: { $0.a > 200 && $0.r > 240 && $0.g < 20 && $0.b < 20 })
        let bbox = try #require(redBBox, "highlight rect must be painted")
        #expect(bbox.minX >= Double(cellL) - tol && bbox.minX <= Double(cellL) + tol,
                "highlight left edge \(bbox.minX) vs cell \(Double(cellL))")
        #expect(bbox.maxX >= Double(cellR) - tol && bbox.maxX <= Double(cellR) + tol,
                "highlight right edge \(bbox.maxX) vs cell \(Double(cellR))")
    }

    // MARK: - §40: selection background stays cell-aligned

    @Test func selectionRectStaysCellAligned() throws {
        let (view, cellW, cellH, scale) = makeView(size: 24)
        view.selectedTextBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let term = view.getTerminal()
        term.feed(text: "\u{1b}[2J\u{1b}[H")
        term.feed(text: s1)
        term.feed(text: "\u{1b}[?25l")
        view.selection.setSelection(start: Position(col: 3, row: 0), end: Position(col: 4, row: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let canvas = render(view, scale: scale)
        let tol = tolerance(scale: scale)
        let H = view.bounds.height
        let band = (top: H, bottom: H - cellH)
        let cellL = 3 * cellW, cellR = 4 * cellW
        let blueBBox = inkBBox(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                               xMinPt: 2 * cellW, xMaxPt: 6 * cellW,
                               match: { $0.a > 200 && $0.b > 200 && $0.r < 90 && $0.g < 90 })
        let bbox = try #require(blueBBox, "selection rect must be painted")
        #expect(bbox.minX >= Double(cellL) - tol && bbox.minX <= Double(cellL) + tol,
                "selection left edge \(bbox.minX) vs cell \(Double(cellL))")
        #expect(bbox.maxX >= Double(cellR) - tol && bbox.maxX <= Double(cellR) + tol,
                "selection right edge \(bbox.maxX) vs cell \(Double(cellR))")
    }

    // MARK: - §41: light/dark geometry consistency

    @Test func lightDarkGeometryConsistent() throws {
        let (_, lightCellW, lightCellH, lightScale) = makeView(size: 24)
        let (darkView, darkCellW, darkCellH, _) = makeView(size: 24)
        darkView.nativeBackgroundColor = .black
        darkView.nativeForegroundColor = .white
        #expect(lightCellW == darkCellW && lightCellH == darkCellH,
                "appearance must not change cell geometry")
        feedStandardContent(darkView)
        let canvas = render(darkView, scale: lightScale)
        let tol = tolerance(scale: lightScale)
        let H = darkView.bounds.height
        let gap = Int(0.5 * darkCellW * lightScale)
        let band = (top: H, bottom: H - darkCellH)
        for (i, col) in [1, 3].enumerated() {
            let cellL = CGFloat(col) * darkCellW, cellR = cellL + darkCellW
            let clusters = chromaticClusters(canvas, rowTopYpt: band.top, rowBottomYpt: band.bottom,
                                             xMinPt: cellL - 1.5 * darkCellW, xMaxPt: cellR + 1.5 * darkCellW,
                                             gapLimitPx: gap)
            guard let cluster = clusters.min(by: {
                abs(($0.minX + $0.maxX) / 2 - Double((cellL + cellR) / 2)) <
                abs(($1.minX + $1.maxX) / 2 - Double((cellL + cellR) / 2))
            }) else {
                Issue.record("dark emoji \(i): no ink")
                return
            }
            expectContained(cluster, cellLeft: cellL, cellRight: cellR,
                            rowTop: band.top, rowBottom: band.bottom, tol: tol,
                            label: "dark emoji \(i)")
        }
    }

    // MARK: - §24: documentation guard — why a scaled CTFont is forbidden here

    /// Documents the Phase 9D-C root cause as executable knowledge: for Apple
    /// Color Emoji (an sbix bitmap font), the declared ink/size ratio is
    /// piecewise-constant per bitmap strike, so
    /// `CTFontCreateCopyWithAttributes(ace, size × s)` re-selects a strike and
    /// the copy's ink is NOT `ink(size) × s`. Any future "optimization" that
    /// reintroduces a scaled CTFont copy in the single-cell CG fit branch
    /// reopens the overflow this suite gates against. If a future macOS makes
    /// Apple Color Emoji metrics point-size-linear, this test starts failing
    /// and the guard comment in `AppleTerminalView.scaledFits` can be
    /// revisited.
    @Test func appleColorEmojiScaledCopyDoesNotScaleInkLinearly() throws {
        let base = cascadeFont(size: 24)
        let attr = NSAttributedString(string: "\u{26A0}\u{FE0F}", attributes: [.font: base])
        let line = CTLineCreateWithAttributedString(attr)
        var emojiFont: CTFont?
        var emojiGlyph = CGGlyph(0)
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] where CTRunGetGlyphCount(run) > 0 {
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            let attrs = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
            emojiFont = (attrs?[.font] as? NSFont) as CTFont?
            emojiGlyph = glyphs[0]
        }
        let font = try #require(emojiFont, "⚠️ must resolve to a font")
        #expect((CTFontCopyPostScriptName(font) as String) == "AppleColorEmoji")

        var g = emojiGlyph
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &ink, 1)
        let size = CTFontGetSize(font)
        let originalRatio = ink.width / size

        let scale: CGFloat = 0.604 // the 24pt fit scale from Phase 9D-C
        let copy = CTFontCreateCopyWithAttributes(font, size * scale, nil, nil)
        var copyInk = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(copy, .horizontal, &g, &copyInk, 1)
        let copyRatio = copyInk.width / CTFontGetSize(copy)

        #expect(abs(copyRatio - originalRatio) > 0.05,
                "ACE ink/size ratio must be strike-quantized (orig \(originalRatio), copy \(copyRatio)); if this fails on a future macOS, revisit the CGContext-transform guard")
    }
}
#endif
