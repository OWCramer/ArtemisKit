// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// One Artemis layer. Ids are dotted paths (`100.1.2` sits inside `100.1`, inside `100`);
/// siblings draw in numeric id order. Positions are in stage pixels relative to the parent.
public final class ArtemisLayer {
    public internal(set) var id: String
    public var image: CGImage?
    /// ARGB fill for colour layers (`color="FF000000"`).
    public var color: UInt32?
    public var width: Double = 0
    public var height: Double = 0
    public var left: Double = 0
    public var top: Double = 0
    /// 0...255
    public var alpha: Double = 255
    /// Percent.
    public var xscale: Double = 100
    public var yscale: Double = 100
    /// Degrees, clockwise.
    public var rotate: Double = 0
    /// Scale/rotation origin in layer pixels; nil means the layer's centre.
    public var anchorX: Double?
    public var anchorY: Double?
    public var visible = true
    public internal(set) var children: [ArtemisLayer] = []
    /// Source path of the image, for logs and layer info.
    public var file: String?
    /// A video layer's decoder (`[video id=...]`); its frames become `image`.
    public var video: ArtemisVideo?
    /// Stands in for a layered message layer (`[chgmsg layered=1]`): its text draws here,
    /// in the layer tree, instead of above every layer.
    public var messageLayer: String?
    /// `[anime]` frames, when the layer is a flip-book.
    public var anime: ArtemisAnime?
    /// `reversex` / `reversey`: mirrored around the anchor.
    public var reverseX = false
    public var reverseY = false
    /// `clip`: the part of the image shown (image pixels); width/height follow it.
    public var clip: CGRect?
    /// `layermode`: normal, add, screen or multiply.
    public var blendMode = "normal"
    /// `negative`, `grayscale`, `colormultiply` (0xFFFFFF = none), `lyc mask=`.
    public var negative = false
    public var grayscale = false
    public var colorMultiply: UInt32 = 0xFFFFFF
    public var mask: CGImage?
    /// `lyprop shader=` (the newer generation's pixel shaders, done with Core Image), and
    /// the shaders of the layers it sits in (a character's time-of-day tint is set on its
    /// "tone" parent, a blur on a "blurx"/"blury" one).
    public var shader: ArtemisShader?
    public internal(set) var inheritedShaders: [ArtemisShader] = []
    /// `intermediate_render`: the layer and its children draw offscreen first, and its
    /// shader and colour effects apply to the result.
    public var intermediateRender = false
    /// `clickablethreshold`: events fire only where the image's alpha reaches this.
    public var clickThreshold: Double?
    /// `draggable` / `dragarea` (left, top, right, bottom the layer stays within).
    public var draggable = false
    public var dragArea: CGRect?

    /// The image as shown: mask and colour effects applied (cached).
    public var displayImage: CGImage? {
        guard let image else { return nil }
        let shaders = (shader.map { [$0] } ?? []) + inheritedShaders
        guard negative || grayscale || colorMultiply != 0xFFFFFF || mask != nil || !shaders.isEmpty else { return image }
        let key = "\(ObjectIdentifier(image))|\(negative)|\(grayscale)|\(colorMultiply)|\(mask.map { "\(ObjectIdentifier($0))" } ?? "-")|"
            + shaders.map(\.key).joined(separator: ";")
        if key == processedKey, let processed { return processed }
        processed = ArtemisLayer.process(image, negative: negative, grayscale: grayscale, multiply: colorMultiply, mask: mask, shaders: shaders)
        processedKey = key
        return processed
    }
    private var processed: CGImage?
    private var processedKey: String?

