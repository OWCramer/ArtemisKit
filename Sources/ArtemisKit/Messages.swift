import CoreGraphics
import CoreText
import Foundation

/// Artemis message layers: named text areas (`adv`, `novel`, `name`, ...) chosen with
/// `[chgmsg id=...]`, laid out by `[font ...]`, filled by prose and `[print]`, cleared by `[rp]`.
public final class ArtemisMessages {
    public struct Font: Equatable, Codable {
        public var face: String?
        public var left: Double = 0
        public var top: Double = 0
        public var width: Double = 800
        public var height: Double = 200
        public var size: Double = 28
        public var color: UInt32 = 0xFFFFFF
        public var shadowColor: UInt32 = 0x000000
        public var outlineColor: UInt32 = 0x000000
        public var outline = false
        public var shadow = false
        public var kerning: Double = 0
        /// Gap between the ruby and the text (Artemis `spacemiddle`).
        public var lineSpacing: Double = 0
        /// Gap above the ruby (`spacetop`) and below the text (`spacebottom`).
        public var spaceTop: Double = 0
        public var spaceBottom: Double = 0
        /// Ruby band height (`rubysize`); reserved above every line, ruby or not.
        public var rubySize: Double = 0
        /// left, center or right (`equalize` lays out as left).
        public var align = "left"

        public init() {}

        /// Saves from before a field existed still load, with its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            face = try c.decodeIfPresent(String.self, forKey: .face)
            left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 0
            top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 800
            height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 200
            size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 28
            color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? 0xFFFFFF
            shadowColor = try c.decodeIfPresent(UInt32.self, forKey: .shadowColor) ?? 0
            outlineColor = try c.decodeIfPresent(UInt32.self, forKey: .outlineColor) ?? 0
            outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? false
            shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
            kerning = try c.decodeIfPresent(Double.self, forKey: .kerning) ?? 0
            lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0
            spaceTop = try c.decodeIfPresent(Double.self, forKey: .spaceTop) ?? 0
            spaceBottom = try c.decodeIfPresent(Double.self, forKey: .spaceBottom) ?? 0
            rubySize = try c.decodeIfPresent(Double.self, forKey: .rubySize) ?? 0
            align = try c.decodeIfPresent(String.self, forKey: .align) ?? "left"
        }

