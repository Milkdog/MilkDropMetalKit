import Foundation
import Metal
import Testing
@testable import MilkMetal

struct ClassicVisPaletteTests {
    private typealias C = ClassicVisPalette.Color

    /// 24 distinct colours: entry i is (i, 100 + i, 200 + i).
    private func expected(_ i: Int) -> C { C(red: UInt8(i), green: UInt8(100 + i), blue: UInt8(200 + i)) }

    @Test func parsesASkinsViscolorFile() {
        let text = (0..<24).map { i in "\(i),\(100 + i),\(200 + i) // colour \(i)" }.joined(separator: "\n")
        let palette = ClassicVisPalette(viscolorText: text)
        #expect(palette.colors == (0..<24).map(expected))
        #expect(palette[ClassicVisPalette.peakIndex] == expected(23))
    }

    @Test func toleratesJunkCommentsAndOddSeparators() {
        var lines = ["\u{FEFF}// viscolor.txt for My Skin", "", "   ", "not a colour at all", "// another comment"]
        for i in 0..<24 {
            switch i % 4 {
            case 0: lines.append("\(i), \(100 + i), \(200 + i),   // trailing comma and comment")
            case 1: lines.append("\t\(i)\t\(100 + i)\t\(200 + i)")
            case 2: lines.append("\(i) , \(100 + i) , \(200 + i) junk after 1 2 3")
            default: lines.append("rgb(\(i);\(100 + i);\(200 + i))")
            }
            if i == 10 { lines.append("// in the middle") }
        }
        lines.append("1,2,3 // a 25th entry is ignored")
        let palette = ClassicVisPalette(viscolorText: lines.joined(separator: "\r\n"))
        #expect(palette.colors == (0..<24).map(expected))
    }

    @Test func clampsAndKeepsTheFallbackForWhatItCantRead() {
        let fallback = ClassicVisPalette.default
        let text = """
        999,256,1000
        12,34
        -5,7,8
        """
        let palette = ClassicVisPalette(viscolorText: text)
        #expect(palette[0] == C(red: 255, green: 255, blue: 255), "values over 255 clamp")
        #expect(palette[1] == fallback[1], "a line with two numbers keeps the fallback but uses up its entry")
        #expect(palette[2] == C(red: 5, green: 7, blue: 8), "a minus sign is ignored")
        #expect(Array(palette.colors[3...]) == Array(fallback.colors[3...]), "a short file keeps the rest")
    }

    @Test func emptyOrGarbageTextIsTheFallback() {
        let custom = ClassicVisPalette(colors: [C(red: 1, green: 2, blue: 3)])
        #expect(ClassicVisPalette(viscolorText: "").colors == ClassicVisPalette.default.colors)
        #expect(ClassicVisPalette(viscolorText: "hello\nworld\n// 1,2,3\n", fallback: custom) == custom)
        #expect(ClassicVisPalette(viscolorData: Data([0xFF, 0x00, 0xC3, 0x28]), fallback: custom) == custom)
    }

    @Test func readsLatin1BytesAndMixedLineEndings() {
        // "é" in Windows Latin-1 is not valid UTF-8.
        var data = Data("1,2,3 // caf".utf8) + Data([0xE9]) + Data("\r4,5,6\n7,8,9\r\n".utf8)
        data += Data("10,11,12".utf8)
        let palette = ClassicVisPalette(viscolorData: data)
        #expect(palette[0] == C(red: 1, green: 2, blue: 3))
        #expect(palette[1] == C(red: 4, green: 5, blue: 6))
        #expect(palette[2] == C(red: 7, green: 8, blue: 9))
        #expect(palette[3] == C(red: 10, green: 11, blue: 12))
    }

    @Test func colorsInitPadsAndTruncates() {
        let one = ClassicVisPalette(colors: [C(red: 9, green: 9, blue: 9)])
        #expect(one.colors.count == 24)
        #expect(one[0] == C(red: 9, green: 9, blue: 9))
        #expect(one[1] == ClassicVisPalette.default[1])
        let many = ClassicVisPalette(colors: (0..<30).map(expected))
        #expect(many.colors == (0..<24).map(expected))
    }