    /// The image with only its mask applied: the Metal renderer does colour effects and
    /// shaders on the GPU (cached).
    public var maskedImage: CGImage? {
        guard let image else { return nil }
        guard let mask else { return image }
        let key = "\(ObjectIdentifier(image))|\(ObjectIdentifier(mask))"
        if key == maskedKey, let masked { return masked }
        masked = ArtemisLayer.process(image, negative: false, grayscale: false, multiply: 0xFFFFFF, mask: mask)
        maskedKey = key
        return masked
    }
    private var masked: CGImage?
    private var maskedKey: String?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func process(_ image: CGImage, negative: Bool, grayscale: Bool, multiply: UInt32, mask: CGImage?,
                        shaders: [ArtemisShader] = []) -> CGImage? {
        var output = CIImage(cgImage: image)
        let extent = output.extent
        if grayscale {
            output = output.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }
        if negative {
            output = output.applyingFilter("CIColorInvert")
        }
        if multiply != 0xFFFFFF {
            let r = CGFloat((multiply >> 16) & 0xFF) / 255, g = CGFloat((multiply >> 8) & 0xFF) / 255, b = CGFloat(multiply & 0xFF) / 255
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        for shader in shaders { output = shader.apply(to: output, extent: extent) }
        if let mask {
            // White in the mask is opaque, black transparent.
            let maskImage = CIImage(cgImage: mask).transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width),
                                                                                    y: extent.height / CGFloat(mask.height)))
            output = output.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: maskImage,
            ])
        }
        return ciContext.createCGImage(output.cropped(to: extent), from: extent)
    }

    static func filtered(_ image: CGImage, _ filter: (CIImage) -> CIImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        return ciContext.createCGImage(filter(input).cropped(to: input.extent), from: input.extent)
    }

    /// Alpha (0...255) of the shown image at a point in layer pixels; 255 for colour layers.
    func alpha(at point: CGPoint) -> Double {
        guard let image = maskedImage else { return 255 }
        let x = Int(point.x + (clip?.minX ?? 0)), y = Int(point.y + (clip?.minY ?? 0))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 255 }
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Double(pixel[3])
    }

    init(id: String) {
        self.id = id
    }

    /// Siblings draw in id order: numeric ids numerically, anything else as strings
    /// (Artemis spec, layer.txt). Compares the last path component.
    static func drawsBefore(_ a: ArtemisLayer, _ b: ArtemisLayer) -> Bool {
        let x = a.id.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let y = b.id.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let xNumeric = !x.isEmpty && x.allSatisfy(\.isASCII) && x.allSatisfy(\.isNumber)
        let yNumeric = !y.isEmpty && y.allSatisfy(\.isASCII) && y.allSatisfy(\.isNumber)
        if xNumeric, yNumeric { return (Double(x) ?? 0) < (Double(y) ?? 0) }
        return x < y
    }

    public var effectiveAnchorX: Double { anchorX ?? width / 2 }
    public var effectiveAnchorY: Double { anchorY ?? height / 2 }

    /// The transform from this layer's pixels to its parent's.
    public var transform: CGAffineTransform {
        let ax = effectiveAnchorX, ay = effectiveAnchorY
        return CGAffineTransform(translationX: left + ax, y: top + ay)
            .rotated(by: rotate * .pi / 180)
            .scaledBy(x: xscale / 100 * (reverseX ? -1 : 1), y: yscale / 100 * (reverseY ? -1 : 1))
            .translatedBy(x: -ax, y: -ay)
    }

    func property(_ name: String) -> Double? {
        switch name {
        case "left", "x": return left
        case "top", "y": return top
        case "alpha": return alpha
        case "xscale": return xscale
        case "yscale": return yscale
        case "rotate", "rotation": return rotate
        case "width": return width
        case "height": return height
        default: return nil
        }
    }

    func setProperty(_ name: String, _ value: Double) {
        switch name {
        case "left", "x": left = value
        case "top", "y": top = value
        case "alpha": alpha = max(0, min(255, value))
        case "xscale": xscale = value
        case "yscale": yscale = value
        case "rotate", "rotation": rotate = value
        case "anchorx": anchorX = value
        case "anchory": anchorY = value
        case "visible": visible = value != 0
        case "reversex": reverseX = value != 0
        case "reversey": reverseY = value != 0
        default: break
        }
    }
}

/// A running property animation (`lytween`).
public struct ArtemisTween {
    public let layer: String
    public let property: String
    public let from: Double
    public let to: Double
    public let start: Double
    public let duration: Double
    public let ease: String
    /// Plays: 0 once, N times, -1 forever (`loop`, or `yoyo` which swaps from/to on
    /// every repeat).
    public let loop: Int
    public let yoyo: Bool
    /// `loopdelay`: pause between repeats (ms).
    public var loopDelay: Double = 0
    /// `file`/`label`/`handler` to run when it finishes (the tag's parameters, like lyevent).
    public var completion: [String: String]?
    /// `delete="1"`: remove the layer when it finishes.
    public var deletesLayer = false
    /// Tweens of one `[tweenset]` share a group; removing one removes them all.
    public var group: Int?

    /// Total plays, nil for forever.
    var plays: Int? { loop < 0 ? nil : max(1, loop) }

    /// The value at the end of the last play.
    var endValue: Double {
        guard yoyo, let plays else { return to }
        return (plays - 1) % 2 == 1 ? from : to
    }

    var endTime: Double {
        guard let plays else { return .infinity }
        return start + Double(plays) * duration + Double(plays - 1) * loopDelay
    }

    func value(at time: Double) -> (value: Double, finished: Bool) {
        let elapsed = time - start
        if elapsed < 0 { return (from, false) }
        guard duration > 0 else { return (endValue, plays != nil) }
        let cycleLength = duration + loopDelay
        let cycle = Int(floor(elapsed / cycleLength))
        if let plays, cycle >= plays { return (endValue, true) }
        var t = min(1, (elapsed - Double(cycle) * cycleLength) / duration)
        if let plays, cycle == plays - 1, t >= 1 { return (endValue, true) }
        if yoyo, cycle % 2 == 1 { t = 1 - t }
        return (from + (to - from) * ArtemisTween.eased(t, ease), false)
    }

    /// The engine's easing methods (lytween.txt; easings.net).
    static func eased(_ t: Double, _ ease: String) -> Double {
        let name = ease.lowercased()
        let parts = name.split(separator: "_")
        // Older spellings: in, out, inout.
        let direction: String, curve: String
        if parts.count == 2 {
            direction = String(parts[0]).replacingOccurrences(of: "ease", with: "")
            curve = String(parts[1])
        } else {
            switch name {
            case "in", "easein": (direction, curve) = ("in", "quad")
            case "out", "easeout": (direction, curve) = ("out", "quad")
            case "inout", "easeinout": (direction, curve) = ("inout", "quad")
            default: return t
            }
        }
        func easeIn(_ x: Double) -> Double {
            switch curve {
            case "quad": return x * x
            case "cubic": return x * x * x
            case "quart": return x * x * x * x
            case "quint": return x * x * x * x * x
            case "expo": return x == 0 ? 0 : pow(2, 10 * x - 10)
            case "circ": return 1 - (1 - x * x).squareRoot()
            case "sine": return 1 - cos(x * .pi / 2)
            case "back":
                let c1 = 1.70158, c3 = c1 + 1
                return c3 * x * x * x - c1 * x * x
            case "elastic":
                let c4 = 2 * Double.pi / 3
                return x == 0 ? 0 : x == 1 ? 1 : -pow(2, 10 * x - 10) * sin((x * 10 - 10.75) * c4)
            case "bounce":
                return 1 - bounceOut(1 - x)
            default: return x
            }
        }
        func bounceOut(_ x: Double) -> Double {
            let n1 = 7.5625, d1 = 2.75
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { let y = x - 1.5 / d1; return n1 * y * y + 0.75 }
            if x < 2.5 / d1 { let y = x - 2.25 / d1; return n1 * y * y + 0.9375 }
            let y = x - 2.625 / d1
            return n1 * y * y + 0.984375
        }
        switch direction {
        case "in": return easeIn(t)
        case "out": return 1 - easeIn(1 - t)
        case "inout": return t < 0.5 ? easeIn(2 * t) / 2 : 1 - easeIn(2 - 2 * t) / 2
        default: return t
        }
    }
}

