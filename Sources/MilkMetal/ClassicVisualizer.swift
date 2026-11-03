import Accelerate
import Foundation
import Metal

/// Winamp 2's classic main-window visualization: the small spectrum analyzer and the oscilloscope, drawn in a 76×16
/// pixel display from a 24-colour `ClassicVisPalette`.
///
/// Audio comes in as it does for `MilkRenderer`: `feed` takes any chunk size in playback order, and each frame
/// analyzes the audio that should be playing at its `time`. To drive a `MilkRenderer` and a classic display from
/// one audio tap, create the visualizer with `init(sharingAudioWith:)`: the tap feeds the renderer once, and the
/// visualizer reads the same stream on its own clock (see that initializer for why each keeps its own analysis).
///
/// Two ways to get pixels out, both of which advance the display to `time`:
/// - `render(time:)` returns the frame as RGBA bytes, for a host that draws it itself (into a `CALayer`, say) or
///   for tests.
/// - `render(to:commandBuffer:time:)` draws it into a Metal texture of any size, scaled up with nearest-neighbour
///   filtering. `ClassicVisualizerView` does this for you on every display refresh.
///
/// Set `mode` and the options at any time; they apply from the next frame. Main-actor bound, apart from `feed`.
@MainActor
public final class ClassicVisualizer {
    /// What the display shows. Winamp cycles through them in this order when the display is clicked.
    public enum Mode: String, Sendable, CaseIterable {
        /// The spectrum analyzer: bars over a log-frequency axis.
        case analyzer
        /// The oscilloscope: the waveform across the display.
        case oscilloscope
        /// Nothing: every pixel is transparent, so whatever the host draws beneath (a skin's background) shows.
        case off
    }

    /// How the analyzer colours its bars from the palette's 16 analyzer colours (2–17, top row to bottom).
    public enum AnalyzerStyle: String, Sendable, CaseIterable {
        /// Each pixel takes the colour of its row, so a tall bar shows the whole gradient.
        case normal
        /// Each pixel takes its colour by its distance below the bar's top, so every bar is tipped with the top
        /// colour.
        case fire
        /// The whole bar is one colour: the one for the row its top reaches.
        case line
    }

    /// How wide the analyzer's bars are.
    public enum AnalyzerBands: String, Sendable, CaseIterable {
        /// 3-pixel bars with 1-pixel gaps: 19 bars across the main window's display (18 across the windowshade's).
        case thick
        /// One bar per pixel column: 76 bars (72).
        case thin
    }

    /// How the oscilloscope draws the waveform.
    public enum ScopeStyle: String, Sendable, CaseIterable {
        /// One pixel per column, at the sample's height.
        case dots
        /// Each column's sample joined to the last by a vertical run, so the trace is continuous.
        case lines
        /// Each column filled from the centre line to the sample.
        case solid
    }

    /// How fast the analyzer's bars, or its peak markers, fall back after a louder moment. Five speeds, as in
    /// Winamp's options; the rates are `barRate` and `peakRate`.
    public enum Falloff: Int, Sendable, CaseIterable {
        case slowest = 1, slow, moderate, fast, fastest

        /// How fast a bar falls at this speed, in rows (pixels) per second. A full-height bar empties in 16 / rate
        /// seconds: 1.6 s at `.slowest`, 0.2 s at `.fastest`.
        public var barRate: Double { [10.0, 20, 32, 48, 80][rawValue - 1] }
        /// How fast a peak marker falls at this speed, in rows per second: from the top it takes 8 s at `.slowest`,
        /// 0.8 s at `.fastest`.
        public var peakRate: Double { [2.0, 4, 8, 12, 20][rawValue - 1] }
    }

    /// The display's size in pixels.
    public enum Size: String, Sendable, CaseIterable {
        /// 76×16: the main window's display.
        case mainWindow
        /// 72×16: the display in the playlist editor's bottom bar while the main window is in windowshade mode.
        case windowshade

        public var width: Int { self == .mainWindow ? 76 : 72 }
        public var height: Int { 16 }
    }