    @Test func defaultPaletteIsAGreenAnalyzer() {
        let p = ClassicVisPalette.default
        #expect(p.colors.count == 24)
        for i in ClassicVisPalette.analyzerIndices {
            #expect(p[i].green > p[i].red && p[i].green > p[i].blue, "analyzer colour \(i) is green")
        }
        // Brightest at the top row, darkest at the bottom; the scope dims towards the centre.
        #expect(Int(p[2].green) + Int(p[2].red) > Int(p[17].green) + Int(p[17].red))
        #expect(p[18].red > p[22].red)
    }
}

/// Drives a `ClassicVisualizer` the way a host would: one video frame per 800 samples at 48 kHz (60 fps).
@MainActor
private final class Driver {
    let vis: ClassicVisualizer
    private(set) var frame = 0
    private var sample = 0
    init(_ vis: ClassicVisualizer = ClassicVisualizer()) { self.vis = vis }

    /// A visualizer whose bars fall fast and show no peaks, so the click of a tone starting is gone by the time
    /// it's measured.
    static func settled() -> Driver {
        let driver = Driver()
        driver.vis.barFalloff = .fastest
        driver.vis.showsPeaks = false
        return driver
    }

    var time: Double { Double(frame) / 60 }

    /// Feeds `frames` frames of `signal` (seconds → sample), rendering after each.
    @discardableResult
    func run(_ frames: Int, feed: Bool = true, _ signal: (Double) -> Float = { _ in 0 }) -> [UInt8] {
        var rgba: [UInt8] = []
        var buffer = [Float](repeating: 0, count: 1600)
        for _ in 0..<frames {
            if feed {
                for i in 0..<800 {
                    let s = signal(Double(sample + i) / 48_000)
                    buffer[2 * i] = s
                    buffer[2 * i + 1] = s
                }
                sample += 800
                buffer.withUnsafeBufferPointer { vis.feed(samples: $0, channels: 2, sampleRate: 48_000) }
            }
            frame += 1
            rgba = vis.render(time: time)
        }
        return rgba
    }

    /// Lit rows (any analyzer or peak colour) in column `x` of the last frame.
    func columnHeight(_ x: Int) -> Int {
        (0..<vis.height).filter { y in
            let i = Int(vis.indices[y * vis.width + x])
            return ClassicVisPalette.analyzerIndices.contains(i) || i == ClassicVisPalette.peakIndex
        }.count
    }

    /// True if the last frame is only background and grid, in the grid's pattern.
    var isBackgroundAndGrid: Bool {
        var canvas = ClassicCanvas(width: vis.width, height: vis.height)
        canvas.drawGrid()
        return vis.indices == canvas.pixels
    }
}

private func sine(_ hz: Double, amplitude: Float = 0.5) -> (Double) -> Float {
    { t in amplitude * Float(sin(2 * .pi * hz * t)) }
}

@MainActor
struct ClassicAnalyzerTests {
    /// The thick band a frequency falls in, by the documented log axis (50 Hz – 16 kHz at 48 kHz).
    private func expectedBand(_ hz: Double, of count: Int) -> Int {
        Int((log(hz / 50) / log(16_000 / 50) * Double(count)).rounded(.down))
    }

    /// The centre (in log frequency) of band `b` of `count`.
    private func centre(_ b: Int, of count: Int) -> Double { 50 * pow(320, (Double(b) + 0.5) / Double(count)) }

    @Test(arguments: [8, 11, 14, 17])
    func aSineLightsItsThickBand(band: Int) {
        let driver = Driver.settled()
        let hz = centre(band, of: 19)
        #expect(expectedBand(hz, of: 19) == band)
        driver.run(40, sine(hz))
        let heights = (0..<19).map { driver.columnHeight($0 * 4) }
        #expect(heights.firstIndex(of: heights.max()!) == band, "\(hz) Hz: \(heights)")
        #expect(heights[band] >= 12, "\(hz) Hz at -6 dBFS nearly fills its bar: \(heights)")
        for (b, h) in heights.enumerated() where abs(b - band) >= 2 {
            #expect(h == 0, "\(hz) Hz leaks into bar \(b): \(heights)")
        }
        // The gap column between bars stays background.
        #expect(driver.columnHeight(band * 4 + 3) == 0)
    }

    @Test func aLowSineLightsALowBand() {
        let driver = Driver.settled()
        let hz = centre(3, of: 19)
        driver.run(40, sine(hz))
        let heights = (0..<19).map { driver.columnHeight($0 * 4) }
        #expect(heights.firstIndex(of: heights.max()!) == 3, "\(hz) Hz: \(heights)")
        #expect(heights[10...].allSatisfy { $0 == 0 }, "\(heights)")
    }

    @Test func thinBandsResolveSingleColumns() {
        let driver = Driver.settled()
        driver.vis.analyzerBands = .thin
        let hz = centre(50, of: 76)
        driver.run(40, sine(hz))
        let heights = (0..<76).map { driver.columnHeight($0) }
        let top = heights.firstIndex(of: heights.max()!)!
        #expect(abs(top - 50) <= 1, "\(hz) Hz: \(heights)")
        #expect(heights[..<45].allSatisfy { $0 == 0 } && heights[56...].allSatisfy { $0 == 0 }, "\(heights)")
    }

    @Test func louderIsTallerOnADecibelScale() {
        func height(_ amplitude: Float) -> Int {
            let driver = Driver.settled()
            driver.run(40, sine(centre(12, of: 19), amplitude: amplitude))
            return driver.columnHeight(48)
        }
        let full = height(0.25), tenth = height(0.025), hundredth = height(0.0025)
        // 20 dB is about 6 rows (54 dB across 16 rows).
        #expect(full > tenth && tenth > hundredth)
        #expect(abs((full - tenth) - 6) <= 1 && abs((tenth - hundredth) - 6) <= 1, "\(full) \(tenth) \(hundredth)")
    }

    @Test func windowshadeHasEighteenThickBars() {
        let driver = Driver.settled()
        driver.vis.size = .windowshade
        #expect(driver.vis.width == 72 && driver.vis.height == 16)
        driver.run(40, sine(centre(17, of: 18)))
        #expect(driver.vis.indices.count == 72 * 16)
        let heights = (0..<18).map { driver.columnHeight($0 * 4) }
        #expect(heights.firstIndex(of: heights.max()!) == 17, "\(heights)")
    }

    @Test func stylesColourBarsByRowDistanceOrHeight() {
        // One bar 10 rows tall (rows 6–15), drawn in each style.
        var bars = ClassicBars(count: 19)
        bars.step(targets: [10] + Array(repeating: 0, count: 18), dt: 0, barRate: 0, peakRate: 0)
        func column(_ style: ClassicVisualizer.AnalyzerStyle) -> [UInt8] {
            var canvas = ClassicCanvas(width: 76, height: 16)
            canvas.drawGrid()
            canvas.drawAnalyzer(bars, style: style, thick: true, peaks: false)
            return (0..<16).map { canvas[1, $0] }
        }
        let grid: [UInt8] = (0..<6).map { $0 % 2 == 1 ? 1 : 0 }
        #expect(column(.normal) == grid + (6..<16).map { UInt8(2 + $0) })
        #expect(column(.fire) == grid + (0..<10).map { UInt8(2 + $0) })
        #expect(column(.line) == grid + Array(repeating: UInt8(2 + 6), count: 10))
    }

    @Test func peaksSitAboveFallingBars() {
        var bars = ClassicBars(count: 19)
        bars.step(targets: [16] + Array(repeating: 0, count: 18), dt: 0, barRate: 32, peakRate: 8)
        bars.step(targets: Array(repeating: 0, count: 19), dt: 0.25, barRate: 32, peakRate: 8)
        #expect(bars.heights[0] == 8 && bars.peaks[0] == 14)
        var canvas = ClassicCanvas(width: 76, height: 16)
        canvas.drawGrid()
        canvas.drawAnalyzer(bars, style: .normal, thick: true, peaks: true)
        #expect((0..<3).allSatisfy { canvas[$0, 2] == UInt8(ClassicVisPalette.peakIndex) }, "peak on row 16 - 14")
        #expect(canvas[0, 7] == 0 && canvas[0, 8] == 2 + 8, "bar top on row 8")
        #expect(canvas[3, 2] == 0, "not in the gap")
    }