/// `[anime]`: a flip-book on a layer, frames shown at times from its start.
public struct ArtemisAnime {
    public struct Frame {
        public var time: Double
        public var file: String
        public var image: CGImage?
        public var properties: [String: String]
    }
    public var frames: [Frame] = []
    /// When the last frame ends (`mode=end time=`); nil while frames are still being added.
    public var endTime: Double?
    /// -1 forever, 0 once, N times.
    public var loop = -1
    public var started: Double = 0
    public var shownFrame = -1
}

/// An input handler on a layer (`lyevent`).
public struct ArtemisLayerEvent {
    public var attributes: [String: String]
    public var enabled = true
}

/// The layer tree, tweens and layer events of a running game.
public final class ArtemisStage {
    public let width: Double
    public let height: Double
    public let root = ArtemisLayer(id: "")
    public private(set) var tweens: [ArtemisTween] = []
    /// layer id -> event type (click, rollover, rollout) -> handler.
    public private(set) var events: [String: [String: ArtemisLayerEvent]] = [:]
    /// Bumped on flip/trans: the presenter shows changes then (with a transition for trans).
    public private(set) var presentationCount = 0
    /// Pixel shaders loaded by `lyshader`, by the id `lyprop shader=` names.
    public var shaderPrograms: [String: ArtemisShaderProgram] = [:]
    public private(set) var lastTransition: (type: String, duration: Double, rule: String?, vague: Double)?

    private var imageCache: [String: CGImage] = [:]
    let loadImage: (String) -> CGImage?

    public init(width: Double, height: Double, loadImage: @escaping (String) -> CGImage?) {
        self.width = width
        self.height = height
        self.loadImage = loadImage
        root.width = width
        root.height = height
        root.anchorX = 0
        root.anchorY = 0
    }

    // MARK: Layers

    public func layer(_ id: String) -> ArtemisLayer? {
        guard !id.isEmpty else { return root }
        var current = root
        var path = ""
        for part in id.split(separator: ".") {
            path = path.isEmpty ? String(part) : path + "." + part
            guard let child = current.children.first(where: { $0.id == path }) else { return nil }
            current = child
        }
        return current
    }

    /// The layer with this id, created (with any missing parents) if needed.
    @discardableResult
    public func ensureLayer(_ id: String) -> ArtemisLayer {
        var current = root
        var path = ""
        for part in id.split(separator: ".") {
            path = path.isEmpty ? String(part) : path + "." + part
            if let child = current.children.first(where: { $0.id == path }) {
                current = child
            } else {
                let child = ArtemisLayer(id: path)
                current.children.append(child)
                current.children.sort(by: ArtemisLayer.drawsBefore)
                current = child
            }
        }
        return current
    }

    public func deleteLayer(_ id: String) {
        guard !id.isEmpty else {
            root.children.removeAll()
            tweens.removeAll()
            events.removeAll()
            return
        }
        let parentId = id.split(separator: ".").dropLast().joined(separator: ".")
        guard let parent = layer(parentId) else { return }
        parent.children.removeAll { $0.id == id }
        tweens.removeAll { $0.layer == id || $0.layer.hasPrefix(id + ".") }
        for key in events.keys where key == id || key.hasPrefix(id + ".") { events[key] = nil }
    }

    /// `[chgmsg layered=1]`: a place in the tree for a message layer's text.
    public func placeMessageLayer(_ id: String) {
        let layer = ensureLayer(id)
        guard layer.messageLayer != id else { return }
        layer.messageLayer = id
        layer.width = width
        layer.height = height
        tweenRevision += 1
    }

    /// `[chgmsg layered=0]`: the message layer goes back above the layers.
    public func removeMessageLayer(_ id: String) {
        guard layer(id)?.messageLayer == id else { return }
        deleteLayer(id)
        tweenRevision += 1
    }

    /// Opens a video layer's file again (loading a save): path and loop.
    public var loadVideo: ((String, Bool) -> ArtemisVideo?)?

    /// Draws a layered message layer's text (headless rendering).
    public var drawMessageLayer: ((String, CGContext) -> Void)?

    /// `[lyrename id= to=]`: moves a layer (and its subtree, tweens and events) to a new id
    /// without reloading it.
    public func rename(_ id: String, to newID: String) {
        guard !id.isEmpty, !newID.isEmpty, id != newID, let moving = layer(id) else { return }
        let parentId = id.split(separator: ".").dropLast().joined(separator: ".")
        layer(parentId)?.children.removeAll { $0 === moving }
        deleteLayer(newID)
        func retag(_ node: ArtemisLayer) {
            node.id = newID + node.id.dropFirst(id.count)
            node.children.forEach(retag)
        }
        retag(moving)
        let newParentId = newID.split(separator: ".").dropLast().joined(separator: ".")
        let parent = ensureLayer(newParentId)
        parent.children.append(moving)
        parent.children.sort(by: ArtemisLayer.drawsBefore)
        func moved(_ key: String) -> String? {
            key == id ? newID : key.hasPrefix(id + ".") ? newID + key.dropFirst(id.count) : nil
        }
        tweens = tweens.map { tween in
            guard let key = moved(tween.layer) else { return tween }
            var copy = ArtemisTween(layer: key, property: tween.property, from: tween.from, to: tween.to, start: tween.start,
                                    duration: tween.duration, ease: tween.ease, loop: tween.loop, yoyo: tween.yoyo)
            copy.completion = tween.completion
            copy.deletesLayer = tween.deletesLayer
            return copy
        }
        for key in events.keys {
            if let target = moved(key) { events[target] = events.removeValue(forKey: key) }
        }
        videoLayers = Set(videoLayers.map { moved($0) ?? $0 })
    }

