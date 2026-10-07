import CoreGraphics
import Foundation
import ImageIO

/// One Artemis layer. Ids are dotted paths (`100.1.2` sits inside `100.1`, inside `100`);
/// siblings draw in numeric id order. Positions are in stage pixels relative to the parent.
public final class ArtemisLayer {
    public let id: String
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
            .scaledBy(x: xscale / 100, y: yscale / 100)
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
    /// 0 = once; otherwise repeats (-1 forever), alternating when yoyo.
    public let loop: Int
    public let yoyo: Bool

    func value(at time: Double) -> (value: Double, finished: Bool) {
        guard duration > 0 else { return (to, time >= start) }
        var t = (time - start) / duration
        if t < 0 { return (from, false) }
        var finished = false
        if loop == 0 {
            if t >= 1 { t = 1; finished = true }
        } else {
            let cycle = floor(t)
            if loop > 0, cycle >= Double(loop) { t = 1; finished = true } else {
                t -= cycle
                if yoyo, Int(cycle) % 2 == 1 { t = 1 - t }
            }
        }
        if yoyo, loop == 0 { t = t < 0.5 ? t * 2 : (1 - t) * 2 }
        return (from + (to - from) * ArtemisTween.eased(t, ease), finished)
    }

    static func eased(_ t: Double, _ ease: String) -> Double {
        switch ease.lowercased() {
        case "in", "easein", "in_quad", "quad_in": return t * t
        case "out", "easeout", "out_quad", "quad_out": return t * (2 - t)
        case "inout", "easeinout", "in_out", "inout_quad": return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
        default: return t
        }
    }
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
    public private(set) var lastTransition: (type: String, duration: Double, rule: String?)?

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

    /// `[lyc]`: (re)creates a layer's content from an image or a colour. Keeps children.
    public func create(_ tag: ArtemisTag) {
        guard let id = tag["id"] else { return }
        let layer = ensureLayer(id)
        // A fresh layer resets its properties, as recreating it in the engine does.
        layer.left = 0; layer.top = 0; layer.alpha = 255; layer.xscale = 100; layer.yscale = 100
        layer.rotate = 0; layer.anchorX = nil; layer.anchorY = nil; layer.visible = true
        layer.image = nil; layer.color = nil; layer.file = nil
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

    /// `[lyprop]`
    public func setProperties(_ tag: ArtemisTag) {
        guard let id = tag["id"] else { return }
        apply(properties: tag, to: ensureLayer(id))
    }

    private func apply(properties tag: ArtemisTag, to layer: ArtemisLayer) {
        for key in ["left", "top", "alpha", "xscale", "yscale", "rotate", "anchorx", "anchory", "visible"] {
            if let value = tag[key], let number = ArtemisValue.number(from: value) {
                layer.setProperty(key, number)
                // An explicit set stops tweens on that property.
                tweens.removeAll { $0.layer == layer.id && $0.property == key }
            }
        }
    }

    func image(_ file: String) -> CGImage? {
        if let cached = imageCache[file] { return cached }
        guard let image = loadImage(file) else { return nil }
        imageCache[file] = image
        return image
    }

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
        let loop = Int(tag.number("loop"))
        tweens.removeAll { $0.layer == id && $0.property == property }
        let tween = ArtemisTween(layer: id, property: property, from: from, to: to, start: now + delay,
                                 duration: duration, ease: tag["ease"] ?? "none", loop: loop, yoyo: tag["yoyo"] == "1")
        tweens.append(tween)
        layer.setProperty(property, from)
        return loop == 0 ? now + delay + duration : .infinity
    }

    public func deleteTweens(_ tag: ArtemisTag) {
        guard let id = tag["id"] else { tweens.removeAll(); return }
        let property = tag["param"]
        tweens.removeAll { $0.layer == id && (property == nil || $0.property == property) }
    }

    /// Bumped whenever a tween moved or finished: animated layers show immediately (the
    /// engine animates the visible screen), so presenters resync then.
    public private(set) var tweenRevision = 0

    /// Advances tweens to `time` (ms). Finished ones land on their end value.
    public func update(time: Double) {
        if !tweens.isEmpty { tweenRevision += 1 }
        var remaining: [ArtemisTween] = []
        for tween in tweens {
            guard let layer = layer(tween.layer) else { continue }
            let (value, finished) = tween.value(at: time)
            layer.setProperty(tween.property, value)
            if !finished { remaining.append(tween) }
        }
        tweens = remaining
    }

    // MARK: Presenting

    public func present(transition tag: ArtemisTag?) {
        presentationCount += 1
        if let tag {
            lastTransition = (tag["type"] ?? "1", tag.number("time"), tag["rule"])
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
                if local.x >= 0, local.y >= 0, local.x < layer.width, local.y < layer.height { result = layer.id }
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
                if local.x >= 0, local.y >= 0, local.x < layer.width, local.y < layer.height { result = (layer.id, event) }
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
            if let image = layer.image {
                context.saveGState()
                context.translateBy(x: 0, y: rect.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: rect)
                context.restoreGState()
            }
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