    /// What the display shows. Default `.analyzer`.
    public var mode = Mode.analyzer
    /// How the analyzer colours its bars. Default `.normal`.
    public var analyzerStyle = AnalyzerStyle.normal
    /// How wide the analyzer's bars are. Default `.thick`. Changing it starts the bars from empty.
    public var analyzerBands = AnalyzerBands.thick
    /// How fast the analyzer's bars fall. Default `.moderate`.
    public var barFalloff = Falloff.moderate
    /// Whether the analyzer draws a peak marker over each bar, in the palette's peak colour. Default true.
    public var showsPeaks = true
    /// How fast the peak markers fall. Default `.moderate`.
    public var peakFalloff = Falloff.moderate
    /// How the oscilloscope draws. Default `.lines`.
    public var scopeStyle = ScopeStyle.lines
    /// The display's colours, e.g. from a skin's `viscolor.txt`. Default `ClassicVisPalette.default`.
    public var palette = ClassicVisPalette.default
    /// The display's size. Default `.mainWindow` (76×16). Changing it starts the bars from empty.
    public var size = Size.mainWindow

    /// The display's width in pixels: 76, or 72 for `.windowshade`.
    public var width: Int { size.width }
    /// The display's height in pixels: 16.
    public var height: Int { size.height }

    nonisolated let audio: AudioRing
    /// True when `audio` belongs to a `MilkRenderer`, so `reset` leaves it alone.
    private let sharesAudio: Bool
    private let analysis = ClassicAnalysis()
    private var bars = ClassicBars(count: 0)
    private var lastTime: TimeInterval?
    /// The palette index of each pixel of the last frame, row by row from the top; `transparentIndex` when off.
    private(set) var indices: [UInt8] = []
    private var gpu: (device: MTLDevice, format: MTLPixelFormat, pipeline: MTLRenderPipelineState?)?

    /// The index `indices` uses for a transparent pixel (off mode), past the palette's 24 colours.
    static let transparentIndex: UInt8 = 24

    /// Creates a visualizer with its own audio input: `feed` it as you would a `MilkRenderer`.
    public init() {
        audio = AudioRing()
        sharesAudio = false
    }

    /// Creates a visualizer that shows the audio fed to `renderer`, so one tap drives both.
    ///
    /// Only the feed is shared: the tap writes each buffer once, into the renderer's ring, and calling either
    /// object's `feed` writes to that same ring (so still feed from one thread at a time). Each reads the stream on
    /// its own clock and does its own analysis, which is what keeps them independent: the classic display usually
    /// keeps running in the main window while the MilkDrop window is closed or paused, the two often draw at
    /// different rates, and they need different analysis (a 2,048-sample windowed mono spectrum on a log axis here;
    /// MilkDrop's 1,024-sample linear spectra and bass, mid and treble levels there). The visualizer's analysis is
    /// one small FFT per frame.
    ///
    /// The visualizer starts with the next audio fed, and starts over if the renderer is `reset`. Resetting the
    /// visualizer doesn't touch the renderer's audio.
    public init(sharingAudioWith renderer: MilkRenderer) {
        audio = renderer.audio
        sharesAudio = true
        analysis.playhead = AudioPlayhead(startingAt: audio.state().written)
    }

    /// Hands the visualizer audio, exactly like `MilkRenderer.feed(samples:channels:sampleRate:)`: interleaved
    /// Float32, any chunk size, in playback order, from one thread at a time; it never allocates, locks or blocks.
    /// For a visualizer made with `init(sharingAudioWith:)` this feeds the renderer too (it's the same input), so
    /// call one or the other, not both.
    public nonisolated func feed(samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        audio.write(samples: samples, channels: channels, sampleRate: sampleRate)
    }

    /// Back to a new visualizer's state: empty bars and peaks, the clock starting again, and, unless the audio is
    /// shared with a renderer, the audio fed so far forgotten (a shared visualizer starts again from the next audio
    /// fed). Settings are kept.
    public func reset() {
        lastTime = nil
        bars = ClassicBars(count: 0)
        if sharesAudio {
            analysis.restart(at: audio.state().written)
        } else {
            audio.clear()
            analysis.restart(at: 0)
        }
    }

    /// Advances the display to `time` and returns the frame as `width` × `height` RGBA pixels, 8 bits per channel,
    /// row by row from the top (`width * height * 4` bytes). Colours are the palette's, opaque; in `.off` mode
    /// every byte is 0 (transparent).
    ///
    /// `time` is in seconds and should rise steadily, as for `MilkRenderer.render(to:commandBuffer:time:)`: it
    /// paces the fed audio and the bars' and peaks' falloff. Calling again with the same `time` gives the same
    /// frame.
    public func render(time: TimeInterval) -> [UInt8] {
        advance(to: time)
        var rgba = [UInt8](repeating: 0, count: indices.count * 4)
        let colors = palette.colors
        for (i, index) in indices.enumerated() where index != Self.transparentIndex {
            let c = colors[Int(index)]
            rgba[4 * i] = c.red
            rgba[4 * i + 1] = c.green
            rgba[4 * i + 2] = c.blue
            rgba[4 * i + 3] = 255
        }
        return rgba
    }

    /// Advances the display to `time` and draws it into `texture`, scaled to fill it with nearest-neighbour
    /// filtering (so a texture 4× the display's size shows each pixel as a 4×4 block). `ClassicVisualizerView`
    /// calls this for you.
    ///
    /// The contract follows `MilkRenderer.render(to:commandBuffer:time:)`:
    /// - The texture needs `.renderTarget` usage. Any colour-renderable pixel format works, e.g. a `CAMetalLayer`'s
    ///   `bgra8Unorm`; `_srgb` formats get the palette's sRGB colours, not twice-encoded ones. In `.off` mode every
    ///   pixel is cleared to transparent black.
    /// - Commit the command buffer. Unlike `MilkRenderer`, this never waits on the GPU: the frame's data travels in
    ///   the command buffer itself.
    /// - `time` should rise steadily, as for `render(time:)`.
    /// - The first frame for each device and pixel format compiles a tiny pipeline. If it can't (or the texture is
    ///   0×0), the display still advances but nothing is encoded.
    public func render(to texture: MTLTexture, commandBuffer: MTLCommandBuffer, time: TimeInterval) {
        advance(to: time)
        guard texture.width > 0, texture.height > 0, let pipeline = pipeline(for: texture) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "ClassicVisualizer"
        encoder.setRenderPipelineState(pipeline)
        let srgb = texture.pixelFormat == .bgra8Unorm_srgb || texture.pixelFormat == .rgba8Unorm_srgb
        var colors = palette.colors.map { c -> SIMD4<Float> in
            func channel(_ v: UInt8) -> Float {
                let x = Float(v) / 255
                return srgb ? (x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)) : x
            }
            return SIMD4(channel(c.red), channel(c.green), channel(c.blue), 1)
        }
        colors.append(.zero)  // transparentIndex
        var uniforms = ClassicUniforms(size: SIMD2(UInt32(width), UInt32(height)),
                                       target: SIMD2(Float(texture.width), Float(texture.height)))
        indices.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        colors.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ClassicUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Frame

    /// Moves the audio and the bars on to `time` and redraws `indices`.
    private func advance(to time: TimeInterval) {
        let elapsed = lastTime.map { time - $0 } ?? 0
        let dt = elapsed.isFinite ? min(max(elapsed, 0), 0.25) : 0
        if time.isFinite { lastTime = time }

        analysis.update(from: audio, time: time)
        let barCount = analyzerBands == .thick ? width / 4 : width
        if bars.heights.count != barCount { bars = ClassicBars(count: barCount) }
        let targets = analysis.bandRows(count: barCount)
        bars.step(targets: targets, dt: dt, barRate: barFalloff.barRate, peakRate: peakFalloff.peakRate)

        var canvas = ClassicCanvas(width: width, height: height)
        switch mode {
        case .off:
            canvas.fill(Self.transparentIndex)
        case .analyzer:
            canvas.drawGrid()
            canvas.drawAnalyzer(bars, style: analyzerStyle, thick: analyzerBands == .thick, peaks: showsPeaks)
        case .oscilloscope:
            canvas.drawGrid()
            if analysis.isPlaying {
                canvas.drawScope(analysis.scopeSamples(count: width), style: scopeStyle)
            }
        }
        indices = canvas.pixels
    }

    private func pipeline(for texture: MTLTexture) -> MTLRenderPipelineState? {
        if let gpu, gpu.device === texture.device, gpu.format == texture.pixelFormat { return gpu.pipeline }
        var pipeline: MTLRenderPipelineState?
        if let library = try? texture.device.makeLibrary(source: Self.shaderSource, options: nil) {
            let d = MTLRenderPipelineDescriptor()
            d.label = "ClassicVisualizer"
            d.vertexFunction = library.makeFunction(name: "classic_vertex")
            d.fragmentFunction = library.makeFunction(name: "classic_fragment")
            d.colorAttachments[0].pixelFormat = texture.pixelFormat
            pipeline = try? texture.device.makeRenderPipelineState(descriptor: d)
        }
        // Remembered either way, so a format that can't work doesn't recompile every frame.
        gpu = (texture.device, texture.pixelFormat, pipeline)
        return pipeline
    }

    private struct ClassicUniforms {
        var size: SIMD2<UInt32>
        var target: SIMD2<Float>
    }

    /// One full-screen triangle; each target pixel looks up the display pixel it falls in.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ClassicUniforms { uint2 size; float2 target; };

    vertex float4 classic_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2 - 1, 0, 1);
    }

    fragment float4 classic_fragment(float4 position [[position]],
                                     constant uchar *indices [[buffer(0)]],
                                     constant float4 *palette [[buffer(1)]],
                                     constant ClassicUniforms &u [[buffer(2)]]) {
        uint x = min(uint(position.x * float(u.size.x) / u.target.x), u.size.x - 1);
        uint y = min(uint(position.y * float(u.size.y) / u.target.y), u.size.y - 1);
        return palette[indices[y * u.size.x + x]];
    }
    """
}

// MARK: - Analysis

/// Reads the window of fed audio that's playing "now" and turns it into what the classic display shows: band
/// levels in rows for the analyzer and per-column samples for the scope.
///
/// The spectrum is a 2,048-sample Hann-windowed FFT of the mono mix. Bands are spaced evenly in log frequency
/// from 50 Hz to 16 kHz (or just under Nyquist), and a band's level is its loudest bin (or, for a band narrower
/// than a bin, the magnitude interpolated at its centre). Levels go to rows on a dB scale: 54 dB across the 16 rows,
/// from −60 dBFS (empty) to −6 dBFS (full) for a sine at 1 kHz, tilted by 3 dB per octave around 1 kHz so that
/// music's quieter treble still moves.
final class ClassicAnalysis {
    static let windowSize = 2048
    /// Samples across the scope: 12 ms at 48 kHz, close to what Winamp's scope shows.
    static let scopeSpan = 576
    static let minFrequency = 50.0
    static let maxFrequency = 16_000.0
    /// dBFS (for a sine at 1 kHz) at the bottom and the top of the analyzer.
    static let floorDB = -60.0, ceilingDB = -6.0
    /// dB per octave added above 1 kHz (and taken off below).
    static let tiltPerOctave = 3.0
    private static let log2n = vDSP_Length(11)

    var playhead = AudioPlayhead()
    /// Whether audio is playing: false before any is fed and once the feed has stopped and played out.
    var isPlaying: Bool { playhead.position != nil }
    private(set) var sampleRate = 44_100.0
    /// Magnitude per bin (0…windowSize/2), scaled so a full-scale sine centred on a bin reads 1.
    private(set) var magnitudes = [Float](repeating: 0, count: windowSize / 2)
    private(set) var mono = [Float](repeating: 0, count: windowSize)

    private let fft: FFTSetup
    private let hann: [Float]
    private var left = [Float](repeating: 0, count: windowSize)
    private var right = [Float](repeating: 0, count: windowSize)
    private var windowed = [Float](repeating: 0, count: windowSize)
    private var real = [Float](repeating: 0, count: windowSize / 2)
    private var imag = [Float](repeating: 0, count: windowSize / 2)
    /// The ring's frame count at the last update, to notice it being cleared (`MilkRenderer.reset`).
    private var lastWritten: Int64 = 0

    init() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        fft = setup
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.windowSize,
                           isHalfWindow: false)
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// Starts again with the audio fed from stream position `frame` on.
    func restart(at frame: Int64) {
        playhead = AudioPlayhead(startingAt: frame)
        lastWritten = frame
        vDSP.fill(&magnitudes, with: 0)
        vDSP.fill(&mono, with: 0)
    }

    func update(from ring: AudioRing, time: Double) {
        var state = ring.state()
        if state.written < lastWritten { restart(at: 0) }
        lastWritten = state.written
        sampleRate = state.sampleRate
        let maxLag = AudioPlayhead.maxLag(sampleRate: state.sampleRate, capacity: ring.capacity,
                                          windowSize: Self.windowSize)
        var window = playhead.advance(to: time, state, maxLag: maxLag)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for _ in 0..<4 {
                    if ring.copy(window, count: Self.windowSize, left: l, right: r) { return }
                    state = ring.state()
                    guard let caught = playhead.catchUp(state, maxLag: maxLag) else { return }
                    window = caught
                }
            }
        }
        vDSP.add(left, right, result: &mono)
        vDSP.multiply(0.5, mono, result: &mono)
        vDSP.multiply(mono, hann, result: &windowed)

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                              vDSP_Length(Self.windowSize / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { m in
                    vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(Self.windowSize / 2))
                }
            }
        }
        magnitudes[0] = abs(real[0])  // zrip packs Nyquist into imag[0]
        // zrip doubles the DFT; a Hann window halves a sine's peak: |X| = A·N/4 → A.
        vDSP.multiply(2 / Float(Self.windowSize), magnitudes, result: &magnitudes)
    }

    /// The frequency range the analyzer spans at the current sample rate.
    var frequencyRange: (low: Double, high: Double) {
        let high = min(Self.maxFrequency, 0.95 * sampleRate / 2)
        return (min(Self.minFrequency, high / 2), high)
    }

    /// Band `band` of `count`'s edges in Hz.
    func bandEdges(_ band: Int, of count: Int) -> (low: Double, high: Double) {
        let (lo, hi) = frequencyRange
        let ratio = hi / lo
        return (lo * pow(ratio, Double(band) / Double(count)), lo * pow(ratio, Double(band + 1) / Double(count)))
    }

    /// Each of `count` bands' level in rows, 0…16.
    func bandRows(count: Int) -> [Double] {
        let binHz = sampleRate / Double(Self.windowSize)
        let last = magnitudes.count - 1
        return (0..<count).map { band in
            let (low, high) = bandEdges(band, of: count)
            let kLow = low / binHz, kHigh = high / binHz
            var level: Float = 0
            var k = Int(kLow.rounded(.up))
            while Double(k) < kHigh && k <= last {
                level = max(level, magnitudes[k])
                k += 1
            }
            let centre = (low * high).squareRoot()
            if kHigh - kLow < 1 {
                let x = min(centre / binHz, Double(last))
                let i = Int(x), f = Float(x - Double(i))
                level = max(level, magnitudes[i] * (1 - f) + magnitudes[min(i + 1, last)] * f)
            }
            return Self.rows(magnitude: Double(level), frequency: centre)
        }
    }

    /// A band's height in rows (0…16) for its `magnitude` (1 = full scale) at `frequency`.
    static func rows(magnitude: Double, frequency: Double) -> Double {
        guard magnitude > 0 else { return 0 }
        let db = 20 * log10(magnitude) + tiltPerOctave * log2(frequency / 1000)
        return min(max((db - floorDB) / (ceilingDB - floorDB) * 16, 0), 16)
    }

    /// The newest `scopeSpan` mono samples, averaged down to `count` columns, oldest first; −1…1.
    func scopeSamples(count: Int) -> [Float] {
        let base = Self.windowSize - Self.scopeSpan
        return (0..<count).map { c in
            let start = base + c * Self.scopeSpan / count
            let end = max(start + 1, base + (c + 1) * Self.scopeSpan / count)
            var sum: Float = 0
            for i in start..<end { sum += mono[i] }
            return sum / Float(end - start)
        }
    }
}

// MARK: - Bars

/// The analyzer's bar and peak heights in rows (0…16), with their falloff.
struct ClassicBars {
    private(set) var heights: [Double]
    private(set) var peaks: [Double]

    init(count: Int) {
        heights = [Double](repeating: 0, count: count)
        peaks = [Double](repeating: 0, count: count)
    }

    /// Bars jump up to their targets and fall at `barRate` rows per second; peaks are pushed up by their bars and
    /// fall at `peakRate`.
    mutating func step(targets: [Double], dt: Double, barRate: Double, peakRate: Double) {
        for i in heights.indices {
            let target = i < targets.count ? targets[i] : 0
            heights[i] = max(target, heights[i] - barRate * dt, 0)
            peaks[i] = max(heights[i], peaks[i] - peakRate * dt, 0)
        }
    }

    /// Whole rows a height covers (rounded to nearest).
    static func rows(_ height: Double) -> Int { min(16, max(0, Int((height + 0.5).rounded(.down)))) }
}

// MARK: - Drawing

/// Palette indices for one frame, row by row from the top.
struct ClassicCanvas {
    let width: Int, height: Int
    var pixels: [UInt8]

    /// The scope's centre line: a silent sample sits on this row, and `.solid` fills from it.
    static let centreRow = 8

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: UInt8(ClassicVisPalette.backgroundIndex), count: width * height)
    }

    mutating func fill(_ index: UInt8) {
        for i in pixels.indices { pixels[i] = index }
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// The background: colour 0, with a colour-1 dot on every second pixel of every second row.
    mutating func drawGrid() {
        for y in 0..<height {
            for x in 0..<width {
                self[x, y] = UInt8(x % 2 == 1 && y % 2 == 1 ? ClassicVisPalette.gridIndex
                                                             : ClassicVisPalette.backgroundIndex)
            }
        }
    }

    mutating func drawAnalyzer(_ bars: ClassicBars, style: ClassicVisualizer.AnalyzerStyle, thick: Bool,
                               peaks: Bool) {
        let first = ClassicVisPalette.analyzerIndices.lowerBound
        for (bar, height) in bars.heights.enumerated() {
            let columns = thick ? (bar * 4)..<min(bar * 4 + 3, width) : bar..<min(bar + 1, width)
            let n = min(ClassicBars.rows(height), self.height)
            let top = self.height - n
            for y in top..<self.height {
                let colour = switch style {
                case .normal: first + y
                case .fire: first + (y - top)
                case .line: first + top
                }
                for x in columns { self[x, y] = UInt8(colour) }
            }
            if peaks {
                let p = min(ClassicBars.rows(bars.peaks[bar]), self.height)
                if p > 0 {
                    for x in columns { self[x, self.height - p] = UInt8(ClassicVisPalette.peakIndex) }
                }
            }
        }
    }

    /// The row a sample (−1…1) sits on: +1 at the top row, 0 on `centreRow`, −1 at the bottom.
    func row(for sample: Float) -> Int {
        let y = Double(Self.centreRow) - Double(sample.isFinite ? sample : 0) * Double(Self.centreRow)
        return min(max(Int(y.rounded(.down)), 0), height - 1)
    }

    /// The scope colour for a row: brightest (18) at the outer rows, dimmest (22) by the centre line.
    func scopeColour(row: Int) -> UInt8 {
        let distance = abs(Double(row) - (Double(height) - 1) / 2)          // 0.5 … 7.5
        let band = min(4, Int(distance * 5 / (Double(height) / 2)))       // 0 … 4
        return UInt8(ClassicVisPalette.oscilloscopeIndices.upperBound - band)
    }

    mutating func drawScope(_ samples: [Float], style: ClassicVisualizer.ScopeStyle) {
        var previous: Int?
        for (x, sample) in samples.prefix(width).enumerated() {
            let y = row(for: sample)
            let span: ClosedRange<Int> = switch style {
            case .dots: y...y
            case .lines: previous.map { min($0, y)...max($0, y) } ?? y...y
            case .solid: min(Self.centreRow, y)...max(Self.centreRow, y)
            }
            for r in span { self[x, r] = scopeColour(row: r) }
            previous = y
        }
    }
}
