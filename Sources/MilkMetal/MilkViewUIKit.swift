#if canImport(UIKit)
import Metal
import QuartzCore
import UIKit

/// A `UIView` backed by a `CAMetalLayer` that draws a `MilkRenderer` on every display refresh (tvOS/iOS twin of the
/// AppKit `MilkView`). The host owns everything else: preset browsing, input, overlays.
@MainActor
public final class MilkView: UIView {
    /// The renderer the view draws. Load presets, change settings and `feed` audio through it.
    public let renderer: MilkRenderer
    /// Fixed drawable size in pixels (e.g. 1920×1080 on a 4K screen to save GPU); nil follows the view's size.
    public var renderSize: CGSize? { didSet { setNeedsLayout() } }
    /// Called on the main thread before each frame renders, with the frame's presentation time
    /// (`CADisplayLink.targetTimestamp`). Hosts use it to feed audio for the moment the frame is shown.
    public var willRender: ((CFTimeInterval) -> Void)?
    /// The last frame's render interval, for frame-rate overlays.
    public private(set) var lastFrameInterval: CFTimeInterval = 0
    private let commandQueue: MTLCommandQueue
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Creates a view that draws `renderer` in the renderer's `pixelFormat`. It starts drawing once it's in a
    /// window, with its own clock starting at 0. Throws `MilkRendererError.noCommandQueue` if the device can't make
    /// a command queue.
    public init(renderer: MilkRenderer, frame: CGRect = .zero) throws(MilkRendererError) {
        guard let queue = renderer.device.makeCommandQueue() else { throw MilkRendererError.noCommandQueue }
        self.renderer = renderer
        commandQueue = queue
        super.init(frame: frame)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = renderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        isOpaque = true
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = renderSize
            ?? CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    @objc private func step(_ link: CADisplayLink) {
        if let last = lastTimestamp { lastFrameInterval = link.targetTimestamp - last }
        lastTimestamp = link.targetTimestamp
        willRender?(link.targetTimestamp)
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let start = startTime ?? link.targetTimestamp
        startTime = start
        renderer.render(to: drawable.texture, commandBuffer: commandBuffer, time: link.targetTimestamp - start)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// tvOS/iOS twin of the AppKit `ClassicVisualizerView`: draws a `ClassicVisualizer` scaled up with
/// nearest-neighbour filtering for the chunky Winamp look.
@MainActor
public final class ClassicVisualizerView: UIView {
    public let visualizer: ClassicVisualizer
    /// Drawable size in pixels; defaults to the classic 76×16 display ×2.
    public var renderSize = CGSize(width: 152, height: 32) { didSet { setNeedsLayout() } }
    private let commandQueue: MTLCommandQueue
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init(visualizer: ClassicVisualizer, device: MTLDevice, frame: CGRect = .zero) throws(MilkRendererError) {
        guard let queue = device.makeCommandQueue() else { throw MilkRendererError.noCommandQueue }
        self.visualizer = visualizer
        commandQueue = queue
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.magnificationFilter = .nearest
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.drawableSize = renderSize
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let start = startTime ?? link.targetTimestamp
        startTime = start
        visualizer.render(to: drawable.texture, commandBuffer: commandBuffer, time: link.targetTimestamp - start)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif
