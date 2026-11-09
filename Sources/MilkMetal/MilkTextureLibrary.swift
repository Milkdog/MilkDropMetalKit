import Foundation
import Metal
import MetalKit

/// Disk textures that preset shaders name (`sampler_clouds2` → "clouds2"), loaded from a folder of images such as
/// projectM's presets-milkdrop-texture-pack. Names match file names without their extension, ignoring case, as in
/// MilkDrop. `rand00`–`rand15` pick a random image (an optional `_suffix`, e.g. `rand02_smalltiled`, limits the pick
/// to images whose names contain it); a pick stays the same until `reshuffle()`, which the renderer calls per load.
/// Images load on first use and are cached.
@MainActor
public final class MilkTextureLibrary {
    public let device: MTLDevice
    private let loader: MTKTextureLoader
    private let files: [String: URL]          // lower-cased name without extension → file
    private var cache: [String: MTLTexture] = [:]
    private var randomPicks: [String: MTLTexture] = [:]
    private var generator = SystemRandomNumberGenerator()

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "heic"]

    /// Indexes the images directly inside `directory`. Throws if the folder can't be read.
    public init(device: MTLDevice, directory: URL) throws {
        self.device = device
        loader = MTKTextureLoader(device: device)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var files: [String: URL] = [:]
        for url in urls where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            files[url.deletingPathExtension().lastPathComponent.lowercased()] = url
        }
        self.files = files
    }

    /// Names of the images available, lower-cased.
    public var names: [String] { files.keys.sorted() }

    /// The texture for a shader's name, or nil if there's no such image (the renderer then uses noise).
    public func texture(named name: String) -> MTLTexture? {
        let key = name.lowercased()
        if let random = Self.randomName(key) { return randomTexture(key, filter: random.filter) }
        return load(key)
    }

    /// Forgets the random picks, so the next preset gets new ones.
    public func reshuffle() { randomPicks.removeAll() }

    private func load(_ key: String) -> MTLTexture? {
        if let t = cache[key] { return t }
        guard let url = files[key] else { return nil }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false, .generateMipmaps: false, .textureStorageMode: MTLStorageMode.private.rawValue,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]
        guard let t = try? loader.newTexture(URL: url, options: options) else { return nil }
        cache[key] = t
        return t
    }

    private func randomTexture(_ key: String, filter: String?) -> MTLTexture? {
        if let t = randomPicks[key] { return t }
        var candidates = files.keys.sorted()
        if let filter, case let filtered = candidates.filter({ $0.contains(filter) }), !filtered.isEmpty {
            candidates = filtered
        }
        guard let pick = candidates.randomElement(using: &generator), let t = load(pick) else { return nil }
        randomPicks[key] = t
        return t
    }

    /// `rand00`…`rand15`, optionally followed by `_filter`.
    nonisolated static func randomName(_ key: String) -> (index: Int, filter: String?)? {
        guard key.hasPrefix("rand"), key.count >= 6 else { return nil }
        let digits = key.dropFirst(4).prefix(2)
        guard digits.count == 2, let index = Int(digits) else { return nil }
        let rest = key.dropFirst(6)
        if rest.isEmpty { return (index, nil) }
        guard rest.first == "_", rest.count > 1 else { return nil }
        return (index, String(rest.dropFirst()))
    }
}