    /// `[lyc]`: (re)creates a layer's content from an image or a colour. Keeps children.
    public func create(_ tag: ArtemisTag) {
        guard let id = tag["id"] else { return }
        let layer = ensureLayer(id)
        // A fresh layer resets its properties, as recreating it in the engine does.
        layer.left = 0; layer.top = 0; layer.alpha = 255; layer.xscale = 100; layer.yscale = 100
        layer.rotate = 0; layer.anchorX = nil; layer.anchorY = nil; layer.visible = true
        layer.image = nil; layer.color = nil; layer.file = nil; layer.video = nil
        layer.reverseX = false; layer.reverseY = false; layer.clip = nil; layer.blendMode = "normal"
        layer.negative = false; layer.grayscale = false; layer.colorMultiply = 0xFFFFFF; layer.mask = nil
        layer.shader = nil; layer.intermediateRender = false
        layer.clickThreshold = nil; layer.draggable = false; layer.dragArea = nil; layer.anime = nil
        if let mask = tag["mask"], !mask.isEmpty { layer.mask = image(mask) }
        tweens.removeAll { $0.layer == id }
        if let file = tag["file"], !file.isEmpty {
            layer.file = file
            if let image = image(file) {
                layer.image = image
                layer.width = Double(image.width)
                layer.height = Double(image.height)
            }
        } else if let color = tag["color"] {
            layer.color = UInt32(color.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0xFF00_0000
            layer.width = tag.number("width", default: width)
            layer.height = tag.number("height", default: height)
        }
        if tag["width"] != nil, layer.image != nil { layer.width = tag.number("width") }
        if tag["height"] != nil, layer.image != nil { layer.height = tag.number("height") }
        apply(properties: tag, to: layer)
    }

    /// `[video id=...]`: makes the layer a video layer, sized to the video, showing its
    /// first frame. Keeps children, like `[lyc]`.
    public func createVideo(id: String, file: String, video: ArtemisVideo) {
        let layer = ensureLayer(id)
        layer.left = 0; layer.top = 0; layer.alpha = 255; layer.xscale = 100; layer.yscale = 100
        layer.rotate = 0; layer.anchorX = nil; layer.anchorY = nil; layer.visible = true
        layer.color = nil; layer.file = file
        tweens.removeAll { $0.layer == id }
        layer.video = video
        layer.width = Double(video.width)
        layer.height = Double(video.height)
        video.update(time: clock)
        layer.image = video.image
        videoLayers.insert(id)
        videoRevision += 1
    }

    /// While skipping, video layers hold their picture (decoding frames nobody sees would
    /// cost more than the skip); they pick up again afterwards.
    public var holdsVideoFrames = false

    /// Ids of layers that have had a video; pruned as they go.
    private var videoLayers: Set<String> = []
    /// Bumped when a video layer shows a new frame.
    public private(set) var videoRevision = 0
    /// The last `update(time:)`.
    private var clock: Double = 0

    /// Whether the video layer `id` is still playing (false once it ends or is deleted).
    public func isVideoPlaying(_ id: String) -> Bool {
        guard let video = layer(id)?.video else { return false }
        return !video.isFinished
    }

    /// `[lyprop]`
    public func setProperties(_ tag: ArtemisTag) {
        guard let id = tag["id"] else { return }
        apply(properties: tag, to: ensureLayer(id))
    }

    private func apply(properties tag: ArtemisTag, to layer: ArtemisLayer) {
        func numbers(_ key: String) -> [Double]? {
            tag[key].map { $0.split(separator: ",").compactMap { ArtemisValue.number(from: String($0)) } }
        }
        if let clip = numbers("clip") {
            if clip.count == 4 {
                layer.clip = CGRect(x: clip[0], y: clip[1], width: clip[2], height: clip[3])
                layer.width = clip[2]
                layer.height = clip[3]
            } else {
                layer.clip = nil
                if let image = layer.image { layer.width = Double(image.width); layer.height = Double(image.height) }
            }
        }
        if let mode = tag["layermode"] { layer.blendMode = mode.lowercased() }
        if let value = tag["negative"] { layer.negative = value == "1" }
        if let value = tag["grayscale"] { layer.grayscale = value == "1" }
        if let value = tag["colormultiply"] { layer.colorMultiply = ArtemisMessages.rgb(value) & 0xFFFFFF }
        if let name = tag["shader"] {
            // `shaderconstant` names the parameters the shader gets, each in its own attribute.
            let names = (tag["shaderconstant"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var values: [String: String] = [:]
            for key in names { values[key] = tag[key] }
            var textures: [String: String] = [:]
            for key in (tag["shadertexture"] ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                textures[key] = tag[key]
            }
            layer.shader = name.isEmpty || name == "reset" ? nil : ArtemisShader(name: name, values: values, textures: textures)
            shadersChanged = true
        }
        if let value = tag["intermediate_render"] { layer.intermediateRender = value == "1" }
        if let value = tag["clickablethreshold"] { layer.clickThreshold = ArtemisValue.number(from: value) }
        if let value = tag["draggable"] { layer.draggable = value == "1" }
        if let area = numbers("dragarea") { layer.dragArea = area.count == 4 ? CGRect(x: area[0], y: area[1], width: area[2] - area[0], height: area[3] - area[1]) : nil }
        for key in ["left", "top", "alpha", "xscale", "yscale", "rotate", "anchorx", "anchory", "visible", "reversex", "reversey"] {
            if let value = tag[key], let number = ArtemisValue.number(from: value) {
                layer.setProperty(key, number)
                // An explicit set stops tweens on that property.
                tweens.removeAll { $0.layer == layer.id && $0.property == key }
            }
        }
    }

    public func image(_ file: String) -> CGImage? {
        if let cached = imageCache[file] {
            cacheOrder.removeAll { $0 == file }
            cacheOrder.append(file)
            return cached
        }
        guard let image = loadImage(file) else { return nil }
        imageCache[file] = image
        cacheOrder.append(file)
        cacheBytes += image.bytesPerRow * image.height
        // Least recently used first; images still on screen stay alive through their layers.
        while cacheBytes > Self.cacheLimit, cacheOrder.count > 1 {
            let evicted = cacheOrder.removeFirst()
            if let old = imageCache.removeValue(forKey: evicted) { cacheBytes -= old.bytesPerRow * old.height }
        }
        return image
    }

    /// Decoded images kept for reuse (a few dozen full-screen backgrounds).
    static let cacheLimit = 256 << 20
    private var cacheOrder: [String] = []
    private var cacheBytes = 0

    // MARK: Tweens

    /// `[lytween]`. Returns when it ends (for `sync`).
    @discardableResult
    public func tween(_ tag: ArtemisTag, now: Double) -> Double {
        guard let id = tag["id"], let property = tag["param"] else { return now }
        let layer = ensureLayer(id)
        let from = tag["from"].flatMap { ArtemisValue.number(from: $0) } ?? layer.property(property) ?? 0
        let to = tag.number("to", default: from)
        let duration = tag.number("msec", default: tag.number("time"))
        let delay = tag.number("delay")
        let yoyoCount = Int(tag.number("yoyo"))
        let loop = yoyoCount != 0 ? yoyoCount : Int(tag.number("loop"))
        // In a [tweenset], each tween starts when the one before it ends.
        let start = (tweenSet.map { max($0.cursor, now) } ?? now) + delay
        if tweenSet == nil { tweens.removeAll { $0.layer == id && $0.property == property } }
        var tween = ArtemisTween(layer: id, property: property, from: from, to: to, start: start,
                                 duration: duration, ease: tag["ease"] ?? "none", loop: loop, yoyo: yoyoCount != 0)
        tween.loopDelay = tag.number("loopdelay")
        if tag["file"] != nil || tag["label"] != nil || tag["handler"] != nil { tween.completion = tag.attributes }
        tween.deletesLayer = tag["delete"] == "1"
        if let set = tweenSet {
            tween.group = set.group
            tweenSet?.cursor = tween.endTime
            if set.first { layer.setProperty(property, from) }
            tweenSet?.first = false
        } else {
            layer.setProperty(property, from)
        }
        tweens.append(tween)
        return tween.endTime
    }

    /// `[tweenset]` ... `[/tweenset]` in progress.
    private var tweenSet: (group: Int, cursor: Double, first: Bool)?
    private var nextTweenGroup = 1

    public func beginTweenSet(now: Double) {
        tweenSet = (nextTweenGroup, now, true)
        nextTweenGroup += 1
    }

    public func endTweenSet() {
        tweenSet = nil
    }

    /// `[lytweendel]`: completes the layer's tweens (they land on their end values), and
    /// the rest of any tween set they belong to.
    public func deleteTweens(_ tag: ArtemisTag) {
        let id = tag["id"]
        let property = tag["param"]
        let matching = tweens.filter { id == nil || ($0.layer == id && (property == nil || $0.property == property)) }
        let groups = Set(matching.compactMap(\.group))
        let done = tweens.filter { tween in matching.contains { $0.layer == tween.layer && $0.property == tween.property && $0.start == tween.start }
            || (tween.group.map(groups.contains) ?? false) }
        tweens.removeAll { tween in done.contains { $0.layer == tween.layer && $0.property == tween.property && $0.start == tween.start } }
        // Last tween per property decides the value.
        for tween in done.sorted(by: { $0.start < $1.start }) { layer(tween.layer)?.setProperty(tween.property, tween.endValue) }
        tweenRevision += 1
    }

    /// Bumped whenever a tween moved or finished: animated layers show immediately (the
    /// engine animates the visible screen), so presenters resync then.
    public private(set) var tweenRevision = 0

    /// Advances tweens to `time` (ms). Finished ones land on their end value.
    /// A shader was set or cleared since the last update; `shadersActive`: some layer has one.
    private var shadersChanged = false
    public private(set) var shadersActive = false
    func markShadersChanged() { shadersChanged = true }

    /// Hands each layer the shaders of the layers it sits in, nearest first. Walks the tree
    /// only while any shader is set (layers come and go under a tinted parent every scene).
    private func propagateShaders() {
        guard shadersChanged || shadersActive else { return }
        shadersChanged = false
        var active = false
        func visit(_ layer: ArtemisLayer, _ inherited: [ArtemisShader]) {
            if layer.inheritedShaders != inherited { layer.inheritedShaders = inherited }
            let own = layer.shader.map { [$0] + inherited } ?? inherited
            if layer.shader != nil { active = true }
            for child in layer.children { visit(child, own) }
        }
        visit(root, [])
        shadersActive = active
    }

    public func update(time: Double) {
        propagateShaders()
        clock = time
        for id in videoLayers where !holdsVideoFrames {
            guard let layer = layer(id), let video = layer.video else {
                videoLayers.remove(id)
                continue
            }
            if video.update(time: time) {
                layer.image = video.image
                videoRevision += 1
            }
        }
        if !tweens.isEmpty { tweenRevision += 1 }
        updateAnime(time: time)
        var remaining: [ArtemisTween] = []
        var deleted: [String] = []
        for tween in tweens {
            guard let layer = layer(tween.layer) else { continue }
            // A tween set's later tweens wait their turn without touching the layer.
            if tween.group != nil, time < tween.start {
                remaining.append(tween)
                continue
            }
            let (value, finished) = tween.value(at: time)
            layer.setProperty(tween.property, value)
            if !finished {
                remaining.append(tween)
            } else {
                if tween.deletesLayer { deleted.append(tween.layer) }
                if let completion = tween.completion { finishedHandlers.append(completion) }
            }
        }
        // A finished tween's set-mates go with it when its layer goes.
        tweens = remaining
        deleted.forEach(deleteLayer)
    }

    // MARK: Anime

    /// `[anime id= mode=init|add|end ...]`.
    public func anime(_ tag: ArtemisTag, now: Double) {
        guard let id = tag["id"] else { return }
        switch tag["mode"] ?? "init" {
        case "init":
            let layer = ensureLayer(id)
            layer.left = 0; layer.top = 0; layer.alpha = 255; layer.xscale = 100; layer.yscale = 100
            layer.rotate = 0; layer.visible = true; layer.color = nil
            var anime = ArtemisAnime()
            anime.loop = tag["loop"].flatMap { Int(ArtemisValue.number(from: $0) ?? -1) } ?? -1
            anime.frames = [frame(tag, time: 0)]
            layer.anime = anime
            if let image = anime.frames[0].image {
                layer.image = image
                layer.file = anime.frames[0].file
                layer.width = Double(image.width)
                layer.height = Double(image.height)
            }
            if let mask = tag["mask"] { layer.mask = image(mask) }
            animeLayers.insert(id)
        case "add":
            layer(id)?.anime?.frames.append(frame(tag, time: tag.number("time")))
        case "end":
            guard let layer = layer(id), var anime = layer.anime else { return }
            anime.endTime = max(tag.number("time"), (anime.frames.last?.time ?? 0) + 1)
            anime.started = now
            layer.anime = anime
        default:
            break
        }
    }

    private var animeLayers: Set<String> = []

    /// Every frame of the flip-books on the stage (to prepare ahead of showing them).
    public var animeFrameImages: [CGImage] {
        animeLayers.compactMap { layer($0) }.filter { $0.mask == nil }
            .flatMap { $0.anime?.frames.compactMap(\.image) ?? [] }
    }

    private func frame(_ tag: ArtemisTag, time: Double) -> ArtemisAnime.Frame {
        var properties = tag.attributes
        for key in ["id", "mode", "file", "mask", "time", "loop"] { properties[key] = nil }
        let file = tag["file"] ?? ""
        return ArtemisAnime.Frame(time: time, file: file, image: file.isEmpty ? nil : image(file), properties: properties)
    }

    private func updateAnime(time: Double) {
        for id in animeLayers {
            guard let layer = layer(id), var anime = layer.anime else {
                animeLayers.remove(id)
                continue
            }
            guard let end = anime.endTime, end > 0 else { continue }
            var elapsed = time - anime.started
            let cycle = Int(floor(elapsed / end))
            let plays = anime.loop < 0 ? Int.max : max(1, anime.loop)
            if cycle >= plays { elapsed = end - 0.001 } else { elapsed -= Double(cycle) * end }
            let index = anime.frames.lastIndex { $0.time <= elapsed } ?? 0
            guard index != anime.shownFrame else { continue }
            anime.shownFrame = index
            layer.anime = anime
            let frame = anime.frames[index]
            if let image = frame.image {
                layer.image = image
                layer.file = frame.file
            }
            if !frame.properties.isEmpty {
                apply(properties: ArtemisTag(name: "lyprop", attributes: frame.properties, order: Array(frame.properties.keys)), to: layer)
            }
            tweenRevision += 1
        }
    }

    // MARK: lyedit

    /// `[lyedit]`: bakes an effect into the layer's image.
    public func edit(_ tag: ArtemisTag) {
        guard let id = tag["id"], let layer = layer(id), let source = layer.image else { return }
        let color = ArtemisMessages.rgb(tag["color"] ?? "FFFFFF")
        let r = CGFloat((color >> 16) & 0xFF) / 255, g = CGFloat((color >> 8) & 0xFF) / 255, b = CGFloat(color & 0xFF) / 255
        var output: CGImage?
        switch tag["mode"] {
        case "negative":
            output = ArtemisLayer.process(source, negative: true, grayscale: false, multiply: 0xFFFFFF, mask: nil)
        case "gray":
            output = ArtemisLayer.process(source, negative: false, grayscale: true, multiply: 0xFFFFFF, mask: nil)
        case "sepia":
            output = ArtemisLayer.filtered(source) { $0.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1]) }
        case "multiply":
            output = ArtemisLayer.process(source, negative: false, grayscale: false, multiply: color & 0xFFFFFF, mask: nil)
        case "add":
            output = ArtemisLayer.filtered(source) {
                $0.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: r, y: g, z: b, w: 0)])
            }
        case "blend":
            guard let file = tag["file"], let overlay = image(file) else { return }
            let w = source.width, h = source.height
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            let left = tag.number("left"), top = tag.number("top")
            context.draw(overlay, in: CGRect(x: left, y: Double(h) - top - Double(overlay.height),
                                             width: Double(overlay.width), height: Double(overlay.height)))
            output = context.makeImage()
        default:
            break
        }
        if let output {
            layer.image = output
            tweenRevision += 1
        }
    }

    /// Completion handlers of tweens that finished, for the player to run.
    private var finishedHandlers: [[String: String]] = []

    public func takeFinishedHandlers() -> [[String: String]] {
        defer { finishedHandlers.removeAll() }
        return finishedHandlers
    }

    // MARK: Presenting

    public func present(transition tag: ArtemisTag?) {
        presentationCount += 1
        if let tag {
            lastTransition = (tag["type"] ?? "1", tag.number("time"), tag["rule"], tag.number("vague", default: 32))
        } else {
            lastTransition = nil
        }
    }

    // MARK: Events

    /// `[lyevent]` / `[lyevent_enable]` / `[lyevent_disable]`.
    public func event(_ tag: ArtemisTag, enable: Bool? = nil) {
        guard let id = tag["id"] else { return }
        let type = tag["type"] ?? "click"
        let mode = enable.map { $0 ? "enable" : "disable" } ?? tag["mode"] ?? "init"
        switch mode {
        case "init":
            var attributes = tag.attributes
            attributes["id"] = nil
            attributes["type"] = nil
            attributes["mode"] = nil
            events[id, default: [:]][type] = ArtemisLayerEvent(attributes: attributes)
        case "enable", "disable":
            let on = mode == "enable"
            if tag["mode"] == "all" || enable != nil {
                // Every event on this layer and below.
                for key in events.keys where key == id || key.hasPrefix(id + ".") {
                    for kind in events[key]!.keys { events[key]![kind]!.enabled = on }
                }
            } else {
                events[id]?[type]?.enabled = on
            }
        case "reset", "delete":
            events[id]?[type] = nil
        default:
            break
        }
    }

    func savedEvents() -> [String: [String: [String: String]]] {
        events.mapValues { $0.mapValues { event in
            var attributes = event.attributes
            attributes["__enabled"] = event.enabled ? "1" : "0"
            return attributes
        } }
    }

    func restoreEvents(_ saved: [String: [String: [String: String]]]) {
        events = saved.mapValues { $0.mapValues { attributes in
            var attributes = attributes
            let enabled = attributes.removeValue(forKey: "__enabled") != "0"
            return ArtemisLayerEvent(attributes: attributes, enabled: enabled)
        } }
        tweens.removeAll()
    }

    /// The topmost visible layer with an enabled event of `type` under `point`.
    public func eventTarget(at point: CGPoint, type: String) -> String? {
        var result: String?
        func visit(_ layer: ArtemisLayer, _ transform: CGAffineTransform) {
            guard layer.visible else { return }
            let combined = layer.transform.concatenating(transform)
            if let event = events[layer.id]?[type], event.enabled {
                let local = point.applying(combined.inverted())
                if hits(layer, local) { result = layer.id }
            }
            for child in layer.children { visit(child, combined) }
        }
        for child in root.children { visit(child, .identity) }
        return result
    }

    private func hits(_ layer: ArtemisLayer, _ local: CGPoint) -> Bool {
        guard local.x >= 0, local.y >= 0, local.x < layer.width, local.y < layer.height else { return false }
        if let threshold = layer.clickThreshold { return layer.alpha(at: local) >= threshold }
        return true
    }

    /// The topmost visible draggable layer under `point` (`lyprop draggable=1`).
    public func draggableLayer(at point: CGPoint) -> ArtemisLayer? {
        var result: ArtemisLayer?
        func visit(_ layer: ArtemisLayer, _ transform: CGAffineTransform) {
            guard layer.visible else { return }
            let combined = layer.transform.concatenating(transform)
            if layer.draggable, hits(layer, point.applying(combined.inverted())) { result = layer }
            for child in layer.children { visit(child, combined) }
        }
        for child in root.children { visit(child, .identity) }
        return result
    }

    /// Moves a dragged layer by a stage-pixel delta, kept inside its drag area; the screen
    /// follows at once.
    public func drag(_ layer: ArtemisLayer, by delta: CGSize) {
        layer.left += delta.width
        layer.top += delta.height
        if let area = layer.dragArea {
            layer.left = min(max(layer.left, area.minX), max(area.minX, area.maxX - layer.width))
            layer.top = min(max(layer.top, area.minY), max(area.minY, area.maxY - layer.height))
        }
        tweenRevision += 1
    }

    /// Where the visible layers with an enabled event of one of `types` are (stage pixels),
    /// for moving a keyboard or controller focus between buttons.
    public func eventFrames(types: Set<String>) -> [CGRect] {
        var result: [CGRect] = []
        func visit(_ layer: ArtemisLayer, _ transform: CGAffineTransform) {
            guard layer.visible else { return }
            let combined = layer.transform.concatenating(transform)
            if layer.width > 0, layer.height > 0,
               events[layer.id]?.contains(where: { types.contains($0.key) && $0.value.enabled }) == true {
                result.append(CGRect(x: 0, y: 0, width: layer.width, height: layer.height).applying(combined))
            }
            for child in layer.children { visit(child, combined) }
        }
        for child in root.children { visit(child, .identity) }
        return result
    }

    /// The topmost visible layer with an enabled click event under `point` (stage pixels).
    public func clickTarget(at point: CGPoint) -> (layer: String, event: ArtemisLayerEvent)? {
        var result: (String, ArtemisLayerEvent)?
        func visit(_ layer: ArtemisLayer, _ transform: CGAffineTransform, _ opacity: Double) {
            guard layer.visible else { return }
            let combined = layer.transform.concatenating(transform)
            let alpha = opacity * layer.alpha / 255
            if let event = events[layer.id]?["click"], event.enabled, alpha > 0 || events[layer.id]?["click"] != nil {
                let local = point.applying(combined.inverted())
                if hits(layer, local) { result = (layer.id, event) }
            }
            for child in layer.children { visit(child, combined, alpha) }
        }
        for child in root.children { visit(child, .identity, 1) }
        return result
    }

    /// `[var system="get_layer_info"]`: li.<id>.left/top/width/height/... (style=map), or
    /// li.size and li.<n>.id/... as a list.
    public func layerInfo(style: String?) -> [String: String] {
        var all: [ArtemisLayer] = []
        func collect(_ layer: ArtemisLayer) {
            all.append(layer)
            layer.children.forEach(collect)
        }
        root.children.forEach(collect)
        var result: [String: String] = [:]
        for (index, layer) in all.enumerated() {
            let key = style == "map" ? layer.id : String(index)
            let fields: [(String, Double)] = [
                ("left", layer.left), ("top", layer.top), ("width", layer.width), ("height", layer.height),
                ("alpha", layer.alpha), ("xscale", layer.xscale), ("yscale", layer.yscale), ("rotate", layer.rotate),
                ("anchorx", layer.effectiveAnchorX), ("anchory", layer.effectiveAnchorY), ("visible", layer.visible ? 1 : 0),
            ]
            for (name, value) in fields { result["\(key).\(name)"] = ArtemisValue.format(value) }
            result["\(key).id"] = layer.id
            result["\(key).reversex"] = layer.reverseX ? "1" : "0"
            result["\(key).reversey"] = layer.reverseY ? "1" : "0"
            if let image = layer.image {
                result["\(key).surfacewidth"] = String(image.width)
                result["\(key).surfaceheight"] = String(image.height)
            }
            if let clip = layer.clip {
                result["\(key).clip"] = [clip.minX, clip.minY, clip.width, clip.height].map(ArtemisValue.format).joined(separator: ",")
            }
        }
        result["size"] = String(all.count)
        return result
    }

    // MARK: Drawing

    /// Renders the stage into a bitmap (headless snapshots; the iOS player draws with layers).
    public func render(scale: Double = 1) -> CGImage? {
        let w = Int(width * scale), h = Int(height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Stage coordinates are top-left origin.
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        func draw(_ layer: ArtemisLayer, opacity: Double) {
            guard layer.visible else { return }
            let alpha = opacity * layer.alpha / 255
            context.saveGState()
            context.concatenate(layer.transform)
            context.setAlpha(alpha)
            let rect = CGRect(x: 0, y: 0, width: layer.width, height: layer.height)
            if let color = layer.color {
                let a = Double((color >> 24) & 0xFF) / 255, r = Double((color >> 16) & 0xFF) / 255
                let g = Double((color >> 8) & 0xFF) / 255, b = Double(color & 0xFF) / 255
                context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
                context.fill(rect)
            }
            if let image = layer.displayImage {
                context.saveGState()
                switch layer.blendMode {
                case "add": context.setBlendMode(.plusLighter)
                case "screen": context.setBlendMode(.screen)
                case "multiply": context.setBlendMode(.multiply)
                default: break
                }
                context.clip(to: rect)
                let clip = layer.clip ?? rect
                let full = CGRect(x: -clip.minX, y: -clip.minY, width: Double(image.width), height: Double(image.height))
                context.translateBy(x: 0, y: full.height + 2 * full.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: full)
                context.restoreGState()
            }
            if let id = layer.messageLayer { drawMessageLayer?(id, context) }
            for child in layer.children { draw(child, opacity: alpha) }
            context.restoreGState()
        }
        for child in root.children { draw(child, opacity: 1) }
        return context.makeImage()
    }
}

/// Decodes an image file's bytes (PNG, JPEG, BMP, ...).
public func decodeImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