        /// Height of one line: ruby band and gaps (font.txt) around the text row, which is
        /// the font's own line height (ascent + descent + leading). Measured against the
        /// PC build's screenshots: Memory's Dogma's baselines land where this puts them.
        func linePitch(textHeight: Double) -> Double {
            let pitch = spaceTop + rubySize + lineSpacing + textHeight + spaceBottom
            return pitch > 0 ? pitch : textHeight
        }
    }

    public final class Layer {
        public let id: String
        public var font = Font()
        public var text = ""
        public var visible = true
        /// `[sceout]`: the page is hidden but kept, until `[scein]` (or a new page).
        public var pageHidden = false
        /// Characters revealed so far (typewriter); `text.count` when complete.
        public var revealed: Double = 0
        /// Milliseconds per character (`[scetween mode=add type=in delay=...]`); 0 = instant.
        public var charDelay: Double = 30
        public var isRevealing: Bool { revealed < Double(text.count) }
        /// Bumped whenever the rendered text would change.
        public internal(set) var revision = 0

        init(id: String) { self.id = id }
    }

    public private(set) var layers: [String: Layer] = [:]
    private var stack: [String] = []
    public private(set) var current = "default"
    /// Bumped on any change, so presenters can redraw.
    public private(set) var revision = 0
    public var defaultFont = Font()

    public init() {}

    public func layer(_ id: String) -> Layer {
        if let layer = layers[id] { return layer }
        let layer = Layer(id: id)
        layer.font = defaultFont
        layers[id] = layer
        return layer
    }

    public var currentLayer: Layer { layer(current) }

    var stackSnapshot: [String] { stack }

    func resetLayers() {
        layers.removeAll()
        stack.removeAll()
        current = "default"
        revision += 1
    }

    func restoreStack(current: String, stack: [String]) {
        self.current = current
        self.stack = stack
        revision += 1
    }

    /// `[chgmsg id=...]` (pushes) and `[/chgmsg]` (pops).
    /// `stack="0"` switches without remembering the previous layer.
    public func change(to id: String?, push: Bool = true) {
        if let id {
            if push { stack.append(current) }
            current = id
            _ = layer(id)
        } else if let previous = stack.popLast() {
            current = previous
        }
    }

    public func setFont(_ tag: ArtemisTag, defaults: Bool = false) {
        var font = defaults ? defaultFont : currentLayer.font
        if let face = tag["face"] { font.face = face }
        font.left = tag.number("left", default: font.left)
        font.top = tag.number("top", default: font.top)
        font.width = tag.number("width", default: font.width)
        font.height = tag.number("height", default: font.height)
        font.size = tag.number("size", default: font.size)
        font.kerning = tag.number("kerning", default: font.kerning)
        font.lineSpacing = tag.number("spacemiddle", default: font.lineSpacing)
        font.spaceTop = tag.number("spacetop", default: font.spaceTop)
        font.spaceBottom = tag.number("spacebottom", default: font.spaceBottom)
        font.rubySize = tag.number("rubysize", default: font.rubySize)
        if let align = tag["align"] { font.align = align.lowercased() }
        if let color = tag["color"] { font.color = Self.rgb(color) }
        if let color = tag["shadowcolor"] { font.shadowColor = Self.rgb(color) }
        if let color = tag["outlinecolor"] { font.outlineColor = Self.rgb(color) }
        if let style = tag["style"] {
            font.outline = style.contains("outline")
            font.shadow = style.contains("shadow")
        }
        if defaults {
            defaultFont = font
        } else {
            currentLayer.font = font
            touch(currentLayer)
        }
    }

    public func append(_ text: String) {
        let layer = currentLayer
        layer.text += text
        touch(layer)
    }

    public func clear(_ id: String? = nil) {
        let layer = id.map(self.layer) ?? currentLayer
        guard !layer.text.isEmpty || layer.pageHidden else { return }
        layer.text = ""
        layer.revealed = 0
        layer.pageHidden = false
        touch(layer)
    }

    /// `[sceout]` / `[scein]` on the current layer.
    public func setPageHidden(_ hidden: Bool) {
        let layer = currentLayer
        guard layer.pageHidden != hidden else { return }
        layer.pageHidden = hidden
        touch(layer)
    }

    /// Advances every layer's reveal by `ms`. Returns whether anything is still revealing.
    @discardableResult
    func advanceReveal(by ms: Double, instant: Bool) -> Bool {
        var revealing = false
        for layer in layers.values where layer.isRevealing {
            if instant || layer.charDelay <= 0 {
                layer.revealed = Double(layer.text.count)
            } else {
                layer.revealed = min(Double(layer.text.count), layer.revealed + ms / layer.charDelay)
            }
            revealing = revealing || layer.isRevealing
        }
        return revealing
    }

    public var isRevealing: Bool { layers.values.contains { $0.isRevealing && $0.visible && !$0.pageHidden } }

    func revealAll() { advanceReveal(by: 0, instant: true) }

    private func touch(_ layer: Layer) {
        layer.revision += 1
        revision += 1
    }

    static func rgb(_ text: String) -> UInt32 {
        UInt32(text.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0xFFFFFF
    }
}

/// Draws message text with the game's own fonts (registered from its files).
public final class ArtemisTextRenderer {
    private var fonts: [String: CTFontDescriptor] = [:]
    private let fontData: (String) -> Data?

    public init(fontData: @escaping (String) -> Data?) {
        self.fontData = fontData
    }

    private func font(_ spec: ArtemisMessages.Font) -> CTFont {
        if let face = spec.face {
            let key = face
            if fonts[key] == nil {
                for candidate in [face, face + ".ttf", face + ".otf", face + ".ttc"] {
                    if let data = fontData(candidate),
                       let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
                        fonts[key] = descriptor
                        break
                    }
                }
            }
            if let descriptor = fonts[key] { return CTFontCreateWithFontDescriptor(descriptor, spec.size, nil) }
        }
        return CTFontCreateWithName("Hiragino Sans" as CFString, spec.size, nil)
    }

    /// One laid-out line: where it starts (stage pixels, top-left origin) and its text.
    private struct Line {
        let line: CTLine
        /// Left edge and top of the line's box (ruby band included).
        let x: Double
        let top: Double
        let pitch: Double
        let baseline: Double
        let range: CFRange
        let width: Double
    }

    /// Lays text out the engine's way: wrapped to `width`, every line `linePitch` tall,
    /// glyphs under a ruby band, aligned left, centre or right.
    private func layout(_ text: String, spec: ArtemisMessages.Font, attributes: [NSAttributedString.Key: Any]) -> [Line] {
        let ctFont = font(spec)
        let string = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = (text as NSString).length
        let ascent = CTFontGetAscent(ctFont)
        let textHeight = ascent + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        let pitch = spec.linePitch(textHeight: textHeight)
        var lines: [Line] = []
        var start = 0
        var index = 0
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, max(1, spec.width)))
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(typesetter, range)
            // Trailing newlines and spaces don't count towards alignment.
            let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
            let x: Double
            switch spec.align {
            case "center": x = spec.left + (spec.width - width) / 2
            case "right": x = spec.left + spec.width - width
            default: x = spec.left
            }
            let top = spec.top + Double(index) * pitch
            let textTop = top + spec.spaceTop + spec.rubySize + spec.lineSpacing
            lines.append(Line(line: line, x: x, top: top, pitch: pitch, baseline: textTop + ascent, range: range, width: width))
            start += count
            index += 1
        }
        return lines
    }

    private func attributes(_ spec: ArtemisMessages.Font, fill: CGColor?, strokeWidth: Double?, strokeColor: CGColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(spec),
            NSAttributedString.Key(kCTKernAttributeName as String): spec.kerning,
        ]
        if let fill { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = fill }
        if let strokeWidth, let strokeColor {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
        }
        return attributes
    }

    /// Draws `layer`'s text into `context` (top-left origin, stage pixels).
    public func draw(_ layer: ArtemisMessages.Layer, in context: CGContext) {
        guard layer.visible, !layer.pageHidden, !layer.text.isEmpty else { return }
        let spec = layer.font
        func color(_ rgb: UInt32) -> CGColor {
            CGColor(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: 1)
        }
        func pass(_ attributes: [NSAttributedString.Key: Any], offset: CGSize) {
            for line in layout(layer.text, spec: spec, attributes: attributes) {
                context.saveGState()
                // CoreText draws bottom-up: flip around each line's baseline.
                context.translateBy(x: line.x + offset.width, y: line.baseline + offset.height)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line.line, context)
                context.restoreGState()
            }
        }
        if spec.shadow {
            pass(attributes(spec, fill: color(spec.shadowColor), strokeWidth: spec.outline ? -18 : nil, strokeColor: color(spec.shadowColor)),
                 offset: CGSize(width: 2, height: 2))
        }
        if spec.outline {
            pass(attributes(spec, fill: color(spec.outlineColor), strokeWidth: 18, strokeColor: color(spec.outlineColor)), offset: .zero)
        }
        pass(attributes(spec, fill: color(spec.color), strokeWidth: nil, strokeColor: nil), offset: .zero)
    }

    /// Rectangles (stage pixels, top-left origin) covering the first `count` characters, for
    /// revealing text gradually with a mask over a fully drawn line.
    public func revealRects(for layer: ArtemisMessages.Layer, count: Int) -> [CGRect] {
        let spec = layer.font
        let target = utf16Offset(layer.text, characters: count)
        var rects: [CGRect] = []
        for line in layout(layer.text, spec: spec, attributes: attributes(spec, fill: nil, strokeWidth: nil, strokeColor: nil)) {
            guard line.range.location < target else { break }
            let end = min(target, line.range.location + line.range.length)
            let x = end >= line.range.location + line.range.length ? line.width
                : CTLineGetOffsetForStringIndex(line.line, end, nil)
            // Generous margins so outlines and shadows aren't clipped.
            rects.append(CGRect(x: line.x - 8, y: line.top - 6, width: x + 16, height: line.pitch + 12))
        }
        return rects
    }

    private func utf16Offset(_ text: String, characters: Int) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(characters, text.count))
        return text[..<index].utf16.count
    }

    /// The layer's text as a transparent stage-sized image (for presenters that composite).
    public func image(for layer: ArtemisMessages.Layer, stageWidth: Double, stageHeight: Double, scale: Double = 1) -> CGImage? {
        let w = Int(stageWidth * scale), h = Int(stageHeight * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        draw(layer, in: context)
        return context.makeImage()
    }
}