    /// Falls from full height at each speed: empty after 16 / rate seconds (within a frame), not before.
    @Test(arguments: ClassicVisualizer.Falloff.allCases)
    func barsAndPeaksFallAtTheirRates(speed: ClassicVisualizer.Falloff) {
        let dt = 1.0 / 60
        var bars = ClassicBars(count: 1)
        bars.step(targets: [16], dt: 0, barRate: speed.barRate, peakRate: speed.peakRate)
        var barEmpty: Double?, peakEmpty: Double?
        var t = 0.0
        while peakEmpty == nil && t < 20 {
            bars.step(targets: [0], dt: dt, barRate: speed.barRate, peakRate: speed.peakRate)
            t += dt
            if barEmpty == nil && bars.heights[0] == 0 { barEmpty = t }
            if peakEmpty == nil && bars.peaks[0] == 0 { peakEmpty = t }
            // Halfway, both are exactly where their rates put them.
            if abs(t - 0.1) < dt / 2 {
                #expect(abs(bars.heights[0] - max(0, 16 - speed.barRate * t)) < 1e-9)
                #expect(abs(bars.peaks[0] - max(bars.heights[0], 16 - speed.peakRate * t)) < 1e-9)
            }
        }
        #expect(barEmpty != nil && peakEmpty != nil)
        #expect(abs((barEmpty ?? 0) - 16 / speed.barRate) <= dt + 1e-9, "\(speed) bar")
        #expect(abs((peakEmpty ?? 0) - 16 / speed.peakRate) <= dt + 1e-9, "\(speed) peak")
    }

    @Test func speedsGoFromSlowestToFastest() {
        let speeds = ClassicVisualizer.Falloff.allCases
        #expect(speeds.count == 5 && speeds.first == .slowest && speeds.last == .fastest)
        #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0.barRate < $1.barRate && $0.peakRate < $1.peakRate })
        #expect(speeds.allSatisfy { $0.peakRate < $0.barRate }, "peaks linger after their bars")
    }

    /// End to end: after the feed stops, bars and peaks fall at the chosen speed and the display clears.
    @Test func barsFallAfterTheMusicStops() {
        let driver = Driver()
        driver.vis.barFalloff = .fastest
        driver.vis.peakFalloff = .slowest
        driver.run(20, sine(centre(12, of: 19)))
        #expect(driver.columnHeight(48) >= 12)
        // Held for 0.25 s (the playhead's underrun hold), then silence, then 16 rows at 80 rows/s.
        driver.run(Int(0.25 * 60) + 3 + 12 + 6, feed: false)
        let bar = driver.vis.indices.enumerated().filter { $0.offset % 76 == 48 }
            .map(\.element).filter { ClassicVisPalette.analyzerIndices.contains(Int($0)) }
        #expect(bar.isEmpty, "the bar has emptied")
        #expect(driver.columnHeight(48) == 1, "the slow peak is still up")
        driver.run(60 * 9, feed: false)
        #expect(driver.isBackgroundAndGrid)
    }

    @Test func changingBandsOrSizeRestartsTheBars() {
        let driver = Driver()
        driver.run(10, sine(1000))
        driver.vis.analyzerBands = .thin
        driver.run(1, feed: false)
        #expect(driver.vis.indices.count == 76 * 16)
        driver.vis.size = .windowshade
        driver.run(1, feed: false)
        #expect(driver.vis.indices.count == 72 * 16)
    }
}

@MainActor
struct ClassicScopeTests {
    private func canvas(_ samples: [Float], _ style: ClassicVisualizer.ScopeStyle) -> ClassicCanvas {
        var c = ClassicCanvas(width: 76, height: 16)
        c.drawGrid()
        c.drawScope(samples, style: style)
        return c
    }

    /// Lit rows of column x, as (row, colour index).
    private func lit(_ c: ClassicCanvas, _ x: Int) -> [Int] {
        (0..<16).filter { ClassicVisPalette.oscilloscopeIndices.contains(Int(c[x, $0])) }
    }

    @Test func rowsAndColoursFollowTheSample() {
        let c = ClassicCanvas(width: 76, height: 16)
        #expect(c.row(for: 0) == 8 && c.row(for: 0.5) == 4 && c.row(for: 1) == 0 && c.row(for: -0.5) == 12)
        #expect(c.row(for: -1) == 15 && c.row(for: 3) == 0 && c.row(for: .nan) == 8)
        #expect([0, 1, 14, 15].map(c.scopeColour) == [18, 18, 18, 18], "brightest at the outer rows")
        #expect([7, 8].map(c.scopeColour) == [22, 22], "dimmest by the centre")
    }

    /// A step: +0.5 for the first half, −0.5 for the second.
    private let step = (0..<76).map { $0 < 38 ? Float(0.5) : -0.5 }

