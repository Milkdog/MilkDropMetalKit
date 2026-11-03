import AppKit
import Metal
import QuartzCore

/// An `NSView` backed by a `CAMetalLayer` that draws a `ClassicVisualizer` on every display refresh, scaled to the
/// view's size with nearest-neighbour filtering. Give it a size that's a whole multiple of the display's (76×16
/// points at ×1, 152×32 at ×2, and so on) for even pixels.
///
/// The layer isn't opaque: in `.off` mode the view is transparent, so whatever is behind it (a skin's main window)
/// shows through. The host owns layout, clicks (Winamp cycles `mode` on a click) and the options menu.
@MainActor
public final class ClassicVisualizerView: NSView {
    /// The visualizer the view draws. Change its mode and options, and `feed` it, through this.
    public let visualizer: ClassicVisualizer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval?

    /// Creates a view that draws `visualizer` with `device`. It starts drawing once it's in a window, with its own
    /// clock starting at 0. Throws `MilkRendererError.noCommandQueue` if the device can't make a command queue.
    public init(visualizer: ClassicVisualizer, device: MTLDevice, frame: NSRect = .zero) throws(MilkRendererError) {
        guard let queue = device.makeCommandQueue() else { throw MilkRendererError.noCommandQueue }
        self.visualizer = visualizer
        self.device = device
        commandQueue = queue
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        return layer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let metalLayer, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let start = startTime ?? link.targetTimestamp
        startTime = start
        visualizer.render(to: drawable.texture, commandBuffer: commandBuffer, time: link.targetTimestamp - start)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
