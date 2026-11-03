import AppKit
import Foundation
import Metal
import MilkDemoSupport
import MilkMetal

// The classic Winamp visualization (ClassicVisualizer): offscreen frames and a window, fed by SynthAudio.

/// `--vis`, `--style` and the other classic options.
struct ClassicOptions {
    var mode = ClassicVisualizer.Mode.analyzer
    var analyzerStyle = ClassicVisualizer.AnalyzerStyle.normal
    var scopeStyle = ClassicVisualizer.ScopeStyle.lines
    var bands = ClassicVisualizer.AnalyzerBands.thick
    var falloff = ClassicVisualizer.Falloff.moderate
    var peakFalloff = ClassicVisualizer.Falloff.moderate
    var peaks = true
    var size = ClassicVisualizer.Size.mainWindow
    var scale = 4
    var palette: URL?

    /// Takes `flag` if it's a classic option, reading its value with `value`; false if it isn't one.
    mutating func parse(_ flag: String, value: () -> String) -> Bool {
        func falloffValue() -> ClassicVisualizer.Falloff {
            let v = value()
            guard let n = Int(v), let f = ClassicVisualizer.Falloff(rawValue: n) else { fail("\(flag) needs 1-5") }
            return f
        }
        switch flag {
        case "--vis":
            let v = value()
            guard let m = ClassicVisualizer.Mode(rawValue: v == "scope" ? "oscilloscope" : v) else {
                fail("unknown --vis \(v)")
            }
            mode = m
        case "--style":
            let v = value()
            if let s = ClassicVisualizer.AnalyzerStyle(rawValue: v) {
                analyzerStyle = s
            } else if let s = ClassicVisualizer.ScopeStyle(rawValue: v) {
                scopeStyle = s
            } else {
                fail("unknown --style \(v)")
            }
        case "--bands":
            let v = value()
            guard let b = ClassicVisualizer.AnalyzerBands(rawValue: v) else { fail("unknown --bands \(v)") }
            bands = b
        case "--falloff": falloff = falloffValue()
        case "--peak-falloff": peakFalloff = falloffValue()
        case "--no-peaks": peaks = false
        case "--shade": size = .windowshade
        case "--scale": scale = max(1, min(Int(value()) ?? scale, 64))
        case "--palette": palette = URL(fileURLWithPath: value())
        default: return false
        }
        return true
    }

    @MainActor
    func apply(to vis: ClassicVisualizer) {
        vis.mode = mode
        vis.analyzerStyle = analyzerStyle
        vis.scopeStyle = scopeStyle
        vis.analyzerBands = bands
        vis.barFalloff = falloff
        vis.peakFalloff = peakFalloff
        vis.showsPeaks = peaks
        vis.size = size
        if let palette {
            guard let data = try? Data(contentsOf: palette) else { fail("cannot read \(palette.path)") }
            vis.palette = ClassicVisPalette(viscolorData: data)
        }
    }

    /// For the log: what's being drawn.
    var summary: String {
        let style = mode == .oscilloscope ? scopeStyle.rawValue : analyzerStyle.rawValue
        return "classic \(mode.rawValue) \(style) \(bands.rawValue)\(peaks ? "" : " no-peaks") "
            + "falloff \(falloff.rawValue)/\(peakFalloff.rawValue) \(size.rawValue) x\(scale)"
    }
}

@MainActor
func renderClassicFrames() {
    guard let out = options.out else { fail("classic-frames needs --out DIR") }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fail("no Metal device")
    }
    let vis = ClassicVisualizer()
    options.classic.apply(to: vis)
    let scale = options.classic.scale
    let (width, height) = (vis.width * scale, vis.height * scale)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor) else { fail("cannot make the target texture") }
    print("device \(device.name)")
    print(options.classic.summary)

    let fps = 60.0
    var synth = SynthAudio()
    let samplesPerFrame = Int(synth.sampleRate / fps)
    let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: samplesPerFrame * 2)
    defer { buffer.deallocate() }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var mismatches = 0
    let start = Date()
    for frame in 0..<options.count {
        synth.render(into: buffer, frames: samplesPerFrame)
        vis.feed(samples: UnsafeBufferPointer(buffer), channels: 2, sampleRate: synth.sampleRate)
        guard let commandBuffer = queue.makeCommandBuffer() else { fail("no command buffer") }
        let time = Double(frame) / fps
        vis.render(to: texture, commandBuffer: commandBuffer, time: time)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard (frame + 1) % options.every == 0 else { continue }
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
        // The same frame from the CPU path (same time, so nothing moves), scaled up: must match exactly.
        let rgba = vis.render(time: time)
        for y in 0..<height {
            for x in 0..<width {
                let s = 4 * ((y / scale) * vis.width + x / scale), d = 4 * (y * width + x)
                if pixels[d] != rgba[s + 2] || pixels[d + 1] != rgba[s + 1] || pixels[d + 2] != rgba[s]
                    || pixels[d + 3] != rgba[s + 3] { mismatches += 1 }
            }
        }
        writePNG(bgra: pixels, width: width, height: height,
                 to: out.appendingPathComponent(String(format: "%04d.png", frame + 1)))
    }
    print(String(format: "frames %d in %.2f s", options.count, Date().timeIntervalSince(start)))
    print("classic gpu/cpu mismatches \(mismatches)")
    if mismatches > 0 { exit(1) }
}

/// `ClassicVisualizerView` in a borderless window at the display's size times `--scale`, fed SynthAudio in real time.
@MainActor
final class ClassicDemoApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var feeder: Timer?
    private var synth = SynthAudio()
    private var fedFrames = 0
    private let started = Date()
    private let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: 48_000 * 2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        let vis = ClassicVisualizer()
        options.classic.apply(to: vis)
        let view: ClassicVisualizerView
        do { view = try ClassicVisualizerView(visualizer: vis, device: device) } catch { fail("\(error)") }
        print("device \(device.name)")
        print(options.classic.summary)

        let scale = CGFloat(options.classic.scale)
        let size = NSSize(width: CGFloat(vis.width) * scale, height: CGFloat(vis.height) * scale)
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let origin = NSPoint(x: options.originX, y: screenHeight - options.originY - size.height)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window
        NSApp.activate()

        feeder = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed(vis) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("window \(window.windowNumber) \(Int(options.originX)) \(Int(options.originY)) \(Int(size.width)) \(Int(size.height))")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { NSApp.terminate(nil) }
    }

    private func feed(_ vis: ClassicVisualizer) {
        let due = Int(Date().timeIntervalSince(started) * synth.sampleRate) - fedFrames
        let frames = min(max(due, 0), buffer.count / 2)
        guard frames > 0 else { return }
        synth.render(into: buffer, frames: frames)
        vis.feed(samples: UnsafeBufferPointer(rebasing: buffer[..<(frames * 2)]), channels: 2,
                 sampleRate: synth.sampleRate)
        fedFrames += frames
    }
}