    @Test func dotsDrawOnePixelPerColumn() {
        let c = canvas(step, .dots)
        for x in 0..<76 { #expect(lit(c, x) == [x < 38 ? 4 : 12], "column \(x)") }
        #expect(c[0, 4] == c.scopeColour(row: 4))
    }

    @Test func linesJoinEachColumnToTheLast() {
        let c = canvas(step, .lines)
        for x in 0..<76 where x != 38 { #expect(lit(c, x) == [x < 38 ? 4 : 12], "column \(x)") }
        #expect(lit(c, 38) == Array(4...12), "the step is a vertical run")
        #expect((4...12).allSatisfy { c[38, $0] == c.scopeColour(row: $0) })
    }

    @Test func solidFillsFromTheCentreLine() {
        let c = canvas(step, .solid)
        for x in 0..<76 { #expect(lit(c, x) == Array(x < 38 ? 4...8 : 8...12), "column \(x)") }
    }

    @Test func scopeFromFedAudioOnTheCPUPath() {
        // A steady +0.5: every column's sample sits on row 4.
        for style in ClassicVisualizer.ScopeStyle.allCases {
            let driver = Driver()
            driver.vis.mode = .oscilloscope
            driver.vis.scopeStyle = style
            let rgba = driver.run(6) { _ in 0.5 }
            let rows: [Int] = style == .solid ? Array(4...8) : [4]
            let palette = ClassicVisPalette.default
            for x in [0, 37, 75] {
                for y in 0..<16 {
                    let i = 4 * (y * 76 + x)
                    let c = palette[rows.contains(y) ? Int(ClassicCanvas(width: 76, height: 16).scopeColour(row: y))
                                                     : (x % 2 == 1 && y % 2 == 1 ? 1 : 0)]
                    #expect(Array(rgba[i..<(i + 4)]) == [c.red, c.green, c.blue, 255], "\(style) (\(x), \(y))")
                }
            }
        }
    }

    @Test func scopeFollowsAWaveformAcrossTheDisplay() {
        // A full-scale 100 Hz sine.
        let driver = Driver()
        driver.vis.mode = .oscilloscope
        driver.vis.scopeStyle = .dots
        driver.run(6) { t in Float(sin(2 * .pi * 100 * t)) }
        let rows = (0..<76).map { x in (0..<16).first { y in
            ClassicVisPalette.oscilloscopeIndices.contains(Int(driver.vis.indices[y * 76 + x])) } }
        #expect(rows.allSatisfy { $0 != nil }, "one dot per column")
        // 576 samples at 48 kHz are 1.2 cycles of 100 Hz, so the trace crosses the full height and back.
        let values = rows.compactMap(\.self)
        #expect(values.min()! <= 1 && values.max()! >= 14, "\(values)")
    }
}

@MainActor
struct ClassicVisualizerTests {
    @Test(arguments: [ClassicVisualizer.Mode.analyzer, .oscilloscope])
    func silenceIsBackgroundAndGridOnly(mode: ClassicVisualizer.Mode) {
        // Never fed.
        let idle = Driver()
        idle.vis.mode = mode
        idle.run(10, feed: false)
        #expect(idle.isBackgroundAndGrid)
        // Played, then stopped: once the feed has played out, nothing is drawn.
        let stopped = Driver()
        stopped.vis.mode = mode
        stopped.vis.barFalloff = .fastest
        stopped.vis.peakFalloff = .fastest
        stopped.run(10, sine(1000))
        stopped.run(90, feed: false)
        #expect(stopped.isBackgroundAndGrid)
    }

    @Test func fedZerosDrawNoBars() {
        let driver = Driver()
        driver.run(20)
        #expect(driver.isBackgroundAndGrid)
        // The scope draws a flat line on the centre row while silence plays, as Winamp does.
        driver.vis.mode = .oscilloscope
        driver.run(1)
        #expect((0..<76).allSatisfy { driver.vis.indices[8 * 76 + $0] == 22 })
    }

    @Test func offIsTransparent() {
        let driver = Driver()
        driver.vis.mode = .off
        let rgba = driver.run(10, sine(1000))
        #expect(rgba.count == 76 * 16 * 4 && rgba.allSatisfy { $0 == 0 })
    }

    @Test func gridAndBackgroundUseThePalette() {
        let driver = Driver()
        let black = ClassicVisPalette.Color(red: 0, green: 0, blue: 0)
        let white = ClassicVisPalette.Color(red: 255, green: 255, blue: 255)
        driver.vis.palette = ClassicVisPalette(colors: [black, white])
        let rgba = driver.run(1, feed: false)
        #expect(Array(rgba[0..<4]) == [0, 0, 0, 255])
        let dot = 4 * (1 * 76 + 1)
        #expect(Array(rgba[dot..<(dot + 4)]) == [255, 255, 255, 255])
    }

    @Test func sameTimeGivesTheSameFrame() {
        let driver = Driver()
        let a = driver.run(15, sine(440))
        #expect(driver.vis.render(time: driver.time) == a)
    }

    @Test func resetStartsAgain() {
        let driver = Driver()
        driver.run(20, sine(1000))
        driver.vis.reset()
        #expect(driver.vis.audio.state().written == 0, "its own audio is forgotten")
        _ = driver.vis.render(time: 0)
        #expect(driver.isBackgroundAndGrid)
    }

    @Test func sharesARenderersFeed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
        // Audio fed before the visualizer existed isn't heard.
        let early = [Float](repeating: 0.5, count: 9_600)
        early.withUnsafeBufferPointer { renderer.feed(samples: $0, channels: 2, sampleRate: 48_000) }
        let vis = ClassicVisualizer(sharingAudioWith: renderer)
        #expect(vis.audio === renderer.audio)
        vis.mode = .oscilloscope
        _ = vis.render(time: 0)
        _ = vis.render(time: 0.05)
        #expect(!(0..<76).contains { x in (0..<16).contains { vis.indices[$0 * 76 + x] >= 18 } })

        // Fed through the renderer, drawn by the visualizer.
        let driver = Driver(vis)
        var buffer = [Float](repeating: 0, count: 1600)
        for frame in 0..<20 {
            for i in 0..<800 {
                let s = Float(0.5 * sin(2 * .pi * 1000 * Double(frame * 800 + i) / 48_000))
                buffer[2 * i] = s
                buffer[2 * i + 1] = s
            }
            buffer.withUnsafeBufferPointer { renderer.feed(samples: $0, channels: 2, sampleRate: 48_000) }
            _ = vis.render(time: 0.1 + Double(frame) / 60)
        }
        vis.mode = .analyzer
        _ = vis.render(time: 0.1 + 19.0 / 60)
        let band = Int((log(1000.0 / 50) / log(320) * 19).rounded(.down))
        #expect(driver.columnHeight(band * 4) >= 12)

        // A renderer reset clears the ring: the visualizer notices and plays the new stream from its start (else
        // its playhead would wait, silent, until the new stream passed where the old one had got to).
        renderer.reset()
        #expect(renderer.audio.state().written == 0)
        vis.barFalloff = .fastest
        for frame in 0..<12 {
            for i in 0..<800 {
                let s = Float(0.5 * sin(2 * .pi * 4000 * Double(frame * 800 + i) / 48_000))
                buffer[2 * i] = s
                buffer[2 * i + 1] = s
            }
            buffer.withUnsafeBufferPointer { renderer.feed(samples: $0, channels: 2, sampleRate: 48_000) }
            _ = vis.render(time: 1 + Double(frame) / 60)
        }
        let high = Int((log(4000.0 / 50) / log(320) * 19).rounded(.down))
        #expect(driver.columnHeight(high * 4) >= 12)

        // Resetting a sharing visualizer leaves the renderer's audio alone.
        vis.reset()
        #expect(renderer.audio.state().written == 12 * 800)
        _ = vis.render(time: 2)
        #expect(driver.isBackgroundAndGrid)
    }

    @Test(arguments: [MTLPixelFormat.bgra8Unorm, .rgba8Unorm])
    func gpuPathMatchesTheCPUPathScaled(format: MTLPixelFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let (w, h) = (76 * 4, 16 * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let driver = Driver()
        driver.vis.analyzerStyle = .fire
        for mode in ClassicVisualizer.Mode.allCases {
            driver.vis.mode = mode
            driver.run(12, sine(700))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            driver.vis.render(to: texture, commandBuffer: commandBuffer, time: driver.time)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let cpu = driver.vis.render(time: driver.time)
            var gpu = [UInt8](repeating: 0, count: w * h * 4)
            texture.getBytes(&gpu, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var mismatches = 0
            for y in 0..<h {
                for x in 0..<w {
                    let s = 4 * ((y / 4) * 76 + x / 4), d = 4 * (y * w + x)
                    let expected = format == .bgra8Unorm ? [cpu[s + 2], cpu[s + 1], cpu[s], cpu[s + 3]]
                                                         : Array(cpu[s..<(s + 4)])
                    if Array(gpu[d..<(d + 4)]) != expected { mismatches += 1 }
                }
            }
            #expect(mismatches == 0, "\(mode) \(format.rawValue)")
        }
    }
}
