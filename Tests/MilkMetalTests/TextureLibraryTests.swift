import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import MilkMetal

/// Writes a solid-colour PNG of the given size.
private func writePNG(_ url: URL, width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) { (bytes[4 * i], bytes[4 * i + 1], bytes[4 * i + 2]) = rgb }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func textureFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("milktex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("Clouds2.png"), width: 4, height: 2, rgb: (255, 0, 0))
    try writePNG(dir.appendingPathComponent("smoke_smalltiled.png"), width: 8, height: 8, rgb: (0, 255, 0))
    return dir
}

/// Renders `text` once at 16×16 and returns the BGRA bytes of the centre pixel.
@MainActor
private func centrePixel(_ text: String, library: MilkTextureLibrary?) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
    renderer.compilesShadersInBackground = false
    renderer.textureLibrary = library
    try renderer.load(MilkPreset(text: text, name: "tex"))
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let target = try #require(device.makeTexture(descriptor: desc))
    let queue = try #require(device.makeCommandQueue())
    let cb = try #require(queue.makeCommandBuffer())
    renderer.render(to: target, commandBuffer: cb, time: 0)
    cb.commit()
    cb.waitUntilCompleted()
    var pixel = [UInt8](repeating: 0, count: 4)
    target.getBytes(&pixel, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
    return pixel
}

@MainActor
@Suite struct TextureLibraryTests {
    @Test func findsImagesByNameIgnoringCase() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try MilkTextureLibrary(device: device, directory: textureFolder())
        let clouds = try #require(library.texture(named: "clouds2"))
        #expect(clouds.width == 4 && clouds.height == 2)
        #expect(library.texture(named: "CLOUDS2") === clouds)
        #expect(library.texture(named: "nosuch") == nil)
    }

    @Test func randomNamesPickAnImageAndStayPut() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try MilkTextureLibrary(device: device, directory: textureFolder())
        let pick = try #require(library.texture(named: "rand00"))
        #expect(library.texture(named: "rand00") === pick)
        // A suffix filters the candidates: only smoke_smalltiled matches "smalltiled".
        #expect(library.texture(named: "rand03_smalltiled")?.width == 8)
    }

    @Test func boundInsteadOfNoise() throws {
        let preset = "[preset00]\ncomp_1=`shader_body { ret = tex2D(sampler_clouds2, uv).xyz; }"
        let pixel = try centrePixel(preset, library: MilkTextureLibrary(device: MTLCreateSystemDefaultDevice()!,
                                                                         directory: textureFolder()))
        #expect(pixel[2] == 255 && pixel[1] == 0 && pixel[0] == 0, "BGRA \(pixel)") // red image → red
    }

    @Test func texsizeReportsTheImageSize() throws {
        // 1 only when texsize_clouds2.x is 4 (the image's width); noise would report 256.
        let preset = "[preset00]\ncomp_1=`shader_body { float w = texsize_clouds2.x; "
            + "ret = float3(step(3.5, w) * (1 - step(4.5, w)), 0, 0) + 0 * tex2D(sampler_clouds2, uv).xyz; }"
        let pixel = try centrePixel(preset, library: MilkTextureLibrary(device: MTLCreateSystemDefaultDevice()!,
                                                                         directory: textureFolder()))
        #expect(pixel[2] == 255, "BGRA \(pixel)")
    }

    @Test func presetErrorsListOnlyMissingTextures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MilkRenderer(device: device, pixelFormat: .bgra8Unorm)
        renderer.compilesShadersInBackground = false
        renderer.textureLibrary = try MilkTextureLibrary(device: device, directory: textureFolder())
        let text = "[preset00]\ncomp_1=`shader_body { ret = tex2D(sampler_clouds2, uv).xyz + tex2D(sampler_nosuch, uv).xyz; }"
        try renderer.load(MilkPreset(text: text, name: "mixed"))
        let notes = renderer.presetErrors.filter { $0.hasPrefix("textures not available") }
        #expect(notes.count == 1)
        #expect(notes.first?.contains("nosuch") == true)
        #expect(notes.first?.contains("clouds2") == false)
    }
}
