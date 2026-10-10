import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

/// Draws an Artemis stage with Metal: the layer tree (transforms, opacity, colour fills,
/// clipped pictures, add/screen/multiply blending, negative/grayscale/colormultiply), the
/// message text with its typewriter reveal, pixel shaders on layers and whole layer groups
/// (a layer with `shader=` or `intermediate_render` draws its children offscreen first, as
/// the engine does), and fade and rule transitions between presented frames.
///
/// Shaders are the game's own when it ships them as GLSL (`ArtemisShaderProgram`); built-in
/// versions of the stock effects stand in otherwise. Shared by the app and `artemis-cli`,
/// so frames can be checked headless on the Mac.
@MainActor
public final class ArtemisMetalRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var blendPipelines: [String: MTLRenderPipelineState] = [:]
    private var effectPipelines: [String: MTLRenderPipelineState] = [:]
    /// Game shader programs by `lyshader` id; nil when one didn't compile.
    private var programPipelines: [String: (source: String, state: MTLRenderPipelineState?)] = [:]
    private var transitionPipeline: MTLRenderPipelineState?
    private let linear: MTLSamplerState
    private let nearest: MTLSamplerState
    private let clearTexture: MTLTexture
    private let whiteTexture: MTLTexture

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ArtemisMetalShaders.source, options: nil)
        } catch {
            NSLog("Artemis: Metal shaders failed to compile: %@", "\(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            // Past a picture's edge is transparent (a clip wider than its picture).
            descriptor.sAddressMode = .clampToZero
            descriptor.tAddressMode = .clampToZero
            return device.makeSamplerState(descriptor: descriptor)
        }
        func pixel(_ value: UInt8) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var bytes = [value, value, value, value]
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
            return texture
        }
        guard let linear = sampler(.linear), let nearest = sampler(.nearest),
              let clear = pixel(0), let white = pixel(255) else { return nil }
        self.linear = linear
        self.nearest = nearest
        clearTexture = clear
        whiteTexture = white
    }

    // MARK: Pipelines

    private func pipeline(blend: String) -> MTLRenderPipelineState? {
        if let state = blendPipelines[blend] { return state }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        attachment.isBlendingEnabled = true
        // Premultiplied colour throughout.
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        switch blend {
        case "add":
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
        case "screen":
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
        case "multiply":
            // src*dst + dst*(1-srcA): multiplies where the layer is, leaves the rest.
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        case "subtract":
            attachment.rgbBlendOperation = .reverseSubtract
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
        default:
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        }
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        blendPipelines[blend] = state
        return state
    }

    private func passPipeline(fragment: MTLFunction?, vertex: MTLFunction?) -> MTLRenderPipelineState? {
        guard let fragment, let vertex else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// A full-target pass running one of the built-in effects over a source texture.
    private func effectPipeline(_ name: String) -> MTLRenderPipelineState? {
        if let state = effectPipelines[name] { return state }
        let state = passPipeline(fragment: library.makeFunction(name: "effect_" + name), vertex: library.makeFunction(name: "quad_vertex"))
        effectPipelines[name] = state
        return state
    }

    /// The game's own shader, compiled once per source.
    private func programPipeline(_ id: String, _ program: ArtemisShaderProgram) -> MTLRenderPipelineState? {
        if let cached = programPipelines[id], cached.source == program.metalSource { return cached.state }
        var state: MTLRenderPipelineState?
        do {
            let library = try device.makeLibrary(source: program.metalSource, options: nil)
            state = passPipeline(fragment: library.makeFunction(name: ArtemisShaderProgram.fragmentName),
                                 vertex: library.makeFunction(name: ArtemisShaderProgram.vertexName))
        } catch {
            NSLog("Artemis: shader %@ didn't compile (using the built-in effect): %@", id, "\(error)")
        }
        programPipelines[id] = (program.metalSource, state)
        return state
    }

    // MARK: Textures

    private final class CachedTexture {
        let image: CGImage
        let texture: MTLTexture
        var lastUsed: Int
        init(image: CGImage, texture: MTLTexture, lastUsed: Int) {
            self.image = image
            self.texture = texture
            self.lastUsed = lastUsed
        }
    }
    private var textures: [ObjectIdentifier: CachedTexture] = [:]
    private var frameNumber = 0

    /// The picture as a premultiplied RGBA texture (cached while the same image is shown).
    public func texture(for image: CGImage) -> MTLTexture? {
        let key = ObjectIdentifier(image)
        if let cached = textures[key], cached.image === image {
            cached.lastUsed = frameNumber
            return cached.texture
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        textures[key] = CachedTexture(image: image, texture: texture, lastUsed: frameNumber)
        return texture
    }

    /// Drops textures no frame has used for a while (videos make a new picture each frame).
    private func trimTextures() {
        frameNumber += 1
        guard frameNumber % 30 == 0 else { return }
        textures = textures.filter { frameNumber - $0.value.lastUsed < 60 }
    }

    /// Offscreen targets for groups, reused once the GPU is done with them.
    private var pool: [MTLTexture] = []
    private var inFlight: [MTLTexture] = []

    private func scratch(like target: MTLTexture) -> MTLTexture? {
        let texture: MTLTexture?
        if let index = pool.firstIndex(where: { $0.width == target.width && $0.height == target.height }) {
            texture = pool.remove(at: index)
        } else {
            texture = makeTarget(width: target.width, height: target.height)
        }
        if let texture { inFlight.append(texture) }
        return texture
    }

    /// Frames' offscreen targets, back in the pool once the GPU can't still be using them
    /// (drawables keep at most three frames in flight).
    private var generations: [[MTLTexture]] = []

    private func recycle(after buffer: MTLCommandBuffer) {
        generations.append(inFlight)
        inFlight = []
        while generations.count > 3 { pool.append(contentsOf: generations.removeFirst()) }
        if pool.count > 8 { pool.removeFirst(pool.count - 8) }
    }

    /// A texture the renderer can draw into and sample, `width`×`height` pixels.
    public func makeTarget(width: Int, height: Int, readable: Bool = false) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: max(1, width),
                                                                  height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = readable ? .shared : .private
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Drawing

    /// One message layer's text, drawn over the whole stage, and how much of it shows.
    public struct Text {
        public var id: String
        public var image: CGImage
        /// Rectangles (stage pixels) of the text revealed so far; nil when all of it shows.
        public var reveal: [CGRect]?
        /// Drawn at its stand-in layer in the tree (`chgmsg layered=1`), else above it all.
        public var layered: Bool
        public init(id: String, image: CGImage, reveal: [CGRect]?, layered: Bool) {
            self.id = id
            self.image = image
            self.reveal = reveal
            self.layered = layered
        }
    }

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    /// Matches `Uniforms` in the shader source.
    private struct Uniforms {
        var color: SIMD4<Float> = .zero
        var multiply: SIMD4<Float> = SIMD4(1, 1, 1, 1)
        var alpha: Float = 1
        /// 1: sample the texture; 0: flat colour.
        var textured: Float = 1
        var grayscale: Float = 0
        var negative: Float = 0
    }

    private struct Frame {
        let target: MTLTexture
        let stageSize: CGSize
        var encoder: MTLRenderCommandEncoder
        let buffer: MTLCommandBuffer
        let stage: ArtemisStage
        let layeredTexts: [String: Text]
    }

    /// Draws `stage` (and `texts`) into `target`, which covers the whole stage.
    public func render(stage: ArtemisStage, texts: [Text], textsVisible: Bool, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) {
        trimTextures()
        guard let encoder = begin(target, buffer: commandBuffer, load: .clear) else { return }
        let layered = Dictionary(texts.filter(\.layered).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var frame = Frame(target: target, stageSize: CGSize(width: stage.width, height: stage.height), encoder: encoder,
                          buffer: commandBuffer, stage: stage, layeredTexts: layered)
        for child in stage.root.children { draw(child, transform: .identity, opacity: 1, frame: &frame) }
        if textsVisible {
            for text in texts where !text.layered { drawText(text, transform: .identity, opacity: 1, frame: frame) }
        }
        frame.encoder.endEncoding()
        recycle(after: commandBuffer)
    }

    /// Draws the non-layered texts over an already rendered stage (the app redraws only
    /// text while it types).
    public func renderTexts(_ texts: [Text], stageSize: CGSize, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = begin(target, buffer: commandBuffer, load: .load) else { return }
        for text in texts where !text.layered {
            drawText(text, transform: .identity, opacity: 1, stageSize: stageSize, encoder: encoder)
        }
        encoder.endEncoding()
    }

    /// Copies `source` over `target` (the cached stage under this frame's text).
    public func draw(_ source: MTLTexture, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = begin(target, buffer: commandBuffer, load: .clear) else { return }
        fullQuad(source, uniforms: Uniforms(), blend: "copy", encoder: encoder)
        encoder.endEncoding()
    }

    private func begin(_ target: MTLTexture, buffer: MTLCommandBuffer, load: MTLLoadAction) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return buffer.makeRenderCommandEncoder(descriptor: pass)
    }

    private static func effects(of layer: ArtemisLayer) -> Uniforms {
        var uniforms = Uniforms()
        let m = layer.colorMultiply
        uniforms.multiply = SIMD4(Float((m >> 16) & 0xFF) / 255, Float((m >> 8) & 0xFF) / 255, Float(m & 0xFF) / 255, 1)
        uniforms.grayscale = layer.grayscale ? 1 : 0
        uniforms.negative = layer.negative ? 1 : 0
        return uniforms
    }

    private static func hasColorEffects(_ layer: ArtemisLayer) -> Bool {
        layer.negative || layer.grayscale || layer.colorMultiply != 0xFFFFFF
    }

    private func draw(_ layer: ArtemisLayer, transform parent: CGAffineTransform, opacity: Double, frame: inout Frame) {
        guard layer.visible else { return }
        let alpha = opacity * layer.alpha / 255
        guard alpha > 0.001 else { return }
        let transform = layer.transform.concatenating(parent)

        // A group: the layer and its children draw offscreen; its shader and colour effects
        // apply to the result, which goes on the stage with its opacity and blending.
        let grouped = layer.shader != nil
            || (layer.intermediateRender && !layer.children.isEmpty && (Self.hasColorEffects(layer) || layer.alpha < 255))
        if grouped, let group = scratch(like: frame.target) {
            frame.encoder.endEncoding()
            guard let groupEncoder = begin(group, buffer: frame.buffer, load: .clear) else { return }
            var groupFrame = Frame(target: group, stageSize: frame.stageSize, encoder: groupEncoder, buffer: frame.buffer,
                                   stage: frame.stage, layeredTexts: frame.layeredTexts)
            drawContent(layer, transform: transform, opacity: 1, effects: Uniforms(), frame: &groupFrame)
            groupFrame.encoder.endEncoding()
            var result = group
            if let shader = layer.shader, let output = scratch(like: frame.target) {
                applyShader(shader, layer: layer, source: group, output: output, frame: frame)
                result = output
            }
            guard let resumed = begin(frame.target, buffer: frame.buffer, load: .load) else { return }
            frame.encoder = resumed
            var uniforms = Self.effects(of: layer)
            uniforms.alpha = Float(alpha)
            fullQuad(result, uniforms: uniforms, blend: layer.blendMode, encoder: frame.encoder)
            return
        }
        drawContent(layer, transform: transform, opacity: alpha, effects: Self.effects(of: layer), frame: &frame)
    }

    /// The layer's own fill, picture and text, then its children.
    private func drawContent(_ layer: ArtemisLayer, transform: CGAffineTransform, opacity alpha: Double, effects: Uniforms,
                             frame: inout Frame) {
        let rect = CGRect(x: 0, y: 0, width: layer.width, height: layer.height)
        if let color = layer.color {
            let a = Float((color >> 24) & 0xFF) / 255
            var uniforms = effects
            uniforms.color = SIMD4(Float((color >> 16) & 0xFF) / 255 * a, Float((color >> 8) & 0xFF) / 255 * a,
                                   Float(color & 0xFF) / 255 * a, a)
            uniforms.alpha = Float(alpha)
            uniforms.textured = 0
            quad(rect, uv: CGRect(x: 0, y: 0, width: 1, height: 1), transform: transform, texture: nil, uniforms: uniforms,
                 blend: layer.blendMode, stageSize: frame.stageSize, encoder: frame.encoder)
        }
        if let image = layer.maskedImage, let texture = texture(for: image) {
            let clip = layer.clip ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let uv = CGRect(x: clip.minX / Double(image.width), y: clip.minY / Double(image.height),
                            width: clip.width / Double(image.width), height: clip.height / Double(image.height))
            var uniforms = effects
            uniforms.alpha = Float(alpha)
            quad(rect, uv: uv, transform: transform, texture: texture, uniforms: uniforms, blend: layer.blendMode,
                 stageSize: frame.stageSize, encoder: frame.encoder)
        }
        if let id = layer.messageLayer, let text = frame.layeredTexts[id] {
            drawText(text, transform: transform, opacity: alpha, frame: frame)
        }
        for child in layer.children { draw(child, transform: transform, opacity: alpha, frame: &frame) }
    }

    private func drawText(_ text: Text, transform: CGAffineTransform, opacity: Double, frame: Frame) {
        drawText(text, transform: transform, opacity: opacity, stageSize: frame.stageSize, encoder: frame.encoder)
    }

    private func drawText(_ text: Text, transform: CGAffineTransform, opacity: Double, stageSize size: CGSize,
                          encoder: MTLRenderCommandEncoder) {
        guard let texture = texture(for: text.image) else { return }
        let rects = text.reveal ?? [CGRect(origin: .zero, size: size)]
        for rect in rects {
            let area = rect.intersection(CGRect(origin: .zero, size: size))
            guard !area.isEmpty else { continue }
            let uv = CGRect(x: area.minX / size.width, y: area.minY / size.height,
                            width: area.width / size.width, height: area.height / size.height)
            quad(area, uv: uv, transform: transform, texture: texture, uniforms: Uniforms(alpha: Float(opacity)),
                 blend: "normal", stageSize: size, encoder: encoder)
        }
    }

    /// One textured or flat quad: `rect` in layer pixels, placed by `transform` on the stage.
    private func quad(_ rect: CGRect, uv: CGRect, transform: CGAffineTransform, texture: MTLTexture?, uniforms: Uniforms,
                      blend: String, stageSize: CGSize, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipeline(blend: blend) else { return }
        let w = stageSize.width, h = stageSize.height
        func ndc(_ x: Double, _ y: Double) -> SIMD2<Float> {
            let p = CGPoint(x: x, y: y).applying(transform)
            return SIMD2(Float(p.x / w * 2 - 1), Float(1 - p.y / h * 2))
        }
        let vertices = [
            Vertex(position: ndc(rect.minX, rect.minY), uv: SIMD2(Float(uv.minX), Float(uv.minY))),
            Vertex(position: ndc(rect.maxX, rect.minY), uv: SIMD2(Float(uv.maxX), Float(uv.minY))),
            Vertex(position: ndc(rect.minX, rect.maxY), uv: SIMD2(Float(uv.minX), Float(uv.maxY))),
            Vertex(position: ndc(rect.maxX, rect.maxY), uv: SIMD2(Float(uv.maxX), Float(uv.maxY))),
        ]
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * 4, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture ?? whiteTexture, index: 0)
        encoder.setFragmentSamplerState(linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let fullVertices = [
        Vertex(position: SIMD2(-1, 1), uv: SIMD2(0, 0)), Vertex(position: SIMD2(1, 1), uv: SIMD2(1, 0)),
        Vertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)), Vertex(position: SIMD2(1, -1), uv: SIMD2(1, 1)),
    ]

    private func fullQuad(_ texture: MTLTexture, uniforms: Uniforms, blend: String, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipeline(blend: blend == "copy" ? "normal" : blend) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(Self.fullVertices, length: MemoryLayout<Vertex>.stride * 4, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Shaders

    /// Matches `Effect` in the shader source.
    private struct EffectUniforms {
        var color: SIMD4<Float> = SIMD4(1, 1, 1, 0)
        /// One stage pixel in texture coordinates.
        var texel: SIMD2<Float> = .zero
        var padding: SIMD2<Float> = .zero
        var params: SIMD4<Float> = .zero
        var weights0: SIMD4<Float> = .zero
        var weights1: SIMD4<Float> = .zero
    }

    /// Runs the layer's shader over its group: the game's program when it has one, else the
    /// built-in effect of that name.
    private func applyShader(_ shader: ArtemisShader, layer: ArtemisLayer, source: MTLTexture, output: MTLTexture, frame: Frame) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = frame.buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.setVertexBytes(Self.fullVertices, length: MemoryLayout<Vertex>.stride * 4, index: 0)

        if let program = frame.stage.shaderPrograms[shader.name], let pipeline = programPipeline(shader.name, program) {
            encoder.setRenderPipelineState(pipeline)
            var values = program.uniformValues(shader.values)
            encoder.setFragmentBytes(&values, length: MemoryLayout<Float>.stride * values.count, index: 0)
            for (slot, name) in program.textures.enumerated() {
                let texture: MTLTexture?
                switch name {
                case "textureFore": texture = source
                case "textureMask": texture = whiteTexture
                default:
                    // `shadertexture` names another layer (often hidden) whose picture it reads.
                    texture = shader.textures[name].flatMap { frame.stage.layer($0)?.maskedImage }.flatMap { self.texture(for: $0) }
                }
                encoder.setFragmentTexture(texture ?? clearTexture, index: slot)
            }
            encoder.setFragmentSamplerState(linear, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return
        }

        func number(_ key: String, _ fallback: Float = 0) -> Float {
            shader.values[key].flatMap { Float($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
        }
        var uniforms = EffectUniforms()
        uniforms.color = SIMD4(number("red", 1), number("green", 1), number("blue", 1), 0)
        uniforms.texel = SIMD2(Float(1 / frame.stageSize.width), Float(1 / frame.stageSize.height))
        let name: String
        switch shader.name {
        case "cmul": name = "multiply"
        case "cadd", "rgb": name = "add"
        case "csub":
            name = "add"
            uniforms.color = -uniforms.color
        case "gray": name = "gray"
        case "sepia", "sepia2": name = "sepia"
        case "nega": name = "negative"
        case "blur_h", "blur_v":
            name = shader.name
            let weights = (shader.values["weights"] ?? "").split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            let w = weights + Array(repeating: 0, count: max(0, 8 - weights.count))
            uniforms.weights0 = SIMD4(w[0], w[1], w[2], w[3])
            uniforms.weights1 = SIMD4(w[4], w[5], w[6], w[7])
            // `width`: the step between taps (one pixel unless the game says otherwise).
            if let step = shader.values["width"].flatMap({ Float($0) }), step > 0 {
                uniforms.texel = shader.name == "blur_h" ? SIMD2(step, uniforms.texel.y) : SIMD2(uniforms.texel.x, step)
            }
        case "mosaic":
            name = "mosaic"
            uniforms.params = SIMD4(number("size"), number("ratio", Float(frame.stageSize.width / frame.stageSize.height)), 0, 0)
        case "raster":
            name = "raster"
            uniforms.params = SIMD4(number("angle"), number("inter"), number("size"), 0)
        case "uzumaki":
            name = "swirl"
            uniforms.params = SIMD4(number("size", 0.1), number("radius", 2), 0, 0)
        case "fglass":
            name = "frosted"
            uniforms.params = SIMD4(number("size", 5), 0, 0, 0)
        default:
            name = "copy"
        }
        guard let pipeline = effectPipeline(name) ?? effectPipeline("copy") else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(name == "mosaic" ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: Transitions

    /// Matches `Transition` in the shader source.
    private struct TransitionUniforms {
        var progress: Float
        var vague: Float
        /// 1: through the rule image; 0: a plain crossfade.
        var ruled: Float
        var padding: Float = 0
    }

    /// Draws the old frame over `target` as it dissolves: plainly, or through a greyscale rule
    /// image (darker pixels first, `vague` softening the edge, in 0...255 levels).
    public func dissolve(old: MTLTexture, over target: MTLTexture, progress: Double, rule: CGImage?, vague: Double,
                         commandBuffer: MTLCommandBuffer) {
        if transitionPipeline == nil {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "transition_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            transitionPipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let pipeline = transitionPipeline, let encoder = begin(target, buffer: commandBuffer, load: .load) else { return }
        var uniforms = TransitionUniforms(progress: Float(min(1, max(0, progress))), vague: Float(max(1, vague)) / 255,
                                          ruled: rule == nil ? 0 : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(Self.fullVertices, length: MemoryLayout<Vertex>.stride * 4, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(old, index: 0)
        encoder.setFragmentTexture(rule.flatMap { texture(for: $0) } ?? whiteTexture, index: 1)
        encoder.setFragmentSamplerState(linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Copies `source` into `destination` (same size), e.g. to keep the outgoing frame.
    public func copy(_ source: MTLTexture, to destination: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
    }

    /// Reads a readable target back as an image (CLI snapshots).
    public static func image(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // BGRA, premultiplied.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The renderer's Metal shaders, compiled when it starts.
enum ArtemisMetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex { float2 position; float2 uv; };
    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut quad_vertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]]) {
        VOut out;
        out.position = float4(vertices[id].position, 0, 1);
        out.uv = vertices[id].uv;
        return out;
    }

    struct Uniforms { float4 color; float4 multiply; float alpha; float textured; float grayscale; float negative; };

    // Premultiplied colour in and out; the layer's colour effects in the engine's order.
    fragment float4 quad_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = u.textured > 0.5 ? tex.sample(s, in.uv) : u.color;
        if (u.grayscale > 0.5) { c.rgb = float3(dot(c.rgb, float3(0.299, 0.587, 0.114))); }
        if (u.negative > 0.5) { c.rgb = c.a - c.rgb; }
        c.rgb *= u.multiply.rgb;
        return c * u.alpha;
    }

    struct Effect { float4 color; float2 texel; float2 padding; float4 params; float4 weights0; float4 weights1; };

    static float4 unpremultiply(float4 c) { return c.a > 0 ? float4(c.rgb / c.a, c.a) : float4(0); }
    static float4 premultiply(float4 c) { return float4(c.rgb * c.a, c.a); }

    fragment float4 effect_copy(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    fragment float4 effect_multiply(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                    texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return float4(c.rgb * e.color.rgb, c.a);
    }
    fragment float4 effect_add(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                               texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = unpremultiply(tex.sample(s, in.uv));
        return premultiply(float4(clamp(c.rgb + e.color.rgb, 0.0, 1.0), c.a));
    }
    fragment float4 effect_gray(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return float4(float3(dot(c.rgb, float3(0.298912, 0.586611, 0.114478))), c.a);
    }
    fragment float4 effect_sepia(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        float y = dot(c.rgb, float3(0.298912, 0.586611, 0.114478));
        return float4(min(y * e.color.rgb, float3(c.a)), c.a);
    }
    fragment float4 effect_negative(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return float4(c.a - c.rgb, c.a);
    }
    static float4 blur(VOut in, constant Effect &e, texture2d<float> tex, sampler s, float2 step) {
        float w[8] = { e.weights0.x, e.weights0.y, e.weights0.z, e.weights0.w,
                       e.weights1.x, e.weights1.y, e.weights1.z, e.weights1.w };
        float4 sum = tex.sample(s, in.uv) * w[0];
        for (int i = 1; i < 8; i++) {
            sum += (tex.sample(s, in.uv + step * float(i)) + tex.sample(s, in.uv - step * float(i))) * w[i];
        }
        return sum;
    }
    fragment float4 effect_blur_h(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return blur(in, e, tex, s, float2(e.texel.x, 0));
    }
    fragment float4 effect_blur_v(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return blur(in, e, tex, s, float2(0, e.texel.y));
    }
    fragment float4 effect_mosaic(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        // size: cells down; ratio: width / height.
        float h = max(e.params.x, 1.0);
        float2 grid = float2(h * max(e.params.y, 0.01), h);
        return tex.sample(s, floor(in.uv * grid) / grid);
    }
    fragment float4 effect_raster(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        // A sideways wave down the screen: inter (degrees over the screen height) sets the
        // spacing, angle moves it each frame, size the swing.
        float2 uv = in.uv;
        uv.x += sin((uv.y * e.params.y - e.params.x) * M_PI_F / 180.0) * e.params.z;
        return tex.sample(s, uv);
    }
    fragment float4 effect_swirl(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 d = in.uv - 0.5;
        float r = length(d);
        float a = e.params.x * e.params.y * 10.0 * M_PI_F * max(0.0, 0.5 - r) * 2.0;
        float2 rotated = float2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
        return tex.sample(s, rotated + 0.5);
    }
    fragment float4 effect_frosted(VOut in [[stage_in]], constant Effect &e [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 noise = fract(sin(float2(dot(in.uv, float2(12.9898, 78.233)), dot(in.uv, float2(39.346, 11.135)))) * 43758.5453);
        return tex.sample(s, in.uv + (noise - 0.5) * e.params.x * e.texel * 2.0);
    }

    struct Transition { float progress; float vague; float ruled; float padding; };

    fragment float4 transition_fragment(VOut in [[stage_in]], constant Transition &t [[buffer(0)]],
                                        texture2d<float> old [[texture(0)]], texture2d<float> rule [[texture(1)]],
                                        sampler s [[sampler(0)]]) {
        float4 c = old.sample(s, in.uv);
        float keep;
        if (t.ruled > 0.5) {
            float value = rule.sample(s, in.uv).r;
            float threshold = t.progress * (1.0 + t.vague) - t.vague;
            keep = clamp((value - threshold) / t.vague, 0.0, 1.0);
        } else {
            keep = 1.0 - t.progress;
        }
        return c * keep;
    }
    """
}
